defmodule Backplane.AgentRuntime.Codex.EventRequest do
  @moduledoc false
  alias Backplane.AgentRuntime.{Error, ToolEffects}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.McpProtocol.Client

  def run(%{backend_context: %{runtime: runtime} = context} = operation, starter)
      when is_pid(runtime) and is_function(starter, 1) do
    control = Client.event_cancellation_control()

    with {:ok, deadline} <- live_deadline(context),
         {:ok, admitted, registration} <- call(runtime, {:open, operation, deadline, control}),
         {:ok, coordinator} <- context.register_cancellation.(admitted, registration),
         :ok <- call(runtime, {:coordinate, registration, coordinator}),
         {:ok, opts} <- call(runtime, {:begin, registration}) do
      finish(runtime, registration, starter.(opts))
    end
  end

  def run(_, _), do: unavailable("Events requires an admitted native operation")

  defp finish(runtime, registration, {:ok, handle}) do
    with {:ok, identity} <- Client.event_request_identity(handle),
         :ok <- call(runtime, {:attach, registration, identity}),
         {:ok, control} <- call(runtime, {:control, registration}) do
      result = Client.await_event_request(handle, :infinity, cancellation: control)
      {:ok, deadline} = call(runtime, {:due, registration})

      receipt =
        Client.retire_event_request(handle,
          timeout: max(1, deadline - now()),
          deadline: deadline
        )

      with :ok <- call(runtime, {:finish, registration, receipt}) do
        case result do
          {:cancelled, _} -> {:error, Error.new(:cancelled, "MCP Events request cancelled")}
          other -> other
        end
      end
    else
      _ -> finish(runtime, registration, :unavailable)
    end
  end

  defp finish(runtime, registration, _error) do
    call(runtime, {:finish, registration, :unavailable})
    unavailable("Events start has no confirmed request retirement")
  end

  def cancel(operation) do
    deadline = operation.cleanup_deadline

    call(
      operation.backend_context.runtime,
      {:cancel, operation, deadline},
      max(1, deadline - now())
    )
  end

  def retired?(%{operation: %{event_request_admission: %{gate: gate}}}),
    do: :atomics.get(gate, 7) == 1

  def release(%{operation: operation, registration: registration}) do
    GenServer.cast(
      operation.backend_context.runtime,
      {:event_request_release, registration, ToolEffects.cancellation_identity(operation)}
    )
  end

  def handle({:open, operation, deadline, control}, {owner, _}, state) do
    if map_size(state.event_requests) < 1_024 do
      registration = unique_id()
      generation = unique_id()
      coordinator = operation.backend_context.cancellation_coordinator
      gate = :atomics.new(7, signed: false)
      publish_words(gate, registration_digest(operation, registration, generation, coordinator))

      admitted =
        Map.put(operation, :event_request_admission, %{
          registration: registration,
          generation: generation,
          gate: gate,
          identity: ToolEffects.cancellation_identity(operation),
          coordinator: coordinator
        })

      entry = %{
        operation: admitted,
        registration: registration,
        generation: generation,
        gate: gate,
        owner: owner,
        monitor: Process.monitor(owner),
        coordinator: coordinator,
        coordinator_monitor: Process.monitor(coordinator),
        control: control,
        managed: false,
        phase: :registered,
        identity: nil,
        receipt: nil,
        deadline: deadline,
        cleanup_deadline: nil,
        stop_generation: nil,
        waiters: []
      }

      {:reply, {:ok, admitted, registration}, put_in(state.event_requests[registration], entry)}
    else
      {:reply, unavailable("too many active Events requests"), state}
    end
  end

  def handle({:cancel, operation, deadline}, from, state) do
    entry = state.event_requests[operation[:event_registration]]

    if entry && registered?(entry.gate) &&
         ToolEffects.cancellation_identity(entry.operation) ===
           ToolEffects.cancellation_identity(operation) &&
         entry.operation.event_request_admission === operation[:event_request_admission] &&
         is_binary(operation[:stop_generation]) && operation.stop_generation != "" &&
         (entry.stop_generation == nil || entry.stop_generation === operation.stop_generation) &&
         (entry.cleanup_deadline == nil || entry.cleanup_deadline === deadline) &&
         is_integer(deadline) && deadline > now() do
      seal_gate(entry.gate)

      entry = %{
        entry
        | stop_generation: operation.stop_generation,
          cleanup_deadline: deadline,
          waiters: [from | entry.waiters]
      }

      if entry.control && entry.phase in [:starting, :active] do
        Client.cancel_event_wait(entry.control, "runtime_cancelled",
          timeout: max(1, min(deadline, entry.deadline) - now())
        )
      end

      {:noreply, put_in(state.event_requests[entry.registration], reply_if_retired(entry))}
    else
      {:reply, unavailable("Events cancellation registration is stale"), state}
    end
  end

  def handle(message, {owner, _}, state) do
    registration = elem(message, 1)

    case state.event_requests[registration] do
      %{owner: ^owner} = entry -> transition(message, entry, state)
      _ -> {:reply, unavailable("Events request registration is foreign or stale"), state}
    end
  end

  defp transition({:coordinate, _, coordinator}, entry, state) do
    if coordinator === entry.coordinator && registered?(entry.gate) do
      {:reply, :ok, put_in(state.event_requests[entry.registration], %{entry | managed: true})}
    else
      {:reply, unavailable("Events coordinator is stale"), state}
    end
  end

  defp transition({:begin, _}, %{phase: :registered, managed: true} = entry, state) do
    if entry.deadline > now() && :atomics.compare_exchange(entry.gate, 1, 0, 1) == :ok do
      {:reply, {:ok, tracking_options(entry.deadline)},
       put_in(state.event_requests[entry.registration], %{entry | phase: :starting})}
    else
      {:reply, unavailable("Events start fence is closed"), state}
    end
  end

  defp transition({:attach, _, identity}, %{phase: :starting, identity: nil} = entry, state) do
    if valid_identity?(identity) do
      {:reply, :ok,
       put_in(state.event_requests[entry.registration], %{
         entry
         | identity: identity,
           phase: :active
       })}
    else
      {:reply, unavailable("Events request identity is invalid"), state}
    end
  end

  defp transition({:control, _}, entry, state), do: {:reply, {:ok, entry.control}, state}
  defp transition({:due, _}, entry, state), do: {:reply, {:ok, due(entry)}, state}

  defp transition({:finish, _, receipt}, entry, state) do
    confirmed =
      match?({:ok, _}, receipt) && valid_receipt?(elem(receipt, 1), entry.identity) &&
        now() < due(entry)

    if confirmed, do: :atomics.put(entry.gate, 7, 1)

    entry = %{
      entry
      | phase: if(confirmed, do: :retired, else: :uncertain),
        receipt: if(confirmed, do: elem(receipt, 1)),
        control: nil
    }

    entry = reply_if_retired(entry)
    reply = if confirmed, do: :ok, else: unavailable("Events local retirement is unconfirmed")
    {:reply, reply, put_in(state.event_requests[entry.registration], entry)}
  end

  defp transition(_, _, state),
    do: {:reply, unavailable("Events request is sealed or stale"), state}

  def released(state, registration, identity) do
    case state.event_requests[registration] do
      %{operation: operation} = entry ->
        if ToolEffects.cancellation_identity(operation) === identity,
          do: drop(state, entry),
          else: state

      _ ->
        state
    end
  end

  def down(state, monitor) do
    Enum.reduce(state.event_requests, state, fn {_, entry}, current ->
      cond do
        entry.coordinator_monitor === monitor ->
          seal_gate(entry.gate)
          Enum.each(entry.waiters, &GenServer.reply(&1, unavailable("Events coordinator exited")))

          if entry.managed || registered?(entry.gate),
            do:
              put_in(current.event_requests[entry.registration], %{
                entry
                | coordinator_monitor: nil,
                  waiters: []
              }),
            else: drop(current, entry)

        entry.monitor === monitor ->
          Enum.each(entry.waiters, &GenServer.reply(&1, unavailable("Events owner exited")))

          if entry.managed || registered?(entry.gate),
            do:
              put_in(current.event_requests[entry.registration], %{
                entry
                | monitor: nil,
                  waiters: []
              }),
            else: drop(current, entry)

        true ->
          current
      end
    end)
  end

  defp drop(state, entry) do
    for monitor <- [entry.monitor, entry.coordinator_monitor],
        is_reference(monitor),
        do: Process.demonitor(monitor, [:flush])

    %{state | event_requests: Map.delete(state.event_requests, entry.registration)}
  end

  defp reply_if_retired(%{phase: :retired, stop_generation: generation} = entry)
       when is_binary(generation) do
    report = %{
      schema_version: 1,
      record_type: :event_request_cancellation,
      registration_id: entry.registration,
      request_generation: entry.generation,
      stop_generation: generation,
      request_identity: entry.identity,
      receipt: entry.receipt,
      local_cleanup: :confirmed,
      remote: :unknown
    }

    if now() < due(entry) do
      :ok = freeze_report(entry.gate, Evidence.digest(report))

      operation =
        entry.operation
        |> Map.put(:stop_generation, generation)
        |> Map.put(:event_registration, entry.registration)

      assertion = ToolEffects.confirm_events_cancellation(operation, report)
      Enum.each(entry.waiters, &GenServer.reply(&1, assertion))
      %{entry | waiters: []}
    else
      entry
    end
  end

  defp reply_if_retired(entry), do: entry

  def register_admission(
        %{event_request_admission: admission} = operation,
        registration,
        coordinator
      ) do
    with true <- coordinator === self(),
         %{
           registration: ^registration,
           generation: generation,
           coordinator: ^coordinator,
           identity: identity,
           gate: gate
         } <- admission,
         true <- get_in(operation, [:backend_context, :cancellation_coordinator]) === coordinator,
         true <- identity === ToolEffects.cancellation_identity(operation),
         true <-
           read_words(gate) ===
             registration_digest(operation, registration, generation, coordinator),
         :ok <- :atomics.compare_exchange(gate, 6, 0, 1) do
      :ok
    else
      _ -> unavailable("Events admission metadata is invalid")
    end
  rescue
    ArgumentError -> unavailable("Events admission gate is invalid")
  end

  def register_admission(_, _, _), do: unavailable("Events admission is missing")

  def seal_admission(%{operation: %{event_request_admission: %{gate: gate}}}), do: seal_gate(gate)

  def sealed_report_digest(operation) do
    with %{gate: gate, registration: registration, identity: identity} <-
           operation[:event_request_admission],
         true <- registration === operation[:event_registration],
         true <- identity === ToolEffects.cancellation_identity(operation),
         3 <- :atomics.get(gate, 6),
         state when state in [2, 3] <- :atomics.get(gate, 1) do
      {:ok, read_words(gate)}
    else
      _ -> unavailable("Events retirement digest is unavailable")
    end
  rescue
    ArgumentError -> unavailable("Events admission gate is invalid")
  end

  def valid_identity?(identity),
    do:
      exact_fields?(identity, ~w(logical_id request_id client_incarnation method)a) &&
        identity.method === "events/list" &&
        Enum.all?(Map.values(identity), &(is_binary(&1) && &1 != ""))

  def valid_receipt?(receipt, identity) when is_map(receipt) do
    valid_identity?(identity) &&
      exact_fields?(
        receipt,
        ~w(schema version logical_id request_id request_ids client_incarnation method terminal local local_cleanup cleanup_evidence remote)a
      ) &&
      receipt.schema === :event_retirement && receipt.version === 1 && receipt.local === :retired &&
      receipt.local_cleanup === :confirmed && receipt.remote === :unknown &&
      receipt.terminal in [:completed, :cancelled, :failed, :timed_out] &&
      Map.take(receipt, Map.keys(identity)) === identity &&
      exact_fields?(receipt.cleanup_evidence, ~w(workers_down worker_count transport)a) &&
      match?(
        %{workers_down: true, transport: :confirmed, worker_count: count}
        when is_integer(count) and count >= 0,
        receipt.cleanup_evidence
      ) &&
      is_list(receipt.request_ids) && length(receipt.request_ids) in 1..256 &&
      hd(receipt.request_ids) === identity.request_id &&
      Enum.uniq(receipt.request_ids) === receipt.request_ids &&
      Enum.all?(receipt.request_ids, &(is_binary(&1) && &1 != "")) &&
      match?({:ok, _}, Evidence.public(receipt))
  end

  def valid_receipt?(_, _), do: false

  defp exact_fields?(map, keys) when is_map(map), do: Enum.sort(Map.keys(map)) === Enum.sort(keys)
  defp exact_fields?(_, _), do: false
  defp registered?(gate), do: :atomics.get(gate, 6) in [1, 3]
  defp due(entry), do: min(entry.deadline, entry.cleanup_deadline || entry.deadline)

  defp live_deadline(context) do
    with coordinator when is_pid(coordinator) <- context[:cancellation_coordinator],
         true <- Process.alive?(coordinator),
         register when is_function(register, 2) <- context[:register_cancellation],
         callback when is_function(callback, 0) <- context[:effect_deadline],
         {:ok, %{deadline_ms: due, paused: false}} when is_integer(due) <- callback.(),
         true <- due > now() do
      {:ok, due}
    else
      _ -> unavailable("Events has no live effect deadline")
    end
  end

  defp tracking_options(due),
    do: [
      track_retirement: true,
      timeout: min(30_000, due - now()),
      registration_timeout: min(5_000, due - now()),
      retirement_deadline: due
    ]

  defp registration_digest(operation, registration, generation, coordinator),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          {ToolEffects.cancellation_identity(operation), registration, generation, coordinator}
        )
      )
      |> Base.encode16(case: :lower)

  defp freeze_report(gate, digest) do
    case :atomics.get(gate, 6) do
      1 ->
        publish_words(gate, digest)
        :ok = :atomics.compare_exchange(gate, 6, 1, 3)
        :ok

      3 ->
        if read_words(gate) === digest, do: :ok, else: unavailable("Events retirement changed")
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

  defp call(runtime, message, timeout \\ 5_000) do
    GenServer.call(runtime, {:event_request, message}, timeout)
  catch
    :exit, _ -> unavailable("Events lifecycle acknowledgement unavailable")
  end

  defp unique_id, do: "events_#{System.unique_integer([:positive, :monotonic])}"
  defp unavailable(message), do: {:error, Error.new(:unknown_outcome, message)}
  defp now, do: System.monotonic_time(:millisecond)
end
