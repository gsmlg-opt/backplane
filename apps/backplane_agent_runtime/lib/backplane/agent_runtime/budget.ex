defmodule Backplane.AgentRuntime.Budget do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Finite root budgets and idempotent work reservations.

  Reservations are replay-safe, cannot exceed a fixed quota, and do not claim
  provider billing exactness.
  """

  @type t :: map()

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(config) when is_map(config) do
    with {:ok, quota} <- quota(config) do
      {:ok,
       %{
         root_run_id: Map.get(config, :root_run_id),
         quota: quota,
         used: 0,
         reservations: %{}
       }}
    end
  end

  def new(_config), do: {:error, Error.new(:validation, "budget config must be a map")}

  @spec reserve(t(), String.t(), non_neg_integer()) :: {:ok, t(), map()} | {:error, Error.t()}
  def reserve(budget, reservation_id, amount \\ 1)

  def reserve(budget, reservation_id, amount)
      when is_binary(reservation_id) and is_integer(amount) and amount > 0 do
    case Map.get(budget.reservations, reservation_id) do
      %{amount: ^amount} ->
        {:ok, budget, %{status: :reserved, reservation_id: reservation_id, amount: amount}}

      nil ->
        if budget.used + amount > budget.quota do
          {:error,
           Error.new(:budget_exceeded, "budget quota exceeded",
             details: %{used: budget.used, requested: amount, quota: budget.quota}
           )}
        else
          reservations = Map.put(budget.reservations, reservation_id, %{amount: amount})

          {:ok, %{budget | used: budget.used + amount, reservations: reservations},
           %{status: :reserved, reservation_id: reservation_id, amount: amount}}
        end

      %{amount: existing} ->
        {:error,
         Error.new(:resource_conflict, "reservation id already used with a different amount",
           details: %{existing: existing, requested: amount}
         )}
    end
  end

  @spec release(t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def release(budget, reservation_id) when is_binary(reservation_id) do
    case Map.pop(budget.reservations, reservation_id) do
      {nil, _reservations} ->
        {:error, Error.new(:not_found, "reservation not found")}

      {%{amount: amount}, reservations} ->
        {:ok, %{budget | used: budget.used - amount, reservations: reservations}}
    end
  end

  defp quota(%{work: quota}) when is_integer(quota) and quota > 0, do: {:ok, quota}

  defp quota(_config) do
    {:error, Error.new(:validation, "budget quota must be a positive integer")}
  end
end
