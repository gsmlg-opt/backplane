defmodule Backplane.AgentRuntime.Codex.Readiness do
  @moduledoc """
  Host-provided readiness and authorization gate with cancellable waits.
  """

  alias Backplane.AgentRuntime.Error

  @spec ready?(map()) :: boolean()
  def ready?(state), do: Map.get(state, :ready, false) and Map.get(state, :authorized, false)

  @spec execute_if_ready(map(), (-> term())) :: {:ok, term()} | {:error, Error.t()}
  def execute_if_ready(state, fun) when is_map(state) and is_function(fun, 0) do
    if ready?(state),
      do: {:ok, fun.()},
      else: {:error, Error.new(:forbidden, "environment is not ready or authorized")}
  end

  @spec await((-> map()), non_neg_integer(), (-> boolean())) :: {:ok, map()} | {:error, Error.t()}
  def await(provider, timeout_ms, cancelled \\ fn -> false end)
      when is_function(provider, 0) and is_integer(timeout_ms) and timeout_ms >= 0 and
             is_function(cancelled, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(provider, cancelled, deadline)
  end

  defp do_await(provider, cancelled, deadline) do
    cond do
      cancelled.() ->
        {:error, Error.new(:cancelled, "readiness wait cancelled")}

      ready?(state = provider.()) ->
        {:ok, state}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, Error.new(:timeout, "environment readiness timed out")}

      true ->
        Process.sleep(min(10, max(deadline - System.monotonic_time(:millisecond), 1)))
        do_await(provider, cancelled, deadline)
    end
  end
end
