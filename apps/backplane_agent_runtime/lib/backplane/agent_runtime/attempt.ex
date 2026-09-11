defmodule Backplane.AgentRuntime.Attempt do
  alias Backplane.AgentRuntime.ID

  @moduledoc """
  Attempt identity and bounded retry accounting.

  Retries preserve the step identity and increment the attempt number. A new
  attempt cannot bypass a failed attempt's remaining retry envelope.
  """

  @type t :: map()

  @spec new(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | {:error, Backplane.AgentRuntime.Error.t()}
  def new(step_id, task_id, max_retries, current_number \\ 0) do
    with {:ok, step_id} <- validate_id(step_id, "step"),
         {:ok, task_id} <- validate_id(task_id, "task"),
         {:ok, max_retries} <- validate_max_retries(max_retries),
         {:ok, current_number} <- validate_number(current_number) do
      {:ok,
       %{
         attempt_id: ID.new("attempt"),
         step_id: step_id,
         task_id: task_id,
         number: current_number,
         max_retries: max_retries,
         status: :started,
         error: nil
       }}
    end
  end

  @spec retry(t(), term(), non_neg_integer()) ::
          {:ok, t(), map()} | {:error, Backplane.AgentRuntime.Error.t()}
  def retry(attempt, error, now) when is_integer(now) do
    if attempt.number >= attempt.max_retries do
      {:error,
       Backplane.AgentRuntime.Error.new(:timeout, "attempt retry limit exceeded",
         details: %{number: attempt.number, max_retries: attempt.max_retries}
       )}
    else
      {:ok,
       %{
         attempt
         | number: attempt.number + 1,
           status: :retrying,
           error: normalize_error(error)
       }, %{scheduled_for: now + 1}}
    end
  end

  defp validate_id(value, _kind) when is_binary(value) and value != "", do: {:ok, value}

  defp validate_id(_, kind),
    do: {:error, Backplane.AgentRuntime.Error.new(:validation, "#{kind} id is required")}

  defp validate_max_retries(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp validate_max_retries(_),
    do:
      {:error, Backplane.AgentRuntime.Error.new(:validation, "max_retries must be non-negative")}

  defp validate_number(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp validate_number(_),
    do:
      {:error,
       Backplane.AgentRuntime.Error.new(:validation, "attempt number must be non-negative")}

  defp normalize_error(%Backplane.AgentRuntime.Error{} = error), do: error

  defp normalize_error(error),
    do: Backplane.AgentRuntime.Error.new(:execution_failure, "attempt failed", cause: error)
end
