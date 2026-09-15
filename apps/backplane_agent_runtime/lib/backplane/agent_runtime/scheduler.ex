defmodule Backplane.AgentRuntime.Scheduler do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Bounded work admission with explicit overload.

  A scheduler is immutable data. It does not spawn processes or own execution.
  Host adapters use it to separate bounded execution slots from waiting
  continuations.
  """

  @type t :: map()

  @spec new(non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def new(limit) when is_integer(limit) and limit >= 0 do
    {:ok, %{limit: limit, active: %{}, order: [], continuations: []}}
  end

  @spec admit(t(), term(), term()) ::
          {:ok, t(), %{status: :admitted | :queued}} | {:error, Error.t()}
  def admit(scheduler, worker_id, continuation \\ nil)
      when is_binary(worker_id) and (continuation == nil or is_map(continuation)) do
    cond do
      Map.has_key?(scheduler.active, worker_id) ->
        {:error,
         Error.new(:resource_conflict, "worker already active", details: %{worker: worker_id})}

      map_size(scheduler.active) < scheduler.limit ->
        order = scheduler.order ++ [worker_id]

        {:ok,
         %{scheduler | active: Map.put(scheduler.active, worker_id, continuation), order: order},
         %{status: :admitted}}

      continuation != nil and length(scheduler.continuations) < scheduler.limit ->
        {:ok, %{scheduler | continuations: scheduler.continuations ++ [continuation]},
         %{status: :queued}}

      continuation != nil ->
        {:error, Error.new(:overloaded, "continuation queue is full")}

      true ->
        {:error, Error.new(:overloaded, "worker slots are full")}
    end
  end

  @spec release(t(), term()) :: {:ok, t()} | {:error, Error.t()}
  def release(scheduler, worker_id) when is_binary(worker_id) do
    if Map.has_key?(scheduler.active, worker_id) do
      {:ok,
       %{
         scheduler
         | active: Map.delete(scheduler.active, worker_id),
           order: Enum.reject(scheduler.order, &(&1 == worker_id))
       }}
    else
      {:error, Error.new(:not_found, "worker is not active", details: %{worker: worker_id})}
    end
  end

  @spec promote(t(), term()) :: {:ok, t()} | {:error, Error.t()}
  def promote(scheduler, worker_id) when is_binary(worker_id) do
    if map_size(scheduler.active) < scheduler.limit and scheduler.continuations != [] do
      [continuation | continuations] = scheduler.continuations

      {:ok,
       %{
         scheduler
         | active: Map.put(scheduler.active, worker_id, continuation),
           order: scheduler.order ++ [worker_id],
           continuations: continuations
       }}
    else
      {:error, Error.new(:resource_conflict, "no continuation is ready to promote")}
    end
  end
end
