defmodule Backplane.HostAgent.Memory.DiagnosticsTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Diagnostics, Migrator, Reducer, Store, Syncer}
  alias Turso.Result

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    {:ok, store: store}
  end

  test "snapshot reports store, sync, facts, tombstones, and recovery state", %{store: store} do
    insert_memory!(store, "pending_memory", "pending", sync_state: "pending")

    insert_memory!(
      store,
      "synced_memory",
      "synced",
      sync_state: "synced",
      synced_at: "2026-06-16T00:00:00Z"
    )

    insert_memory!(store, "dead_memory", "dead", sync_state: "pending")
    pending_seq = insert_outbox!(store, "remember", "pending_memory", "pending")

    failed_seq =
      insert_outbox!(store, "remember", "dead_memory", "dead_letter", "validation failed")

    insert_fact!(store, "fact_1", "fact content", "proj_local", "2026-06-17T00:00:00Z")
    insert_fact!(store, "fact_2", "other fact", "other_scope", "2026-06-15T00:00:00Z")
    insert_tombstone!(store, "wiped")

    assert {:ok,
            %{
              "store" => %{"status" => "ok", "db_path" => "/tmp/memory.db"},
              "memories" => %{"pending" => 2, "synced" => 1},
              "outbox" => %{"pending" => 1, "dead_letter" => 1},
              "oldest_pending_seq" => ^pending_seq,
              "failed_outbox" => [
                %{
                  "seq" => ^failed_seq,
                  "memory_id" => "dead_memory",
                  "op" => "remember",
                  "last_error" => "validation failed"
                }
              ],
              "facts" => %{
                "count" => 2,
                "scopes" => fact_scopes
              },
              "tombstones" => 1,
              "last_successful_sync" => "2026-06-16T00:00:00Z",
              "last_reconcile_at" => "2026-06-17T00:00:00Z"
            }} = Diagnostics.snapshot(store: store, db_path: "/tmp/memory.db")

    assert [
             %{"scope" => "other_scope", "count" => 1},
             %{"scope" => "proj_local", "count" => 1, "fact_set_hash" => fact_hash}
           ] = fact_scopes

    assert fact_hash == Syncer.fact_set_hash(store, "proj_local")
  end

  test "snapshot reports the edge protection decision without opening edge storage", %{
    store: store
  } do
    assert {:ok, %{"edge_protection" => "protection_unavailable"}} =
             Diagnostics.snapshot(
               store: store,
               host_sync_v2: %{enabled: true, development_plaintext: false}
             )
  end

  test "recovery helpers requeue dead-letter rows and purge tombstones explicitly", %{
    store: store
  } do
    insert_memory!(store, "dead_memory", "dead", sync_state: "pending")
    insert_outbox!(store, "remember", "dead_memory", "dead_letter", "validation failed")
    insert_tombstone!(store, "wiped")

    assert {:ok, %{"requeued" => 1}} = Diagnostics.requeue_failed_outbox(store: store)

    assert {:ok, %Result{rows: [%{"state" => "pending", "last_error" => nil}]}} =
             Store.query(store, "SELECT state, last_error FROM memory_outbox")

    assert {:ok, %{"purged" => 1}} = Diagnostics.purge_tombstones(store: store)
    assert_count(store, "tombstones", 0)
  end

  test "requeues only selected dead-letter rows and resets retry state", %{store: store} do
    insert_memory!(store, "first", "first", sync_state: "pending")
    first = insert_outbox!(store, "remember", "first", "dead_letter", "bad")
    insert_memory!(store, "second", "second", sync_state: "pending")
    insert_outbox!(store, "remember", "second", "dead_letter", "bad")

    assert {:ok, %{"requeued" => 1}} =
             Diagnostics.requeue_failed_outbox(store: store, seqs: [first])

    assert {:ok, %Result{rows: rows}} =
             Store.query(
               store,
               "SELECT state, attempts, last_error, dead_lettered_at FROM memory_outbox ORDER BY seq"
             )

    assert [
             %{
               "state" => "pending",
               "attempts" => 0,
               "last_error" => nil,
               "dead_lettered_at" => nil
             },
             %{"state" => "dead_letter"}
           ] = rows
  end

  defp start_memory!(tmp_dir) do
    name = :"host_agent_memory_diagnostics_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "#{name}.db")

    start_supervised!(
      {Store, database: db_path, name: name, pool_size: 1, busy_timeout_ms: 5_000}
    )

    assert :ok = Migrator.migrate(name)
    name
  end

  defp insert_memory!(store, id, content, opts) do
    now = "2026-06-17T00:00:00Z"
    synced_at = Keyword.get(opts, :synced_at)

    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO memories(
                 id, content, content_hash, scope, agent_id, tags, metadata,
                 sync_state, synced_at, inserted_at, updated_at
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
                 Keyword.fetch!(opts, :sync_state),
                 synced_at,
                 now,
                 now
               ]
             )
  end

  defp insert_outbox!(store, op, memory_id, state, last_error \\ nil) do
    now = "2026-06-17T00:00:00Z"

    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO memory_outbox(op, memory_id, state, last_error, inserted_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?)
               """,
               [op, memory_id, state, last_error, now, now]
             )

    assert {:ok, %Result{rows: [%{"seq" => seq}]}} =
             Store.query(store, "SELECT seq FROM memory_outbox WHERE memory_id = ?", [memory_id])

    seq
  end

  defp insert_fact!(store, id, content, scope, updated_at) do
    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO facts(id, content, content_hash, scope, tags, metadata, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               """,
               [id, content, Reducer.content_hash(content), scope, "[]", "{}", updated_at]
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

  defp assert_count(store, table, expected) do
    assert {:ok, %Result{rows: [%{"count" => ^expected}]}} =
             Store.query(store, "SELECT COUNT(*) AS count FROM #{table}")
  end
end
