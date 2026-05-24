defmodule Backplane.Cache do
  @moduledoc """
  ETS-backed cache with per-key TTL, periodic sweep, and stats tracking.

  GenServer owns the ETS table and handles writes/invalidation.
  Reads bypass the GenServer via public ETS for maximum throughput.
  """

  use GenServer

  require Logger

  @table :backplane_response_cache
  @expiry_table :backplane_cache_expiry
  @stats_table :backplane_cache_stats
  @default_sweep_interval 60_000
  @default_max_entries 10_000

  # --- Public API (reads bypass GenServer) ---

  @type cache_key :: term()
  @type ttl_ms :: pos_integer()

  @spec get(cache_key()) :: {:ok, term()} | :miss
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          bump_stat(:hits)
          {:ok, value}
        else
          # Expired — treat as miss, lazy delete
          :ets.delete(@table, key)
          bump_stat(:misses)
          :miss
        end

      [] ->
        bump_stat(:misses)
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @spec put(cache_key(), term(), ttl_ms()) :: :ok
  def put(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    GenServer.cast(__MODULE__, {:put, key, value, ttl_ms})
  end

  @spec invalidate(cache_key()) :: :ok
  def invalidate(key) do
    GenServer.cast(__MODULE__, {:invalidate, key})
  end

  @spec invalidate_prefix(term()) :: non_neg_integer()
  def invalidate_prefix(prefix) do
    GenServer.call(__MODULE__, {:invalidate_prefix, prefix})
  end

  @spec flush() :: non_neg_integer()
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @spec stats() :: %{hits: integer(), misses: integer(), size: integer(), evictions: integer()}
  def stats do
    hits = read_stat(:hits)
    misses = read_stat(:misses)
    evictions = read_stat(:evictions)
    size = safe_ets_size(@table)

    %{
      hits: hits,
      misses: misses,
      size: size,
      evictions: evictions,
      hit_rate: if(hits + misses > 0, do: Float.round(hits / (hits + misses), 3), else: 0.0)
    }
  end

  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:backplane, :cache_enabled, true)
  end

  # --- GenServer ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    ensure_table(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    ensure_table(@expiry_table, [:named_table, :ordered_set, :public, write_concurrency: true])

    ensure_table(@stats_table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.insert(@stats_table, {:hits, 0})
    :ets.insert(@stats_table, {:misses, 0})
    :ets.insert(@stats_table, {:evictions, 0})

    sweep_interval = Keyword.get(opts, :sweep_interval, @default_sweep_interval)
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)

    schedule_sweep(sweep_interval)

    {:ok, %{sweep_interval: sweep_interval, max_entries: max_entries}}
  end

  @impl true
  def handle_cast({:put, key, value, ttl_ms}, state) do
    now = System.monotonic_time(:millisecond)
    expires_at = now + ttl_ms

    # Remove old expiry entry if key already exists
    case :ets.lookup(@table, key) do
      [{^key, _old_val, old_expires}] -> :ets.delete(@expiry_table, {old_expires, key})
      [] -> :ok
    end

    # Enforce max_entries — evict oldest if at capacity
    current_size = :ets.info(@table, :size)

    if current_size >= state.max_entries do
      evict_oldest()
    end

    :ets.insert(@table, {key, value, expires_at})
    :ets.insert(@expiry_table, {{expires_at, key}})
    {:noreply, state}
  end

  def handle_cast({:invalidate, key}, state) do
    case :ets.lookup(@table, key) do
      [{^key, _val, expires_at}] -> :ets.delete(@expiry_table, {expires_at, key})
      [] -> :ok
    end

    :ets.delete(@table, key)
    {:noreply, state}
  end

  @impl true
  def handle_call({:invalidate_prefix, prefix}, _from, state) do
    count = invalidate_matching(prefix)
    {:reply, count, state}
  end

  def handle_call(:flush, _from, state) do
    count = :ets.info(@table, :size)
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@expiry_table)
    bump_stat(:evictions, count)
    {:reply, count, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    swept = sweep_expired()

    if swept > 0 do
      Logger.debug("Cache sweep: evicted #{swept} expired entries")
    end

    schedule_sweep(state.sweep_interval)
    {:noreply, state}
  end

  # --- Internal ---

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end

  defp sweep_expired do
    now = System.monotonic_time(:millisecond)
    count = sweep_expiry_index(now, 0)
    if count > 0, do: bump_stat(:evictions, count)
    count
  end

  defp sweep_expiry_index(now, count) do
    case :ets.first(@expiry_table) do
      :"$end_of_table" ->
        count

      {expires_at, key} = entry when expires_at <= now ->
        :ets.delete(@table, key)
        :ets.delete(@expiry_table, entry)
        sweep_expiry_index(now, count + 1)

      _ ->
        count
    end
  end

  defp evict_oldest do
    case :ets.first(@expiry_table) do
      :"$end_of_table" ->
        :ok

      {_expires_at, key} = entry ->
        :ets.delete(@table, key)
        :ets.delete(@expiry_table, entry)
        bump_stat(:evictions)
    end
  end

  defp invalidate_matching(prefix) do
    entries_to_delete =
      :ets.foldl(
        fn {key, _value, expires_at}, acc ->
          if key_matches_prefix?(key, prefix), do: [{key, expires_at} | acc], else: acc
        end,
        [],
        @table
      )

    for {key, expires_at} <- entries_to_delete do
      :ets.delete(@table, key)
      :ets.delete(@expiry_table, {expires_at, key})
    end

    count = length(entries_to_delete)
    if count > 0, do: bump_stat(:evictions, count)
    count
  end

  defp key_matches_prefix?(key, prefix) when is_tuple(key) and is_tuple(prefix) do
    prefix_list = Tuple.to_list(prefix)
    key_list = Tuple.to_list(key)

    prefix_size = length(prefix_list)
    key_size = length(key_list)

    key_size >= prefix_size and Enum.take(key_list, prefix_size) == prefix_list
  end

  defp key_matches_prefix?(_key, _prefix), do: false

  defp bump_stat(stat, amount \\ 1) do
    :ets.update_counter(@stats_table, stat, amount)
  rescue
    ArgumentError -> :ok
  end

  defp read_stat(stat) do
    case :ets.lookup(@stats_table, stat) do
      [{^stat, value}] -> value
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp safe_ets_size(table) do
    :ets.info(table, :size)
  rescue
    ArgumentError -> 0
  end

  defp ensure_table(name, opts) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, opts)
      _ref -> name
    end
  end
end
