defmodule Backplane.HostAgent.Memory.MigratorTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Migrator, Store}
  alias Backplane.HostAgent.Memory.Migrations.{V1, V8}
  alias Turso.Result

  @moduletag :tmp_dir

  test "migrates a clean database to the latest schema and re-runs idempotently", %{
    tmp_dir: tmp_dir
  } do
    store = start_store!(tmp_dir)

    assert {:ok, 0} = Migrator.current_version(store)
    assert :ok = Migrator.migrate(store)
    assert Migrator.latest_version() == 9
    assert {:ok, 9} = Migrator.current_version(store)

    assert MapSet.subset?(
             MapSet.new(~w(local_records memory_outbox memory_sync_state)),
             table_names(store)
           )

    for legacy <- ~w(memories facts tombstones slots memory_request_keys canonical_memory_receipts) do
      refute MapSet.member?(table_names(store), legacy)
    end

    assert MapSet.subset?(
             MapSet.new(~w(local_records_status_observed_idx local_records_kind_status_idx)),
             index_names(store)
           )

    assert table_columns(store, "memory_outbox") ==
             ~w(seq op local_id payload state attempts last_error inserted_at updated_at)

    assert :ok = Migrator.migrate(store)
    assert {:ok, 9} = Migrator.current_version(store)
  end

  test "V8 tables enforce sync_state and outbox constraints", %{tmp_dir: tmp_dir} do
    store = start_store!(tmp_dir)
    assert :ok = Migrator.migrate(store)
    now = "2026-06-17T00:00:00Z"

    insert = """
    INSERT INTO local_records(local_id, kind, content, writer, observed_at, updated_at, sync_state)
    VALUES (?, 'note', 'c', 'agent', ?, ?, ?)
    """

    assert {:ok, %Result{num_rows: 1}} = Store.execute(store, insert, ["l1", now, now, "pending"])
    assert {:error, %Turso.Error{}} = Store.execute(store, insert, ["l2", now, now, "bogus"])

    assert {:error, %Turso.Error{}} =
             Store.execute(
               store,
               "INSERT INTO memory_outbox(op, local_id, payload, inserted_at, updated_at) VALUES ('update', 'l1', '{}', ?, ?)",
               [now, now]
             )
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

  test "V8 -> V9 adds provenance columns, keeps rows and clears the pull cursor", %{
    tmp_dir: tmp_dir
  } do
    store = start_store!(tmp_dir)
    now = "2026-06-17T00:00:00Z"

    assert {:ok, _} =
             Store.transaction(store, fn conn ->
               Enum.each(V8.up(), fn sql -> assert {:ok, _} = Store.execute(conn, sql) end)
               assert {:ok, _} = Store.execute(conn, "PRAGMA user_version = 8")
             end)

    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO local_records(local_id, kind, content, writer, observed_at, updated_at, sync_state) VALUES ('l1', 'note', 'c', 'agent', ?, ?, 'synced')",
               [now, now]
             )

    for {key, value} <- [{"pull_cursor", ~s({"id":"x"})}, {"last_sync_at", now}] do
      assert {:ok, _} =
               Store.execute(store, "INSERT INTO memory_sync_state(key, value) VALUES (?, ?)", [
                 key,
                 value
               ])
    end

    assert :ok = Migrator.migrate(store)
    assert {:ok, 9} = Migrator.current_version(store)

    columns = table_columns(store, "local_records")
    assert Enum.take(columns, -3) == ~w(host_id client_id source_event_ids)

    assert {:ok, %Result{rows: [row]}} =
             Store.query(store, "SELECT host_id, client_id, source_event_ids FROM local_records")

    assert row == %{"host_id" => nil, "client_id" => nil, "source_event_ids" => "[]"}

    assert {:ok, %Result{rows: [%{"key" => "last_sync_at"}]}} =
             Store.query(store, "SELECT key FROM memory_sync_state")
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
