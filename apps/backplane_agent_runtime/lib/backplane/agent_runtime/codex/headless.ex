defmodule Backplane.AgentRuntime.Codex.Headless do
  @moduledoc """
  One host-authored Code Mode occurrence owned by the existing Conversation.

  `execute/3` fixes its caller as the lifetime owner. Observers may await or inspect
  without transferring ownership. A timeout does not cancel or replay execution.
  Restored runs are inspection-only; unfinished runs require host reconciliation.
  """
  alias Backplane.AgentRuntime.{Conversation, Error}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  def start_link(opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :provider) or Keyword.has_key?(opts, :provider_context) ->
        {:error, Error.new(:validation, "headless execution does not accept a provider")}

      Keyword.has_key?(opts, :run) and
          get_in(Keyword.fetch!(opts, :run), [:context, :execution_mode]) != :headless ->
        {:error, Error.new(:validation, "restored run is not a headless occurrence")}

      true ->
        Conversation.start_link(Keyword.put(opts, :execution_mode, :headless))
    end
  end

  def execute(pid, source, opts \\ []) do
    with true <- is_binary(source) and byte_size(source) in 1..131_072 and String.valid?(source),
         true <- is_list(opts) and Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 == :input)),
         {:ok, input} <- Evidence.public(Keyword.get(opts, :input)),
         true <- byte_size(JSON.encode!(input)) <= 1_048_576 do
      GenServer.call(pid, {:headless_execute, source, input}, :infinity)
    else
      _ -> {:error, Error.new(:validation, "headless source or input exceeds its JSON contract")}
    end
  end

  def await(pid, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    if is_integer(timeout) and timeout >= 0,
      do: await_until(pid, System.monotonic_time(:millisecond) + timeout),
      else: {:error, Error.new(:validation, "await timeout must be finite and nonnegative")}
  end

  def status(pid), do: Conversation.status(pid)
  def cancel(pid), do: Conversation.cancel(pid)

  defp await_until(pid, deadline) do
    state = status(pid)

    cond do
      state.phase == :terminal and state.run.state == :completed ->
        case get_in(state.run, [:context, :conversation, :headless_result]) do
          nil ->
            {:error,
             state.error ||
               Error.new(:unknown_outcome, "headless run stopped without a committed result")}

          result ->
            {:ok, result}
        end

      state.phase in [:terminal, :storage_failed, :recovery_required] ->
        {:error,
         state.error || Error.new(:unknown_outcome, "headless run requires host reconciliation")}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, Error.new(:timeout, "headless await timed out")}

      true ->
        receive do
        after
          min(10, max(0, deadline - System.monotonic_time(:millisecond))) ->
            await_until(pid, deadline)
        end
    end
  end
end
