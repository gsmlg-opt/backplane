defmodule Backplane.HostAgent.Memory.PrunerTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Migrator, Pruner, Reducer, Store}
  alias ExTurso.Result

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    {:ok, store: store}
  end

  test "deletes only old synced local memories and eligible deleted rows", %{store: store} do
    old = "2026-01-01T00:00:00Z"
    recent = "2026-06-17T00:00:00Z"
    cutoff = "2026-03-17T00:00:00Z"

    insert_memory!(store, "old_synced", "old synced", sync_state: "synced", inserted_at: old)
    insert_memory!(store, "old_pending", "old pending", sync_state: "pending", inserted_at: old)
    insert_memory!(store, "old_failed", "old failed", sync_state: "failed", inserted_at: old)

    insert_memory!(store, "recent_synced", "recent synced",
      sync_state: "synced",
      inserted_at: recent
    )

    insert_memory!(
      store,
      "deleted_done",
      "deleted done",
      sync_state: "synced",
      inserted_at: old,
      deleted_at: recent
    )

    insert_outbox!(store, "forget", "deleted_done", "done")

    insert_memory!(
      store,
      "deleted_failed",
      "deleted failed",
      sync_state: "synced",
      inserted_at: old,
      deleted_at: recent
    )

    insert_outbox!(store, "forget", "deleted_failed", "failed")
    insert_fact!(store, "fact_1", "fact stays")
    insert_tombstone!(store, "wiped stays")
    insert_slot!(store, "slot_stays")

    assert {:ok, %{"deleted" => 2, "cutoff" => ^cutoff}} =
             Pruner.prune_once(store: store, cutoff: cutoff)

    assert_memory_ids(store, ["deleted_failed", "old_failed", "old_pending", "recent_synced"])
    assert_count(store, "facts", 1)
    assert_count(store, "tombstones", 1)
    assert_count(store, "slots", 1)
  end

  defp start_memory!(tmp_dir) do
    name = :"host_agent_memory_pruner_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "#{name}.db")

    start_supervised!(
      {Store, database: db_path, name: name, pool_size: 1, busy_timeout_ms: 5_000}
    )

    assert :ok = Migrator.migrate(name)
    name
  end

  defp insert_memory!(store, id, content, opts) do
    inserted_at = Keyword.fetch!(opts, :inserted_at)
    updated_at = Keyword.get(opts, :updated_at, inserted_at)
    deleted_at = Keyword.get(opts, :deleted_at)
    sync_state = Keyword.fetch!(opts, :sync_state)

    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO memories(
                 id, content, content_hash, scope, agent_id, tags, metadata,
                 sync_state, inserted_at, updated_at, deleted_at
               )
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               """,
               [
                 id,
                 content,
                 Reducer.content_hash(content),
                 "proj_local",
                 "agent_1",
                 "[]",
                 "{}",
                 sync_state,
                 inserted_at,
                 updated_at,
                 deleted_at
               ]
             )
  end

  defp insert_outbox!(store, op, memory_id, state) do
    now = "2026-06-17T00:00:00Z"

    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO memory_outbox(op, memory_id, state, inserted_at, updated_at)
               VALUES (?, ?, ?, ?, ?)
               """,
               [op, memory_id, state, now, now]
             )
  end

  defp insert_fact!(store, id, content) do
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
                 "[]",
                 "{}",
                 "2026-06-17T00:00:00Z"
               ]
             )
  end

  defp insert_tombstone!(store, content) do
    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO tombstones(content_hash, scope, wiped_at, directive_id)
               VALUES (?, ?, ?, ?)
               """,
               [Reducer.content_hash(content), "proj_local", "2026-06-17T00:00:00Z", "wipe_1"]
             )
  end

  defp insert_slot!(store, key) do
    assert {:ok, _} =
             Store.execute(
               store,
               "INSERT INTO slots(scope, key, value, updated_at) VALUES (?, ?, ?, ?)",
               ["proj_local", key, Jason.encode!(%{"ok" => true}), "2026-06-17T00:00:00Z"]
             )
  end

  defp assert_memory_ids(store, expected) do
    assert {:ok, %Result{rows: rows}} =
             Store.query(store, "SELECT id FROM memories ORDER BY id")

    assert Enum.map(rows, & &1["id"]) == expected
  end

  defp assert_count(store, table, expected) do
    assert {:ok, %Result{rows: [%{"count" => ^expected}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM #{table}")
  end
end
