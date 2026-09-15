defmodule Backplane.AgentRuntime.ProviderDedupTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Budget
  alias Backplane.AgentRuntime.EphemeralStore
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Execution
  alias Backplane.AgentRuntime.ExecutionController
  alias Backplane.AgentRuntime.Kernel

  defmodule SpyProvider do
    def start(operation) do
      send(operation.provider_context.test, {:provider_called, operation})
      {:ok, %{attempt_id: operation.attempt_id}}
    end
  end

  test "controller rejects an active provider replay before another intent or adapter call" do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 2})

    {:ok, controller} =
      ExecutionController.start_link(
        store: EphemeralStore,
        context: table,
        run: running_record(),
        adapter: SpyProvider,
        provider_context: %{test: self()},
        budget: budget
      )

    attempt = provider("step_1", "attempt_1")

    assert {:ok, %{status: :submitted}} =
             ExecutionController.submit(controller, %{
               command: {:provider_started, 11, attempt},
               operation: %{messages: [%{role: "user", content: "first"}]}
             })

    assert {:ok, %{revision: 1, outbox: [_]}, %{effects: [%{attempt_id: "attempt_1"}]}} =
             ExecutionController.await(controller)

    assert_receive {:provider_called, %{attempt_id: "attempt_1"}}

    assert {:ok, %{status: :submitted}} =
             ExecutionController.submit(controller, %{
               command: {:provider_started, 12, attempt},
               operation: %{messages: [%{role: "user", content: "replay"}]}
             })

    assert {:error, %Error{class: :resource_conflict}} =
             ExecutionController.await(controller)

    refute_receive {:provider_called, _}
    assert {:ok, stored} = EphemeralStore.load(table, "run_1")
    assert stored.revision == 1
    assert stored.run.execution_budget.used == 1
    assert map_size(stored.run.execution_intents) == 1
    assert stored.run.execution_intents["provider:attempt_1"].status == :started
  end

  test "completed attempt cannot replay and new attempts consume quota" do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 2})
    first = provider("step_1", "attempt_1")

    assert {:ok, _, %{run: started}} = run_provider(table, running_record(), first, budget)
    assert_receive {:provider_called, %{attempt_id: "attempt_1"}}

    completion = Map.merge(first, %{final?: false, result: %{"next" => true}})

    assert {:ok, _, %{run: continued}} =
             run_no_effect(table, started, {:provider_completed, 12, completion})

    assert continued.execution_intents["provider:attempt_1"].status == :consumed

    assert {:error, %Error{class: :resource_conflict}} =
             run_provider(table, continued, first, budget, 13)

    refute_receive {:provider_called, _}
    assert {:ok, unchanged} = EphemeralStore.load(table, "run_1")
    assert unchanged.revision == 2
    assert unchanged.run.execution_budget.used == 1
    assert unchanged.run.execution_intents["provider:attempt_1"].status == :consumed

    second = provider("step_2", "attempt_2")

    assert {:ok, _, %{run: second_started}} =
             run_provider(table, unchanged.run, second, budget, 14)

    assert_receive {:provider_called, %{attempt_id: "attempt_2"}}
    assert second_started.execution_budget.used == 2

    third = provider("step_3", "attempt_3")

    assert {:error, %Error{class: :budget_exceeded}} =
             run_provider(table, second_started, third, budget, 15)

    refute_receive {:provider_called, _}
    assert {:ok, quota_state} = EphemeralStore.load(table, "run_1")
    assert quota_state.revision == 3
    assert quota_state.run.execution_budget.used == 2
  end

  test "a newer provider attempt supersedes the active attempt and fences stale completion" do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 3})
    first = provider("step_1", "attempt_1")
    second = provider("step_1", "attempt_2")

    assert {:ok, _, %{run: first_started}} = run_provider(table, running_record(), first, budget)
    assert_receive {:provider_called, %{attempt_id: "attempt_1"}}

    assert {:ok, _, %{run: second_started}} =
             run_provider(table, first_started, second, budget, 12)

    assert_receive {:provider_called, %{attempt_id: "attempt_2"}}
    assert second_started.execution_budget.used == 2

    stale = Map.merge(first, %{final?: false, result: %{stale: true}})

    assert {:error, %Error{class: :resource_conflict}} =
             run_no_effect(table, second_started, {:provider_completed, 13, stale})

    assert {:ok, stored} = EphemeralStore.load(table, "run_1")
    assert stored.revision == 2
    assert stored.run.active_provider.attempt_id == "attempt_2"
    assert stored.run.execution_intents["provider:attempt_1"].status == :started
    assert stored.run.execution_intents["provider:attempt_2"].status == :started
  end

  test "legacy active providers and persisted intents fence attempts without history metadata" do
    attempt = provider("step_1", "attempt_1")

    legacy_active = %{
      running_record()
      | active_provider: attempt,
        current_step: Map.take(attempt, [:step_id, :attempt_id])
    }

    assert {:error, %Error{class: :resource_conflict}} =
             Kernel.execute(legacy_active, {:provider_started, 12, attempt})

    legacy_consumed =
      running_record()
      |> Map.put(:execution_intents, %{
        "provider:attempt_1" => %{type: :provider, status: :consumed}
      })

    assert {:error, %Error{class: :resource_conflict}} =
             Kernel.execute(legacy_consumed, {:provider_started, 13, attempt})
  end

  defp run_provider(table, record, identity, budget, at \\ 11) do
    Execution.run(
      EphemeralStore,
      table,
      record,
      %{
        command: {:provider_started, at, identity},
        operation: %{messages: [%{role: "user", content: identity.attempt_id}]}
      },
      adapter: SpyProvider,
      provider_context: %{test: self()},
      budget: budget
    )
  end

  defp run_no_effect(table, record, command) do
    Execution.run(EphemeralStore, table, record, %{command: command})
  end

  defp provider(step_id, attempt_id) do
    %{run_id: "run_1", incarnation: 1, step_id: step_id, attempt_id: attempt_id}
  end

  defp running_record do
    %{
      run_id: "run_1",
      incarnation: 1,
      expected_revision: 0,
      state: :running,
      admitted: true,
      deadline: nil,
      outcome: nil,
      children: [],
      context: %{},
      active_provider: nil,
      current_step: nil,
      active_tools: %{},
      active_wait: nil,
      dependencies: [],
      settled_children: [],
      continuation_results: %{},
      tool_results: %{}
    }
  end
end
