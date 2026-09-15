defmodule Backplane.AgentRuntime.ExecutionControllerTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Budget
  alias Backplane.AgentRuntime.EphemeralStore
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.ExecutionController
  alias Backplane.AgentRuntime.ToolRegistry
  alias Backplane.AgentRuntime.Tools.LocalResource

  defmodule BlockingStore do
    @behaviour Backplane.AgentRuntime.Store

    def mode, do: :ephemeral
    def capabilities, do: EphemeralStore.capabilities()
    def new(_), do: {:error, Error.new(:unsupported_capability, "use a supplied context")}
    def load(context, run_id, opts), do: EphemeralStore.load(context.table, run_id, opts)

    def store(context, record, meta) do
      send(context.test, {:store_entered, self(), meta.command})

      receive do
        :release ->
          result = EphemeralStore.store(context.table, record, meta)
          send(context.test, {:store_finished, self(), meta.command, result})
          result
      end
    end

    def acknowledge_commit(_context, _stage, _meta),
      do: {:error, Error.new(:unsupported_capability, "staging is unused")}
  end

  defmodule NoCallBackend do
    def execute(operation) do
      send(operation.backend_context.test, {:unexpected_backend_call, operation})
      {:ok, %{}}
    end
  end

  defmodule BlockingBackend do
    def execute(operation) do
      send(operation.backend_context.test, {:effect_entered, self(), operation})

      receive do
        :release -> {:ok, %{released: true}}
      end
    end
  end

  defmodule ScriptedProvider do
    def start(request) do
      send(request.provider_context.test, {:provider_called, request})
      {:ok, Map.fetch!(request.provider_context.responses, request.attempt_id)}
    end
  end

  defmodule ResourceBackend do
    def execute(operation) do
      send(operation.backend_context.test, {:resource_called, operation})

      LocalResource.read(
        operation.backend_context.resource,
        %{path: operation.arguments["path"]},
        []
      )
    end
  end

  test "status and cancellation remain responsive while persistence is blocked" do
    {:ok, table} = EphemeralStore.new(1)
    context = %{table: table, test: self()}
    registry = registry(NoCallBackend, %{test: self()}, "example", value_schema())
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 4})

    {:ok, controller} =
      ExecutionController.start_link(
        store: BlockingStore,
        context: context,
        run: running_record(),
        registry: registry,
        authority: authority("example"),
        budget: budget
      )

    assert {:ok, %{status: :submitted}} =
             ExecutionController.submit(controller, %{
               command: {:tool_invoked, 11, invocation("example")}
             })

    assert_receive {:store_entered, intent_worker, {:tool_invoked, 11, _}}
    assert %{phase: :committing, run_state: :running} = ExecutionController.status(controller)
    assert {:ok, %{status: :accepted}} = ExecutionController.cancel(controller, 12)

    assert_receive {:store_entered, cancel_worker, {:cancel, 12}}
    send(cancel_worker, :release)
    assert_receive {:store_finished, ^cancel_worker, {:cancel, 12}, {:ok, %{revision: 1}}}

    assert %{phase: :cancelling, run_state: :cancelling, cancellation: :cleanup} =
             ExecutionController.await_run_state(controller, :cancelling)

    send(intent_worker, :release)
    assert_receive {:store_finished, ^intent_worker, {:tool_invoked, 11, _}, {:error, %Error{}}}
    refute_receive {:unexpected_backend_call, _}
    assert {:error, %Error{class: :resource_conflict}} = ExecutionController.await(controller)

    settlement = %{certainty: :uncertain, evidence: %{"intent" => "commit raced cancellation"}}

    assert {:ok, %{status: :submitted}} =
             ExecutionController.settle_cleanup(controller, 13, settlement)

    assert_receive {:store_entered, cleanup_worker, {:cleanup_settled, 13, ^settlement}}
    send(cleanup_worker, :release)

    assert_receive {:store_finished, ^cleanup_worker, {:cleanup_settled, 13, _},
                    {:ok, %{revision: 2}}}

    assert {:ok, _, %{run: %{state: :unknown_outcome}}} =
             ExecutionController.await(controller)

    assert {:ok, stored} = EphemeralStore.load(table, "run_1")
    refute Map.has_key?(stored.run, :execution_budget)
    assert Map.get(stored.run, :execution_intents, %{}) == %{}
  end

  test "scripted provider and real scoped resource tool complete through committed steps" do
    scope =
      Path.join(
        System.tmp_dir!(),
        "agent-runtime-execution-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(scope)
    File.write!(Path.join(scope, "input.txt"), "runtime data")
    on_exit(fn -> File.rm_rf(scope) end)
    {:ok, resource_server} = LocalResource.start_link(%{name: nil})
    resource = %{scope: scope, namespace: %{server: resource_server}}

    registry =
      registry(
        ResourceBackend,
        %{test: self(), resource: resource},
        "resource::read",
        path_schema()
      )

    {:ok, denied_table} = EphemeralStore.new(1)
    {:ok, denied_budget} = Budget.new(%{root_run_id: "run_1", work: 1})

    {:ok, denied_controller} =
      ExecutionController.start_link(
        store: EphemeralStore,
        context: denied_table,
        run: running_record(),
        registry: registry,
        authority: %{caller: "host_agent", run_id: "run_1", grants: [], tool_revision: 1},
        budget: denied_budget
      )

    denied_tool = invocation("resource::read") |> put_in([:arguments], %{"path" => "input.txt"})

    assert {:error, %Error{class: :forbidden}} =
             submit(denied_controller, {:tool_invoked, 10, denied_tool})

    refute_receive {:resource_called, _}

    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 5})

    responses = %{
      "attempt_1" => %{
        final?: false,
        result: %{"tool_call" => "invocation_1"},
        context: %{"messages" => ["read requested"]}
      },
      "attempt_2" => %{final?: true, outcome: %{"text" => "runtime data"}}
    }

    {:ok, controller} =
      ExecutionController.start_link(
        store: EphemeralStore,
        context: table,
        run: running_record(),
        registry: registry,
        authority: authority("resource::read"),
        budget: budget,
        adapter: ScriptedProvider,
        provider_context: %{test: self(), responses: responses}
      )

    provider_1 = provider_identity("step_1", "attempt_1")
    provider_response_1 = submit_effect(controller, {:provider_started, 11, provider_1})
    assert_receive {:provider_called, %{attempt_id: "attempt_1"}}

    submit_no_effect(
      controller,
      {:provider_completed, 12, Map.merge(provider_1, provider_response_1)}
    )

    tool = invocation("resource::read") |> put_in([:arguments], %{"path" => "input.txt"})
    tool_result = submit_effect(controller, {:tool_invoked, 13, tool})
    assert tool_result.content == "runtime data"
    assert_receive {:resource_called, %{arguments: %{"path" => "input.txt"}}}

    completion =
      tool
      |> Map.take([:run_id, :incarnation, :step_id, :attempt_id, :invocation_id])
      |> Map.put(:result, tool_result)

    submit_no_effect(controller, {:tool_completed, 14, completion})

    provider_2 = provider_identity("step_2", "attempt_2")
    provider_response_2 = submit_effect(controller, {:provider_started, 15, provider_2})
    assert_receive {:provider_called, %{attempt_id: "attempt_2"}}

    assert {:ok, _, %{run: %{state: :completed, outcome: %{"text" => "runtime data"}}}} =
             submit(
               controller,
               {:provider_completed, 16, Map.merge(provider_2, provider_response_2)}
             )

    assert %{phase: :terminal, run_state: :completed} = ExecutionController.status(controller)
    assert {:ok, stored} = EphemeralStore.load(table, "run_1")
    assert stored.run.state == :completed
    assert stored.run.tool_results["invocation_1"].content == "runtime data"
  end

  test "stalled effects are fenced and the controller settles uncertainty without false success" do
    {:ok, table} = EphemeralStore.new(1)
    registry = registry(BlockingBackend, %{test: self()}, "example", value_schema())
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 3})

    {:ok, controller} =
      ExecutionController.start_link(
        store: EphemeralStore,
        context: table,
        run: running_record(),
        registry: registry,
        authority: authority("example"),
        budget: budget
      )

    assert {:ok, %{status: :submitted}} =
             ExecutionController.submit(controller, %{
               command: {:tool_invoked, 11, invocation("example")}
             })

    assert_receive {:effect_entered, effect_worker, _operation}
    monitor = Process.monitor(effect_worker)
    assert %{phase: :effect, run_state: :running} = ExecutionController.status(controller)
    assert {:ok, %{status: :accepted}} = ExecutionController.cancel(controller, 12)

    assert %{run_state: :cancelling, cancellation: :cleanup} =
             ExecutionController.await_run_state(controller, :cancelling)

    settlement = %{certainty: :uncertain, evidence: %{"invocation_id" => "invocation_1"}}

    assert {:ok, %{status: :submitted}} =
             ExecutionController.settle_cleanup(controller, 13, settlement)

    assert {:ok, _, %{run: %{state: :unknown_outcome}, effects: []}} =
             ExecutionController.await(controller)

    assert_receive {:DOWN, ^monitor, :process, ^effect_worker, :killed}

    assert %{phase: :terminal, run_state: :unknown_outcome} =
             ExecutionController.status(controller)
  end

  defp submit_effect(controller, command) do
    assert {:ok, _, %{effects: [effect]}} = submit(controller, command)
    effect
  end

  defp submit_no_effect(controller, command) do
    assert {:ok, _, %{effects: []}} = submit(controller, command)
  end

  defp submit(controller, command) do
    assert {:ok, %{status: :submitted}} =
             ExecutionController.submit(controller, %{command: command})

    ExecutionController.await(controller)
  end

  defp registry(backend, backend_context, name, schema) do
    descriptor = %{
      tool_name: name,
      tool_revision: 1,
      schema: schema,
      safety: %{read_only: true, retry_safe: true, parallel_safe: true},
      backend: backend,
      backend_context: backend_context
    }

    {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, descriptor)
    registry
  end

  defp authority(tool) do
    %{caller: "host_agent", run_id: "run_1", grants: [tool], tool_revision: 1}
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

  defp provider_identity(step_id, attempt_id) do
    %{run_id: "run_1", incarnation: 1, step_id: step_id, attempt_id: attempt_id}
  end

  defp invocation(tool_name) do
    %{
      run_id: "run_1",
      incarnation: 1,
      step_id: "step_1",
      attempt_id: "attempt_1",
      invocation_id: "invocation_1",
      tool_name: tool_name,
      tool_revision: 1,
      arguments: %{"value" => "hello"}
    }
  end

  defp value_schema do
    %{
      type: "object",
      properties: %{"value" => %{type: "string"}},
      required: ["value"],
      additionalProperties: false
    }
  end

  defp path_schema do
    %{
      type: "object",
      properties: %{"path" => %{type: "string"}},
      required: ["path"],
      additionalProperties: false
    }
  end
end
