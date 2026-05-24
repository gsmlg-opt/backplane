defmodule BackplaneMemory.Embedding.CircuitBreaker do
  @moduledoc "ETS-backed circuit breaker for the embedding client."

  @table :memory_embedding_circuit
  @max_failures 5
  @half_open_after_ms 30_000
  @close_after_successes 2

  @doc "Returns the current circuit state: :closed | :open | :half_open"
  def state do
    ensure_table()

    case :ets.lookup(@table, :state) do
      [{:state, :open, _failures, last_failure_at, _successes}] ->
        if elapsed_ms(last_failure_at) >= @half_open_after_ms, do: :half_open, else: :open

      [{:state, circuit_state, _failures, _last_failure_at, _successes}] ->
        circuit_state

      [] ->
        :closed
    end
  end

  @doc "Returns true if a request should be allowed through."
  def allow_request? do
    case state() do
      :closed -> true
      :open -> false
      :half_open -> true
    end
  end

  @doc "Call after a successful embed."
  def record_success do
    ensure_table()

    case :ets.lookup(@table, :state) do
      [{:state, :half_open, failures, last_failure_at, successes}] ->
        new_successes = successes + 1

        if new_successes >= @close_after_successes do
          :ets.insert(@table, {:state, :closed, 0, nil, 0})
        else
          :ets.insert(@table, {:state, :half_open, failures, last_failure_at, new_successes})
        end

      _ ->
        :ok
    end
  end

  @doc "Call after a failed embed."
  def record_failure do
    ensure_table()

    case :ets.lookup(@table, :state) do
      [{:state, _circuit_state, failures, _last_failure_at, _successes}] ->
        new_failures = failures + 1

        if new_failures >= @max_failures do
          :ets.insert(@table, {:state, :open, new_failures, DateTime.utc_now(), 0})
        else
          :ets.insert(@table, {:state, :closed, new_failures, DateTime.utc_now(), 0})
        end

      [] ->
        :ets.insert(@table, {:state, :closed, 1, DateTime.utc_now(), 0})
    end
  end

  @doc "Reset circuit breaker to closed state."
  def reset do
    ensure_table()
    :ets.insert(@table, {:state, :closed, 0, nil, 0})
  end

  defp ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
      :ets.insert(@table, {:state, :closed, 0, nil, 0})
    end
  end

  defp elapsed_ms(nil), do: 0

  defp elapsed_ms(last_failure_at) do
    DateTime.diff(DateTime.utc_now(), last_failure_at, :millisecond)
  end
end
