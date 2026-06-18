defmodule Backplane.HostAgent.MemoryTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory
  alias Backplane.HostAgent.Memory.{Migrator, Reducer, Store}
  alias ExTurso.Result

  @moduletag :tmp_dir

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
