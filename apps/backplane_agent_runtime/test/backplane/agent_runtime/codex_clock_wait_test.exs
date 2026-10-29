defmodule Backplane.AgentRuntime.CodexClockWaitTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Error, ToolEffects}
  alias Backplane.AgentRuntime.Codex.{ClockWait, ResourceRegistry}

  defmodule Coordinator do
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(nil), do: {:ok, nil}

    def handle_call({:register, operation, registration}, _from, state),
      do: {:reply, ClockWait.register_admission(operation, registration, self()), state}
  end

  test "normal completion joins waiter but retains registration until result acknowledgement" do
    {registry, task, operation, registration} = waiting(10)
    admission = operation.clock_wait_admission
    assert :ok = ClockWait.register_admission(operation, registration, self())
    send(task.pid, {:registered, self()})
    assert {:ok, %{wall_time_seconds: elapsed}} = Task.await(task)
    assert elapsed >= 0.01
    refute Process.alive?(admission.waiter)
    assert ClockWait.retired?(%{operation: operation})
    assert {:ok, _} = ResourceRegistry.fetch(registry, admission.handle, "owner")

    assert {:error, %Error{class: :unknown_outcome}} =
             ResourceRegistry.owner_transfer_ready(registry, "owner")

    assert {:ok, :ok} = ClockWait.release(%{operation: operation})
    assert :ok = ResourceRegistry.owner_transfer_ready(registry, "owner")
  end

  test "cancellation seals exact waiter and repeated generation keeps the same report" do
    {_registry, task, operation, registration} = waiting(60_000)
    assert :ok = ClockWait.register_admission(operation, registration, self())
    send(task.pid, {:registered, self()})

    operation =
      operation
      |> Map.put(:clock_registration, registration)
      |> Map.put(:stop_generation, "stop-one")
      |> Map.put(:cleanup_deadline, System.monotonic_time(:millisecond) + 1_000)

    assert {:ok, %ToolEffects.ClockCancellation{} = assertion} = ClockWait.cancel(operation)
    refute Process.alive?(operation.clock_wait_admission.waiter)
    assert {:ok, ^assertion} = ClockWait.cancel(operation)
    assert {:ok, _} = ToolEffects.validate_cancellation(assertion, operation)

    assert {:error, %Error{class: :unknown_outcome}} =
             ClockWait.cancel(%{operation | stop_generation: "stop-two"})

    assert {:error, %Error{class: :unknown_outcome}} = Task.await(task)
    assert {:ok, :ok} = ClockWait.release(%{operation: operation})
  end

  test "sealed registration cannot arm and stale completion cannot finish an unarmed waiter" do
    {_registry, task, operation, registration} = waiting(60_000)
    admission = operation.clock_wait_admission
    send(admission.waiter, {:elapsed, admission.generation})
    assert %{started: nil, timer: nil} = :sys.get_state(admission.waiter)
    assert Process.alive?(admission.waiter)
    monitor = Process.monitor(admission.waiter)
    assert :ok = ClockWait.register_admission(operation, registration, self())
    assert :ok = ClockWait.seal_admission(%{operation: operation})
    send(task.pid, {:registered, self()})
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    assert {:ok, :ok} = ClockWait.release(%{operation: operation})
    refute Process.alive?(admission.waiter)
  end

  test "completed timer retains exact facts for cancellation before the result ACK" do
    {_registry, task, operation, registration} = waiting(1)
    assert :ok = ClockWait.register_admission(operation, registration, self())
    send(task.pid, {:registered, self()})
    assert {:ok, %{wall_time_seconds: _}} = Task.await(task)

    operation = cancellation(operation, registration)
    assert {:ok, assertion} = ClockWait.cancel(operation)
    assert {:ok, public} = ToolEffects.validate_cancellation(assertion, operation)
    assert public["registration_id"] == registration
    assert public["waiter_down"] == true
    assert public["timer_retired"] == true
    assert ClockWait.retired?(%{operation: operation})
    assert {:ok, :ok} = ClockWait.release(%{operation: operation})
  end

  test "timer completion and cancellation race cannot publish an unretired receipt" do
    for _ <- 1..12 do
      {_registry, task, operation, registration} = waiting(1)
      assert :ok = ClockWait.register_admission(operation, registration, self())
      send(task.pid, {:registered, self()})
      operation = cancellation(operation, registration)
      assert {:ok, assertion} = ClockWait.cancel(operation)
      assert {:ok, _} = ToolEffects.validate_cancellation(assertion, operation)
      refute Process.alive?(operation.clock_wait_admission.waiter)

      case Task.await(task) do
        {:ok, %{wall_time_seconds: elapsed}} -> assert elapsed >= 0.001
        {:error, %Error{class: :unknown_outcome}} -> :ok
      end

      assert {:ok, :ok} = ClockWait.release(%{operation: operation})
    end
  end

  test "expired cleanup deadline never produces a cancellation receipt" do
    {_registry, task, operation, registration} = waiting(60_000)
    assert :ok = ClockWait.register_admission(operation, registration, self())
    send(task.pid, {:registered, self()})

    operation =
      operation
      |> cancellation(registration)
      |> Map.put(:cleanup_deadline, System.monotonic_time(:millisecond) - 1)

    assert {:error, %Error{class: :unknown_outcome}} = ClockWait.cancel(operation)
    assert {:error, %Error{class: :unknown_outcome}} = ClockWait.sealed_report_digest(operation)
    assert Process.alive?(operation.clock_wait_admission.waiter)
    assert {:ok, :ok} = ClockWait.release(%{operation: operation})
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(task)
  end

  test "registration delayed beyond the fixed effect deadline cannot arm the timer" do
    deadline = System.monotonic_time(:millisecond) + 500

    {_registry, task, operation, registration} =
      waiting(60_000, deadline: deadline, hold_result: true)

    admission = operation.clock_wait_admission
    assert :ok = ClockWait.register_admission(operation, registration, self())

    receive do
    after
      max(1, deadline - System.monotonic_time(:millisecond) + 1) -> :ok
    end

    send(task.pid, {:registered, self()})
    task_pid = task.pid
    assert_receive {:clock_result, ^task_pid, {:error, %Error{class: :unknown_outcome}}}, 1_000
    assert %{timer: nil, started: nil} = :sys.get_state(admission.waiter)
    assert :atomics.get(admission.gate, 1) == 0
    monitor = Process.monitor(admission.waiter)
    send(task.pid, :release_result)
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
    assert {:ok, :ok} = ClockWait.release(%{operation: operation})
  end

  test "owner death invokes Registry cleanup and joins the actual waiter" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    {registry, task, operation, registration} = waiting(60_000, owner_pid: owner)
    assert :ok = ClockWait.register_admission(operation, registration, self())
    send(task.pid, {:registered, self()})
    waiter = operation.clock_wait_admission.waiter
    monitor = Process.monitor(waiter)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^waiter, _}, 1_000
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(task)

    assert {:ok, %{status: :confirmed}} =
             await_cleanup(registry, operation.clock_wait_admission.handle)

    assert {:error, %Error{class: :resource_conflict}} =
             ResourceRegistry.start_clock_wait(registry, "owner", %{}, incarnation: 1)
  end

  test "coordinator death seals and stops the waiter while retaining unacknowledged registration" do
    coordinator = start_supervised!(Coordinator)
    {registry, task, operation, registration} = waiting(60_000, coordinator: coordinator)
    assert :ok = GenServer.call(coordinator, {:register, operation, registration})
    send(task.pid, {:registered, coordinator})
    waiter = operation.clock_wait_admission.waiter
    monitor = Process.monitor(waiter)
    :ok = GenServer.stop(coordinator)
    assert_receive {:DOWN, ^monitor, :process, ^waiter, :normal}, 1_000
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(task)
    assert :atomics.get(operation.clock_wait_admission.gate, 1) in [2, 3]

    assert {:ok, _} =
             ResourceRegistry.fetch(registry, operation.clock_wait_admission.handle, "owner")

    assert {:ok, :ok} = ClockWait.release(%{operation: operation})
  end

  test "malformed typed cancellation assertions fail closed" do
    {_registry, task, operation, registration} = waiting(60_000)
    assert :ok = ClockWait.register_admission(operation, registration, self())
    send(task.pid, {:registered, self()})
    operation = cancellation(operation, registration)
    assert {:ok, assertion} = ClockWait.cancel(operation)

    for evidence <- [nil, 12, "bad", [:bad], %{}] do
      assert {:error, %Error{class: :unknown_outcome}} =
               ToolEffects.validate_cancellation(%{assertion | evidence: evidence}, operation)
    end

    assert {:error, %Error{class: :unknown_outcome}} = Task.await(task)
    assert {:ok, :ok} = ClockWait.release(%{operation: operation})
  end

  test "capacity rejects before allocating another waiter and is scoped to owner" do
    registry = start_supervised!(ResourceRegistry)
    gate = :atomics.new(8, signed: false)

    value = %{
      registration: "capacity",
      generation: "capacity",
      identity: %{},
      gate: gate,
      coordinator: self(),
      executor: self()
    }

    handles =
      for _ <- 1..128 do
        assert {:ok, handle, _} =
                 ResourceRegistry.start_clock_wait(registry, "owner", value,
                   incarnation: 1,
                   owner_pid: self()
                 )

        handle
      end

    {:ok, supervisor} = ResourceRegistry.worker_supervisor(registry)
    before = DynamicSupervisor.count_children(supervisor)

    assert {:error, %Error{class: :overloaded}} =
             ResourceRegistry.start_clock_wait(registry, "owner", value,
               incarnation: 1,
               owner_pid: self()
             )

    assert DynamicSupervisor.count_children(supervisor) == before

    assert {:ok, other, _} =
             ResourceRegistry.start_clock_wait(registry, "other", value,
               incarnation: 1,
               owner_pid: self()
             )

    for handle <- handles, do: ResourceRegistry.release(registry, handle, "owner")
    assert {:ok, :ok} = ResourceRegistry.release(registry, other, "other")
  end

  defp waiting(duration, opts \\ []) do
    registry = start_supervised!({ResourceRegistry, []}, id: make_ref())
    observer = self()
    coordinator = Keyword.get(opts, :coordinator, observer)
    deadline = Keyword.get(opts, :deadline, System.monotonic_time(:millisecond) + 65_000)

    operation = %{
      run_id: "clock-run",
      incarnation: 1,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "invocation",
      tool_name: "clock::sleep",
      tool_revision: 1,
      arguments: %{"duration_ms" => duration},
      backend_context: %{family: :local, cancellation_coordinator: coordinator}
    }

    context = %{
      runtime_operation: operation,
      resource_owner: %{
        resource_registry: registry,
        owner_id: "owner",
        incarnation: 1,
        owner_pid: Keyword.get(opts, :owner_pid, observer)
      },
      cancellation_coordinator: coordinator,
      effect_deadline: fn ->
        {:ok, %{deadline_ms: deadline, paused: false}}
      end,
      register_cancellation: fn admitted, registration ->
        send(observer, {:registration, self(), admitted, registration})

        receive do
          {:registered, ^coordinator} -> {:ok, coordinator}
        end
      end
    }

    task =
      Task.async(fn ->
        result = ClockWait.run(context, duration)

        if Keyword.get(opts, :hold_result, false) do
          send(observer, {:clock_result, self(), result})
          receive do: (:release_result -> :ok)
        end

        result
      end)

    assert_receive {:registration, task_pid, admitted, registration}, 1_000
    assert task_pid == task.pid
    {registry, task, admitted, registration}
  end

  defp cancellation(operation, registration) do
    operation
    |> Map.put(:clock_registration, registration)
    |> Map.put(:stop_generation, "stop-one")
    |> Map.put(:cleanup_deadline, System.monotonic_time(:millisecond) + 1_000)
  end

  defp await_cleanup(registry, handle, attempts \\ 100)

  defp await_cleanup(registry, handle, attempts) when attempts > 0 do
    case ResourceRegistry.cleanup_status(registry, handle, "owner") do
      {:ok, %{status: :confirmed}} = result ->
        result

      _ ->
        receive do
        after
          1 -> await_cleanup(registry, handle, attempts - 1)
        end
    end
  end

  defp await_cleanup(registry, handle, 0),
    do: ResourceRegistry.cleanup_status(registry, handle, "owner")
end
