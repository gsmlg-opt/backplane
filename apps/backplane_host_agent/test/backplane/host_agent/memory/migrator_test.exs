defmodule Backplane.HostAgent.Memory.MigratorTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Migrator, Store}
  alias Backplane.HostAgent.Memory.Migrations.{V1, V2}
  alias Turso.Result

  @moduletag :tmp_dir

  test "migrates a clean database and re-runs idempotently", %{tmp_dir: tmp_dir} do
    store = start_store!(tmp_dir)

    assert {:ok, 0} = Migrator.current_version(store)
    assert :ok = Migrator.migrate(store)
    refute MapSet.member?(table_names(store), "memory_outbox_sequence_v2")

    latest = Migrator.latest_version()
    assert {:ok, ^latest} = Migrator.current_version(store)

    assert MapSet.subset?(
             MapSet.new(~w(memories facts memory_outbox tombstones slots)),
             table_names(store)
           )

    assert MapSet.subset?(
             MapSet.new(~w(
                 memories_content_scope_live_uniq
                 memories_scope_inserted_idx
                 memories_sync_state_idx
                 memories_deleted_idx
                 facts_scope_updated_idx
                 memory_outbox_due_seq_idx
                 memory_outbox_retention_idx
                 memory_outbox_memory_id_idx
               )),
             index_names(store)
           )

    assert table_columns(store, "tombstones") ==
             ~w(content_hash scope wiped_at directive_id)

    assert List.last(table_columns(store, "memories")) == "remote_revision"

    assert table_sql(store, "tombstones") =~ "PRIMARY KEY (scope, content_hash)"

    assert table_columns(store, "memory_outbox") ==
             ~w(
               seq op memory_id state attempts next_attempt_at last_error completed_at
               dead_lettered_at inserted_at updated_at
             )

    assert index_columns(store, "memory_outbox_due_seq_idx") == ~w(state next_attempt_at seq)

    assert index_columns(store, "memory_outbox_retention_idx") ==
             ~w(state completed_at dead_lettered_at seq)

    assert index_columns(store, "memory_outbox_memory_id_idx") == ["memory_id"]

    assert table_sql(store, "memory_outbox") =~
             "CHECK (state IN ('pending', 'inflight', 'retry_wait', 'done', 'dead_letter'))"

    assert :ok = Migrator.migrate(store)
    assert {:ok, ^latest} = Migrator.current_version(store)
  end

  test "creates the PR1 memory tables with defaults and constraints", %{tmp_dir: tmp_dir} do
    store = start_store!(tmp_dir)
    assert :ok = Migrator.migrate(store)

    now = "2026-06-17T00:00:00Z"
    content_hash = String.duplicate("a", 64)

    insert_memory_sql = """
    INSERT INTO memories(id, content, content_hash, scope, agent_id, inserted_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT DO NOTHING
    """

    assert {:ok, %Result{num_rows: 1}} =
             Store.execute(store, insert_memory_sql, [
               "mem_1",
               "remember this",
               content_hash,
               "proj_local",
               "agent_1",
               now,
               now
             ])

    assert {:ok,
            %Result{
              rows: [
                %{
                  "memory_type" => "episodic",
                  "sync_state" => "pending",
                  "tags" => "[]",
                  "metadata" => "{}",
                  "confidence" => confidence
                }
              ]
            }} =
             Store.query(
               store,
               "SELECT memory_type, sync_state, tags, metadata, confidence FROM memories WHERE id = ?",
               ["mem_1"]
             )

    assert confidence in [1, 1.0]

    assert {:ok, %Result{num_rows: 0}} =
             Store.execute(store, insert_memory_sql, [
               "mem_duplicate",
               "duplicate",
               content_hash,
               "proj_local",
               "agent_1",
               now,
               now
             ])

    assert {:ok, _} =
             Store.execute(
               store,
               "UPDATE memories SET deleted_at = ?, updated_at = ? WHERE id = ?",
               [now, now, "mem_1"]
             )

    assert {:ok, %Result{num_rows: 1}} =
             Store.execute(store, insert_memory_sql, [
               "mem_2",
               "remember this again",
               content_hash,
               "proj_local",
               "agent_1",
               now,
               now
             ])

    assert {:error, %Turso.Error{}} =
             Store.execute(
               store,
               """
               INSERT INTO memory_outbox(op, memory_id, inserted_at, updated_at)
               VALUES (?, ?, ?, ?)
               """,
               ["update", "mem_2", now, now]
             )

    assert {:ok, %Result{num_rows: 1}} =
             Store.execute(
               store,
               """
               INSERT INTO memory_outbox(op, memory_id, inserted_at, updated_at)
               VALUES (?, ?, ?, ?)
               """,
               ["remember", "mem_2", now, now]
             )

    assert {:ok, %Result{rows: [%{"state" => "pending", "attempts" => 0}]}} =
             Store.query(
               store,
               "SELECT state, attempts FROM memory_outbox WHERE memory_id = ?",
               ["mem_2"]
             )
  end

  test "upgrades V1 tombstones and every historical outbox state to V2 without losing rows", %{
    tmp_dir: tmp_dir
  } do
    store = start_store!(tmp_dir)
    now = "2026-06-17T00:00:00Z"

    assert :ok = apply_v1!(store)

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO tombstones(content_hash, scope, wiped_at, directive_id) VALUES (?, ?, ?, ?)",
               ["same-hash", "scope-a", now, "wipe-a"]
             )

    for {state, seq} <- Enum.with_index(~w(pending inflight done failed), 1) do
      assert {:ok, _} =
               Store.execute(
                 store,
                 """
                 INSERT INTO memory_outbox(seq, op, memory_id, state, attempts, last_error, inserted_at, updated_at)
                 VALUES (?, 'remember', ?, ?, ?, ?, ?, ?)
                 """,
                 [seq, "memory-#{state}", state, seq, "#{state} error", now, now]
               )
    end

    assert :ok = Migrator.migrate(store)
    assert {:ok, 3} = Migrator.current_version(store)

    assert MapSet.subset?(
             MapSet.new(
               ~w(memory_outbox_due_seq_idx memory_outbox_retention_idx memory_outbox_memory_id_idx)
             ),
             index_names(store)
           )

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO tombstones(content_hash, scope, wiped_at, directive_id) VALUES (?, ?, ?, ?)",
               ["same-hash", "scope-b", now, "wipe-b"]
             )

    assert {:ok, %Result{rows: [%{"count" => 2}]}} =
             Store.query(
               store,
               "SELECT COUNT(*) AS count FROM tombstones WHERE content_hash = ?",
               ["same-hash"]
             )

    assert {:ok,
            %Result{
              rows: [
                %{"state" => "pending", "attempts" => 1, "last_error" => "pending error"},
                %{"state" => "inflight", "attempts" => 2, "last_error" => "inflight error"},
                %{"state" => "done", "attempts" => 3, "completed_at" => ^now},
                %{
                  "state" => "dead_letter",
                  "attempts" => 4,
                  "last_error" => "failed error",
                  "dead_lettered_at" => ^now
                }
              ]
            }} =
             Store.query(
               store,
               "SELECT state, attempts, last_error, completed_at, dead_lettered_at FROM memory_outbox ORDER BY seq"
             )

    assert :ok = Migrator.migrate(store)
    assert {:ok, 3} = Migrator.current_version(store)
  end

  test "upgrades populated V2 command memories to V3 without changing data", %{tmp_dir: tmp_dir} do
    store = start_store!(tmp_dir)
    now = "2026-06-17T00:00:00Z"
    assert :ok = apply_v1!(store)

    assert {:ok, _} =
             Store.transaction(store, fn conn ->
               Enum.each(V2.up(), fn sql ->
                 assert {:ok, _} = Store.execute(conn, sql)
               end)

               assert {:ok, _} = Store.execute(conn, "PRAGMA user_version = 2")
             end)

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO memories(id, content, content_hash, scope, agent_id, remote_id, sync_state, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [
                 "mem_old",
                 "old",
                 String.duplicate("a", 64),
                 "proj_local",
                 "agent_1",
                 "hub_old",
                 "synced",
                 now,
                 now
               ]
             )

    assert :ok = Migrator.migrate(store)
    assert {:ok, 3} = Migrator.current_version(store)

    assert {:ok,
            %Result{
              rows: [
                %{
                  "id" => "mem_old",
                  "remote_id" => "hub_old",
                  "sync_state" => "synced",
                  "remote_revision" => nil
                }
              ]
            }} =
             Store.query(store, "SELECT id, remote_id, sync_state, remote_revision FROM memories")

    assert :ok = Migrator.migrate(store)
  end

  test "preserves the V1 outbox sequence high-water when all rows were deleted", %{
    tmp_dir: tmp_dir
  } do
    store = start_store!(tmp_dir)
    now = "2026-06-17T00:00:00Z"
    assert :ok = apply_v1!(store)

    for index <- 1..3 do
      assert {:ok, _} =
               Store.execute(
                 store,
                 "INSERT INTO memory_outbox(op, memory_id, inserted_at, updated_at) VALUES (?, ?, ?, ?)",
                 ["remember", "legacy-memory-#{index}", now, now]
               )
    end

    assert {:ok, %Result{rows: [%{"seq" => high_water}]}} =
             Store.query(store, "SELECT seq FROM sqlite_sequence WHERE name = 'memory_outbox'")

    assert {:ok, _} = Store.execute(store, "DELETE FROM memory_outbox")
    assert :ok = Migrator.migrate(store)

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO memory_outbox(op, memory_id, inserted_at, updated_at) VALUES (?, ?, ?, ?)",
               ["remember", "post-upgrade-memory", now, now]
             )

    assert {:ok, %Result{rows: [%{"seq" => next_seq}]}} =
             Store.query(store, "SELECT seq FROM memory_outbox WHERE memory_id = ?", [
               "post-upgrade-memory"
             ])

    assert next_seq > high_water
  end

  test "fails closed rather than dropping or inventing a sentinel for a NULL V1 tombstone identity",
       %{
         tmp_dir: tmp_dir
       } do
    store = start_store!(tmp_dir)
    now = "2026-06-17T00:00:00Z"
    assert :ok = apply_v1!(store)

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO tombstones(content_hash, scope, wiped_at, directive_id) VALUES (NULL, ?, ?, ?)",
               ["scope-a", now, "invalid-null-hash"]
             )

    for index <- 1..2 do
      assert {:ok, _} =
               Store.execute(
                 store,
                 "INSERT INTO memory_outbox(op, memory_id, inserted_at, updated_at) VALUES (?, ?, ?, ?)",
                 ["remember", "legacy-memory-#{index}", now, now]
               )
    end

    assert {:ok, %Result{rows: [%{"seq" => high_water}]}} =
             Store.query(store, "SELECT seq FROM sqlite_sequence WHERE name = 'memory_outbox'")

    assert {:error, _} = Migrator.migrate(store)
    assert {:ok, 1} = Migrator.current_version(store)
    assert MapSet.member?(table_names(store), "tombstones")
    assert MapSet.member?(table_names(store), "memory_outbox")
    refute MapSet.member?(table_names(store), "tombstones_v1")
    refute MapSet.member?(table_names(store), "memory_outbox_v1")
    refute MapSet.member?(table_names(store), "memory_outbox_sequence_v2")

    assert {:ok, %Result{rows: [%{"count" => 1}]}} =
             Store.query(
               store,
               "SELECT COUNT(*) AS count FROM tombstones WHERE content_hash IS NULL"
             )

    assert {:ok, %Result{rows: [%{"seq" => ^high_water}]}} =
             Store.query(store, "SELECT seq FROM sqlite_sequence WHERE name = 'memory_outbox'")
  end

  test "rolls back the rebuilt outbox and sequence after a late migration failure", %{
    tmp_dir: tmp_dir
  } do
    store = start_store!(tmp_dir)
    now = "2026-06-17T00:00:00Z"
    assert :ok = apply_v1!(store)

    for index <- 1..2 do
      assert {:ok, _} =
               Store.execute(
                 store,
                 "INSERT INTO memory_outbox(op, memory_id, inserted_at, updated_at) VALUES (?, ?, ?, ?)",
                 ["remember", "legacy-memory-#{index}", now, now]
               )
    end

    assert {:ok, %Result{rows: [%{"seq" => high_water}]}} =
             Store.query(store, "SELECT seq FROM sqlite_sequence WHERE name = 'memory_outbox'")

    assert {:ok, _} =
             Store.execute(store, "CREATE TABLE migration_collision (id INTEGER PRIMARY KEY)")

    assert {:ok, _} =
             Store.execute(
               store,
               "CREATE INDEX memory_outbox_due_seq_idx ON migration_collision(id)"
             )

    assert {:error, _} = Migrator.migrate(store)
    assert {:ok, 1} = Migrator.current_version(store)
    assert MapSet.member?(table_names(store), "tombstones")
    assert MapSet.member?(table_names(store), "memory_outbox")
    refute MapSet.member?(table_names(store), "tombstones_v1")
    refute MapSet.member?(table_names(store), "memory_outbox_v1")
    refute MapSet.member?(table_names(store), "memory_outbox_sequence_v2")

    assert {:ok, %Result{rows: [%{"count" => 2}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM memory_outbox")

    assert {:ok, %Result{rows: [%{"seq" => ^high_water}]}} =
             Store.query(store, "SELECT seq FROM sqlite_sequence WHERE name = 'memory_outbox'")
  end

  defp table_names(store) do
    {:ok, %Result{rows: rows}} =
      Store.query(store, "SELECT name FROM sqlite_master WHERE type = 'table'")

    rows
    |> Enum.map(& &1["name"])
    |> MapSet.new()
  end

  defp index_names(store) do
    {:ok, %Result{rows: rows}} =
      Store.query(store, "SELECT name FROM sqlite_master WHERE type = 'index'")

    rows
    |> Enum.map(& &1["name"])
    |> MapSet.new()
  end

  defp table_columns(store, table) do
    assert {:ok, %Result{rows: rows}} = Store.query(store, "PRAGMA table_info(#{table})")
    Enum.map(rows, & &1["name"])
  end

  defp table_sql(store, table) do
    assert {:ok, %Result{rows: [%{"sql" => sql}]}} =
             Store.query(
               store,
               "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
               [table]
             )

    sql
  end

  defp index_columns(store, index) do
    assert {:ok, %Result{rows: rows}} = Store.query(store, "PRAGMA index_info(#{index})")
    Enum.map(rows, & &1["name"])
  end

  defp start_store!(tmp_dir) do
    name = :"host_agent_memory_migrator_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "#{name}.db")

    start_supervised!(
      {Store, database: db_path, name: name, pool_size: 1, busy_timeout_ms: 5_000}
    )

    name
  end

  defp apply_v1!(store) do
    assert {:ok, _} =
             Store.transaction(store, fn conn ->
               Enum.each(V1.up(), fn sql ->
                 assert {:ok, _} = Store.execute(conn, sql)
               end)

               assert {:ok, _} = Store.execute(conn, "PRAGMA user_version = 1")
             end)

    :ok
  end
end
