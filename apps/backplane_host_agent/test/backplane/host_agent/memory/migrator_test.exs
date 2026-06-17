defmodule Backplane.HostAgent.Memory.MigratorTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Migrator, Store}
  alias ExTurso.Result

  @moduletag :tmp_dir

  test "migrates a clean database and re-runs idempotently", %{tmp_dir: tmp_dir} do
    store = start_store!(tmp_dir)

    assert {:ok, 0} = Migrator.current_version(store)
    assert :ok = Migrator.migrate(store)

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
                 memory_outbox_state_seq_idx
                 memory_outbox_memory_id_idx
               )),
             index_names(store)
           )

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

    assert {:error, %ExTurso.Error{}} =
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

  defp start_store!(tmp_dir) do
    name = :"host_agent_memory_migrator_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "#{name}.db")

    start_supervised!(
      {Store, database: db_path, name: name, pool_size: 1, busy_timeout_ms: 5_000}
    )

    name
  end
end
