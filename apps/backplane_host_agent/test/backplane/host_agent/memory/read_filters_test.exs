defmodule Backplane.HostAgent.Memory.ReadFiltersTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{Memory, MemoryFacade, MemoryProxy}
  alias Backplane.HostAgent.Memory.{Access, Migrator, Store}
  alias Backplane.HostAgent.Memory.{Edge, Mirror}

  @moduletag :tmp_dir
  @partition %{
    "memory_space_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "scope" => "proj_local",
    "namespace" => "private"
  }
  @access_id "11111111-1111-4111-8111-111111111111"
  @config %{enabled: true, development_plaintext: true}

  defmodule Remote do
    def call(method, args, opts) do
      send(self(), {:canonical, method, args})

      case Process.get(:read_filter_reply, {:ok, %{"results" => []}}) do
        {:ok, result} when is_list(opts) ->
          if opts[:access],
            do:
              {:ok,
               %{
                 "access" => opts[:access],
                 "partition" => %{
                   "memory_space_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                   "scope" => "proj_local",
                   "namespace" => "private"
                 },
                 "result" => result
               }},
            else: {:ok, result}

        error ->
          error
      end
    end
  end

  defmodule ForgetIdentities do
    def pending_overlay(_args, _opts) do
      ids =
        for index <- 1..Process.get(:forget_identity_count),
            do:
              "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0")

      {:ok, %{"upserts" => [], "delete_ids" => ids, "pending_operations" => length(ids)}}
    end
  end

  setup %{tmp_dir: dir} do
    MemoryProxy.set_channel(nil)
    {:ok, store} = Store.start_link(database: Path.join(dir, "commands.db"), pool_size: 1)
    :ok = Migrator.migrate(store)
    {:ok, edge} = Edge.Store.start_link(database: Path.join(dir, "edge.db"), config: @config)
    :ok = Edge.Migrator.migrate(edge)
    on_exit(fn -> MemoryProxy.set_channel(nil) end)
    opts = [store: store, config: %{bound_scope: "proj_local"}, agent_id: "generator"]

    context = %{
      agent_id: "route-agent",
      store: store,
      config: opts[:config],
      remote_adapter: Remote
    }

    %{
      store: store,
      edge: edge,
      opts: opts,
      context: context,
      edge_opts: [store: edge, config: @config]
    }
  end

  test "provisional deletion sideband preserves identities and rejects oversized envelopes", c do
    Process.put(:read_filter_reply, {:error, :not_connected})
    context = Map.put(c.context, :local_adapter, ForgetIdentities)
    Process.put(:forget_identity_count, 101)
    assert {:ok, result} = MemoryFacade.call("list", %{}, context)
    assert length(result["delete_ids"]) == 101
    Process.put(:forget_identity_count, 15_000)
    assert {:error, :payload_too_large} = MemoryFacade.call("list", %{}, context)
  end

  test "real canonical forget sets preserve every identity and suppression order", c do
    ids =
      for index <- 1..512,
          do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0")

    insert_canonical_forgets!(c, ids)
    opts = c.opts ++ [method: "list", overlay_mode: :online, edge_partition: @partition]
    assert {:ok, overlay} = Memory.pending_overlay(%{}, opts)
    assert overlay["delete_ids"] == Enum.reverse(ids)
    assert overlay["pending_operations"] == length(ids)
    assert overlay["upserts"] == []
    refute overlay["overlay_truncated"]

    visible = item("ffffffff-ffff-4fff-8fff-ffffffffffff", "needle visible", "target")
    context = Map.put(c.context, :edge_partition, @partition)

    for page <- Enum.chunk_every(ids, 99), {method, args} <- read_cases() do
      canonical = [visible | Enum.map(page, &item(&1, "needle forgotten", "target"))]
      Process.put(:read_filter_reply, {:ok, %{"results" => canonical}})
      assert {:ok, result} = MemoryFacade.call(method, args, context)
      assert result["results"] == [visible]
    end
  end

  test "canonical receipt forget survives full private pending and acknowledged upsert caps", c do
    victim = "00000000-0000-4000-8000-000000000001"
    victim_item = item(victim, "needle victim", "target")
    assert :ok = Memory.record_canonical_result(%{"results" => [victim_item]}, @partition, c.opts)
    assert {:ok, _} = Memory.forget(%{"id" => victim}, c.opts)

    remembers =
      for index <- 1..100,
          do: remember!(c, "needle replacement #{index}", %{"project" => "target"})

    canonical = [
      victim_item
      | Enum.map(Enum.take(remembers, 99), &item(&1["id"], "needle canonical", "target"))
    ]

    install_items!(c, canonical)

    context =
      Map.merge(c.context, %{
        edge_partition: @partition,
        edge_adapter: Mirror,
        edge_store: c.edge,
        edge_config: @config
      })

    for reply <- [{:ok, %{"results" => canonical}}, {:error, :not_connected}],
        {method, args} <- read_cases() do
      Process.put(:read_filter_reply, reply)
      assert {:ok, result} = MemoryFacade.call(method, args, context)
      assert_victim_suppressed(result, victim)
    end

    assert {:ok, _} =
             Store.execute(c.store, "UPDATE memories SET sync_state='synced', remote_id=id")

    assert {:ok, _} =
             Store.execute(
               c.store,
               "UPDATE memory_outbox SET state='done', ack_revision=200, ack_partition=? WHERE op='remember'",
               [Jason.encode!(@partition)]
             )

    Process.put(:read_filter_reply, {:error, :not_connected})

    for {method, args} <- read_cases() do
      assert {:ok, result} = MemoryFacade.call(method, args, context)
      assert_victim_suppressed(result, victim)
    end
  end

  test "private local forget selection is independent of newer matching upserts", c do
    victim = remember!(c, "needle victim", %{"project" => "other"})
    assert {:ok, _} = Memory.forget(%{"id" => victim["id"]}, c.opts)
    for index <- 1..105, do: remember!(c, "needle newer #{index}", %{"project" => "target"})

    for mode <- [:online, :offline], {method, args} <- read_cases() do
      assert {:ok, overlay} =
               Memory.pending_overlay(args, c.opts ++ [method: method, overlay_mode: mode])

      assert victim["id"] in overlay["delete_ids"]
      assert length(overlay["upserts"]) == 100
      assert overlay["overlay_truncated"]
    end
  end

  test "shared forget suppression survives full pending and acknowledged upsert caps", c do
    {owner, target} = shared_owner!(c)
    victim = "00000000-0000-4000-8000-000000000001"
    victim_item = item(victim, "needle victim", "target")

    assert {:ok, _} =
             Access.run_local(
               target,
               :forget,
               &Memory.shared_enqueue(&1, "forget", %{"id" => victim}, "generator"),
               owner
             )

    remembers =
      for index <- 1..100 do
        assert {:ok, receipt} =
                 Access.run_local(
                   target,
                   :remember,
                   &Memory.shared_enqueue(
                     &1,
                     "remember",
                     %{
                       "content" => "needle shared #{index}",
                       "metadata" => %{"project" => "target"}
                     },
                     "generator"
                   ),
                   owner
                 )

        receipt
      end

    canonical = [
      victim_item
      | Enum.map(Enum.take(remembers, 99), &item(&1["command_id"], "needle canonical", "target"))
    ]

    activate_shared_items!(c, owner, canonical)
    context = Map.put(c.context, :access_server, owner)

    for reply <- [{:ok, %{"results" => canonical}}, {:error, :not_connected}],
        {method, args} <- read_cases() do
      Process.put(:read_filter_reply, reply)

      assert {:ok, result} =
               MemoryFacade.call(method, Map.put(args, "memory_access_id", @access_id), context)

      assert_victim_suppressed(result, victim)
    end

    assert {:ok, _} =
             Store.execute(
               c.store,
               "UPDATE memory_outbox SET state='done', ack_revision=200, ack_canonical_id=command_id WHERE op='remember'"
             )

    Process.put(:read_filter_reply, {:error, :not_connected})

    for {method, args} <- read_cases() do
      assert {:ok, result} =
               MemoryFacade.call(method, Map.put(args, "memory_access_id", @access_id), context)

      assert_victim_suppressed(result, victim)
    end
  end

  test "private online and offline project filters select before the overlay cap", c do
    remember!(c, "needle target", %{"project" => "Café project"})
    for index <- 1..105, do: remember!(c, "needle unrelated #{index}", %{"project" => "other"})
    remember!(c, "needle working", %{"project" => "Café project"}, "working")
    remember!(c, "needle malformed", %{"project" => 42})

    args = %{"query" => "needle", "project" => "  Cafe\u0301\n project  "}

    for reply <- [{:ok, %{"results" => []}}, {:error, :not_connected}] do
      Process.put(:read_filter_reply, reply)
      assert {:ok, result} = MemoryFacade.call("recall", args, c.context)
      assert Enum.map(result["hits"], & &1["content"]) == ["needle target"]
      assert Enum.map(result["results"], & &1["content"]) == ["needle target"]
      refute result["overlay_truncated"]
    end
  end

  test "shared pending and acknowledged overlays filter projects before cap online and offline",
       c do
    {:ok, cache} = Backplane.HostAgent.Memory.RecallCache.start_link(name: nil)

    {:ok, owner} =
      Access.start_link(
        name: nil,
        store: c.store,
        edge_store: c.edge,
        edge_config: @config,
        recall_cache: cache,
        now_fun: fn -> 10_000 end
      )

    inventory = %{
      "extensions" => ["memory_access.v1", "memory_commands.v2"],
      "default_access_id" => @access_id,
      "accesses" => [
        %{
          "access_id" => @access_id,
          "authority_version" => 1,
          "status" => "active",
          "partition" => @partition,
          "capabilities" => ~w(read deliver remember forget),
          "offline_read_lease_seconds" => 300
        }
      ]
    }

    assert :ok = Access.install_inventory(%{id: 1, sent_at_ms: 10_000}, inventory, owner)
    {:ok, target, _} = Access.begin_request({:access_id, @access_id}, :remember, owner)

    for {content, project} <-
          [{"needle target", "target"}] ++ Enum.map(1..105, &{"needle other #{&1}", "other"}) do
      assert {:ok, _} =
               Access.run_local(
                 target,
                 :remember,
                 &Memory.shared_enqueue(
                   &1,
                   "remember",
                   %{"content" => content, "metadata" => %{"project" => project}},
                   "generator"
                 ),
                 owner
               )
    end

    context = Map.put(c.context, :access_server, owner)
    args = %{"memory_access_id" => @access_id, "query" => "needle", "project" => "target"}
    assert {:ok, result} = MemoryFacade.call("recall", args, context)
    assert [%{"content" => "needle target"}] = result["hits"]

    assert {:ok, _} =
             Store.execute(
               c.store,
               "UPDATE memory_outbox SET state='done', ack_revision=2, ack_canonical_id=command_id WHERE access_id IS NOT NULL"
             )

    {:ok, target, ticket} = Access.begin_request({:access_id, @access_id}, :deliver, owner)
    chunk_hash = Mirror.Store.hash(%{"items" => []})

    frame = %{
      "protocol" => "host_memory.v2",
      "status" => "batch",
      "kind" => "snapshot_chunk",
      "batch_id" => "shared-snapshot",
      "partition" => @partition,
      "access" => Access.claim(target),
      "snapshot_id" => "shared-snapshot",
      "chunk_index" => 0,
      "chunk_count" => 1,
      "item_count" => 0,
      "base_revision" => 0,
      "to_revision" => 1,
      "chunk_hash" => chunk_hash,
      "integrity_hash" =>
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, chunk_hash), case: :lower),
      "items" => []
    }

    assert {:ok, permitted, _} = Access.finish_request(ticket, {:ok, frame}, owner)

    assert {:ok, _} =
             Access.run_local(
               permitted,
               :deliver,
               fn _ -> Mirror.apply_delivery(frame, c.edge_opts) end,
               owner
             )

    Process.put(:read_filter_reply, {:error, :not_connected})
    assert {:ok, result} = MemoryFacade.call("recall", args, context)
    assert [%{"content" => "needle target"}] = result["hits"]
    assert result["acknowledged_operations"] == 1
  end

  test "acknowledged rows are project filtered before their cap", c do
    remember!(c, "needle target", %{"project" => "target"})
    for index <- 1..105, do: remember!(c, "needle unrelated #{index}", %{"project" => "other"})

    assert {:ok, _} =
             Store.execute(c.store, "UPDATE memories SET sync_state='synced', remote_id=id")

    assert {:ok, _} =
             Store.execute(
               c.store,
               "UPDATE memory_outbox SET state='done', ack_revision=1, ack_partition=?",
               [Jason.encode!(@partition)]
             )

    opts = c.opts ++ [method: "recall", overlay_mode: :offline, edge_partition: @partition]

    assert {:ok, result} =
             Memory.pending_overlay(%{"query" => "needle", "project" => "target"}, opts)

    assert Enum.map(result["upserts"], & &1["content"]) == ["needle target"]
    assert result["acknowledged_operations"] == 1
  end

  test "private provisional list filters before pagination and uses the real generator", c do
    for index <- 1..3, do: remember!(c, "list target #{index}", %{}, "semantic", ["wanted"])
    for index <- 1..105, do: remember!(c, "list unrelated #{index}", %{}, "episodic", ["other"])
    Process.put(:read_filter_reply, {:error, :not_connected})

    args = %{
      "q" => "target",
      "type" => "semantic",
      "tag" => "wanted",
      "agent_id" => "generator",
      "offset" => 1,
      "limit" => 1
    }

    assert {:ok, result} = MemoryFacade.call("list", args, c.context)
    assert [%{"content" => "list target 2"}] = result["items"]
  end

  test "invalid read arguments never reach canonical or fallback", c do
    Process.put(:read_filter_reply, {:error, :not_connected})

    for {method, args} <- [
          {"recall", %{"query" => 1}},
          {"recall", %{"type" => "semantic"}},
          {"recall", %{"offset" => 1}},
          {"recall", %{"project" => 3}},
          {"list", %{"project" => "target"}},
          {"list", %{"tag" => []}},
          {"list", %{"offset" => -1}},
          {"list", %{"limit" => "1"}}
        ] do
      assert {:error, :invalid_arguments} = MemoryFacade.call(method, args, c.context)
      refute_received {:canonical, _, _}
    end
  end

  test "unsupported fallback filters fail with stable field names", c do
    Process.put(:read_filter_reply, {:error, :not_connected})

    for {method, args, fields} <- [
          {"recall", %{"query" => "needle", "agent_id" => "a", "tag" => "t"},
           ["agent_id", "tag"]},
          {"recall", %{"query" => "needle", "host_id" => "creator-host"}, ["host_id"]},
          {"recall", %{"query" => "needle", "include_working" => false}, ["include_working"]},
          {"recall",
           %{"query" => "needle", "facets" => [%{"dimension" => "kind", "value" => "plan"}]},
           ["facets"]},
          {"list", %{"q" => "wild%"}, ["q"]}
        ] do
      assert {:error, {:unsupported_filter, ^fields}} = MemoryFacade.call(method, args, c.context)
    end
  end

  test "online unsupported overlays fail before cap but canonical with only forget remains usable",
       c do
    target = remember!(c, "needle target", %{"project" => "target"})
    for index <- 1..105, do: remember!(c, "needle unrelated #{index}", %{"project" => "other"})
    args = %{"query" => "needle", "project" => "target", "channel_weights" => %{"fts" => 1.0}}

    assert {:error, {:unsupported_filter, ["channel_weights"]}} =
             MemoryFacade.call("recall", args, c.context)

    assert {:ok, _} = Memory.forget(%{"id" => target["id"]}, c.opts)
    Process.put(:read_filter_reply, {:ok, %{"results" => [%{"id" => target["id"]}]}})
    assert {:ok, result} = MemoryFacade.call("recall", args, c.context)
    assert result["results"] == []
  end

  test "canonical authority failures never become fallback success", c do
    remember!(c, "needle", %{})

    for reason <- [
          :unauthorized,
          :invalid_arguments,
          {:unsupported_filter, ["project"]},
          :partition_mismatch
        ] do
      Process.put(:read_filter_reply, {:error, reason})
      assert {:error, ^reason} = MemoryFacade.call("recall", %{"query" => "needle"}, c.context)
    end
  end

  test "mirror project type tag and plain q predicates precede limits", c do
    items =
      [item("z-target", "needle target", "target")] ++
        Enum.map(1..105, &item("a-#{&1}", "needle unrelated", "other"))

    install_items!(c, items)

    assert {:ok, result} =
             Mirror.offline_read(
               "recall",
               Map.merge(@partition, %{"query" => "needle", "project" => "target", "limit" => 1}),
               c.edge_opts
             )

    assert [%{"canonical_id" => "z-target"}] = result["items"]

    assert {:ok, result} =
             Mirror.offline_read(
               "list",
               Map.merge(@partition, %{
                 "q" => "target",
                 "type" => "semantic",
                 "tag" => "wanted",
                 "limit" => 1
               }),
               c.edge_opts
             )

    assert [%{"canonical_id" => "z-target"}] = result["items"]
  end

  test "mirror excludes working expired and inactive records", c do
    install_items!(c, [
      item("active", "needle", "target"),
      Map.put(item("working", "needle", "target"), "memory_type", "working"),
      Map.put(item("expired", "needle", "target"), "expires_at", "2000-01-01T00:00:00Z")
    ])

    assert {:ok, _} =
             Edge.Store.execute(
               c.edge,
               "UPDATE edge_memories SET lifecycle_state='archived' WHERE canonical_id='active'"
             )

    assert {:ok, %{"items" => []}} =
             Mirror.offline_read("recall", Map.put(@partition, "query", "needle"), c.edge_opts)
  end

  test "mirror rejects unavailable generator pagination and wildcard semantics", c do
    install_items!(c, [item("target", "needle", "target")])

    for {args, fields} <- [
          {%{"agent_id" => "generator"}, ["agent_id"]},
          {%{"offset" => 1}, ["offset"]},
          {%{"q" => "needle_"}, ["q"]},
          {%{"q" => "needle\\"}, ["q"]}
        ] do
      assert {:error, {:unsupported_filter, ^fields}} =
               Mirror.offline_read("list", Map.merge(@partition, args), c.edge_opts)
    end
  end

  defp insert_canonical_forgets!(c, ids) do
    now = "2026-10-24T00:00:00Z"

    assert {:ok, :ok} =
             Store.transaction(c.store, fn conn ->
               for chunk <- Enum.chunk_every(ids, 100) do
                 receipt_values = Enum.map_join(chunk, ",", fn _ -> "(?, ?, ?, ?, ?, ?)" end)

                 receipt_params =
                   Enum.flat_map(chunk, fn id ->
                     [
                       id,
                       @partition["memory_space_id"],
                       @partition["scope"],
                       @partition["namespace"],
                       "generator",
                       now
                     ]
                   end)

                 assert {:ok, _} =
                          Store.execute(
                            conn,
                            "INSERT INTO canonical_memory_receipts(canonical_id, memory_space_id, scope, namespace, agent_id, received_at) VALUES " <>
                              receipt_values,
                            receipt_params
                          )

                 command_values = Enum.map_join(chunk, ",", fn _ -> "('forget', ?, ?, ?, ?)" end)

                 command_params =
                   Enum.flat_map(chunk, fn id ->
                     command_id = "canonical:" <> id

                     payload =
                       Map.merge(@partition, %{
                         "op" => "forget",
                         "id" => command_id,
                         "canonical_id" => id,
                         "agent_id" => "generator"
                       })

                     [command_id, Jason.encode!(payload), now, now]
                   end)

                 assert {:ok, _} =
                          Store.execute(
                            conn,
                            "INSERT INTO memory_outbox(op, memory_id, payload, inserted_at, updated_at) VALUES " <>
                              command_values,
                            command_params
                          )
               end

               :ok
             end)
  end

  defp read_cases do
    [
      {"recall", %{"query" => "needle", "project" => "target", "limit" => 100}},
      {"list", %{"q" => "needle", "limit" => 100}}
    ]
  end

  defp assert_victim_suppressed(result, victim) do
    assert result["results"] != []

    for field <- ~w(results hits items upserts provisional_results),
        row <- Map.get(result, field, []) do
      refute (row["canonical_id"] || row["id"]) == victim,
             "forgotten memory leaked through #{field}"
    end
  end

  defp shared_owner!(c) do
    {:ok, cache} = Backplane.HostAgent.Memory.RecallCache.start_link(name: nil)

    {:ok, owner} =
      Access.start_link(
        name: nil,
        store: c.store,
        edge_store: c.edge,
        edge_config: @config,
        recall_cache: cache,
        now_fun: fn -> 10_000 end
      )

    inventory = %{
      "extensions" => ["memory_access.v1", "memory_commands.v2"],
      "default_access_id" => @access_id,
      "accesses" => [
        %{
          "access_id" => @access_id,
          "authority_version" => 1,
          "status" => "active",
          "partition" => @partition,
          "capabilities" => ~w(read deliver remember forget),
          "offline_read_lease_seconds" => 300
        }
      ]
    }

    assert :ok = Access.install_inventory(%{id: 1, sent_at_ms: 10_000}, inventory, owner)
    {:ok, target, _} = Access.begin_request({:access_id, @access_id}, :remember, owner)
    {owner, target}
  end

  defp activate_shared_items!(c, owner, items) do
    {:ok, target, ticket} = Access.begin_request({:access_id, @access_id}, :deliver, owner)
    chunk_hash = Mirror.Store.hash(%{"items" => items})

    frame = %{
      "protocol" => "host_memory.v2",
      "status" => "batch",
      "kind" => "snapshot_chunk",
      "batch_id" => "delete-snapshot",
      "partition" => @partition,
      "access" => Access.claim(target),
      "snapshot_id" => "delete-snapshot",
      "chunk_index" => 0,
      "chunk_count" => 1,
      "item_count" => length(items),
      "base_revision" => 0,
      "to_revision" => 1,
      "chunk_hash" => chunk_hash,
      "integrity_hash" =>
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, chunk_hash), case: :lower),
      "items" => items
    }

    {:ok, permitted, _} = Access.finish_request(ticket, {:ok, frame}, owner)

    assert {:ok, _} =
             Access.run_local(
               permitted,
               :deliver,
               fn _ -> Mirror.apply_delivery(frame, c.edge_opts) end,
               owner
             )
  end

  defp remember!(c, content, metadata, type \\ "semantic", tags \\ []) do
    assert {:ok, result} =
             Memory.remember(
               %{"content" => content, "type" => type, "metadata" => metadata, "tags" => tags},
               c.opts
             )

    result
  end

  defp item(id, content, project),
    do: %{
      "canonical_id" => id,
      "memory_type" => "semantic",
      "content" => content,
      "content_hash" => id,
      "confidence" => 0.9,
      "edge_priority" => 0.9,
      "updated_at" => "2026-10-20T00:00:00Z",
      "lifecycle_state" => "active",
      "tags" => if(project == "target", do: ["wanted"], else: []),
      "metadata" => %{"project" => project},
      "expires_at" => nil
    }

  defp install_items!(c, items) do
    Enum.chunk_every(items, 100)
    |> Enum.reduce(1, fn chunk, revision ->
      changes =
        Enum.with_index(chunk, revision)
        |> Enum.map(fn {item, index} ->
          %{
            "revision" => index,
            "op" => "upsert",
            "memory_id" => item["canonical_id"],
            "payload" => item
          }
        end)

      delivery = %{
        "protocol" => "host_memory.v2",
        "status" => "batch",
        "kind" => "delta",
        "batch_id" => "batch-#{revision}",
        "partition" => @partition,
        "from_revision" => revision,
        "to_revision" => revision + length(chunk) - 1,
        "changes" => changes
      }

      assert {:ok, _} = Mirror.apply_delivery(delivery, c.edge_opts)
      revision + length(chunk)
    end)
  end
end
