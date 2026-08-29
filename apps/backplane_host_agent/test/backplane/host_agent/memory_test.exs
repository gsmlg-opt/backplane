defmodule Backplane.HostAgent.MemoryTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{Memory, MemoryFacade}
  alias Backplane.HostAgent.Memory.{Migrator, Reducer, Store}
  alias Turso.Result

  @moduletag :tmp_dir

  defmodule RemoteDisconnected do
    def call(_method, _args, _opts), do: {:error, :not_connected}
  end

  test "remember inserts one local row and one outbox row, then deduplicates", %{
    tmp_dir: tmp_dir
  } do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)
    args = %{"content" => "local observation", "tags" => ["ops"], "metadata" => %{"k" => "v"}}

    assert {:ok,
            %{
              "id" => id,
              "scope" => "proj_local",
              "dedup" => false,
              "sync_state" => "pending"
            }} = Memory.remember(args, opts)

    assert {:ok,
            %{
              "id" => ^id,
              "scope" => "proj_local",
              "dedup" => true,
              "sync_state" => "pending"
            }} = Memory.remember(args, opts)

    assert_count(store, "memories", 1)
    assert_count(store, "memory_outbox", 1)

    assert {:ok, %Result{rows: [%{"tags" => tags, "metadata" => metadata}]}} =
             Store.query(store, "SELECT tags, metadata FROM memories WHERE id = ?", [id])

    assert Jason.decode!(tags) == ["ops"]
    assert Jason.decode!(metadata) == %{"k" => "v"}
  end

  test "concurrent identical remembers produce one memory and one outbox item", %{
    tmp_dir: tmp_dir
  } do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    results =
      1..10
      |> Enum.map(fn _ ->
        Task.async(fn -> Memory.remember(%{"content" => "concurrent observation"}, opts) end)
      end)
      |> Task.await_many(10_000)

    assert Enum.all?(results, &match?({:ok, %{"id" => _}}, &1))
    assert Enum.count(results, &match?({:ok, %{"dedup" => false}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{"dedup" => true}}, &1)) == 9
    assert_count(store, "memories", 1)
    assert_count(store, "memory_outbox", 1)
  end

  test "forced outbox failure rolls back the memory row", %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)

    assert {:ok, _} = Store.execute(store, "DROP TABLE memory_outbox")

    assert {:ok, _} =
             Store.execute(store, """
             CREATE TABLE memory_outbox (
               seq INTEGER PRIMARY KEY AUTOINCREMENT,
               op TEXT NOT NULL CHECK (op = 'never'),
               memory_id TEXT NOT NULL,
               state TEXT NOT NULL DEFAULT 'pending',
               attempts INTEGER NOT NULL DEFAULT 0,
               last_error TEXT,
               inserted_at TEXT NOT NULL,
               updated_at TEXT NOT NULL
             )
             """)

    assert {:error, {:storage_error, _}} =
             Memory.remember(%{"content" => "rolled back observation"}, memory_opts(store))

    assert_count(store, "memories", 0)
    assert_count(store, "memory_outbox", 0)
  end

  test "tombstone blocks exact re-remember without writing outbox", %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    content = "globally wiped observation"
    now = "2026-06-17T00:00:00Z"

    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO tombstones(content_hash, scope, wiped_at, directive_id)
               VALUES (?, ?, ?, ?)
               """,
               [Reducer.content_hash(content), "proj_local", now, "wipe_1"]
             )

    assert {:error, :wiped} = Memory.remember(%{"content" => content}, memory_opts(store))
    assert_count(store, "memories", 0)
    assert_count(store, "memory_outbox", 0)
  end

  test "forget soft-deletes local memories, enqueues forget, and rejects facts", %{
    tmp_dir: tmp_dir
  } do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)
    fact_id = "fact_1"

    assert {:ok, %{"id" => id}} = Memory.remember(%{"content" => "forget me"}, opts)
    insert_fact!(store, fact_id, "read only fact")

    assert {:ok, %{"id" => ^id, "sync_state" => "pending"}} = Memory.forget(%{"id" => id}, opts)
    assert {:error, :read_only_fact} = Memory.forget(%{"id" => fact_id}, opts)

    assert {:ok, %{"hits" => []}} = Memory.recall(%{"query" => "forget me"}, opts)

    assert {:ok, %Result{rows: [%{"count" => 1}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM memory_outbox WHERE op = 'forget'")
  end

  test "pending overlay exposes the latest pending remember as provisional", %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, %{"id" => provisional_id}} =
             Memory.remember(%{"content" => "pending insight"}, opts)

    assert {:ok,
            %{
              "upserts" => [
                %{
                  "id" => ^provisional_id,
                  "canonical_id" => nil,
                  "content" => "pending insight",
                  "origin" => "host_command",
                  "authority" => "provisional",
                  "provisional" => true
                }
              ],
              "delete_ids" => [],
              "pending_operations" => 1
            }} = Memory.pending_overlay(%{"query" => "pending"}, opts)
  end

  test "pending overlay continues to expose an inflight remember", %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, %{"id" => id}} = Memory.remember(%{"content" => "inflight insight"}, opts)

    assert {:ok, _} =
             Store.execute(
               store,
               "UPDATE memory_outbox SET state = 'inflight' WHERE memory_id = ?",
               [id]
             )

    assert {:ok, %{"upserts" => [%{"id" => ^id}], "pending_operations" => 1}} =
             Memory.pending_overlay(%{"query" => "inflight"}, opts)
  end

  test "pending overlay uses only the latest operation and prefers remote forget ids", %{
    tmp_dir: tmp_dir
  } do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, %{"id" => id}} = Memory.remember(%{"content" => "forget pending"}, opts)

    assert {:ok, _} =
             Store.execute(store, "UPDATE memories SET remote_id = ? WHERE id = ?", [
               "remote-1",
               id
             ])

    assert {:ok, _} = Memory.forget(%{"id" => id}, opts)

    assert {:ok,
            %{
              "upserts" => [],
              "delete_ids" => ["remote-1"],
              "pending_operations" => 1
            }} = Memory.pending_overlay(%{"query" => "forget"}, opts)
  end

  test "pending overlay keeps in-scope forgets regardless of canonical list filters", %{
    tmp_dir: tmp_dir
  } do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, %{"id" => id}} = Memory.remember(%{"content" => "deleted wording"}, opts)
    assert {:ok, _} = Memory.forget(%{"id" => id}, opts)

    assert {:ok, %{"upserts" => [], "delete_ids" => [^id], "pending_operations" => 1}} =
             Memory.pending_overlay(
               %{
                 "q" => "semantic recall hit",
                 "type" => "semantic",
                 "agent_id" => "other-agent",
                 "tag" => "other-tag"
               },
               opts
             )
  end

  test "pending overlay excludes synced memories even with an unresolved outbox row", %{
    tmp_dir: tmp_dir
  } do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, %{"id" => id}} = Memory.remember(%{"content" => "already canonical"}, opts)

    assert {:ok, _} =
             Store.execute(store, "UPDATE memories SET sync_state = 'synced' WHERE id = ?", [id])

    assert {:ok, %{"upserts" => [], "delete_ids" => [], "pending_operations" => 0}} =
             Memory.pending_overlay(%{}, opts)
  end

  test "pending overlay excludes a memory whose latest operation is done", %{
    tmp_dir: tmp_dir
  } do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, %{"id" => done_id}} = Memory.remember(%{"content" => "done insight"}, opts)

    assert {:ok, _} =
             Store.execute(
               store,
               "UPDATE memory_outbox SET state = 'done' WHERE memory_id = ?",
               [done_id]
             )

    assert {:ok, %{"upserts" => [], "delete_ids" => [], "pending_operations" => 0}} =
             Memory.pending_overlay(%{}, opts)
  end

  test "pending overlay does not present a failed operation as pending", %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, %{"id" => failed_id}} = Memory.remember(%{"content" => "failed insight"}, opts)

    assert {:ok, _} =
             Store.execute(
               store,
               "UPDATE memory_outbox SET state = 'failed' WHERE memory_id = ?",
               [failed_id]
             )

    assert {:ok, %{"upserts" => [], "delete_ids" => [], "pending_operations" => 0}} =
             Memory.pending_overlay(%{}, opts)
  end

  test "pending overlay enforces scope and query filters", %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)
    other_opts = Keyword.put(opts, :config, %{bound_scope: "other_scope"})

    assert {:ok, %{"id" => expected_id}} =
             Memory.remember(%{"content" => "matching pending"}, opts)

    assert {:ok, _} = Memory.remember(%{"content" => "unmatched pending"}, opts)
    assert {:ok, _} = Memory.remember(%{"content" => "matching other scope"}, other_opts)

    assert {:ok, %{"upserts" => [%{"id" => ^expected_id}], "pending_operations" => 1}} =
             Memory.pending_overlay(
               %{"scope" => "proj_local", "query" => "matching pending"},
               opts
             )

    assert {:ok, %{"upserts" => [], "delete_ids" => [], "pending_operations" => 0}} =
             Memory.pending_overlay(%{"scope" => "proj_local", "query" => "absent"}, opts)
  end

  test "pending overlay applies canonical list filters to remember upserts", %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)
    agent_2_opts = Keyword.put(opts, :agent_id, "agent_2")

    assert {:ok, %{"id" => expected_id}} =
             Memory.remember(%{"content" => "alpha target", "tags" => ["ops"]}, opts)

    assert {:ok, _} = Memory.remember(%{"content" => "beta target", "tags" => ["ops"]}, opts)
    assert {:ok, _} = Memory.remember(%{"content" => "alpha ui", "tags" => ["ui"]}, opts)

    assert {:ok, _} =
             Memory.remember(%{"content" => "alpha other agent", "tags" => ["ops"]}, agent_2_opts)

    for args <- [
          %{"q" => "alpha", "type" => "episodic", "agent_id" => "agent_1", "tag" => "ops"},
          %{q: "alpha", type: "episodic", agent_id: "agent_1", tag: "ops"}
        ] do
      assert {:ok,
              %{
                "upserts" => [
                  %{
                    "id" => ^expected_id,
                    "memory_type" => "episodic",
                    "agent_id" => "agent_1"
                  }
                ],
                "pending_operations" => 1
              }} = Memory.pending_overlay(args, opts)
    end

    assert {:ok, %{"upserts" => [], "pending_operations" => 0}} =
             Memory.pending_overlay(%{"type" => "semantic"}, opts)
  end

  test "pending overlay omits recall upserts for nonempty canonical facets but keeps forgets", %{
    tmp_dir: tmp_dir
  } do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, _} = Memory.remember(%{"content" => "facet candidate"}, opts)
    assert {:ok, %{"id" => deleted_id}} = Memory.remember(%{"content" => "facet deletion"}, opts)
    assert {:ok, _} = Memory.forget(%{"id" => deleted_id}, opts)

    assert {:ok, %{"upserts" => [], "delete_ids" => [^deleted_id], "pending_operations" => 1}} =
             Memory.pending_overlay(
               %{"query" => "facet", "facets" => %{"kind" => ["decision"]}},
               opts
             )
  end

  test "pending overlay bounds real outbox content independently of caller limits", %{
    tmp_dir: tmp_dir
  } do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    for index <- 1..102 do
      assert {:ok, _result} =
               Memory.remember(%{"content" => "bounded pending #{index}"}, opts)
    end

    assert {:ok,
            %{
              "upserts" => upserts,
              "delete_ids" => [],
              "pending_operations" => 100,
              "overlay_truncated" => true
            }} =
             Memory.pending_overlay(
               %{"limit" => 200},
               Keyword.put(opts, :method, "list")
             )

    assert length(upserts) == 100
    assert List.first(upserts)["content"] == "bounded pending 102"
    assert List.last(upserts)["content"] == "bounded pending 3"
  end

  test "pending overlay filters remembers before applying the hard cap", %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, %{"id" => expected_id}} =
             Memory.remember(
               %{"content" => "older needle", "tags" => ["ops"]},
               opts
             )

    for index <- 1..101 do
      assert {:ok, _result} =
               Memory.remember(
                 %{"content" => "newer unrelated #{index}", "tags" => ["ui"]},
                 opts
               )
    end

    assert {:ok,
            %{
              "upserts" => [%{"id" => ^expected_id}],
              "delete_ids" => [],
              "pending_operations" => 1,
              "overlay_truncated" => false
            }} =
             Memory.pending_overlay(
               %{
                 "q" => "needle",
                 "type" => "episodic",
                 "agent_id" => "agent_1",
                 "tag" => "ops"
               },
               Keyword.put(opts, :method, "list")
             )
  end

  test "offline list pages the filtered provisional set beyond offset 100 exactly once", %{
    tmp_dir: tmp_dir
  } do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    for index <- 1..105 do
      assert {:ok, _result} =
               Memory.remember(
                 %{"content" => "paged match #{index}", "tags" => ["ops"]},
                 opts
               )
    end

    assert {:ok,
            %{
              "items" => [
                %{"content" => "paged match 5"},
                %{"content" => "paged match 4"}
              ],
              "pending_operations" => 5,
              "overlay_truncated" => false
            }} =
             MemoryFacade.call(
               "list",
               %{"q" => "paged match", "tag" => "ops", "offset" => 100, "limit" => 2},
               %{
                 agent_id: "agent_1",
                 remote_adapter: RemoteDisconnected,
                 local_adapter: Memory,
                 store: store,
                 config: %{bound_scope: "proj_local", tombstone_relearn: "block"}
               }
             )
  end

  test "stats overlay counts pending operations without loading pending content", %{
    tmp_dir: tmp_dir
  } do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    for index <- 1..102 do
      assert {:ok, _result} =
               Memory.remember(%{"content" => "private pending #{index}"}, opts)
    end

    assert {:ok,
            %{
              "pending_operations" => 102,
              "overlay_truncated" => true
            } = overlay} = Memory.pending_overlay(%{}, Keyword.put(opts, :method, "stats"))

    refute Map.has_key?(overlay, "upserts")
    refute Map.has_key?(overlay, "delete_ids")
    refute inspect(overlay) =~ "private pending"
  end

  test "recall merges local memories and facts with source and degraded quality", %{
    tmp_dir: tmp_dir
  } do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, %{"id" => local_id}} =
             Memory.remember(%{"content" => "alpha beta local note", "tags" => ["local"]}, opts)

    insert_fact!(store, "fact_1", "alpha beta fact", tags: ["fact"])

    assert {:ok, %{"hits" => hits}} =
             Memory.recall(%{"query" => "alpha beta", "limit" => 10}, opts)

    assert Enum.map(hits, & &1["id"]) == ["fact_1", local_id]
    assert Enum.map(hits, & &1["source"]) == ["hub_fact", "local"]
    assert Enum.all?(hits, &(&1["quality"] == "degraded"))
    assert Enum.map(hits, & &1["tags"]) == [["fact"], ["local"]]
  end

  test "list filters local memories and optionally includes facts", %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, %{"id" => local_id}} =
             Memory.remember(%{"content" => "ops local memory", "tags" => ["ops"]}, opts)

    assert {:ok, _} =
             Memory.remember(%{"content" => "ui local memory", "tags" => ["ui"]}, opts)

    insert_fact!(store, "fact_1", "ops fact", tags: ["ops"])

    assert {:ok, %{"items" => items}} = Memory.list(%{"tag" => "ops"}, opts)
    assert Enum.map(items, & &1["id"]) == [local_id]

    assert {:ok, %{"items" => with_facts}} =
             Memory.list(%{"tag" => "ops", "include_facts" => true}, opts)

    assert Enum.map(with_facts, & &1["source"]) == ["hub_fact", "local"]
  end

  test "stats returns local sync, outbox, facts, tombstones, and known scopes", %{
    tmp_dir: tmp_dir
  } do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, _} = Memory.remember(%{"content" => "stats local"}, opts)
    insert_fact!(store, "fact_1", "stats fact")

    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO tombstones(content_hash, scope, wiped_at, directive_id)
               VALUES (?, ?, ?, ?)
               """,
               [Reducer.content_hash("wiped"), "proj_local", "2026-06-17T00:00:00Z", "wipe_1"]
             )

    assert {:ok,
            %{
              "memories" => %{"pending" => 1},
              "outbox" => %{"pending" => 1},
              "facts" => 1,
              "tombstones" => 1,
              "known_scopes" => ["proj_local"]
            }} = Memory.stats(%{}, opts)
  end

  test "slots are device-local JSON values", %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, %{"key" => "goal", "value" => %{"step" => "PR2"}}} =
             Memory.slot_write(%{"key" => "goal", "value" => %{"step" => "PR2"}}, opts)

    assert {:ok, %{"key" => "goal", "value" => %{"step" => "PR2"}}} =
             Memory.slot_read(%{"key" => "goal"}, opts)

    assert {:ok, %{"slots" => [%{"key" => "goal", "value" => %{"step" => "PR2"}}]}} =
             Memory.slot_list(%{}, opts)
  end

  test "facets update local memory tags and query local JSON facets", %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    opts = memory_opts(store)

    assert {:ok, %{"id" => id}} = Memory.remember(%{"content" => "facet local"}, opts)

    assert {:ok, %{"id" => ^id, "tags" => ["important"], "metadata" => %{"topic" => "memory"}}} =
             Memory.facet_tag(
               %{"id" => id, "tags" => ["important"], "metadata" => %{"topic" => "memory"}},
               opts
             )

    assert {:ok, %{"items" => [%{"id" => ^id}]}} =
             Memory.facet_query(%{"tag" => "important", "facet" => %{"topic" => "memory"}}, opts)
  end

  defp memory_opts(store) do
    [
      store: store,
      agent_id: "agent_1",
      config: %{bound_scope: "proj_local", tombstone_relearn: "block"}
    ]
  end

  defp start_memory!(tmp_dir, opts \\ []) do
    name = :"host_agent_memory_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "#{name}.db")

    start_supervised!(
      {Store,
       database: db_path,
       name: name,
       pool_size: Keyword.get(opts, :pool_size, 1),
       busy_timeout_ms: 5_000}
    )

    assert :ok = Migrator.migrate(name)
    name
  end

  defp insert_fact!(store, id, content, opts \\ []) do
    now = Keyword.get(opts, :updated_at, "2026-06-17T00:00:00Z")
    tags = Keyword.get(opts, :tags, [])
    metadata = Keyword.get(opts, :metadata, %{})

    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO facts(id, content, content_hash, scope, tags, metadata, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               """,
               [
                 id,
                 content,
                 Reducer.content_hash(content),
                 "proj_local",
                 Jason.encode!(tags),
                 Jason.encode!(metadata),
                 now
               ]
             )
  end

  defp assert_count(store, table, expected) do
    assert {:ok, %Result{rows: [%{"count" => ^expected}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM #{table}")
  end
end
