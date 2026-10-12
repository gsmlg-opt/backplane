Code.require_file("../../fixtures/goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.GoalStoreConformanceTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.Goal.{State, Store}
  alias Backplane.AgentRuntime.GoalFileStore

  test "CAS identity, tombstone, receipt and deferral survive owner restart" do
    dir = Path.join(System.tmp_dir!(), "goal-store-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, store} = GoalFileStore.start_link(dir)
    {:ok, empty} = Store.load(GoalFileStore, store, "thread")
    {:ok, goal} = State.create(empty, %{objective: "ship"})
    {:ok, record} = Store.compare_and_swap(GoalFileStore, store, "thread", 0, nil, goal)

    assert {:error, %{class: :resource_conflict}} =
             Store.compare_and_swap(GoalFileStore, store, "thread", 0, nil, goal)

    event = %{
      receipt_id: "abort",
      revision: 1,
      thread_id: "thread",
      run_id: "run",
      incarnation: 1,
      turn_id: "turn",
      expected_goal_id: record.goal.goal_id,
      type: :turn_aborted,
      payload: %{reason: :interrupt_turn}
    }

    {:ok, next} = State.account(record, event)
    {:ok, next} = State.clear(next)

    {:ok, tombstone} =
      Store.compare_and_swap(GoalFileStore, store, "thread", 1, record.goal.goal_id, next)

    GenServer.stop(store)
    {:ok, store} = GoalFileStore.start_link(dir)
    {:ok, restored} = Store.load(GoalFileStore, store, "thread")
    assert restored == tombstone
    assert restored.revision == 2
    assert restored.receipts["abort"]
    assert restored.continuation_deferral
    {:ok, replacement} = State.create(restored, %{objective: "new"})

    assert {:error, %{class: :resource_conflict}} =
             Store.compare_and_swap(
               GoalFileStore,
               store,
               "thread",
               2,
               record.goal.goal_id,
               replacement
             )

    assert {:ok, %{revision: 3}} =
             Store.compare_and_swap(GoalFileStore, store, "thread", 2, nil, replacement)

    GenServer.stop(store)
  end
end
