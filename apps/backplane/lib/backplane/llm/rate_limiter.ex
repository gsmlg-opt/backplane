defmodule Backplane.LLM.RateLimiter do
  @moduledoc """
  ETS-based sliding window rate limiter, per LLM provider.

  Uses `:counters` for atomic increment operations. Each provider gets a
  60-second tumbling window tracked via an ETS entry.

  ## API

  - `check(provider_id, rpm_limit)` — `:ok` or `{:error, retry_after_seconds}`
  - `check(_, nil)` — always `:ok` (no limit configured)
  - `reset()` — clears all rate limiter state (useful for tests)
  - `expire(provider_id)` — resets a single provider's window (useful for tests)
  - `start_link/1` — start the GenServer that owns the ETS table
  """

  @table :llm_rate_limiter
  @window_ms 60_000

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc "Check rate limit for provider. Returns :ok or {:error, retry_after_seconds}."
  @spec check(binary(), integer() | nil) :: :ok | {:error, pos_integer()}
  def check(_provider_id, nil), do: :ok

  def check(provider_id, rpm_limit) when is_integer(rpm_limit) and rpm_limit > 0 do
    ensure_table()
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, provider_id) do
      [] ->
        # First request — create counter and record window start
        ref = :counters.new(1, [:atomics])
        :counters.add(ref, 1, 1)
        :ets.insert(@table, {provider_id, ref, now_ms})
        :ok

      [{^provider_id, ref, window_start}] ->
        elapsed_ms = now_ms - window_start

        if elapsed_ms > @window_ms do
          # Window expired — reset
          :counters.put(ref, 1, 1)
          :ets.insert(@table, {provider_id, ref, now_ms})
          :ok
        else
          current = :counters.get(ref, 1)

          if current < rpm_limit do
            :counters.add(ref, 1, 1)
            :ok
          else
            retry_after = ceil((@window_ms - elapsed_ms) / 1_000)
            {:error, max(retry_after, 1)}
          end
        end
    end
  end

  @doc "Clear all rate limiter state."
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Reset a single provider's window (for testing)."
  @spec expire(binary()) :: :ok
  def expire(provider_id) do
    ensure_table()
    :ets.delete(@table, provider_id)
    :ok
  end

  @doc "Start the RateLimiter GenServer (owns the ETS table)."
  def start_link(opts \\ []) do
    Backplane.LLM.RateLimiter.Server.start_link(opts)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    end
  rescue
    ArgumentError -> :ok
  end
end

defmodule Backplane.LLM.RateLimiter.Server do
  @moduledoc false

  use GenServer

  @table :llm_rate_limiter

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end
  rescue
    ArgumentError -> :ok
  end
end
