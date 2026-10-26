defmodule Mix.Tasks.Agent.MemoryTasksTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Access, Migrator, Reducer, Store}
  alias Backplane.HostAgent.Memory
  alias Turso.Result

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)
    owner = start_supervised!({Access, name: nil, store: store, now_fun: fn -> 10_000 end})
    access_id = "11111111-1111-4111-8111-111111111111"

    assert :ok =
             Access.install_inventory(
               %{id: 1, sent_at_ms: 10_000},
               %{
                 "extensions" => ~w(memory_access.v1 memory_commands.v2),
                 "default_access_id" => access_id,
                 "accesses" => [
                   %{
                     "access_id" => access_id,
                     "authority_version" => 1,
                     "status" => "active",
                     "partition" => %{
                       "memory_space_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                       "scope" => "proj_local",
                       "namespace" => "private"
                     },
                     "capabilities" => ~w(read remember forget),
                     "offline_read_lease_seconds" => 0
                   }
                 ]
               },
               owner
             )

    {:ok, target, _} = Access.begin_request(:default, :remember, owner)
    Application.put_env(:backplane_host_agent, :memory_store, store)

    on_exit(fn ->
      Application.delete_env(:backplane_host_agent, :memory_store)
      Mix.Task.reenable("agent.memory.resync")
      Mix.Task.reenable("agent.memory.tombstones")
    end)

    {:ok, store: store, owner: owner, target: target}
  end

  test "agent.memory.resync requeues failed authority-bound commands without changing identity",
       c do
    command = insert_failed_command!(c, "dead memory")
    Mix.Tasks.Agent.Memory.Resync.run([])
    assert {:ok, %Result{rows: [requeued]}} = Store.query(c.store, "SELECT * FROM memory_outbox")
    assert requeued["state"] == "pending"
    assert requeued["attempts"] == 0
    assert requeued["last_error"] == nil
    assert requeued["dead_lettered_at"] == nil

    assert Map.take(
             requeued,
             ~w(command_id access_id authority_version target_partition payload payload_digest request_key request_agent_id)
           ) ==
             Map.take(
               command,
               ~w(command_id access_id authority_version target_partition payload payload_digest request_key request_agent_id)
             )
  end

  test "agent.memory.resync requeues only selected authority-bound sequence numbers", c do
    first = insert_failed_command!(c, "first")
    second = insert_failed_command!(c, "second")
    Mix.Task.reenable("agent.memory.resync")
    Mix.Tasks.Agent.Memory.Resync.run(["--seq", Integer.to_string(first["seq"])])
    first_id = first["command_id"]
    second_id = second["command_id"]

    assert {:ok,
            %Result{
              rows: [
                %{"command_id" => ^first_id, "state" => "pending"},
                %{"command_id" => ^second_id, "state" => "dead_letter"}
              ]
            }} =
             Store.query(c.store, "SELECT command_id,state FROM memory_outbox ORDER BY seq")
  end

  test "agent.memory.resync never replays quarantined history even when explicitly selected", c do
    command = insert_failed_command!(c, "bound command")

    assert {:ok, _} =
             Store.execute(
               c.store,
               "INSERT INTO memory_outbox(op,memory_id,payload,state,attempts,last_error,inserted_at,updated_at,migration_state,migration_reason) VALUES ('remember','historical','original-payload','dead_letter',2,'lost ACK','original-time','original-time','inflight','needs_verified_receipt_and_authority_mapping')"
             )

    assert {:ok, %Result{rows: [quarantined]}} =
             Store.query(c.store, "SELECT * FROM memory_outbox WHERE access_id IS NULL")

    Mix.Tasks.Agent.Memory.Resync.run(["--all"])

    assert {:ok, %Result{rows: [^quarantined]}} =
             Store.query(c.store, "SELECT * FROM memory_outbox WHERE access_id IS NULL")

    Mix.Task.reenable("agent.memory.resync")
    Mix.Tasks.Agent.Memory.Resync.run(["--seq", Integer.to_string(quarantined["seq"])])

    assert {:ok, %Result{rows: [^quarantined]}} =
             Store.query(c.store, "SELECT * FROM memory_outbox WHERE access_id IS NULL")

    assert {:ok, %Result{rows: [%{"state" => "pending"}]}} =
             Store.query(c.store, "SELECT state FROM memory_outbox WHERE command_id=?", [
               command["command_id"]
             ])
  end

  test "agent.memory.resync rejects positional arguments before mutating commands", c do
    command = insert_failed_command!(c, "dead")
    Mix.Task.reenable("agent.memory.resync")
    assert_raise Mix.Error, fn -> Mix.Tasks.Agent.Memory.Resync.run(["unexpected"]) end
    assert {:ok, %Result{rows: [^command]}} = Store.query(c.store, "SELECT * FROM memory_outbox")
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

  defp insert_failed_command!(c, content) do
    assert {:ok, receipt} =
             Access.run_local(
               c.target,
               :remember,
               &Memory.shared_enqueue(
                 &1,
                 "remember",
                 %{"content" => content, "idempotency_key" => content},
                 "agent_1"
               ),
               c.owner
             )

    assert {:ok, _} =
             Store.execute(
               c.store,
               "UPDATE memory_outbox SET state='dead_letter',attempts=3,last_error='validation failed',dead_lettered_at='2026-06-17T00:00:00Z' WHERE command_id=?",
               [receipt["command_id"]]
             )

    assert {:ok, %Result{rows: [command]}} =
             Store.query(c.store, "SELECT * FROM memory_outbox WHERE command_id=?", [
               receipt["command_id"]
             ])

    command
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
