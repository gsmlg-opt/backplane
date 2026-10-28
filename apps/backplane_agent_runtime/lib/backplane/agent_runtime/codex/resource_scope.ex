defmodule Backplane.AgentRuntime.Codex.ResourceScope do
  @moduledoc false
  alias Backplane.AgentRuntime.{Error, ToolEffects}
  alias Backplane.AgentRuntime.Codex.ResourceRequest
  alias Backplane.McpProtocol.Client

  @enforce_keys [:runtime, :registration, :generation, :admission_gate]
  defstruct [:runtime, :registration, :generation, :admission_gate]

  def run(%{backend_context: %{runtime: runtime} = context} = operation, callback)
      when is_pid(runtime) and is_function(callback, 1) do
    with {:ok, deadline} <- live_deadline(context),
         {:ok, scope} <- GenServer.call(runtime, {:resource_scope, {:open, operation, deadline}}) do
      case ResourceRequest.register_conversation(
             context,
             registration_operation(operation, scope),
             scope.registration
           ) do
        :ok ->
          try do
            callback.(scope)
          after
            GenServer.call(runtime, {:resource_scope, {:close, scope}})
          end

        error ->
          GenServer.call(runtime, {:discard_resource, scope.registration})
          error
      end
    end
  end

  def run(_, _), do: unavailable("resource scope requires an admitted native operation")

  def request(%__MODULE__{} = scope, starter) when is_function(starter, 1) do
    control = Client.resource_cancellation_control()

    with {:ok, context} <- GenServer.call(scope.runtime, {:resource_scope, {:context, scope}}),
         {:ok, deadline} <- live_deadline(context),
         {:ok, slot, control, opts} <-
           GenServer.call(scope.runtime, {:resource_scope, {:admit, scope, deadline, control}}) do
      result = starter.(opts)

      case result do
        {:ok, handle} ->
          with {:ok, identity} <- Client.resource_request_identity(handle),
               :ok <-
                 GenServer.call(
                   scope.runtime,
                   {:resource_scope, {:attach, scope, slot, identity}}
                 ) do
            result = Client.await_resource_request(handle, :infinity, cancellation: control)
            deadline = GenServer.call(scope.runtime, {:resource_scope, {:due, scope}})

            receipt =
              Client.retire_resource_request(handle,
                timeout: max(1, deadline - now()),
                deadline: deadline
              )

            GenServer.call(scope.runtime, {:resource_scope, {:finish, scope, slot, receipt}})

            case result do
              {:cancelled, _} -> {:error, Error.new(:cancelled, "MCP resource request cancelled")}
              other -> other
            end
          end

        error ->
          GenServer.call(scope.runtime, {:resource_scope, {:finish, scope, slot, :unavailable}})
          error
      end
    end
  end

  def request(_, _), do: unavailable("resource scope capability is invalid")

  def handle({:open, operation, deadline}, {owner, _}, state) do
    occupied =
      Enum.any?(state.resource_requests, fn {_, e} ->
        e.owner == owner and Map.get(e, :callback_open, false)
      end)

    if occupied do
      {:reply, unavailable("nested resource scopes are forbidden"), state}
    else
      registration = ResourceRequest.registration_id()

      scope = %__MODULE__{
        runtime: self(),
        registration: registration,
        generation: ResourceRequest.registration_id(),
        admission_gate: :atomics.new(6, signed: false)
      }

      coordinator = operation.backend_context.cancellation_coordinator

      publish_words(
        scope.admission_gate,
        registration_digest(operation, registration, scope.generation, coordinator)
      )

      entry = %{
        coordinator: coordinator,
        kind: :scope,
        scope: scope,
        registration: registration,
        operation: registration_operation(operation, scope),
        owner: owner,
        monitor: Process.monitor(owner),
        coordinator_monitor: Process.monitor(coordinator),
        managed: false,
        callback_open: true,
        gate: :open,
        slots: [],
        current: nil,
        deadline: deadline,
        cleanup_deadline: nil,
        stop_generation: nil,
        waiters: [],
        result: nil
      }

      {:reply, {:ok, scope}, put_in(state.resource_requests[registration], entry)}
    end
  end

  def handle({:cancel, operation, deadline}, from, state) do
    entry = state.resource_requests[operation[:resource_registration]]

    if entry && entry.kind == :scope && registered?(entry.scope) &&
         get_in(operation, [:backend_context, :cancellation_coordinator]) === entry.coordinator &&
         get_in(operation, [:resource_scope_admission, :gate]) === entry.scope.admission_gate &&
         get_in(operation, [:resource_scope_admission, :generation]) === entry.scope.generation &&
         ToolEffects.cancellation_identity(entry.operation) ===
           ToolEffects.cancellation_identity(operation) &&
         is_binary(operation[:stop_generation]) && operation.stop_generation != "" &&
         (entry.stop_generation == nil || entry.stop_generation === operation.stop_generation) &&
         (entry.cleanup_deadline == nil || entry.cleanup_deadline === deadline) &&
         is_integer(deadline) && deadline > now() do
      seal_gate(entry.scope.admission_gate)

      entry = %{
        entry
        | gate: :sealed,
          stop_generation: operation.stop_generation,
          cleanup_deadline: deadline,
          waiters: [from | entry.waiters]
      }

      if entry.current do
        slot = Enum.at(entry.slots, entry.current - 1)
        ResourceRequest.signal(slot.control, "runtime_cancelled", min(deadline, entry.deadline))
      end

      entry = reply_if_retired(entry)
      {:noreply, put_in(state.resource_requests[entry.registration], entry)}
    else
      {:reply, unavailable("resource scope cancellation is stale"), state}
    end
  end

  def handle(message, {owner, _}, state) do
    scope = elem(message, 1)
    entry = state.resource_requests[scope.registration]

    if entry && Map.get(entry, :kind) == :scope && entry.scope === scope && entry.owner === owner do
      transition(message, entry, state)
    else
      {:reply, unavailable("resource scope is foreign or stale"), state}
    end
  end

  defp transition({:context, _}, %{callback_open: true, gate: :open} = entry, state),
    do: {:reply, {:ok, entry.operation.backend_context}, state}

  defp transition({:due, _}, entry, state),
    do:
      {:reply,
       if(entry.cleanup_deadline,
         do: min(entry.deadline, entry.cleanup_deadline),
         else: entry.deadline
       ), state}

  defp transition({:close, _}, entry, state) do
    seal_gate(entry.scope.admission_gate)
    operation = Map.update!(entry.operation, :backend_context, &Map.take(&1, [:runtime, :family]))

    {:reply, :ok,
     put_in(state.resource_requests[entry.registration], %{
       entry
       | callback_open: false,
         operation: operation
     })}
  end

  defp transition(
         {:admit, _, live_due, control},
         %{callback_open: true, gate: :open, current: nil} = entry,
         state
       ) do
    due = min(live_due, entry.deadline)

    cond do
      due <= now() ->
        {:reply, unavailable("resource scope deadline expired"), state}

      :atomics.get(entry.scope.admission_gate, 1) >= 129 ->
        {:reply, unavailable("resource scope stop fence is closed"), state}

      length(entry.slots) >= 128 ->
        {:reply,
         {:error,
          Error.new(:budget_exceeded, "resource scope exceeds 128 request slots",
            details: %{limit: 128}
          )}, state}

      true ->
        index = length(entry.slots) + 1

        if :atomics.compare_exchange(entry.scope.admission_gate, 1, index - 1, index) == :ok do
          slot = %{index: index, control: control, identity: nil, receipt: nil, phase: :starting}
          entry = %{entry | slots: entry.slots ++ [slot], current: index}

          opts = [
            track_retirement: true,
            timeout: min(30_000, due - now()),
            registration_timeout: min(5_000, due - now()),
            retirement_deadline: due
          ]

          {:reply, {:ok, index, control, opts},
           put_in(state.resource_requests[entry.registration], entry)}
        else
          {:reply, unavailable("resource scope stop fence is closed"), state}
        end
    end
  end

  defp transition({:attach, _, index, identity}, %{current: index} = entry, state) do
    slot = Enum.at(entry.slots, index - 1)

    if slot.identity == nil do
      slot = %{slot | identity: identity, phase: :active}
      entry = %{entry | slots: List.replace_at(entry.slots, index - 1, slot)}
      {:reply, :ok, put_in(state.resource_requests[entry.registration], entry)}
    else
      {:reply, unavailable("resource slot already attached"), state}
    end
  end

  defp transition({:finish, _, index, receipt}, %{current: index} = entry, state) do
    slot = Enum.at(entry.slots, index - 1)
    confirmed = match?({:ok, _}, receipt) && valid_receipt?(elem(receipt, 1), slot.identity)
    if not confirmed, do: seal_gate(entry.scope.admission_gate)

    slot = %{
      slot
      | receipt: if(confirmed, do: elem(receipt, 1)),
        phase: if(confirmed, do: :retired, else: :uncertain),
        control: nil
    }

    entry =
      %{
        entry
        | slots: List.replace_at(entry.slots, index - 1, slot),
          current: nil,
          gate: if(confirmed, do: entry.gate, else: :sealed)
      }
      |> reply_if_retired()

    {:reply, :ok, put_in(state.resource_requests[entry.registration], entry)}
  end

  defp transition(_, _, state),
    do: {:reply, unavailable("resource scope is sealed, busy or stale"), state}

  def valid_receipt?(receipt, identity) when is_map(receipt) and is_map(identity) do
    exact_fields?(identity, ~w(logical_id request_id client_incarnation method)a) &&
      exact_fields?(
        receipt,
        ~w(schema version logical_id request_id request_ids client_incarnation method terminal local local_cleanup cleanup_evidence remote)a
      ) &&
      exact_fields?(receipt[:cleanup_evidence], ~w(workers_down worker_count transport)a) &&
      match?({:ok, _}, Backplane.AgentRuntime.Codex.Reconciliation.Evidence.public(receipt)) &&
      receipt[:schema] === :resource_retirement && receipt[:version] === 1 &&
      receipt[:local] === :retired && receipt[:local_cleanup] === :confirmed &&
      receipt[:remote] === :unknown &&
      receipt[:terminal] in [:completed, :cancelled, :failed, :timed_out] &&
      Enum.all?([:logical_id, :request_id, :client_incarnation, :method], fn k ->
        Map.fetch(receipt, k) === Map.fetch(identity, k) && is_binary(receipt[k]) &&
          receipt[k] != ""
      end) &&
      is_list(receipt[:request_ids]) && receipt.request_ids != [] &&
      length(receipt.request_ids) <= 256 && Enum.uniq(receipt.request_ids) === receipt.request_ids &&
      hd(receipt.request_ids) === identity.request_id &&
      Enum.all?(receipt.request_ids, &(is_binary(&1) && &1 != "")) &&
      match?(
        %{workers_down: true, transport: :confirmed, worker_count: count}
        when is_integer(count) and count >= 0,
        receipt[:cleanup_evidence]
      )
  end

  def valid_receipt?(_, _), do: false

  defp exact_fields?(value, fields) when is_map(value),
    do: Enum.sort(Map.keys(value)) === Enum.sort(fields)

  defp exact_fields?(_, _), do: false

  defp reply_if_retired(%{stop_generation: generation} = entry) when is_binary(generation) do
    assertion = assertion(entry)

    if match?({:ok, _}, assertion) do
      Enum.each(entry.waiters, &GenServer.reply(&1, assertion))
      %{entry | waiters: []}
    else
      entry
    end
  end

  defp reply_if_retired(entry), do: entry

  defp assertion(entry) do
    if entry.current == nil &&
         Enum.all?(
           entry.slots,
           &(&1.phase === :retired && valid_receipt?(&1.receipt, &1.identity))
         ) &&
         now() <= min(entry.deadline, entry.cleanup_deadline) do
      slots = Enum.map(entry.slots, &Map.take(&1, [:index, :identity, :receipt, :phase]))

      digest = Backplane.AgentRuntime.Codex.Reconciliation.Evidence.digest(slots)
      :ok = freeze_inventory(entry.scope.admission_gate, digest)

      operation =
        entry.operation
        |> Map.put(:stop_generation, entry.stop_generation)
        |> Map.put(:resource_registration, entry.registration)

      ToolEffects.confirm_aggregate_cancellation(operation, %{
        schema_version: 1,
        record_type: :resource_scope_cancellation,
        registration_id: entry.registration,
        scope_generation: entry.scope.generation,
        stop_generation: entry.stop_generation,
        gate: entry.gate,
        inventory_count: length(slots),
        inventory_digest: digest,
        slots: slots,
        local_cleanup: :confirmed,
        remote: :unknown
      })
    else
      unavailable("resource scope cleanup deadline expired")
    end
  end

  def registration_operation(operation, scope) do
    Map.put(operation, :resource_scope_admission, %{
      gate: scope.admission_gate,
      registration: scope.registration,
      generation: scope.generation,
      identity: ToolEffects.cancellation_identity(operation),
      coordinator: operation.backend_context.cancellation_coordinator
    })
  end

  # The atomic reservation is the admission linearization point. Conversation
  # closes this capability without waiting for the Runtime mailbox; the ordered
  # ledger remains the sole authority over every slot reserved before closure.
  def seal_admission(%{operation: operation, registration: registration}) do
    case operation[:resource_scope_admission] do
      %{registration: ^registration, identity: identity, gate: gate} ->
        if identity === ToolEffects.cancellation_identity(operation),
          do: seal_gate(gate)

      _ ->
        :ok
    end

    :ok
  end

  def register_admission(
        %{resource_scope_admission: admission} = operation,
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
         true <- is_binary(generation) and generation != "",
         true <-
           read_words(gate) ===
             registration_digest(operation, registration, generation, coordinator),
         :ok <- :atomics.compare_exchange(gate, 6, 0, 1) do
      :ok
    else
      _ -> unavailable("resource scope registration metadata is invalid")
    end
  rescue
    ArgumentError -> unavailable("resource scope admission gate is invalid")
  end

  def register_admission(_, _, _), do: :ok

  def registered?(%__MODULE__{admission_gate: gate}), do: :atomics.get(gate, 6) in [1, 3]

  def sealed_inventory_digest(operation) do
    with %{gate: gate} <- operation[:resource_scope_admission],
         3 <- :atomics.get(gate, 6) do
      {:ok, read_words(gate)}
    else
      _ -> unavailable("resource scope inventory digest is unavailable")
    end
  rescue
    ArgumentError -> unavailable("resource scope admission gate is invalid")
  end

  # Before registration the words authenticate the original scope metadata.
  # Only Runtime's serialized all-retired ledger replaces them, publishing ready
  # last. A ready digest is immutable for repeated acknowledgement/validation.
  defp freeze_inventory(gate, digest) do
    case :atomics.get(gate, 6) do
      1 ->
        publish_words(gate, digest)
        :ok = :atomics.compare_exchange(gate, 6, 1, 3)
        :ok

      3 ->
        if read_words(gate) === digest,
          do: :ok,
          else: unavailable("resource scope inventory changed")

      _ ->
        unavailable("resource scope is not registered")
    end
  end

  defp registration_digest(operation, registration, generation, coordinator) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {ToolEffects.cancellation_identity(operation), registration, generation, coordinator}
      )
    )
    |> Base.encode16(case: :lower)
  end

  defp publish_words(gate, digest) do
    digest
    |> Base.decode16!(case: :lower)
    |> then(fn binary ->
      for <<word::unsigned-big-integer-size(64) <- binary>>, do: word
    end)
    |> Enum.with_index(2)
    |> Enum.each(fn {word, index} -> :atomics.put(gate, index, word) end)
  end

  defp read_words(gate) do
    for(
      index <- 2..5,
      into: <<>>,
      do: <<:atomics.get(gate, index)::unsigned-big-integer-size(64)>>
    )
    |> Base.encode16(case: :lower)
  end

  def sealed_inventory_count(operation) do
    with %{registration: registration, identity: identity, gate: gate} <-
           operation[:resource_scope_admission],
         true <- registration === operation[:resource_registration],
         true <- identity === ToolEffects.cancellation_identity(operation),
         count when count >= 129 and count <= 257 <- :atomics.get(gate, 1) do
      {:ok, count - 129}
    else
      _ -> unavailable("resource scope inventory is not sealed")
    end
  rescue
    ArgumentError -> unavailable("resource scope admission gate is invalid")
  end

  # Preserve the admitted count in the closed value. Repeated close must never
  # erase it, and a racing reservation must win or lose the same atomic CAS.
  defp seal_gate(gate) do
    count = :atomics.get(gate, 1)

    if count < 129 do
      case :atomics.compare_exchange(gate, 1, count, count + 129) do
        :ok -> :ok
        _ -> seal_gate(gate)
      end
    else
      :ok
    end
  end

  defp live_deadline(context) do
    with coordinator when is_pid(coordinator) <- context[:cancellation_coordinator],
         true <- Process.alive?(coordinator),
         register when is_function(register, 2) <- context[:register_cancellation],
         callback when is_function(callback, 0) <- context[:effect_deadline],
         {:ok, %{deadline_ms: due, paused: false}} when is_integer(due) <- callback.(),
         true <- due > now() do
      {:ok, due}
    else
      _ -> unavailable("resource scope has no live effect deadline")
    end
  end

  defp unavailable(message), do: {:error, Error.new(:unknown_outcome, message)}
  defp now, do: System.monotonic_time(:millisecond)
end
