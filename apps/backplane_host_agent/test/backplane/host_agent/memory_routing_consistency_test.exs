defmodule Backplane.HostAgent.MemoryRoutingConsistencyTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.HostAgent.{Memory, MemoryFacade, MemoryProxy, MemoryRouter}
  alias Backplane.HostAgent.Memory.{Migrator, Mirror, Store, Syncer}
  alias Backplane.HostAgent.Memory.Edge
  alias Turso.Result

  @moduletag :tmp_dir
  @partition %{
    "memory_space_id" => "space-authorized",
    "scope" => "proj_local",
    "namespace" => "private"
  }

  defmodule ConnectedHub do
    def call_tool(name, args), do: {:ok, %{"bypassed" => name, "arguments" => args}}
    def list_tools, do: {:ok, []}
  end

  defmodule Channel do
    @partition %{
      "memory_space_id" => "space-authorized",
      "scope" => "proj_local",
      "namespace" => "private"
    }
    def push(owner, "memory_sync", payload, _timeout \\ 5_000) do
      send(owner, {:upload, payload})
      if callback = Process.get(:before_memory_ack), do: callback.(payload)

      {:ok,
       %{
         "items" =>
           Enum.map(payload["items"], fn item ->
             %{
               "id" => item["id"],
               "status" => "ok",
               "canonical_id" => item["canonical_id"] || "canonical-" <> item["id"],
               "revision" => 7,
               "partition" => @partition
             }
           end)
       }}
    end
  end

  defmodule InvalidBindingChannel do
    def push(owner, "memory_sync", payload, timeout \\ 5_000) do
      {:ok, reply} = Channel.push(owner, "memory_sync", payload, timeout)
      field = Process.get(:invalid_ack_field)

      items =
        Enum.map(reply["items"], fn ack ->
          case field do
            :partition -> put_in(ack, ["partition", "memory_space_id"], "foreign")
            :canonical_id -> Map.put(ack, "canonical_id", "foreign-id")
          end
        end)

      {:ok, Map.put(reply, "items", items)}
    end
  end

  defmodule RejectedChannel do
    def push(_owner, "memory_sync", payload, _timeout \\ 5_000) do
      {:ok,
       %{
         "items" =>
           Enum.map(
             payload["items"],
             &%{"id" => &1["id"], "status" => "error", "error" => "partition revoked"}
           )
       }}
    end
  end

  defmodule Disconnected do
    def call(_method, _args, _opts), do: {:error, :not_connected}
  end

  defmodule CursorMirror do
    def offline_read(_method, _args, _opts), do: {:ok, Process.get(__MODULE__)}
  end

  defmodule Online do
    def call("list", _args, _opts),
      do: {:ok, %{"results" => [%{"id" => "online-id", "content" => "online memory"}]}}
  end

  setup %{tmp_dir: dir} do
    name = :"routing_consistency_#{System.unique_integer([:positive])}"
    start_supervised!({Store, database: Path.join(dir, "commands.db"), name: name, pool_size: 1})
    :ok = Migrator.migrate(name)
    MemoryProxy.set_channel(nil)
    Application.put_env(:backplane_host_agent, :memory_store, name)
    Application.put_env(:backplane_host_agent, :memory_config, %{bound_scope: "proj_local"})
    Application.put_env(:backplane_host_agent, :hub_proxy_module, ConnectedHub)

    on_exit(fn ->
      for key <- [:memory_store, :memory_config, :hub_proxy_module] do
        Application.delete_env(:backplane_host_agent, key)
      end

      MemoryProxy.set_channel(nil)
    end)

    {:ok,
     store: name, opts: [store: name, config: %{bound_scope: "proj_local"}, agent_id: "agent-1"]}
  end

  test "connected direct and MCP writes durably stage the same command", %{store: store} do
    args = %{"content" => "connected durable write", "idempotency_key" => "logical-write"}
    direct = request("/memory/agent-1/call/remember", args)
    assert %{"ok" => true, "result" => %{"id" => id, "authority" => "provisional"}} = direct

    mcp =
      request("/memory/agent-1/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "memory::remember", "arguments" => args}
      })

    assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} = mcp
    assert %{"id" => ^id, "consistency" => "pending_canonical_ack"} = Jason.decode!(text)

    assert {:ok, %Result{rows: [%{"count" => 1}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM memory_outbox")
  end

  test "remember preserves advertised fields through durable retry and upload", %{
    store: store,
    opts: opts
  } do
    args = %{
      "content" => "typed durable command",
      "type" => "procedural",
      "facets" => [%{"dimension" => "project", "value" => "backplane"}],
      "idempotency_key" => "stable-key"
    }

    assert {:ok, %{"id" => id}} = Memory.remember(args, opts)

    assert {:error, :idempotency_conflict} =
             Memory.remember(Map.put(args, "content", "changed"), opts)

    assert {:ok, %{"id" => ^id}} = Memory.remember(args, opts)

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: Channel)

    assert_receive {:upload, %{"items" => [item]}}
    assert item["type"] == "procedural"
    assert item["facets"] == args["facets"]
    assert item["idempotency_key"] == "stable-key"
  end

  test "normal HTTP offline reads use only the negotiated mirror partition", %{tmp_dir: dir} do
    edge_config = %{enabled: true, development_plaintext: true}
    edge_store = :"routing_edge_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Edge.Store,
       database: Path.join(dir, "mirror.db"), name: edge_store, config: edge_config, pool_size: 1}
    )

    :ok = Edge.Migrator.migrate(edge_store)
    mirror_opts = [store: edge_store, config: edge_config]

    delivery = %{
      "protocol" => "host_memory.v2",
      "status" => "batch",
      "kind" => "delta",
      "batch_id" => "batch-1",
      "partition" => @partition,
      "from_revision" => 1,
      "to_revision" => 1,
      "changes" => [
        %{
          "revision" => 1,
          "op" => "upsert",
          "memory_id" => "mirrored-id",
          "payload" => %{
            "canonical_id" => "mirrored-id",
            "content" => "negotiated mirror memory",
            "content_hash" => "hash",
            "confidence" => 1.0,
            "edge_priority" => 1.0,
            "memory_type" => "episodic",
            "lifecycle_state" => "active",
            "updated_at" => "2026-10-19T00:00:00Z",
            "tags" => [],
            "metadata" => %{}
          }
        }
      ]
    }

    assert {:ok, _} = Mirror.apply_delivery(delivery, mirror_opts)

    start_supervised!(
      {Edge.Syncer,
       selected: "host_memory.v2", partitions: [@partition], mirror_opts: mirror_opts}
    )

    assert %{
             "ok" => true,
             "result" => %{
               "consistency" => "bounded_stale",
               "hits" => [%{"canonical_id" => "mirrored-id"}]
             }
           } = request("/memory/agent-1/call/recall", %{"query" => "mirror"})

    assert %{"ok" => false} =
             request("/memory/agent-1/call/recall", %{
               "query" => "mirror",
               "memory_space_id" => "foreign"
             })
  end

  test "online identities permit durable offline forget without a synthetic memory row", %{
    store: store
  } do
    context = %{
      agent_id: "agent-1",
      store: store,
      config: %{bound_scope: "proj_local"},
      remote_adapter: Online,
      edge_partition: @partition
    }

    assert {:ok, _} = MemoryFacade.call("list", %{}, context)

    assert {:ok, %{"id" => "online-id", "sync_state" => "pending", "authority" => "provisional"}} =
             MemoryFacade.call("forget", %{"id" => "online-id"}, context)

    assert {:ok, %Result{rows: [%{"count" => 0}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM memories")

    assert {:ok, %{"delete_ids" => ["online-id"]}} =
             Memory.pending_overlay(%{}, store: store, config: context.config)

    assert {:error, :not_found} = MemoryFacade.call("forget", %{"id" => "unseen-id"}, context)

    assert {:error, :not_found} =
             MemoryFacade.call("forget", %{"id" => "online-id"}, %{
               context
               | edge_partition: Map.put(@partition, "memory_space_id", "foreign")
             })

    assert {:ok, %{"delete_ids" => []}} =
             Memory.pending_overlay(%{},
               store: store,
               config: context.config,
               edge_partition: Map.put(@partition, "memory_space_id", "foreign")
             )
  end

  test "canonical deletion settlement and rejection remain visible on repeated calls", %{
    store: store
  } do
    context = %{
      agent_id: "agent-1",
      store: store,
      config: %{bound_scope: "proj_local"},
      remote_adapter: Online,
      edge_partition: @partition
    }

    assert {:ok, _} = MemoryFacade.call("list", %{}, context)
    assert {:ok, _} = MemoryFacade.call("forget", %{"id" => "online-id"}, context)

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: Channel)

    assert {:ok, %{"sync_state" => "synced", "authority" => "canonical", "revision" => 7}} =
             MemoryFacade.call("forget", %{"id" => "online-id"}, context)

    assert {:ok, %Result{rows: [%{"count" => 1}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM memory_outbox")
  end

  test "a rejected canonical deletion reports failure without silently requeuing", %{store: store} do
    context = %{
      agent_id: "agent-1",
      store: store,
      config: %{bound_scope: "proj_local"},
      remote_adapter: Online,
      edge_partition: @partition
    }

    assert {:ok, _} = MemoryFacade.call("list", %{}, context)
    assert {:ok, _} = MemoryFacade.call("forget", %{"id" => "online-id"}, context)

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: RejectedChannel)

    assert {:error, {:command_rejected, "partition revoked"}} =
             MemoryFacade.call("forget", %{"id" => "online-id"}, context)

    assert {:ok, %Result{rows: [%{"count" => 1}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM memory_outbox")
  end

  test "settled writes remain visible offline until the exact mirror cursor covers the ACK", %{
    store: store
  } do
    context = %{
      agent_id: "agent-1",
      store: store,
      config: %{bound_scope: "proj_local"},
      remote_adapter: Disconnected,
      edge_partition: @partition
    }

    assert {:ok, %{"id" => id}} =
             MemoryFacade.call(
               "remember",
               %{"content" => "settled observation", "type" => "episodic"},
               context
             )

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: Channel)

    canonical_id = "canonical-" <> id

    assert {:ok,
            %{
              "hits" => [%{"canonical_id" => ^canonical_id}],
              "pending_operations" => 0,
              "consistency" => "bounded_stale"
            }} = MemoryFacade.call("recall", %{"query" => "settled"}, context)

    Process.put(CursorMirror, %{"partition_revision" => 6, "items" => []})
    context = Map.put(context, :edge_adapter, CursorMirror)

    assert {:ok, %{"hits" => [%{"canonical_id" => ^canonical_id}]}} =
             MemoryFacade.call("recall", %{"query" => "settled"}, context)

    assert {:ok,
            %{
              "items" => [%{"canonical_id" => ^canonical_id, "authority" => "canonical"}],
              "provisional_results" => []
            }} =
             MemoryFacade.call("list", %{}, context)

    Process.put(CursorMirror, %{
      "partition_revision" => 7,
      "items" => [
        %{
          "id" => canonical_id,
          "canonical_id" => canonical_id,
          "content" => "settled observation"
        }
      ]
    })

    assert {:ok, %{"hits" => [_], "acknowledged_operations" => 0}} =
             MemoryFacade.call("recall", %{"query" => "settled"}, context)

    assert {:ok, %{"hits" => []}} =
             MemoryFacade.call("recall", %{"query" => "settled"}, %{
               context
               | edge_partition: Map.put(@partition, "memory_space_id", "foreign"),
                 edge_adapter: nil
             })
  end

  test "settled canonical deletions suppress a stale mirror until its cursor catches up", %{
    store: store
  } do
    context = %{
      agent_id: "agent-1",
      store: store,
      config: %{bound_scope: "proj_local"},
      remote_adapter: Online,
      edge_partition: @partition
    }

    assert {:ok, _} = MemoryFacade.call("list", %{}, context)
    assert {:ok, _} = MemoryFacade.call("forget", %{"id" => "online-id"}, context)

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: Channel)

    Process.put(CursorMirror, %{
      "partition_revision" => 6,
      "items" => [%{"id" => "online-id", "content" => "online memory"}]
    })

    context = %{context | remote_adapter: Disconnected} |> Map.put(:edge_adapter, CursorMirror)

    assert {:ok, %{"hits" => [], "pending_operations" => 0}} =
             MemoryFacade.call("recall", %{"query" => "online"}, context)
  end

  test "a remember ACK preserves a newer pending forget", %{store: store, opts: opts} do
    assert {:ok, %{"id" => id}} = Memory.remember(%{"content" => "forget while uploading"}, opts)

    Process.put(:before_memory_ack, fn _payload ->
      assert {:ok, _} = Memory.forget(%{"id" => id}, opts)
    end)

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: Channel)

    Process.delete(:before_memory_ack)

    assert {:ok, %{"delete_ids" => [canonical_id], "pending_operations" => 1}} =
             Memory.pending_overlay(%{}, opts)

    assert canonical_id == "canonical-" <> id

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(store: store, channel: self(), channel_module: Channel)

    assert {:ok, %{"pending_operations" => 0}} = Memory.pending_overlay(%{}, opts)
  end

  test "receipts and request keys survive the command store restarting", %{
    store: store,
    opts: opts,
    tmp_dir: dir
  } do
    args = %{"content" => "survive restart", "idempotency_key" => "restart-key"}
    assert {:ok, %{"id" => id}} = Memory.remember(args, opts)

    assert :ok =
             Memory.record_canonical_result(
               %{"results" => [%{"id" => "received-online"}]},
               @partition,
               opts
             )

    assert :ok = stop_supervised(Store)
    start_supervised!({Store, database: Path.join(dir, "commands.db"), name: store, pool_size: 1})
    assert :ok = Migrator.migrate(store)
    assert {:ok, %{"id" => ^id}} = Memory.remember(args, opts)

    assert {:ok, %{"canonical_id" => "received-online"}} =
             Memory.forget(%{"id" => "received-online"}, opts)
  end

  test "V3 migration preserves existing rows and command state", %{tmp_dir: dir} do
    store = :"migration_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Store, database: Path.join(dir, "legacy.db"), name: store, pool_size: 1, id: :legacy_store}
    )

    for migration <- [
          Backplane.HostAgent.Memory.Migrations.V1,
          Backplane.HostAgent.Memory.Migrations.V2,
          Backplane.HostAgent.Memory.Migrations.V3
        ],
        sql <- migration.up() do
      assert {:ok, _} = Store.execute(store, sql)
    end

    assert {:ok, _} = Store.execute(store, "PRAGMA user_version = 3")

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO memories(id, content, content_hash, memory_type, scope, agent_id, sync_state, remote_id, remote_revision, inserted_at, updated_at) VALUES ('old', 'legacy', 'hash', 'episodic', 'proj_local', 'agent-1', 'synced', 'remote-old', 4, 'now', 'now')"
             )

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO memory_outbox(op, memory_id, state, inserted_at, updated_at) VALUES ('remember', 'old', 'done', 'now', 'now')"
             )

    assert :ok = Migrator.migrate(store)

    assert {:ok,
            %Result{rows: [%{"remote_revision" => 4, "content" => "legacy", "facets" => "[]"}]}} =
             Store.query(store, "SELECT remote_revision, content, facets FROM memories")

    assert {:ok, %Result{rows: [%{"state" => "done", "payload" => nil}]}} =
             Store.query(store, "SELECT state, payload FROM memory_outbox")
  end

  test "an ACK cannot rebind a durable canonical delete", %{store: store, opts: opts} do
    for field <- [:partition, :canonical_id] do
      id = "canonical-#{field}"

      assert :ok =
               Memory.record_canonical_result(%{"results" => [%{"id" => id}]}, @partition, opts)

      assert {:ok, _} = Memory.forget(%{"id" => id}, opts)

      assert {:ok, %Result{rows: [%{"payload" => payload}]}} =
               Store.query(store, "SELECT payload FROM memory_outbox WHERE memory_id = ?", [
                 "canonical:" <> id
               ])

      Process.put(:invalid_ack_field, field)

      assert {:error, :invalid_ack} =
               Syncer.drain_once(
                 store: store,
                 channel: self(),
                 channel_module: InvalidBindingChannel
               )

      assert_receive {:upload, %{"items" => [uploaded]}}
      assert uploaded["canonical_id"] == id
      assert Map.take(uploaded, ~w(memory_space_id scope namespace)) == @partition

      assert {:ok,
              %Result{
                rows: [
                  %{
                    "state" => "retry_wait",
                    "ack_partition" => nil,
                    "ack_revision" => nil,
                    "ack_canonical_id" => nil,
                    "payload" => ^payload
                  }
                ]
              }} =
               Store.query(
                 store,
                 "SELECT state, ack_partition, ack_revision, ack_canonical_id, payload FROM memory_outbox WHERE memory_id = ?",
                 ["canonical:" <> id]
               )
    end
  end

  test "settled local deletes survive local tombstone pruning until mirror coverage", %{
    store: store,
    opts: opts
  } do
    assert {:ok, %{"id" => id}} = Memory.remember(%{"content" => "deleted local memory"}, opts)
    assert {:ok, _} = Syncer.drain_once(store: store, channel: self(), channel_module: Channel)
    assert {:ok, _} = Memory.forget(%{"id" => id}, opts)
    assert {:ok, _} = Syncer.drain_once(store: store, channel: self(), channel_module: Channel)
    assert {:ok, _} = Store.execute(store, "DELETE FROM memories WHERE id = ?", [id])

    canonical_id = "canonical-" <> id

    Process.put(CursorMirror, %{
      "partition_revision" => 6,
      "items" => [%{"id" => canonical_id, "content" => "deleted local memory"}]
    })

    context = %{
      agent_id: "agent-1",
      store: store,
      config: %{bound_scope: "proj_local"},
      remote_adapter: Disconnected,
      edge_partition: @partition,
      edge_adapter: CursorMirror
    }

    assert {:ok, %{"hits" => [], "acknowledged_operations" => 1}} =
             MemoryFacade.call("recall", %{"query" => "deleted"}, context)
  end

  defp request(path, body) do
    :post
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> MemoryRouter.call(MemoryRouter.init([]))
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end
end
