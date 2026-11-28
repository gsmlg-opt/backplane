defmodule Backplane.DiagnosticsClient.Reporter do
  @moduledoc "Admits bounded diagnostics evidence without waiting for either durable delivery hop."

  use GenServer
  import Bitwise

  alias Backplane.DiagnosticsClient.{
    Canonical,
    Context,
    Envelope,
    LocalTransport,
    Receipt,
    Redaction
  }

  @count_unit 1 <<< 32
  @epoch_age_ms 24 * 60 * 60 * 1_000
  @default_interval 1_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {name, opts}, name: name)
  end

  @doc "Reports a string-keyed v1 observation, adding the registered source and transport identity."
  def report(attrs, name \\ __MODULE__) when is_map(attrs) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      %{pid: pid} = handle ->
        if Process.alive?(pid), do: admit(handle, attrs), else: {:error, :disabled}

      nil ->
        {:error, :disabled}
    end
  end

  @doc "Reads queue and loss counters without waiting for delivery."
  def health(name \\ __MODULE__) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      %{meters: meters} = handle ->
        packed = :atomics.get(meters, 1)

        %{
          pending: div(packed, @count_unit),
          pending_bytes: rem(packed, @count_unit),
          max_events: handle.max_events,
          max_bytes: handle.max_bytes,
          dropped: :atomics.get(meters, 2),
          rejected: :atomics.get(meters, 3),
          last_confirmed_at_ms: positive(:atomics.get(meters, 4)),
          transport: transport_state(:atomics.get(meters, 5))
        }

      nil ->
        %{transport: :disabled}
    end
  end

  @doc false
  def boot_id(name \\ __MODULE__) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      %{boot_id: id} -> id
      _ -> nil
    end
  end

  @impl true
  def init({name, opts}) do
    source_id = Keyword.fetch!(opts, :source_id)
    app = Keyword.fetch!(opts, :application)
    max_events = Keyword.get(opts, :max_events, 1_000)
    max_bytes = Keyword.get(opts, :max_bytes, 4 * 1024 * 1024)
    interval = Keyword.get(opts, :interval_ms, @default_interval)

    true =
      Envelope.id?(source_id) and Envelope.id?(app) and max_events in 1..100_000 and
        max_bytes in 1..1_073_741_824 and interval in 1..60_000

    sender = Keyword.get_lazy(opts, :send_batch, fn -> LocalTransport.sender(opts, source_id) end)

    identity = %{
      "source_id" => source_id,
      "application" => app,
      "version" => Keyword.get(opts, :version, %{})
    }

    identity =
      if instance = Keyword.get(opts, :service_instance),
        do: Map.put(identity, "service_instance", instance),
        else: identity

    handle = %{
      pid: self(),
      boot_id: random_id(),
      meters: :atomics.new(5, signed: false),
      identity: identity,
      max_events: max_events,
      max_bytes: max_bytes,
      reserve: min(max_bytes, Canonical.max_bytes())
    }

    {:ok,
     schedule(
       %{
         name: name,
         sender: sender,
         interval: interval,
         queue: :queue.new(),
         active: nil,
         handle: handle
       }
       |> rotate()
     )}
  end

  @impl true
  def handle_info({:enqueue, record}, state),
    do: {:noreply, %{state | queue: :queue.in(record, state.queue)}}

  def handle_info(:flush, state) do
    state = if state.epoch_expires_at <= monotonic_ms(), do: rotate(state), else: state
    {:noreply, state |> send_ready_batch() |> schedule()}
  end

  def handle_info({:delivery_result, pid, result}, %{active: %{pid: pid} = active} = state) do
    Process.demonitor(active.monitor, [:flush])
    {:noreply, apply_result(state, active, result)}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{active: %{monitor: monitor} = active} = state
      ) do
    {:noreply, apply_result(state, active, {:error, :host_unavailable})}
  end

  @impl true
  def terminate(_reason, state) do
    if state.active, do: Process.exit(state.active.pid, :kill)
    :persistent_term.erase({__MODULE__, state.name})
    :ok
  end

  defp admit(handle, attrs) do
    if reserve(handle, 8) do
      case prepare(handle, attrs) do
        {:ok, record} ->
          :atomics.sub(handle.meters, 1, handle.reserve - record.size)
          send(handle.pid, {:enqueue, record})
          :enqueued

        {:error, _} = error ->
          :atomics.sub(handle.meters, 1, @count_unit + handle.reserve)
          :atomics.add(handle.meters, 3, 1)
          error
      end
    else
      :atomics.add(handle.meters, 2, 1)
      {:error, :queue_full}
    end
  end

  defp prepare(handle, attrs) do
    event =
      attrs
      |> Context.attach()
      |> Map.put_new("occurred_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.merge(handle.identity)
      |> Map.put("schema_version", 1)
      |> Map.put("event_id", random_id())
      |> Map.put("producer_epoch", handle.epoch)
      |> Map.put("source_sequence", :atomics.add_get(handle.sequence, 1, 1))
      |> Redaction.project()

    case Envelope.seal(event) do
      {:ok, bytes, digest} when byte_size(bytes) <= handle.reserve ->
        {:ok,
         %{
           id: event["event_id"],
           bytes: bytes,
           size: byte_size(bytes),
           digest: digest,
           attempts: 0,
           due: monotonic_ms()
         }}

      {:ok, _, _} ->
        {:error, :event_too_large}

      {:error, _} = error ->
        error
    end
  rescue
    _error -> {:error, :invalid_event}
  end

  defp reserve(_handle, 0), do: false

  defp reserve(handle, attempts) do
    packed = :atomics.get(handle.meters, 1)

    cond do
      div(packed, @count_unit) >= handle.max_events or
          rem(packed, @count_unit) + handle.reserve > handle.max_bytes ->
        false

      :atomics.compare_exchange(handle.meters, 1, packed, packed + @count_unit + handle.reserve) ==
          :ok ->
        true

      true ->
        reserve(handle, attempts - 1)
    end
  end

  defp rotate(state) do
    handle =
      Map.merge(state.handle, %{epoch: random_id(), sequence: :atomics.new(1, signed: false)})

    :persistent_term.put({__MODULE__, state.name}, handle)

    state
    |> Map.put(:handle, handle)
    |> Map.put(:epoch_expires_at, monotonic_ms() + @epoch_age_ms)
  end

  defp schedule(state) do
    Process.send_after(self(), :flush, state.interval)
    state
  end

  defp send_ready_batch(%{active: active} = state) when not is_nil(active), do: state

  defp send_ready_batch(state) do
    now = monotonic_ms()
    {ready, retained} = Enum.split_with(:queue.to_list(state.queue), &(&1.due <= now))
    {chosen, receipts, backlog} = take_batch(ready)

    if chosen != [] do
      id = random_id()
      batch = Receipt.batch(:local, id, receipts)
      caller = self()
      sender = state.sender

      {pid, monitor} =
        spawn_monitor(fn -> send(caller, {:delivery_result, self(), sender.(batch)}) end)

      %{
        state
        | active: %{pid: pid, monitor: monitor, id: id, records: chosen, entries: receipts},
          queue: :queue.from_list(retained ++ backlog)
      }
    else
      state
    end
  end

  defp take_batch(ready) do
    {records, entries, _, _} =
      Enum.reduce_while(ready, {[], [], 0, 0}, fn record, {records, entries, count, bytes} ->
        cost = record.size + 96

        if count < 100 and bytes + cost <= 524_032 do
          entry = Receipt.entry(Formata.JSON.decode!(record.bytes), record.digest)
          {:cont, {[record | records], [entry | entries], count + 1, bytes + cost}}
        else
          {:halt, {records, entries, count, bytes}}
        end
      end)

    {Enum.reverse(records), Enum.reverse(entries), Enum.drop(ready, length(records))}
  end

  defp apply_result(state, active, {:ok, reply}) do
    receipts = Receipt.reconcile(reply, :local, active.id, active.entries)
    status = if map_size(receipts) == length(active.records), do: 1, else: 4
    apply_receipts(state, active.records, receipts, status)
  end

  defp apply_result(state, active, {:error, :unauthorized}),
    do: apply_receipts(state, active.records, %{}, 3)

  defp apply_result(state, active, _error), do: apply_receipts(state, active.records, %{}, 2)

  defp apply_receipts(state, records, receipts, status) do
    now = monotonic_ms()
    meters = state.handle.meters
    :atomics.put(meters, 5, status)

    queue =
      Enum.reduce(records, state.queue, fn record, queue ->
        result = receipts[record.id]

        case result do
          %{"status" => status} when status in ~w(stored duplicate) ->
            :atomics.put(meters, 4, System.system_time(:millisecond))
            :atomics.sub(meters, 1, @count_unit + record.size)
            queue

          %{"status" => status} when status in ~w(permanent_rejection identity_conflict) ->
            :atomics.add(meters, 3, 1)
            :atomics.sub(meters, 1, @count_unit + record.size)
            queue

          _ ->
            :queue.in(retry(record, result, status, now), queue)
        end
      end)

    %{state | active: nil, queue: queue}
  end

  defp retry(record, result, status, now) do
    delay = min(60_000, Integer.pow(2, min(record.attempts, 6)) * 1_000)

    offset =
      if status == 3 or (result && result["status"] == "unsupported_schema"), do: 60_000, else: 0

    hint = if result, do: result["retry_after_ms"] || 0, else: 0
    delay = max(max(offset, hint), min(60_000, delay + :rand.uniform(max(1, div(delay, 2))) - 1))
    %{record | attempts: record.attempts + 1, due: now + delay}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  defp positive(0), do: nil
  defp positive(time), do: time
  defp transport_state(0), do: :untried
  defp transport_state(1), do: :available
  defp transport_state(2), do: :unavailable
  defp transport_state(3), do: :unauthorized
  defp transport_state(4), do: :invalid_receipt
end
