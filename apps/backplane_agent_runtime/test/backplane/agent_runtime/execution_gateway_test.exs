defmodule Backplane.AgentRuntime.ExecutionGatewayTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Budget
  alias Backplane.AgentRuntime.EphemeralStore
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Execution
  alias Backplane.AgentRuntime.ToolRegistry

  defmodule SpyBackend do
    def execute(operation) do
      send(operation.backend_context.test, {:tool_called, operation})
      {:ok, %{value: operation.arguments["value"]}}
    end
  end

  defmodule FailedStore do
    @behaviour Backplane.AgentRuntime.Store
    def mode, do: :ephemeral

    def capabilities,
      do: %{expected_revision: true, transition_events: true, outbox_intents: true}

    def new(_), do: {:ok, nil}
    def load(_, _, _), do: {:error, Error.new(:not_found, "missing")}
    def store(_, _, _), do: {:error, Error.new(:resource_conflict, "commit failed")}
    def acknowledge_commit(_, _, _), do: {:error, Error.new(:resource_conflict, "commit failed")}
  end

  test "denied tool operations never reach the registered backend" do
    {registry, descriptor} = registry(self())
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 2})
    invocation = invocation()

    assert {:error, %Error{class: :forbidden}} =
             Execution.run(
               EphemeralStore,
               new_store(),
               running_record(),
               %{command: {:tool_invoked, 11, invocation}},
               registry: registry,
               authority: authority([]),
               budget: budget
             )

    refute_receive {:tool_called, _}
    assert descriptor.backend == SpyBackend
  end

  test "failed commits prevent backend dispatch" do
    {registry, _descriptor} = registry(self())
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 2})

    assert {:error, %Error{class: :resource_conflict}} =
             Execution.run(
               FailedStore,
               nil,
               running_record(),
               %{command: {:tool_invoked, 11, invocation()}},
               registry: registry,
               authority: authority(["resource::read"]),
               budget: budget
             )

    refute_receive {:tool_called, _}
  end

  test "accepted work dispatches normalized arguments and authoritative identity" do
    {registry, _descriptor} = registry(self())
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 2})

    assert {:ok, %{revision: 1}, result} =
             Execution.run(
               EphemeralStore,
               new_store(),
               running_record(),
               %{command: {:tool_invoked, 11, invocation()}},
               registry: registry,
               authority: authority(["resource::read"]),
               budget: budget
             )

    assert [%{value: "hello"}] = result.effects
    assert result.budget.used == 1

    assert_receive {:tool_called, operation}
    assert operation.arguments == %{"value" => "hello"}
    assert operation.run_id == "run_1"
    assert operation.incarnation == 1
    assert operation.step_id == "step_1"
    assert operation.attempt_id == "attempt_1"
    assert operation.invocation_id == "invocation_1"
    assert operation.caller == "host_agent"
    refute Map.has_key?(operation, :committed)
  end

  test "invalid schema references fail before dispatch" do
    {_registry, descriptor} = registry(self())

    unsupported =
      put_in(descriptor.schema[:properties]["value"], %{"$ref" => "#/$defs/value"})

    {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, unsupported)
    {:ok, budget} = Budget.new(%{work: 1})

    assert {:error,
            %Error{
              class: :validation,
              message: "schema reference could not be resolved"
            }} =
             Execution.run(
               EphemeralStore,
               new_store(),
               running_record(),
               %{command: {:tool_invoked, 11, invocation()}},
               registry: registry,
               authority: authority(["resource::read"]),
               budget: budget
             )

    refute_receive {:tool_called, _}
  end

  test "denied exact approval and exhausted budget prevent dispatch" do
    {_registry, descriptor} = registry(self())
    descriptor = put_in(descriptor.safety[:requires_approval], true)
    {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, descriptor)
    {:ok, budget} = Budget.new(%{work: 1})
    digest = digest(invocation().arguments)

    approval = %{
      approval_id: "approval_1",
      run_id: "run_1",
      tool_name: "resource::read",
      tool_revision: 1,
      arguments_digest: digest,
      current_time: 10,
      expires_at: 20
    }

    decision = %{
      approval_id: "approval_1",
      decision: :denied,
      resolver_id: "human_1",
      tool_name: "resource::read",
      tool_revision: 1,
      arguments_digest: digest
    }

    assert {:error, %Error{class: :forbidden}} =
             Execution.run(
               EphemeralStore,
               new_store(),
               running_record(),
               %{command: {:tool_invoked, 11, invocation()}},
               registry: registry,
               authority: authority(["resource::read"]),
               budget: budget,
               approval: approval,
               approval_decision: decision
             )

    {:ok, exhausted, _} = Budget.reserve(budget, "prior")

    assert {:error, %Error{class: :budget_exceeded}} =
             Execution.run(
               EphemeralStore,
               new_store(),
               running_record(),
               %{command: {:tool_invoked, 11, invocation()}},
               registry: registry,
               authority: authority(["resource::read"]),
               budget: exhausted,
               approval: approval,
               approval_decision: %{decision | decision: :approved}
             )

    refute_receive {:tool_called, _}
  end

  test "backend output is bounded after a committed intent" do
    {registry, _descriptor} = registry(self())
    {:ok, budget} = Budget.new(%{work: 1})

    assert {:error, %Error{class: :resource_conflict}} =
             Execution.run(
               EphemeralStore,
               new_store(),
               running_record(),
               %{command: {:tool_invoked, 11, invocation()}},
               registry: registry,
               authority: authority(["resource::read"]),
               budget: budget,
               output_limit: 0
             )

    assert_receive {:tool_called, _}
  end

  defp new_store do
    {:ok, store} = EphemeralStore.new(1)
    store
  end

  defp registry(test) do
    descriptor = %{
      tool_name: "resource::read",
      tool_revision: 1,
      schema: %{
        type: "object",
        properties: %{"value" => %{type: "string"}},
        required: ["value"],
        additionalProperties: false
      },
      safety: %{read_only: true, retry_safe: true, parallel_safe: true},
      backend: SpyBackend,
      backend_context: %{test: test}
    }

    {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, descriptor)
    {registry, descriptor}
  end

  defp authority(grants) do
    %{caller: "host_agent", run_id: "run_1", grants: grants, tool_revision: 1}
  end

  defp running_record do
    %{
      run_id: "run_1",
      incarnation: 1,
      expected_revision: 0,
      state: :running,
      admitted: true,
      current_step: %{step_id: "step_1", attempt_id: "attempt_1"},
      deadline: nil,
      outcome: nil,
      context: %{},
      children: []
    }
  end

  defp invocation do
    %{
      run_id: "run_1",
      incarnation: 1,
      step_id: "step_1",
      attempt_id: "attempt_1",
      invocation_id: "invocation_1",
      tool_name: "resource::read",
      tool_revision: 1,
      arguments: %{"value" => "hello"}
    }
  end

  defp digest(arguments) do
    :crypto.hash(:sha256, :erlang.term_to_binary(arguments))
    |> Base.encode16(case: :lower)
  end
end
