defmodule Backplane.AgentRuntime.LoopBreaker do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Normalized fingerprints for repeated model/tool/delegation work.

  Only semantically significant fields are fingerprinted. Superficial argument
  changes cannot reset the limit, and unknown fingerprint identity is explicit.
  """

  @type t :: map()

  @spec new(non_neg_integer()) :: {:ok, t()} | {:error, Backplane.AgentRuntime.Error.t()}
  def new(limit) when is_integer(limit) and limit >= 0 do
    {:ok, %{limit: limit, fingerprints: %{}}}
  end

  @spec record(t(), String.t(), map(), map()) ::
          {:ok, t(), %{status: :recorded | :duplicate, count: pos_integer()}}
          | {:error, Error.t()}
  def record(loop_breaker, identity, significant, superficial \\ %{})
      when is_binary(identity) and is_map(significant) and is_map(superficial) do
    fingerprint = fingerprint(significant)
    existing = Map.get(loop_breaker.fingerprints, fingerprint)

    case existing do
      %{count: count} = entry when count < loop_breaker.limit ->
        fingerprints =
          Map.put(loop_breaker.fingerprints, fingerprint, %{
            entry
            | count: count + 1,
              identity: identity
          })

        {:ok, %{loop_breaker | fingerprints: fingerprints},
         %{status: :duplicate, count: count + 1, fingerprint: fingerprint}}

      %{count: count} when count >= loop_breaker.limit ->
        {:error,
         Backplane.AgentRuntime.Error.new(:budget_exceeded, "hard loop limit exceeded",
           details: %{count: count, limit: loop_breaker.limit}
         )}

      nil ->
        fingerprints =
          Map.put(loop_breaker.fingerprints, fingerprint, %{count: 1, identity: identity})

        {:ok, %{loop_breaker | fingerprints: fingerprints},
         %{status: :recorded, count: 1, fingerprint: fingerprint}}
    end
  end

  defp fingerprint(significant) do
    normalized =
      :crypto.hash(:sha256, :erlang.term_to_binary(significant))
      |> Base.encode16()

    {normalized, Map.keys(significant)}
  end
end
