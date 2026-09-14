defmodule Backplane.AgentRuntime.ExecutionTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.EphemeralStore
  alias Backplane.AgentRuntime.Budget
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Execution
  alias Backplane.AgentRuntime.ToolRegistry

  defmodule NoEffectAdapter do
    @behaviour Backplane.AgentRuntime.Provider
    @behaviour Backplane.AgentRuntime.ToolEffects

    @impl Backplane.AgentRuntime.Provider
    def start(_request), do: {:ok, %{started: true}}

    @impl Backplane.AgentRuntime.ToolEffects
    def execute(_invocation), do: {:ok, %{completed: true}}

    @impl Backplane.AgentRuntime.ToolEffects
    def cancel(_invocation), do: :ok

    @impl Backplane.AgentRuntime.Provider
    def chunks(_chunks), do: {:ok, %{type: :completed}}
  end

  describe "store-first execution" do
    test "admits a run without dispatching an external effect" do
      {:ok, context} = EphemeralStore.new(System.unique_integer([:positive]))
      record = base_record()

      assert {:ok, committed, %{effects: [], fenced: []}} =
               Execution.run(
                 EphemeralStore,
                 context,
                 record,
                 %{command: {:admit, 10, %{state: :running}}},
                 adapter: NoEffectAdapter
               )

      assert committed.revision == 1
      assert committed.mode == :ephemeral
    end

    test "dispatches a provider effect only after commit" do
      {:ok, context} = EphemeralStore.new(System.unique_integer([:positive]))
      record = %{base_record() | state: :running, expected_revision: 0}
      {:ok, budget} = Budget.new(%{work: 1})

      assert {:ok, _committed, %{effects: [%{started: true}]}} =
               Execution.run(
                 EphemeralStore,
                 context,
                 record,
                 %{
                   command: {:provider_started, 10, provider_identity(record)}
                 },
                 adapter: NoEffectAdapter,
                 budget: budget
               )
    end

    test "dispatches a tool effect only after commit" do
      {:ok, context} = EphemeralStore.new(System.unique_integer([:positive]))

      record =
        base_record()
        |> Map.put(:state, :running)
        |> Map.put(:current_step, %{step_id: "step_1", attempt_id: "attempt_1"})

      {:ok, budget} = Budget.new(%{work: 1})
      {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, descriptor())

      assert {:ok, _committed, %{effects: [%{completed: true}]}} =
               Execution.run(
                 EphemeralStore,
                 context,
                 record,
                 %{command: {:tool_invoked, 10, tool_invocation(record)}},
                 registry: registry,
                 authority: %{
                   caller: "host",
                   run_id: record.run_id,
                   grants: ["example"],
                   tool_revision: 1
                 },
                 budget: budget
               )
    end

    test "does not dispatch when the store rejects the transition" do
      {:ok, context} = EphemeralStore.new(System.unique_integer([:positive]))
      record = %{base_record() | state: :completed}

      assert {:error, %Error{class: :validation}} =
               Execution.run(
                 EphemeralStore,
                 context,
                 record,
                 %{
                   command: {:provider_started, 10, provider_identity(record)}
                 },
                 adapter: NoEffectAdapter
               )
    end
  end

  defp base_record do
    %{
      run_id: "run_#{System.unique_integer([:positive])}",
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      deadline: nil,
      outcome: nil,
      children: []
    }
  end

  defp tool_invocation(record) do
    %{
      invocation_id: "tool_1",
      run_id: record.run_id,
      incarnation: record.incarnation,
      step_id: "step_1",
      attempt_id: "attempt_1",
      tool_name: "example",
      tool_revision: 1,
      arguments: %{},
      state: :admitted,
      result: nil
    }
  end

  defp provider_identity(record) do
    %{
      run_id: record.run_id,
      incarnation: record.incarnation,
      step_id: "step_1",
      attempt_id: "attempt_1"
    }
  end

  defp descriptor do
    %{
      tool_name: "example",
      tool_revision: 1,
      schema: %{type: "object", properties: %{}, additionalProperties: true},
      safety: %{read_only: true, retry_safe: true, parallel_safe: true},
      backend: NoEffectAdapter
    }
  end
end
