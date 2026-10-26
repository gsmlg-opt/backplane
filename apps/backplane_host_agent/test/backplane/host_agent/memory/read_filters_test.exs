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

    base = %{
      store: store,
      edge: edge,
      opts: opts,
      context: context,
      edge_opts: [store: edge, config: @config]
    }

    {owner, target} = shared_owner!(base)
    activate_shared_items!(base, owner, [])

    Map.merge(base, %{
      owner: owner,
      target: target,
      context: Map.put(context, :access_server, owner)
    })
  end

  test "default and explicit access apply project filters before caps online and offline", c do
    for {content, project} <-
          [{"needle target", "Café project"}] ++
            Enum.map(1..105, &{"needle other #{&1}", "other"}) do
      assert {:ok, _} =
               Access.run_local(
                 c.target,
                 :remember,
                 &Memory.shared_enqueue(
                   &1,
                   "remember",
                   %{"content" => content, "metadata" => %{"project" => project}},
                   "generator"
                 ),
                 c.owner
               )
    end

    args = %{"query" => "needle", "project" => "  Cafe\u0301\n project  "}

    for selector <- [%{}, %{"memory_access_id" => @access_id}],
        reply <- [{:ok, %{"results" => []}}, {:error, :not_connected}] do
      Process.put(:read_filter_reply, reply)
      assert {:ok, result} = MemoryFacade.call("recall", Map.merge(args, selector), c.context)
      assert Enum.map(result["hits"], & &1["content"]) == ["needle target"]
      refute result["overlay_truncated"]
    end
  end

  test "default forget retains every suppression identity beyond the content cap", c do
    ids =
      for index <- 1..512,
          do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0")

    for id <- ids do
      assert {:ok, _} =
               Access.run_local(
                 c.target,
                 :forget,
                 &Memory.shared_enqueue(&1, "forget", %{"id" => id}, "generator"),
                 c.owner
               )
    end

    assert {:ok, overlay} =
             Access.run_local(
               c.target,
               :read,
               &Memory.shared_overlay(&1, "list", %{}, :online, -1),
               c.owner
             )

    assert overlay["delete_ids"] == Enum.reverse(ids)
    visible = item("ffffffff-ffff-4fff-8fff-ffffffffffff", "needle visible", "target")

    for page <- Enum.chunk_every(ids, 99), {method, args} <- read_cases() do
      Process.put(
        :read_filter_reply,
        {:ok, %{"results" => [visible | Enum.map(page, &item(&1, "needle forgotten", "target"))]}}
      )

      assert {:ok, result} = MemoryFacade.call(method, args, c.context)
      assert result["results"] == [visible]
    end
  end

  test "default list filters all provisional rows and preserves canonical pagination", c do
    for {content, type, tags} <-
          Enum.map(1..3, &{"list target #{&1}", "semantic", ["wanted"]}) ++
            Enum.map(1..105, &{"list unrelated #{&1}", "episodic", ["other"]}) do
      assert {:ok, _} =
               Access.run_local(
                 c.target,
                 :remember,
                 &Memory.shared_enqueue(
                   &1,
                   "remember",
                   %{"content" => content, "type" => type, "tags" => tags},
                   "generator"
                 ),
                 c.owner
               )
    end

    assert {:ok, _} =
             Access.run_local(
               c.target,
               :remember,
               &Memory.shared_enqueue(
                 &1,
                 "remember",
                 %{
                   "content" => "list target other agent",
                   "type" => "semantic",
                   "tags" => ["wanted"]
                 },
                 "other-generator"
               ),
               c.owner
             )

    args = %{
      "q" => "target",
      "type" => "semantic",
      "tag" => "wanted",
      "agent_id" => "generator",
      "offset" => 1,
      "limit" => 1
    }

    assert {:ok, overlay} =
             Access.run_local(
               c.target,
               :read,
               &Memory.shared_overlay(&1, "list", args, :offline, 1),
               c.owner
             )

    assert Enum.map(overlay["upserts"], & &1["content"]) ==
             ["list target 3", "list target 2", "list target 1"]

    refute overlay["overlay_truncated"]
    canonical_page = [%{"id" => "canonical-page", "content" => "list canonical target"}]
    Process.put(:read_filter_reply, {:ok, %{"results" => canonical_page}})
    assert {:ok, result} = MemoryFacade.call("list", args, c.context)
    assert result["items"] == canonical_page
    assert result["provisional_results"] == overlay["upserts"]
    assert_received {:canonical, "list", ^args}

    Process.put(:read_filter_reply, {:error, :not_connected})

    assert {:error, {:unsupported_filter, ["agent_id", "offset"]}} =
             MemoryFacade.call("list", args, c.context)

    assert {:ok, offline} =
             MemoryFacade.call("list", Map.drop(args, ["agent_id", "offset"]), c.context)

    assert offline["items"] == []

    assert Enum.map(offline["provisional_results"], & &1["content"]) ==
             ["list target other agent", "list target 3", "list target 2", "list target 1"]
  end

  test "shared forget suppression survives full pending and acknowledged upsert caps", c do
    owner = c.owner
    target = c.target
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

  test "shared pending and acknowledged overlays filter projects before cap online and offline",
       c do
    owner = c.owner
    target = c.target

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

    Process.put(:read_filter_reply, {:error, :not_connected})
    assert {:ok, result} = MemoryFacade.call("recall", args, context)
    assert [%{"content" => "needle target"}] = result["hits"]
    assert result["acknowledged_operations"] == 1
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

  for reason <- [
        :unauthorized,
        :invalid_arguments,
        {:unsupported_filter, ["project"]},
        :partition_mismatch
      ] do
    @canonical_error reason
    test "canonical #{inspect(reason)} errors never become fallback success", c do
      assert {:ok, _} =
               Access.run_local(
                 c.target,
                 :remember,
                 &Memory.shared_enqueue(&1, "remember", %{"content" => "needle"}, "generator"),
                 c.owner
               )

      reason = @canonical_error
      Process.put(:read_filter_reply, {:error, reason})
      assert {:error, ^reason} = MemoryFacade.call("recall", %{"query" => "needle"}, c.context)
      assert_received {:canonical, "recall", %{"query" => "needle"}}
    end
  end

  test "mirror project type tag and plain q predicates precede limits", c do
    items =
      [item("z-target", "needle target", "target")] ++
        Enum.map(1..105, &item("a-#{&1}", "needle unrelated", "other"))

    install_items!(c, items)

    assert {:ok, result} =
             offline_read(c, "recall", %{"query" => "needle", "project" => "target", "limit" => 1})

    assert [%{"canonical_id" => "z-target"}] = result["items"]

    assert {:ok, result} =
             offline_read(c, "list", %{
               "q" => "target",
               "type" => "semantic",
               "tag" => "wanted",
               "limit" => 1
             })

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
             offline_read(c, "recall", %{"query" => "needle"})
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
               offline_read(c, "list", args)
    end
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
    revision = mirror_revision(c)
    snapshot_id = "snapshot-#{revision + 1}"

    frame = %{
      "protocol" => "host_memory.v2",
      "status" => "batch",
      "kind" => "snapshot_chunk",
      "batch_id" => snapshot_id,
      "partition" => @partition,
      "access" => Access.claim(target),
      "snapshot_id" => snapshot_id,
      "chunk_index" => 0,
      "chunk_count" => 1,
      "item_count" => length(items),
      "base_revision" => revision,
      "to_revision" => revision + 1,
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

  defp mirror_revision(c) do
    assert {:ok, %{"partitions" => partitions}} = Mirror.offer(c.edge_opts)

    case Enum.find(partitions, &(Map.take(&1, Map.keys(@partition)) == @partition)) do
      nil -> 0
      partition -> partition["applied_revision"]
    end
  end

  defp offline_read(c, method, args) do
    Access.run_local(
      c.target,
      :read,
      fn target ->
        Mirror.offline_read(
          method,
          Map.merge(@partition, args),
          Keyword.put(c.edge_opts, :access_target, target)
        )
      end,
      c.owner
    )
  end

  defp install_items!(c, items) do
    Enum.chunk_every(items, 100)
    |> Enum.reduce(mirror_revision(c) + 1, fn chunk, revision ->
      {:ok, target, ticket} = Access.begin_request({:access_id, @access_id}, :deliver, c.owner)

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
        "access" => Access.claim(target),
        "from_revision" => revision,
        "to_revision" => revision + length(chunk) - 1,
        "changes" => changes
      }

      assert {:ok, permitted, _} = Access.finish_request(ticket, {:ok, delivery}, c.owner)

      assert {:ok, _} =
               Access.run_local(
                 permitted,
                 :deliver,
                 fn _ -> Mirror.apply_delivery(delivery, c.edge_opts) end,
                 c.owner
               )

      revision + length(chunk)
    end)
  end
end
