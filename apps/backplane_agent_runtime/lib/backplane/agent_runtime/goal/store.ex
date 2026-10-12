defmodule Backplane.AgentRuntime.Goal.Store do
  @moduledoc "Host-owned durable thread records; CAS atomically stores goals and receipt fences."
  alias Backplane.AgentRuntime.Error
  @callback load(term(), binary()) :: {:ok, map()} | {:error, Error.t()}
  @callback compare_and_swap(term(), binary(), non_neg_integer(), binary() | nil, map()) ::
              {:ok, map()} | {:error, Error.t()}

  def load(impl, context, thread_id) do
    with {:ok, record} <- invoke(impl, :load, [context, thread_id]), :ok <- validate(record) do
      {:ok, record}
    end
  end

  def compare_and_swap(impl, context, thread, revision, goal_id, next) do
    with :ok <- validate(next),
         {:ok, record} <-
           invoke(impl, :compare_and_swap, [context, thread, revision, goal_id, next]),
         :ok <- validate(record) do
      if record.revision == revision + 1 and
           Map.delete(record, :revision) == Map.delete(next, :revision),
         do: {:ok, record},
         else: {:error, Error.new(:malformed_result, "invalid goal CAS acknowledgement")}
    end
  end

  defp invoke(impl, function, args) do
    case apply(impl, function, args) do
      {:ok, record} when is_map(record) -> {:ok, record}
      {:error, %Error{}} = error -> error
      _ -> {:error, Error.new(:malformed_result, "invalid goal store response")}
    end
  rescue
    _ -> {:error, Error.new(:execution_failure, "goal store unavailable")}
  catch
    :exit, _ -> {:error, Error.new(:execution_failure, "goal store unavailable")}
  end

  defp validate(
         %{revision: revision, goal: goal, receipts: receipts, continuation_deferral: _} = record
       )
       when is_integer(revision) and revision >= 0 and (is_map(goal) or is_nil(goal)) and
              is_map(receipts) do
    if serializable?(record),
      do: :ok,
      else: {:error, Error.new(:validation, "goal record contains live capabilities")}
  end

  defp validate(_), do: {:error, Error.new(:malformed_result, "invalid goal record")}

  defp serializable?(value)
       when is_pid(value) or is_reference(value) or is_function(value) or is_port(value),
       do: false

  defp serializable?(value) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> serializable?(k) and serializable?(v) end)

  defp serializable?(value) when is_list(value), do: Enum.all?(value, &serializable?/1)

  defp serializable?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.all?(&serializable?/1)

  defp serializable?(_), do: true
end
