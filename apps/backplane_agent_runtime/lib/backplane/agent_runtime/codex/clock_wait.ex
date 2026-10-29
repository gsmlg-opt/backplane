defmodule Backplane.AgentRuntime.Codex.ClockWait do
  @moduledoc false

  alias Backplane.AgentRuntime.{Error, ToolEffects}
  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  def run(context, duration) do
    with {:ok, operation, owner, coordinator, deadline} <- live_context(context),
         {:ok, handle, value} <- allocate(operation, owner, coordinator) do
      admission =
        Map.merge(value, %{
          registry: owner.resource_registry,
          handle: handle
        })

      publish_words(
        admission.gate,
        registration_digest(operation, admission.registration, admission.generation, coordinator)
      )

      admitted = Map.put(operation, :clock_wait_admission, admission)

      case context.register_cancellation.(admitted, admission.registration) do
        {:ok, ^coordinator} ->
          await(admission, duration, deadline)

        error ->
          ResourceRegistry.release(owner.resource_registry, handle, owner.owner_id)
          error
      end
    end
  catch
    :exit, _ -> unavailable("native clock lifetime acknowledgement unavailable")
  end

  defp allocate(operation, owner, coordinator) do
    value = %{
      registration: unique_id(),
      generation: unique_id(),
      identity: ToolEffects.cancellation_identity(operation),
      gate: :atomics.new(8, signed: false),
      coordinator: coordinator,
      executor: self()
    }

    ResourceRegistry.start_clock_wait(owner.resource_registry, owner.owner_id, value,
      incarnation: owner.incarnation,
      owner_pid: owner.owner_pid
    )
  end

  defp await(admission, duration, deadline) do
    monitor = Process.monitor(admission.waiter)

    try do
      with {:ok, elapsed} <-
             GenServer.call(
               admission.waiter,
               {:await, admission.generation, duration, deadline},
               remaining(deadline)
             ),
           :ok <- joined(admission.waiter, monitor, deadline) do
        :atomics.put(admission.gate, 8, 1)
        {:ok, %{wall_time_seconds: elapsed}}
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  def register_admission(
        %{clock_wait_admission: admission} = operation,
        registration,
        coordinator
      ) do
    with true <- coordinator === self(),
         %{registration: ^registration, coordinator: ^coordinator} <- admission,
         true <- get_in(operation, [:backend_context, :cancellation_coordinator]) === coordinator,
         true <- admission.identity === ToolEffects.cancellation_identity(operation),
         {:ok, value} <-
           ResourceRegistry.fetch(admission.registry, admission.handle, admission.handle.owner_id),
         true <- Map.take(admission, Map.keys(value)) === value,
         true <-
           read_words(admission.gate) ===
             registration_digest(operation, registration, admission.generation, coordinator),
         :ok <- :atomics.compare_exchange(admission.gate, 6, 0, 1) do
      :ok
    else
      _ -> unavailable("native clock cancellation admission is stale")
    end
  rescue
    ArgumentError -> unavailable("native clock admission gate is invalid")
  catch
    :exit, _ -> unavailable("native clock registry is unavailable")
  end

  def register_admission(_, _, _), do: unavailable("native clock admission is missing")

  def seal_admission(%{operation: %{clock_wait_admission: %{gate: gate}}}), do: seal_gate(gate)

  def retired?(%{operation: %{clock_wait_admission: %{gate: gate}}}),
    do: :atomics.get(gate, 7) == 1 and :atomics.get(gate, 8) == 1

  def cancel(%{clock_wait_admission: admission} = operation) do
    deadline = operation[:cleanup_deadline]
    generation = operation[:stop_generation]

    with true <- is_integer(deadline) and deadline > now(),
         true <- is_binary(generation) and generation != "",
         true <- admission.registration === operation[:clock_registration],
         true <- admission.identity === ToolEffects.cancellation_identity(operation),
         true <- :atomics.get(admission.gate, 6) in [1, 3],
         :ok <- cleanup(admission, remaining(deadline)),
         report = %{
           schema_version: 1,
           record_type: :native_clock_cancellation,
           registration_id: admission.registration,
           wait_generation: admission.generation,
           stop_generation: generation,
           completion_gate: :closed,
           timer_retired: true,
           waiter_down: true,
           local_cleanup: :confirmed
         },
         :ok <- freeze_report(admission.gate, Evidence.digest(report)),
         true <- now() < deadline do
      ToolEffects.confirm_clock_cancellation(operation, report)
    else
      _ -> unavailable("native clock retirement is unconfirmed")
    end
  rescue
    ArgumentError -> unavailable("native clock admission gate is invalid")
  end

  def cancel(_), do: unavailable("native clock admission is missing")

  def cleanup(%{waiter: waiter, gate: gate}, timeout) do
    deadline = now() + timeout
    monitor = Process.monitor(waiter)
    seal_gate(gate)
    Process.exit(waiter, :kill)

    try do
      with :ok <- joined(waiter, monitor, deadline) do
        :atomics.put(gate, 7, 1)
        :atomics.put(gate, 8, 1)
        :ok
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  def release(%{operation: %{clock_wait_admission: admission}}) do
    ResourceRegistry.release(admission.registry, admission.handle, admission.handle.owner_id)
  catch
    :exit, _ -> unavailable("native clock release acknowledgement unavailable")
  end

  def sealed_report_digest(%{clock_wait_admission: admission} = operation) do
    with true <- admission.registration === operation[:clock_registration],
         true <- admission.identity === ToolEffects.cancellation_identity(operation),
         3 <- :atomics.get(admission.gate, 6),
         phase when phase in [2, 3] <- :atomics.get(admission.gate, 1),
         1 <- :atomics.get(admission.gate, 7),
         1 <- :atomics.get(admission.gate, 8) do
      {:ok, read_words(admission.gate)}
    else
      _ -> unavailable("native clock retirement digest is unavailable")
    end
  rescue
    ArgumentError -> unavailable("native clock admission gate is invalid")
  end

  def sealed_report_digest(_), do: unavailable("native clock admission is missing")

  defp live_context(context) do
    with %{backend_context: %{family: :local}} = operation <- context[:runtime_operation],
         %{resource_registry: registry, owner_id: owner_id, incarnation: incarnation} = owner <-
           context[:resource_owner],
         true <- is_pid(registry) and is_binary(owner_id) and is_integer(incarnation),
         coordinator when is_pid(coordinator) <- context[:cancellation_coordinator],
         true <- Process.alive?(coordinator),
         register when is_function(register, 2) <- context[:register_cancellation],
         due when is_function(due, 0) <- context[:effect_deadline],
         {:ok, %{deadline_ms: deadline, paused: false}} when is_integer(deadline) <- due.(),
         true <- deadline > now() do
      {:ok, operation, owner, coordinator, deadline}
    else
      _ -> unavailable("native clock requires a live admitted operation")
    end
  end

  defp joined(waiter, monitor, deadline) do
    receive do
      {:DOWN, ^monitor, :process, ^waiter, _} -> :ok
    after
      remaining(deadline) -> unavailable("native clock waiter shutdown is unconfirmed")
    end
  end

  defp freeze_report(gate, digest) do
    case :atomics.compare_exchange(gate, 6, 1, 2) do
      :ok ->
        publish_words(gate, digest)
        :atomics.put(gate, 6, 3)
        :ok

      3 ->
        if read_words(gate) === digest,
          do: :ok,
          else: unavailable("native clock retirement changed")

      _ ->
        unavailable("native clock retirement is not sealed")
    end
  end

  defp seal_gate(gate) do
    phase = :atomics.get(gate, 1)

    if phase < 2 do
      case :atomics.compare_exchange(gate, 1, phase, phase + 2) do
        :ok -> :ok
        _ -> seal_gate(gate)
      end
    else
      :ok
    end
  end

  defp registration_digest(operation, registration, generation, coordinator),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          {ToolEffects.cancellation_identity(operation), registration, generation, coordinator}
        )
      )
      |> Base.encode16(case: :lower)

  defp publish_words(gate, digest) do
    digest
    |> Base.decode16!(case: :lower)
    |> then(fn binary -> for <<word::unsigned-big-integer-size(64) <- binary>>, do: word end)
    |> Enum.with_index(2)
    |> Enum.each(fn {word, index} -> :atomics.put(gate, index, word) end)
  end

  defp read_words(gate),
    do:
      for(
        index <- 2..5,
        into: <<>>,
        do: <<:atomics.get(gate, index)::unsigned-big-integer-size(64)>>
      )
      |> Base.encode16(case: :lower)

  defp unique_id, do: "clock_#{System.unique_integer([:positive, :monotonic])}"
  defp unavailable(message), do: {:error, Error.new(:unknown_outcome, message)}
  defp remaining(deadline), do: max(1, deadline - now())
  defp now, do: System.monotonic_time(:millisecond)
end

defmodule Backplane.AgentRuntime.Codex.ClockWait.Worker do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Backplane.AgentRuntime.Error

  def start_link(value), do: GenServer.start_link(__MODULE__, value)

  @impl true
  def init(value) do
    {:ok,
     Map.merge(value, %{
       executor_monitor: Process.monitor(value.executor),
       coordinator_monitor: Process.monitor(value.coordinator),
       started: nil,
       timer: nil,
       from: nil
     })}
  end

  @impl true
  def handle_call({:await, generation, duration, deadline}, {caller, _} = from, state) do
    if caller === state.executor and generation === state.generation and
         is_integer(duration) and duration in 1..43_200_000 and
         :atomics.get(state.gate, 6) == 1 and
         is_integer(deadline) and deadline > System.monotonic_time(:millisecond) and
         :atomics.compare_exchange(state.gate, 1, 0, 1) == :ok do
      started = System.monotonic_time(:microsecond)
      timer = Process.send_after(self(), {:elapsed, generation}, duration)

      {:noreply, %{state | timer: timer, from: from, started: started}}
    else
      {:reply, {:error, Error.new(:unknown_outcome, "native clock start fence is closed")}, state}
    end
  end

  @impl true
  def handle_info(
        {:elapsed, generation},
        %{generation: generation, started: started, timer: timer, from: from} = state
      )
      when is_integer(started) and is_reference(timer) and is_tuple(from) do
    if :atomics.compare_exchange(state.gate, 1, 1, 3) == :ok do
      :atomics.put(state.gate, 7, 1)
      elapsed = (System.monotonic_time(:microsecond) - state.started) / 1_000_000
      GenServer.reply(state.from, {:ok, elapsed})
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state)
      when monitor == state.executor_monitor or monitor == state.coordinator_monitor do
    seal(state.gate)
    if state.timer, do: Process.cancel_timer(state.timer)
    {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp seal(gate) do
    phase = :atomics.get(gate, 1)

    if phase < 2 do
      case :atomics.compare_exchange(gate, 1, phase, phase + 2) do
        :ok -> :ok
        _ -> seal(gate)
      end
    else
      :ok
    end
  end
end
