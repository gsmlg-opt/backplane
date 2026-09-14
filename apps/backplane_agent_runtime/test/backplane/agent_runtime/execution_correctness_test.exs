defmodule Backplane.AgentRuntime.ExecutionCorrectnessTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Budget
  alias Backplane.AgentRuntime.EphemeralStore
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Execution
  alias Backplane.AgentRuntime.ExecutionController
  alias Backplane.AgentRuntime.Kernel
  alias Backplane.AgentRuntime.ToolRegistry

  defmodule SpyBackend do
    def execute(operation) do
      send(operation.backend_context.test, {:tool_called, operation})
      {:ok, %{value: operation.arguments["value"]}}
    end
  end

  defmodule CrashBackend do
    def execute(operation) do
      send(operation.backend_context.test, {:tool_started, self()})
      raise "backend crashed"
    end
  end

  defmodule BlockingBackend do
    def execute(operation) do
      send(operation.backend_context.test, {:tool_started, self()})

      receive do
        :release -> {:ok, %{released: true}}
      end
    end
  end

  defmodule BlockingProvider do
    def start(operation) do
      send(operation.provider_context.test, {:provider_started, self(), operation})

      receive do
        :release -> {:ok, %{final?: false, result: %{}}}
      end
    end
  end

  defmodule ControlledCrashBackend do
    def execute(operation) do
      send(operation.backend_context.test, {:tool_started, self()})

      receive do
        :crash -> raise "controlled crash"
      end
    end
  end

  defmodule HangingStore do
    @behaviour Backplane.AgentRuntime.Store
    def mode, do: :ephemeral
    def capabilities, do: EphemeralStore.capabilities()
    def new(_incarnation), do: {:error, Error.new(:unsupported_capability, "unused")}
    def load(_context, _run_id, _opts), do: {:error, Error.new(:not_found, "missing")}

    def store(context, _record, _meta) do
      send(context.test, {:commit_started, self()})
      receive do: (:release -> {:error, Error.new(:execution_failure, "released")})
    end

    def acknowledge_commit(_context, _stage, _meta),
      do: {:error, Error.new(:unsupported_capability, "unused")}
  end

  defmodule SelectiveStore do
    @behaviour Backplane.AgentRuntime.Store
    def mode, do: :ephemeral
    def capabilities, do: EphemeralStore.capabilities()
    def new(_incarnation), do: {:error, Error.new(:unsupported_capability, "unused")}
    def load(context, run_id, opts), do: EphemeralStore.load(context.table, run_id, opts)

    def store(context, _record, %{command: {kind, _, _}})
        when kind == :cleanup_settled do
      send(context.test, {:cleanup_commit_started, self()})

      receive do
        :fail_cleanup -> {:error, Error.new(:execution_failure, "cleanup commit failed")}
      end
    end

    def store(context, record, %{command: {:cancel, _}} = meta) do
      if Map.get(context, :fail_cancel, false) do
        {:error, Error.new(:execution_failure, "cancel commit failed")}
      else
        EphemeralStore.store(context.table, record, meta)
      end
    end

    def store(context, record, meta), do: EphemeralStore.store(context.table, record, meta)

    def acknowledge_commit(_context, _stage, _meta),
      do: {:error, Error.new(:unsupported_capability, "unused")}
  end

  test "abnormal effect DOWN retains identity and settles one uncertain intent" do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 1})

    {:ok, controller} =
      ExecutionController.start_link(
        store: EphemeralStore,
        context: table,
        run: running_record(),
        registry: registry(CrashBackend, self()),
        authority: authority(),
        budget: budget,
        commit_timeout: 100,
        effect_timeout: 100,
        cleanup_timeout: 20,
        run_timeout: 1_000
      )

    assert {:ok, %{status: :submitted}} = submit(controller, invocation("invocation_1"))
    assert_receive {:tool_started, _worker}

    assert %{run_state: :unknown_outcome} =
             ExecutionController.await_run_state(controller, :unknown_outcome, 1_000)

    assert Process.alive?(controller)
    assert {:ok, stored} = EphemeralStore.load(table, "run_1")

    assert %{
             "tool:invocation_1" => %{
               status: :uncertain,
               operation: %{invocation_id: "invocation_1"}
             }
           } = stored.run.execution_intents
  end

  test "normalized intent and consumed budget survive reload and prevent quota reset" do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 1})
    registry = registry(SpyBackend, self())

    raw_invocation =
      invocation("invocation_1")
      |> Map.put(:backend_context, %{pid: self()})
      |> Map.put(:raw_runtime_field, make_ref())

    assert {:ok, _receipt, %{effects: [%{value: "first"}]}} =
             Execution.run(
               EphemeralStore,
               table,
               running_record(),
               %{command: {:tool_invoked, 11, raw_invocation}},
               registry: registry,
               authority: authority(),
               budget: budget,
               commit_timeout: 100,
               effect_timeout: 100,
               run_timeout: 100,
               wall_now: fn -> 1_000 end
             )

    assert_receive {:tool_called, first_operation}
    assert first_operation.arguments == %{"value" => "first"}

    assert {:ok, stored} = EphemeralStore.load(table, "run_1")
    assert stored.run.execution_budget.used == 1
    assert stored.run.deadline == 1_100

    assert %{
             status: :started,
             operation: %{arguments: %{"value" => "first"}}
           } = stored.run.execution_intents["tool:invocation_1"]

    refute contains_runtime_handle?(stored.run.execution_intents)
    refute Map.has_key?(stored.run.active_tools["invocation_1"], :backend_context)
    refute Map.has_key?(stored.run.active_tools["invocation_1"], :raw_runtime_field)
    refute contains_runtime_handle?(stored.run.active_tools)

    {:ok, fresh_budget} = Budget.new(%{root_run_id: "run_1", work: 1})

    assert {:error, %Error{class: :budget_exceeded}} =
             Execution.run(
               EphemeralStore,
               table,
               stored.run,
               %{command: {:tool_invoked, 12, invocation("invocation_2")}},
               registry: registry,
               authority: authority(),
               budget: fresh_budget,
               commit_timeout: 100,
               effect_timeout: 100,
               run_timeout: 1_000,
               wall_now: fn -> 1_050 end
             )

    refute_receive {:tool_called, %{invocation_id: "invocation_2"}}

    completion =
      invocation("invocation_1")
      |> Map.take([:run_id, :incarnation, :step_id, :attempt_id, :invocation_id])
      |> Map.put(:result, %{value: "first"})

    assert {:ok, _receipt, %{effects: []}} =
             Execution.run(
               EphemeralStore,
               table,
               stored.run,
               %{command: {:tool_completed, 13, completion}},
               budget: fresh_budget,
               commit_timeout: 100,
               effect_timeout: 100,
               run_timeout: 1_000,
               wall_now: fn -> 1_050 end
             )

    assert {:ok, completed} = EphemeralStore.load(table, "run_1")
    assert completed.run.execution_budget.used == 1
    assert completed.run.deadline == 1_100
    assert completed.run.execution_intents["tool:invocation_1"].status == :consumed
  end

  test "active provider rejects tool admission before budget, intent, or backend work" do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 1})

    run =
      running_record()
      |> Map.put(:active_provider, %{
        run_id: "run_1",
        incarnation: 1,
        step_id: "step_1",
        attempt_id: "attempt_1"
      })

    assert {:error, %Error{class: :resource_conflict}} =
             Execution.run(
               EphemeralStore,
               table,
               run,
               %{command: {:tool_invoked, 11, invocation("invocation_1")}},
               registry: registry(SpyBackend, self()),
               authority: authority(),
               budget: budget,
               commit_timeout: 100,
               effect_timeout: 100,
               run_timeout: 1_000
             )

    refute_receive {:tool_called, _}
    assert {:error, %Error{class: :not_found}} = EphemeralStore.load(table, "run_1")
    assert budget.used == 0
  end

  test "synchronous execution bounds a hung effect and reports uncertainty" do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 1})
    registry = registry(BlockingBackend, self())

    task =
      Task.async(fn ->
        Execution.run(
          EphemeralStore,
          table,
          running_record(),
          %{command: {:tool_invoked, 11, invocation("invocation_1")}},
          registry: registry,
          authority: authority(),
          budget: budget,
          commit_timeout: 100,
          effect_timeout: 20,
          run_timeout: 1_000
        )
      end)

    on_exit(fn ->
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end)

    assert_receive {:tool_started, _worker}

    assert {:ok, {:error, %Error{class: :timeout, details: %{certainty: :uncertain}}}} =
             Task.yield(task, 500)

    assert {:ok, stored} = EphemeralStore.load(table, "run_1")
    assert stored.run.state == :unknown_outcome
    assert stored.run.execution_intents["tool:invocation_1"].status == :uncertain
  end

  test "invalid timeout configuration is rejected and stale timeout identities are ignored" do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 1})

    assert {:error, %Error{class: :validation}} =
             ExecutionController.start_link(
               store: EphemeralStore,
               context: table,
               run: running_record(),
               budget: budget,
               effect_timeout: :infinity
             )

    {:ok, controller} =
      ExecutionController.start_link(
        store: EphemeralStore,
        context: table,
        run: running_record(),
        budget: budget,
        commit_timeout: 100,
        effect_timeout: 100,
        cleanup_timeout: 100,
        run_timeout: 1_000
      )

    send(controller, {:task_timeout, make_ref(), make_ref()})
    assert Process.alive?(controller)
    assert %{phase: :idle, run_state: :running} = ExecutionController.status(controller)
  end

  test "hung provider times out while another run continues and late release is fenced" do
    {:ok, first_table} = EphemeralStore.new(1)
    {:ok, first_budget} = Budget.new(%{root_run_id: "run_1", work: 1})

    {:ok, controller} =
      ExecutionController.start_link(
        store: EphemeralStore,
        context: first_table,
        run: running_record(),
        adapter: BlockingProvider,
        provider_context: %{test: self()},
        budget: first_budget,
        commit_timeout: 100,
        effect_timeout: 40,
        cleanup_timeout: 20,
        run_timeout: 1_000
      )

    provider = %{
      run_id: "run_1",
      incarnation: 1,
      step_id: "step_1",
      attempt_id: "attempt_1"
    }

    assert {:ok, %{status: :submitted}} =
             ExecutionController.submit(controller, %{
               command: {:provider_started, 11, provider},
               operation: %{messages: [%{role: "user", content: "continue"}]}
             })

    assert_receive {:provider_started, provider_worker, _operation}

    {:ok, second_table} = EphemeralStore.new(1)
    {:ok, second_budget} = Budget.new(%{root_run_id: "run_2", work: 1})
    second_run = rewrite_run(running_record(), "run_2")
    second_invocation = rewrite_run(invocation("invocation_2"), "run_2")
    second_authority = %{authority() | run_id: "run_2"}

    assert {:ok, _receipt, %{effects: [%{value: "second"}]}} =
             Execution.run(
               EphemeralStore,
               second_table,
               second_run,
               %{command: {:tool_invoked, 11, second_invocation}},
               registry: registry(SpyBackend, self()),
               authority: second_authority,
               budget: second_budget,
               commit_timeout: 100,
               effect_timeout: 100,
               run_timeout: 1_000
             )

    assert_receive {:tool_called, %{run_id: "run_2"}}

    assert %{run_state: :unknown_outcome} =
             ExecutionController.await_run_state(controller, :unknown_outcome, 1_000)

    send(provider_worker, :release)
    assert %{run_state: :unknown_outcome} = ExecutionController.status(controller)
  end

  test "malformed and expired persisted deadlines are rejected before work" do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 1})
    opts = [store: EphemeralStore, context: table, budget: budget, wall_now: fn -> 1_000 end]

    assert {:error, %Error{class: :validation}} =
             ExecutionController.start_link(
               Keyword.put(opts, :run, %{running_record() | deadline: "later"})
             )

    assert {:error, %Error{class: :timeout}} =
             ExecutionController.start_link(
               Keyword.put(opts, :run, %{running_record() | deadline: 1_000})
             )
  end

  test "accepted result wins once and an old timer cannot cancel a newer invocation" do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 3})

    {:ok, controller} =
      ExecutionController.start_link(
        store: EphemeralStore,
        context: table,
        run: running_record(),
        registry: registry(BlockingBackend, self()),
        authority: authority(),
        budget: budget,
        commit_timeout: 100,
        effect_timeout: 500,
        cleanup_timeout: 100,
        run_timeout: 2_000
      )

    assert {:ok, %{status: :submitted}} = submit(controller, invocation("invocation_1"))
    assert_receive {:tool_started, first_worker}
    [{old_ref, old_entry}] = :sys.get_state(controller).tasks |> Map.to_list()
    send(first_worker, :release)
    assert {:ok, _, %{effects: [%{released: true}]}} = ExecutionController.await(controller)
    assert Process.alive?(controller)

    completion =
      invocation("invocation_1")
      |> Map.take([:run_id, :incarnation, :step_id, :attempt_id, :invocation_id])
      |> Map.put(:result, %{released: true})

    assert {:ok, %{status: :submitted}} =
             ExecutionController.submit(controller, %{
               command: {:tool_completed, 12, completion}
             })

    assert {:ok, _, %{effects: []}} = ExecutionController.await(controller)

    assert {:ok, %{status: :submitted}} = submit(controller, invocation("invocation_2"))
    assert_receive {:tool_started, second_worker}
    send(controller, {:task_timeout, old_ref, old_entry.timer_token})
    assert Process.alive?(second_worker)
    assert %{phase: :effect, run_state: :running} = ExecutionController.status(controller)

    send(second_worker, :release)
    assert {:ok, _, %{effects: [%{released: true}]}} = ExecutionController.await(controller)
  end

  test "cancellation racing an abnormal effect still commits one uncertain terminal" do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 1})

    {:ok, controller} =
      ExecutionController.start_link(
        store: EphemeralStore,
        context: table,
        run: running_record(),
        registry: registry(ControlledCrashBackend, self()),
        authority: authority(),
        budget: budget,
        commit_timeout: 100,
        effect_timeout: 500,
        cleanup_timeout: 20,
        run_timeout: 1_000
      )

    assert {:ok, %{status: :submitted}} = submit(controller, invocation("invocation_1"))
    assert_receive {:tool_started, worker}
    assert {:ok, %{status: :accepted}} = ExecutionController.cancel(controller, 12)
    send(worker, :crash)

    assert %{run_state: :unknown_outcome} =
             ExecutionController.await_run_state(controller, :unknown_outcome, 1_000)

    assert {:ok, stored} = EphemeralStore.load(table, "run_1")
    assert stored.revision == 3
    assert stored.run.execution_intents["tool:invocation_1"].status == :uncertain
    assert Process.alive?(controller)
  end

  test "synchronous commit has a finite bound and never dispatches without acknowledgement" do
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 1})

    assert {:error, %Error{class: :timeout, details: %{certainty: :uncertain}}} =
             Execution.run(
               HangingStore,
               %{test: self()},
               running_record(),
               %{command: {:tool_invoked, 11, invocation("invocation_1")}},
               registry: registry(SpyBackend, self()),
               authority: authority(),
               budget: budget,
               commit_timeout: 20,
               effect_timeout: 100,
               run_timeout: 1_000
             )

    assert_receive {:commit_started, _worker}
    refute_receive {:tool_called, _}
  end

  test "expired synchronous cleanup remains available within its own finite envelope" do
    {:ok, table} = EphemeralStore.new(1)

    run =
      Map.merge(running_record(), %{
        state: :cancelling,
        deadline: 999,
        stop_reason: :deadline_exceeded
      })

    settlement = %{certainty: :uncertain, evidence: %{"reason" => "expired cleanup"}}

    assert {:ok, _receipt, %{run: %{state: :unknown_outcome}, effects: []}} =
             Execution.run(
               EphemeralStore,
               table,
               run,
               %{command: {:cleanup_settled, 1_001, settlement}},
               commit_timeout: 100,
               effect_timeout: 100,
               cleanup_timeout: 100,
               run_timeout: 1_000,
               wall_now: fn -> 1_000 end
             )
  end

  test "failed cancel persistence and cleanup timer race become bounded uncertainty" do
    {:ok, cancel_table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 1})

    {:ok, failed_cancel} =
      ExecutionController.start_link(
        store: SelectiveStore,
        context: %{table: cancel_table, test: self(), fail_cancel: true},
        run: running_record(),
        budget: budget,
        commit_timeout: 50,
        effect_timeout: 100,
        cleanup_timeout: 20,
        run_timeout: 1_000
      )

    assert {:ok, %{status: :accepted}} = ExecutionController.cancel(failed_cancel, 12)

    assert {:error, %Error{message: "cancel commit failed"}} =
             ExecutionController.await(failed_cancel)

    assert %{phase: :uncertain, run_state: :running} = ExecutionController.status(failed_cancel)

    {:ok, cleanup_table} = EphemeralStore.new(1)

    {:ok, failed_cleanup} =
      ExecutionController.start_link(
        store: SelectiveStore,
        context: %{table: cleanup_table, test: self()},
        run: running_record(),
        budget: budget,
        commit_timeout: 100,
        effect_timeout: 100,
        cleanup_timeout: 20,
        run_timeout: 1_000
      )

    assert {:ok, %{status: :accepted}} = ExecutionController.cancel(failed_cleanup, 12)

    assert %{run_state: :cancelling} =
             ExecutionController.await_run_state(failed_cleanup, :cancelling)

    settlement = %{certainty: :uncertain, evidence: %{"reason" => "manual"}}

    assert {:ok, %{status: :submitted}} =
             ExecutionController.settle_cleanup(failed_cleanup, 13, settlement)

    assert_receive {:cleanup_commit_started, worker}
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 500

    assert %{phase: :uncertain, run_state: :cancelling} =
             ExecutionController.status(failed_cleanup)
  end

  test "synchronous uncertain settlement is bounded by cleanup timeout" do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 1})
    registry = registry(BlockingBackend, self())
    context = %{table: table, test: self()}

    task =
      Task.async(fn ->
        Execution.run(
          SelectiveStore,
          context,
          running_record(),
          %{command: {:tool_invoked, 11, invocation("invocation_1")}},
          registry: registry,
          authority: authority(),
          budget: budget,
          commit_timeout: 200,
          effect_timeout: 20,
          cleanup_timeout: 20,
          run_timeout: 1_000
        )
      end)

    on_exit(fn ->
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end)

    assert {:ok, {:error, %Error{class: :timeout}}} = Task.yield(task, 150)
  end

  test "pure kernel completion without a gateway intent leaves cleanup safe" do
    identity = %{
      run_id: "run_1",
      incarnation: 1,
      step_id: "step_1",
      attempt_id: "attempt_1"
    }

    {:ok, started, _, []} = Kernel.execute(running_record(), {:provider_started, 11, identity})

    {:ok, continued, _, []} =
      Kernel.execute(
        started,
        {:provider_completed, 12,
         Map.merge(identity, %{final?: false, result: %{"content" => "continue"}})}
      )

    refute Map.has_key?(continued, :execution_intents)
    {:ok, cancelling, _, []} = Kernel.execute(continued, {:cancel, 13})

    assert {:ok, %{state: :unknown_outcome}, _, []} =
             Kernel.execute(
               cancelling,
               {:cleanup_settled, 14,
                %{certainty: :uncertain, evidence: %{"reason" => "pure kernel"}}}
             )
  end

  test "expiry after committed intent settles uncertainty without dispatch or budget reset" do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{root_run_id: "run_1", work: 1})
    counter = :atomics.new(1, [])

    wall_now = fn ->
      case :atomics.add_get(counter, 1, 1) do
        value when value <= 3 -> 1_000
        _value -> 1_200
      end
    end

    assert {:error, %Error{class: :timeout}} =
             Execution.run(
               EphemeralStore,
               table,
               running_record(),
               %{command: {:tool_invoked, 11, invocation("invocation_1")}},
               registry: registry(SpyBackend, self()),
               authority: authority(),
               budget: budget,
               commit_timeout: 100,
               effect_timeout: 100,
               cleanup_timeout: 100,
               run_timeout: 100,
               wall_now: wall_now
             )

    refute_receive {:tool_called, _}
    assert {:ok, stored} = EphemeralStore.load(table, "run_1")
    assert stored.run.state == :unknown_outcome
    assert stored.run.execution_budget.used == 1
    assert stored.run.execution_intents["tool:invocation_1"].status == :uncertain
  end

  defp submit(controller, input) do
    ExecutionController.submit(controller, %{command: {:tool_invoked, 11, input}})
  end

  defp registry(backend, test) do
    descriptor = %{
      tool_name: "example",
      tool_revision: 1,
      schema: %{
        type: "object",
        properties: %{"value" => %{type: "string"}},
        required: ["value"],
        additionalProperties: false
      },
      safety: %{read_only: true, retry_safe: true, parallel_safe: true},
      backend: backend,
      backend_context: %{test: test}
    }

    {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, descriptor)
    registry
  end

  defp authority do
    %{caller: "host_agent", run_id: "run_1", grants: ["example"], tool_revision: 1}
  end

  defp running_record do
    %{
      run_id: "run_1",
      incarnation: 1,
      expected_revision: 0,
      state: :running,
      admitted: true,
      current_step: %{step_id: "step_1", attempt_id: "attempt_1"},
      active_provider: nil,
      active_tools: %{},
      deadline: nil,
      outcome: nil,
      context: %{},
      children: []
    }
  end

  defp invocation(invocation_id) do
    %{
      run_id: "run_1",
      incarnation: 1,
      step_id: "step_1",
      attempt_id: "attempt_1",
      invocation_id: invocation_id,
      tool_name: "example",
      tool_revision: 1,
      arguments: %{"value" => if(invocation_id == "invocation_1", do: "first", else: "second")}
    }
  end

  defp rewrite_run(map, run_id), do: %{map | run_id: run_id}

  defp contains_runtime_handle?(value)
       when is_pid(value) or is_port(value) or is_reference(value),
       do: true

  defp contains_runtime_handle?(value) when is_function(value), do: true

  defp contains_runtime_handle?(value) when is_map(value),
    do:
      Enum.any?(value, fn {key, item} ->
        contains_runtime_handle?(key) or contains_runtime_handle?(item)
      end)

  defp contains_runtime_handle?(value) when is_list(value),
    do: Enum.any?(value, &contains_runtime_handle?/1)

  defp contains_runtime_handle?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&contains_runtime_handle?/1)

  defp contains_runtime_handle?(_value), do: false
end
