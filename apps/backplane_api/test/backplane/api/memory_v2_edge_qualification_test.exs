defmodule Backplane.Api.MemoryV2EdgeQualificationTest do
  use Backplane.Api.ChannelCase, async: false

  alias Backplane.Api.HostAgentSocket
  alias Backplane.HostAgent.{Memory, MemoryFacade}
  alias Backplane.HostAgent.Memory.{Migrator, Store, Syncer}
  alias Backplane.HostAgent.Memory.Mirror
  alias Backplane.HostAgent.Memory.Edge.Supervisor, as: EdgeSupervisor
  alias Backplane.HostAgent.Memory.Edge.Syncer, as: EdgeSyncer
  alias Backplane.HostAgent.Memory.Edge.Store, as: EdgeStore
  alias Backplane.Skills.Hosts
  alias Backplane.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @edge_config %{enabled: true, development_plaintext: true}

  defmodule OfflineRemote do
    def call(_method, _args, _opts), do: {:error, :not_connected}
  end

  defmodule DeniedRemote do
    def call(_method, _args, _opts), do: {:error, "unauthorized"}
  end

  defmodule PartitionMismatchRemote do
    def call(_method, _args, _opts), do: {:error, "partition_mismatch"}
  end

  defmodule RealCommandChannel do
    def push(_connected_pid, event, payload, _timeout \\ 5_000) do
      socket = Process.get({__MODULE__, :socket})
      ref = Phoenix.ChannelTest.push(socket, event, payload)

      receive do
        %Phoenix.Socket.Reply{ref: ^ref, status: :ok, payload: reply} ->
          Process.put({__MODULE__, :last_ack}, reply)
          {:ok, reply}

        %Phoenix.Socket.Reply{ref: ^ref, status: :error, payload: reply} ->
          {:error, reply}
      after
        5_000 -> {:error, :reply_timeout}
      end
    end
  end

  defmodule RealMemoryRemote do
    def call(method, args, _opts) do
      socket = Process.get({__MODULE__, :socket})

      ref =
        Phoenix.ChannelTest.push(socket, "memory_call", %{"method" => method, "arguments" => args})

      receive do
        %Phoenix.Socket.Reply{
          ref: ^ref,
          status: :ok,
          payload: %{"ok" => true, "result" => result}
        } ->
          {:ok, result |> Jason.encode!() |> Jason.decode!()}

        %Phoenix.Socket.Reply{
          ref: ^ref,
          status: :ok,
          payload: %{"ok" => false, "error" => reason}
        } ->
          {:error, reason}
      after
        5_000 -> {:error, :reply_timeout}
      end
    end
  end

  defmodule RealEdgeChannel do
    def push(owner, event, payload, _timeout) do
      send(owner, {:edge_call, self(), event, payload})

      receive do
        {:edge_response, ^event, result} -> result
      after
        5_000 -> {:error, :reply_timeout}
      end
    end
  end

  setup %{tmp_dir: dir} do
    previous = Backplane.Settings.get("memory.host_sync_v2.enabled")
    :ets.insert(:backplane_settings, {"memory.host_sync_v2.enabled", true})
    on_exit(fn -> :ets.insert(:backplane_settings, {"memory.host_sync_v2.enabled", previous}) end)

    {:ok, host, _, token} =
      Hosts.create_agent_with_token(%{
        "name" => "qualification-#{System.unique_integer([:positive])}"
      })

    {:ok, socket} =
      connect(HostAgentSocket, %{"host_id" => host.id},
        connect_info: %{x_headers: [{"x-backplane-host-token", token}]}
      )

    assert {:ok, %{"selected" => "host_memory.v2", "partitions" => [inventory]}, socket} =
             subscribe_and_join(socket, "host_agent:#{host.id}", %{
               "memory_v2" => %{"offers" => ["host_memory.v2"], "partitions" => []}
             })

    partition = Map.take(inventory, ["memory_space_id", "scope", "namespace"])
    open = [database: Path.join(dir, "edge.db"), config: @edge_config]
    {:ok, store} = EdgeStore.start_link(open)
    Process.unlink(store)
    :ok = Backplane.HostAgent.Memory.Edge.Migrator.migrate(store)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)

    %{
      host: host,
      socket: socket,
      partition: partition,
      store: store,
      open: open,
      mirror_opts: [store: store, config: @edge_config]
    }
  end

  test "Scenario B: online recall uses canonical Recall V2 and retains provenance", c do
    previous =
      for key <- [
            "memory.pipeline.enabled",
            "memory.recall_v2.enabled",
            "memory.recall_trace_enabled",
            "memory.recall_channel_weights"
          ],
          into: %{},
          do: {key, :ets.lookup(:backplane_settings, key)}

    :ets.insert(:backplane_settings, {"memory.pipeline.enabled", true})
    :ets.insert(:backplane_settings, {"memory.recall_v2.enabled", true})
    :ets.insert(:backplane_settings, {"memory.recall_trace_enabled", true})

    :ets.insert(
      :backplane_settings,
      {"memory.recall_channel_weights", %{"fts" => 1, "vector" => 0, "graph" => 0}}
    )

    on_exit(fn ->
      Enum.each(previous, fn {key, entries} ->
        :ets.delete(:backplane_settings, key)
        if entries != [], do: :ets.insert(:backplane_settings, entries)
      end)
    end)

    supervisor =
      start_supervised!(
        {Task.Supervisor,
         name: String.to_atom("edge-qualification-recall-#{System.unique_integer([:positive])}")}
      )

    prior_supervisor = Application.get_env(:backplane_memory, :recall_task_supervisor)
    Application.put_env(:backplane_memory, :recall_task_supervisor, supervisor)

    on_exit(fn ->
      if prior_supervisor,
        do: Application.put_env(:backplane_memory, :recall_task_supervisor, prior_supervisor),
        else: Application.delete_env(:backplane_memory, :recall_task_supervisor)
    end)

    Process.put({RealMemoryRemote, :socket}, c.socket)
    on_exit(fn -> Process.delete({RealMemoryRemote, :socket}) end)

    assert {:ok, %{"id" => id}} =
             RealMemoryRemote.call(
               "remember",
               %{"content" => "canonical provenance fact", "agent_id" => "qualification-agent"},
               []
             )

    command_store =
      start_supervised!(
        {Store,
         database: Path.join(Path.dirname(c.open[:database]), "recall-commands.db"), pool_size: 1}
      )

    assert :ok = Migrator.migrate(command_store)

    assert {:ok, result} =
             MemoryFacade.call("recall", %{"query" => "canonical provenance fact"}, %{
               agent_id: "qualification-agent",
               remote_adapter: RealMemoryRemote,
               local_adapter: Memory,
               store: command_store,
               config: %{bound_scope: c.partition["scope"], tombstone_relearn: "block"}
             })

    assert result["authority"] == "canonical"
    assert result["mode"] == "online"
    assert is_binary(result["recall_run_id"])

    assert Enum.any?(result["hits"], fn hit ->
             hit["id"] == id and hit["source_ids"] != [] and
               is_map(hit["score_breakdown"])
           end)
  end

  test "Scenario C: a committed server snapshot survives host restart with bounded stale metadata",
       c do
    id = insert_memory(c, "durable canonical fact")
    {batch, ack} = transfer(c, 0)
    assert batch["kind"] == "snapshot_chunk"
    assert ack["applied_revision"] == batch["to_revision"]
    assert byte_size(Jason.encode!(batch)) <= 524_288

    GenServer.stop(c.store)
    store_name = String.to_atom("qualified-edge-store-#{System.unique_integer([:positive])}")

    supervisor_name =
      String.to_atom("qualified-edge-supervisor-#{System.unique_integer([:positive])}")

    edge_config =
      Map.merge(@edge_config, %{
        db_path: c.open[:database],
        store_name: store_name,
        name: supervisor_name
      })

    assert {:ok, first_supervisor} = EdgeSupervisor.start_link(edge_config)
    Process.unlink(first_supervisor)

    assert {:ok, %{"items" => [%{"canonical_id" => ^id}]}} =
             Mirror.offline_read("list", c.partition, store: store_name, config: edge_config)

    Elixir.Supervisor.stop(first_supervisor)
    assert {:ok, restarted_supervisor} = EdgeSupervisor.start_link(edge_config)
    Process.unlink(restarted_supervisor)

    on_exit(fn ->
      if Process.alive?(restarted_supervisor), do: Elixir.Supervisor.stop(restarted_supervisor)
    end)

    command_store =
      start_supervised!(
        {Store,
         database: Path.join(Path.dirname(c.open[:database]), "restart-commands.db"), pool_size: 1}
      )

    assert :ok = Migrator.migrate(command_store)

    assert {:ok, result} =
             MemoryFacade.call("recall", %{"query" => "canonical"}, %{
               agent_id: "qualification-agent",
               local_adapter: Memory,
               remote_adapter: OfflineRemote,
               store: command_store,
               config: %{bound_scope: c.partition["scope"], tombstone_relearn: "block"},
               edge_adapter: Mirror,
               edge_store: store_name,
               edge_config: edge_config,
               edge_partition: c.partition
             })

    assert [%{"canonical_id" => ^id}] = result["hits"]
    assert result["source"] == "edge_mirror"
    assert result["mode"] == "offline"
    assert result["consistency"] == "bounded_stale"
    assert result["partition_revision"] == batch["to_revision"]
    assert is_binary(result["as_of"])
    assert result["last_sync_age_seconds"] >= 0
  end

  test "Scenario D: a canonical denial cannot fall back to a populated local mirror", c do
    insert_memory(c, "never reveal after denial")
    transfer(c, 0)

    command_store =
      start_supervised!(
        {Store,
         database: Path.join(Path.dirname(c.open[:database]), "denied-commands.db"), pool_size: 1}
      )

    assert :ok = Migrator.migrate(command_store)

    context = %{
      agent_id: "qualification-agent",
      local_adapter: Memory,
      remote_adapter: DeniedRemote,
      store: command_store,
      config: %{bound_scope: c.partition["scope"], tombstone_relearn: "block"},
      edge_adapter: Mirror,
      edge_store: c.store,
      edge_config: @edge_config,
      edge_partition: c.partition
    }

    assert {:ok, %{"authority" => "provisional"}} =
             MemoryFacade.call("remember", %{"content" => "pending secret"}, context)

    for {adapter, error} <- [
          {DeniedRemote, "unauthorized"},
          {PartitionMismatchRemote, "partition_mismatch"}
        ] do
      assert {:error, ^error} =
               MemoryFacade.call("recall", %{"query" => "secret"}, %{
                 context
                 | remote_adapter: adapter
               })
    end
  end

  test "Scenario F: a connected host receives a new canonical delta and ACKs without reconnect",
       c do
    assert {:ok, syncer} =
             EdgeSyncer.start_link(
               name: nil,
               channel: self(),
               channel_module: RealEdgeChannel,
               mirror_opts: c.mirror_opts,
               selected: "host_memory.v2",
               partitions: [Map.put(c.partition, "applied_revision", 0)],
               poll_interval_ms: 60_000
             )

    Process.unlink(syncer)
    on_exit(fn -> if Process.alive?(syncer), do: EdgeSyncer.stop(syncer) end)
    {_initial_request, %{"kind" => "snapshot_chunk"}} = await_edge_call(c, "memory_next")
    {_initial_ack, %{"status" => "advanced"}} = await_edge_call(c, "memory_ack")

    assert_wait(fn ->
      match?(
        {:ok, %{"partition_revision" => 0}},
        Mirror.offline_read("stats", c.partition, c.mirror_opts)
      )
    end)

    id = insert_memory(c, "live semantic fact")

    [[revision]] =
      Repo.query!(
        "SELECT current_revision FROM bpm_memory_partition_revisions WHERE memory_space_id=$1 AND scope=$2 AND namespace=$3",
        [
          Ecto.UUID.dump!(c.partition["memory_space_id"]),
          c.partition["scope"],
          c.partition["namespace"]
        ]
      ).rows

    # The canonical insert remains in ChannelCase's sandbox transaction, so its
    # trigger notification cannot be delivered until that transaction commits.
    hint = Map.put(c.partition, "current_revision", revision)

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("SELECT pg_notify($1, $2)", ["bpm_memory_edge_available", Jason.encode!(hint)])
    end)

    assert_push("memory_available", %{"current_revision" => ^revision} = hint, 5_000)
    assert Map.take(hint, Map.keys(c.partition)) == c.partition
    EdgeSyncer.memory_available(syncer, hint)

    {_delta_request, %{"kind" => "delta", "to_revision" => ^revision}} =
      await_edge_call(c, "memory_next")

    {_delta_ack, %{"status" => "advanced"}} = await_edge_call(c, "memory_ack")

    assert_wait(fn ->
      match?(
        {:ok, %{"items" => [%{"canonical_id" => ^id}]}},
        Mirror.offline_read("list", c.partition, c.mirror_opts)
      )
    end)

    assert Repo.one!(Backplane.Memory.EdgeSync.Cursor).applied_revision == revision

    assert {:ok, %{"items" => [%{"canonical_id" => ^id}]}} =
             Mirror.offline_read("list", c.partition, c.mirror_opts)
  end

  test "Scenario G: a canonical delete converges and an old retry cannot resurrect it", c do
    {_initial, initial_ack} = transfer(c, 0)
    id = insert_memory(c, "delete this fact")
    {upsert_delta, first_ack} = transfer(c, initial_ack["applied_revision"])
    assert upsert_delta["kind"] == "delta"

    assert {:ok, %{"items" => [%{"canonical_id" => ^id}]}} =
             Mirror.offline_read("list", c.partition, c.mirror_opts)

    Repo.query!(
      "UPDATE bpm_memories SET lifecycle_state='tombstoned', deleted_at=now() WHERE id=$1",
      [Ecto.UUID.dump!(id)]
    )

    {deletion, ack} = transfer(c, first_ack["applied_revision"])
    assert deletion["kind"] == "delta"
    assert ack["applied_revision"] > first_ack["applied_revision"]
    assert {:ok, _} = Mirror.apply_delivery(upsert_delta, c.mirror_opts)

    assert {:ok, %{"items" => [], "partition_revision" => revision}} =
             Mirror.offline_read("list", c.partition, c.mirror_opts)

    assert revision == ack["applied_revision"]
  end

  test "Scenario H: a bounded mirror evicts locally without mutating canonical rows", c do
    ids =
      for {label, type, confidence} <- [
            {:semantic_low, "semantic", 0.1},
            {:semantic_high, "semantic", 0.9},
            {:procedural_low, "procedural", 0.1},
            {:procedural_high, "procedural", 0.9}
          ],
          into: %{} do
        id = insert_memory(c, "bounded #{label}")

        Repo.query!("UPDATE bpm_memories SET memory_type=$2, confidence=$3 WHERE id=$1", [
          Ecto.UUID.dump!(id),
          type,
          confidence
        ])

        {label, id}
      end

    {snapshot, _ack} = transfer(c, 0)
    assert snapshot["kind"] == "snapshot_chunk"
    assert {:ok, %{rows: sizes}} = EdgeStore.query(c.store, "SELECT byte_size FROM edge_memories")
    max_one_item_bytes = sizes |> Enum.map(& &1["byte_size"]) |> Enum.max()

    for {name, limits, expected} <- [
          {:type_quota, %{type_quotas: %{"semantic" => 1}},
           [ids.semantic_high, ids.procedural_low, ids.procedural_high]},
          {:partition_cap, %{max_items_per_partition: 2},
           [ids.procedural_low, ids.procedural_high]},
          {:item_cap, %{max_items: 2}, [ids.procedural_low, ids.procedural_high]},
          {:byte_cap, %{max_bytes: max_one_item_bytes}, [ids.procedural_high]}
        ] do
      path = Path.join(Path.dirname(c.open[:database]), "#{name}.db")
      config = Map.merge(@edge_config, limits)
      assert {:ok, store} = EdgeStore.start_link(database: path, config: config)
      Process.unlink(store)
      on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
      assert :ok = Backplane.HostAgent.Memory.Edge.Migrator.migrate(store)
      opts = [store: store, config: config]
      assert {:ok, _} = Mirror.apply_delivery(snapshot, opts)
      assert {:ok, %{"items" => items}} = Mirror.offline_read("list", c.partition, opts)
      assert Enum.sort(Enum.map(items, & &1["canonical_id"])) == Enum.sort(expected)

      assert {:ok, %{rows: [%{"count" => count, "bytes" => bytes}]}} =
               EdgeStore.query(
                 store,
                 "SELECT count(*) AS count, COALESCE(SUM(byte_size),0) AS bytes FROM edge_memories"
               )

      assert count == length(expected)
      assert bytes <= Map.get(limits, :max_bytes, 64 * 1024 * 1024)
      IO.puts("Scenario H #{name}: items=#{count} bytes=#{bytes}")
    end

    assert Repo.query!("SELECT count(*) FROM bpm_memories WHERE id = ANY($1::uuid[])", [
             ids |> Map.values() |> Enum.map(&Ecto.UUID.dump!/1)
           ]).rows == [[4]]
  end

  test "Scenario H: max-age expires old edge rows but preserves canonical memory", c do
    id = insert_memory(c, "old canonical fact")

    Repo.query!("UPDATE bpm_memories SET updated_at=now() - interval '2 days' WHERE id=$1", [
      Ecto.UUID.dump!(id)
    ])

    {snapshot, _ack} = transfer(c, 0)
    assert snapshot["kind"] == "snapshot_chunk"

    config = Map.put(@edge_config, :max_age_days, 1)
    path = Path.join(Path.dirname(c.open[:database]), "max-age.db")
    assert {:ok, store} = EdgeStore.start_link(database: path, config: config)
    Process.unlink(store)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    assert :ok = Backplane.HostAgent.Memory.Edge.Migrator.migrate(store)
    assert {:ok, _} = Mirror.apply_delivery(snapshot, store: store, config: config)

    assert {:ok, %{"items" => []}} =
             Mirror.offline_read("list", c.partition, store: store, config: config)

    assert Repo.query!("SELECT count(*) FROM bpm_memories WHERE id=$1", [Ecto.UUID.dump!(id)]).rows ==
             [[1]]
  end

  test "Scenario E: offline remember is provisional, then one canonical item remains after command ACK",
       c do
    command_store =
      start_supervised!(
        {Store, database: Path.join(Path.dirname(c.open[:database]), "commands.db"), pool_size: 1}
      )

    assert :ok = Migrator.migrate(command_store)

    context = %{
      agent_id: "qualification-agent",
      local_adapter: Memory,
      remote_adapter: OfflineRemote,
      store: command_store,
      config: %{bound_scope: c.partition["scope"], tombstone_relearn: "block"},
      edge_adapter: Mirror,
      edge_store: c.store,
      edge_config: @edge_config,
      edge_partition: c.partition
    }

    assert {:ok, %{"id" => provisional_id, "authority" => "provisional"}} =
             MemoryFacade.call("remember", %{"content" => "read my write"}, context)

    assert {:ok, %{"hits" => [%{"id" => ^provisional_id}], "authority" => "provisional"}} =
             MemoryFacade.call("recall", %{"query" => "read my write"}, context)

    Process.put({RealCommandChannel, :socket}, c.socket)

    on_exit(fn ->
      Process.delete({RealCommandChannel, :socket})
      Process.delete({RealCommandChannel, :last_ack})
    end)

    assert {:ok, %{"drained" => 1}} =
             Syncer.drain_once(
               store: command_store,
               channel: self(),
               channel_module: RealCommandChannel
             )

    assert %{
             "items" => [
               %{"status" => "ok", "canonical_id" => canonical_id, "revision" => revision}
             ]
           } =
             Process.get({RealCommandChannel, :last_ack})

    assert is_integer(revision) and revision > 0

    assert {:ok,
            %{
              rows: [
                %{
                  "remote_id" => ^canonical_id,
                  "remote_revision" => ^revision,
                  "sync_state" => "synced"
                }
              ]
            }} =
             Store.query(
               command_store,
               "SELECT remote_id, remote_revision, sync_state FROM memories WHERE id = ?",
               [provisional_id]
             )

    {delivery, edge_ack} = transfer(c, 0)
    assert delivery["to_revision"] == revision
    assert edge_ack["applied_revision"] == delivery["to_revision"]

    assert Enum.any?(delivery["items"], fn item ->
             item["canonical_id"] == canonical_id and
               item["metadata"]["host_memory"]["local_id"] == provisional_id
           end)

    assert {:ok, %{"items" => [%{"canonical_id" => ^canonical_id}]}} =
             Mirror.offline_read("list", c.partition, c.mirror_opts)

    Process.put({RealMemoryRemote, :socket}, c.socket)
    on_exit(fn -> Process.delete({RealMemoryRemote, :socket}) end)

    online_context = Map.put(context, :remote_adapter, RealMemoryRemote)

    assert {:ok, %{"hits" => hits, "authority" => "canonical", "pending_operations" => 0}} =
             MemoryFacade.call("recall", %{"query" => "read my write"}, online_context)

    assert length(hits) == 1
    assert hd(hits)["id"] == canonical_id

    assert {:ok,
            %{
              "hits" => [%{"canonical_id" => ^canonical_id}],
              "authority" => "canonical",
              "consistency" => "bounded_stale",
              "pending_operations" => 0,
              "partition_revision" => edge_revision
            }} =
             MemoryFacade.call("recall", %{"query" => "read my write"}, context)

    assert edge_revision == delivery["to_revision"]

    assert Repo.query!("SELECT count(*) FROM bpm_memories WHERE id=$1", [
             Ecto.UUID.dump!(canonical_id)
           ]).rows == [[1]]
  end

  defp transfer(c, revision, opts \\ nil) do
    opts = opts || c.mirror_opts

    request = %{
      "protocol" => "host_memory.v2",
      "partition" => c.partition,
      "applied_revision" => revision
    }

    ref = push(c.socket, "memory_next", request)
    assert_reply(ref, :ok, %{"status" => "batch"} = batch)
    assert {:ok, ack} = Mirror.apply_delivery(batch, opts)
    ref = push(c.socket, "memory_ack", ack)
    assert_reply(ref, :ok, %{"status" => status})
    assert status in ["advanced", "progress"]
    {batch, ack}
  end

  defp insert_memory(c, content) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO bpm_memories (id,memory_space_id,host_id,client_id,scope,namespace,agent_id,content,content_hash,memory_type,lifecycle_state,inserted_at,updated_at) VALUES ($1,$2,$3,$4,$5,$6,'qualification',$7,$8,'semantic','active',now(),now())",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(c.partition["memory_space_id"]),
        c.host.id,
        "host:" <> c.host.id,
        c.partition["scope"],
        c.partition["namespace"],
        content,
        :crypto.hash(:sha256, content)
      ]
    )

    id
  end

  defp assert_wait(predicate, attempts \\ 50)
  defp assert_wait(predicate, 0), do: assert(predicate.())

  defp assert_wait(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      assert_wait(predicate, attempts - 1)
    end
  end

  defp await_edge_call(c, expected_event) do
    assert_receive {:edge_call, caller, ^expected_event, payload}, 5_000
    ref = push(c.socket, expected_event, payload)
    assert_reply(ref, :ok, reply, 5_000)
    send(caller, {:edge_response, expected_event, {:ok, reply}})
    {payload, reply}
  end
end
