defmodule Mix.Tasks.Agent.MemoryTasksTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Migrator, Reducer, Store}
  alias Turso.Result

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    Application.put_env(:backplane_host_agent, :memory_store, store)

    on_exit(fn ->
      Application.delete_env(:backplane_host_agent, :memory_store)
      Mix.Task.reenable("agent.memory.resync")
      Mix.Task.reenable("agent.memory.tombstones")
    end)

    {:ok, store: store}
  end

  test "agent.memory.resync requeues dead-lettered outbox rows", %{store: store} do
    insert_memory!(store, "dead_memory", "dead")
    insert_outbox!(store, "dead_memory", "dead_letter", "validation failed")

    Mix.Tasks.Agent.Memory.Resync.run([])

    assert {:ok, %Result{rows: [%{"state" => "pending", "last_error" => nil}]}} =
             Store.query(store, "SELECT state, last_error FROM memory_outbox")
  end

  test "agent.memory.resync requeues only selected sequence numbers", %{store: store} do
    insert_memory!(store, "first", "first")
    insert_outbox!(store, "first", "dead_letter", "bad")
    insert_memory!(store, "second", "second")
    insert_outbox!(store, "second", "dead_letter", "bad")

    assert {:ok, %Result{rows: [%{"seq" => seq}]}} =
             Store.query(store, "SELECT seq FROM memory_outbox WHERE memory_id = 'first'")

    Mix.Task.reenable("agent.memory.resync")
    Mix.Tasks.Agent.Memory.Resync.run(["--seq", Integer.to_string(seq)])

    assert {:ok, %Result{rows: [%{"state" => "pending"}, %{"state" => "dead_letter"}]}} =
             Store.query(store, "SELECT state FROM memory_outbox ORDER BY seq")
  end

  test "agent.memory.resync rejects positional arguments", %{store: store} do
    insert_memory!(store, "dead", "dead")
    insert_outbox!(store, "dead", "dead_letter", "bad")
    Mix.Task.reenable("agent.memory.resync")

    assert_raise Mix.Error, fn -> Mix.Tasks.Agent.Memory.Resync.run(["unexpected"]) end

    assert {:ok, %Result{rows: [%{"state" => "dead_letter"}]}} =
             Store.query(store, "SELECT state FROM memory_outbox")
  end

  test "agent.memory.tombstones requires --purge and purges tombstones", %{store: store} do
    insert_tombstone!(store, "wiped")

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Agent.Memory.Tombstones.run([])
    end

    Mix.Tasks.Agent.Memory.Tombstones.run(["--purge"])

    assert_count(store, "tombstones", 0)
  end

  defp start_memory!(tmp_dir) do
    name = :"host_agent_memory_tasks_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "#{name}.db")

    start_supervised!(
      {Store, database: db_path, name: name, pool_size: 1, busy_timeout_ms: 5_000}
    )

    assert :ok = Migrator.migrate(name)
    name
  end

  defp insert_memory!(store, id, content) do
    now = "2026-06-17T00:00:00Z"

    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO memories(id, content, content_hash, scope, agent_id, tags, metadata, inserted_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
               """,
               [
                 id,
                 content,
                 Reducer.content_hash(content),
                 "proj_local",
                 "agent_1",
                 "[]",
                 "{}",
                 now,
                 now
               ]
             )
  end

  defp insert_outbox!(store, memory_id, state, last_error) do
    now = "2026-06-17T00:00:00Z"

    assert {:ok, _} =
             Store.execute(
               store,
               """
               INSERT INTO memory_outbox(op, memory_id, state, last_error, inserted_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?)
               """,
               ["remember", memory_id, state, last_error, now, now]
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
