defmodule Backplane.HostAgent.Memory.RecallCache do
  @moduledoc """
  Bounded volatile cache for lifecycle context returned by the hub.

  The durable capture spool remains authoritative. This cache only supports a
  visibly stale fallback while the hub transport is unavailable.
  """

  use GenServer

  @default_max_entries 128
  @default_max_bytes 2 * 1024 * 1024
  @default_ttl_ms 15 * 60 * 1_000
  @entry_overhead_bytes 64

  def child_spec(opts) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec put(GenServer.server(), term(), map()) :: :ok
  def put(server, key, context), do: GenServer.call(server, {:put, key, context})

  @spec get(GenServer.server(), term()) :: {:ok, map()} | :miss
  def get(server, key), do: GenServer.call(server, {:get, key})

  @spec stats(GenServer.server()) :: %{entries: non_neg_integer(), bytes: non_neg_integer()}
  def stats(server), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    {:ok,
     %{
       entries: %{},
       bytes: 0,
       sequence: 0,
       max_entries: positive(opts[:max_entries], @default_max_entries),
       max_bytes: positive(opts[:max_bytes], @default_max_bytes),
       ttl_ms: positive(opts[:ttl_ms], @default_ttl_ms)
     }}
  end

  @impl true
  def handle_call({:put, key, context}, _from, state) when is_map(context) do
    now = now_ms()
    state = prune_expired(state, now)
    bytes = retained_bytes(key, context)
    state = remove_key(state, key)

    state =
      if bytes > state.max_bytes do
        state
      else
        sequence = state.sequence + 1

        entry = %{
          context: context,
          bytes: bytes,
          inserted_at_ms: now,
          expires_at_ms: now + effective_ttl_ms(context, state.ttl_ms),
          sequence: sequence
        }

        state
        |> Map.put(:sequence, sequence)
        |> Map.update!(:entries, &Map.put(&1, key, entry))
        |> Map.update!(:bytes, &(&1 + bytes))
        |> enforce_bounds()
      end

    {:reply, :ok, state}
  end

  def handle_call({:put, _key, _context}, _from, state), do: {:reply, :ok, state}

  def handle_call({:get, key}, _from, state) do
    now = now_ms()
    state = prune_expired(state, now)

    case Map.fetch(state.entries, key) do
      {:ok, entry} ->
        age_seconds = max(div(now - entry.inserted_at_ms, 1_000), 0)
        {:reply, {:ok, %{context: entry.context, age_seconds: age_seconds}}, state}

      :error ->
        {:reply, :miss, state}
    end
  end

  def handle_call(:stats, _from, state) do
    state = prune_expired(state, now_ms())
    {:reply, %{entries: map_size(state.entries), bytes: state.bytes}, state}
  end

  defp enforce_bounds(state) do
    if map_size(state.entries) <= state.max_entries and state.bytes <= state.max_bytes do
      state
    else
      {oldest_key, _entry} = Enum.min_by(state.entries, fn {_key, entry} -> entry.sequence end)
      state |> remove_key(oldest_key) |> enforce_bounds()
    end
  end

  defp prune_expired(state, now) do
    Enum.reduce(state.entries, state, fn {key, entry}, acc ->
      if entry.expires_at_ms <= now, do: remove_key(acc, key), else: acc
    end)
  end

  defp remove_key(state, key) do
    case Map.pop(state.entries, key) do
      {nil, _entries} -> state
      {entry, entries} -> %{state | entries: entries, bytes: state.bytes - entry.bytes}
    end
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp retained_bytes(key, context) do
    byte_size(:erlang.term_to_binary({key, context})) + @entry_overhead_bytes
  end

  defp effective_ttl_ms(context, configured_ttl_ms) do
    with expires_at when is_binary(expires_at) <- Map.get(context, "expires_at"),
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(expires_at) do
      remaining = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
      min(max(remaining, 0), configured_ttl_ms)
    else
      _ -> configured_ttl_ms
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
