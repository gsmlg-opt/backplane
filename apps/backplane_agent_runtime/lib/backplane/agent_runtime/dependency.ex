defmodule Backplane.AgentRuntime.Dependency do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Peer run dependency waits and cycle/held-context rejection.

  A waiter holds no execution slot. Held-context dependencies are rejected when
  no safe release is defined, and cycles cannot create deadlocks.
  """

  @type t :: map()

  @spec new(non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def new(max_waits) when is_integer(max_waits) and max_waits >= 0 do
    {:ok, %{max_waits: max_waits, waits: [], results: %{}}}
  end

  @spec wait(t(), String.t(), String.t(), map()) ::
          {:ok, t(), %{status: :waiting}} | {:error, Error.t()}
  def wait(deps, waiter, target, held_contexts \\ %{}) do
    with {:ok, _} <- validate_wait(deps, waiter, target, held_contexts),
         {:ok, deps} <- reject_cycle(deps, waiter, target) do
      {:ok, %{deps | waits: deps.waits ++ [%{waiter: waiter, target: target}]},
       %{status: :waiting}}
    end
  end

  @spec resolve(t(), String.t(), map()) :: {:ok, t(), map()} | {:error, Error.t()}
  def resolve(deps, target, result) when is_map(deps) and is_binary(target) do
    waiters = Enum.filter(deps.waits, &(&1.target == target))

    if waiters == [] do
      {:error, Error.new(:not_found, "no waiter for target", details: %{target: target})}
    else
      results = Map.put(deps.results, target, result)
      waits = Enum.reject(deps.waits, &(&1.target == target))

      {:ok, %{deps | results: results, waits: waits},
       %{status: :resolved, target: target, waiters: Enum.map(waiters, & &1.waiter)}}
    end
  end

  defp validate_wait(%{max_waits: _max_waits} = deps, waiter, target, held_contexts)
       when is_integer(deps.max_waits) and length(deps.waits) < deps.max_waits do
    if waiter == target do
      {:error, Error.new(:validation, "waiter cannot wait on itself")}
    else
      validate_held_context(deps, waiter, target, held_contexts)
    end
  end

  defp validate_wait(_deps, _waiter, _target, _held_contexts) do
    {:error, Error.new(:overloaded, "dependency wait limit exceeded")}
  end

  defp validate_held_context(_deps, waiter, target, held_contexts) do
    if held_contexts[waiter] == target do
      {:error, Error.new(:validation, "wait would deadlock held context")}
    else
      {:ok, target}
    end
  end

  defp reject_cycle(deps, waiter, target) do
    if Enum.any?(deps.waits, &(&1.waiter == target and &1.target == waiter)) do
      {:error, Error.new(:validation, "dependency cycle rejected")}
    else
      {:ok, deps}
    end
  end
end
