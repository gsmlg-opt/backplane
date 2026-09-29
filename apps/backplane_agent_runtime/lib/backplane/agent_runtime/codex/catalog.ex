defmodule Backplane.AgentRuntime.Codex.Catalog do
  alias Backplane.AgentRuntime.{Error, ToolCatalog, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.Contract

  @moduledoc """
  Codex projection over the existing strict runtime catalog.
  """

  @spec admit([map()], map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def admit(contracts, authority \\ %{}, opts \\ [])
      when is_list(contracts) and is_map(authority) do
    with {:ok, contracts} <- normalize_contracts(contracts),
         :ok <- ensure_unique_names(contracts),
         {:ok, bundle} <-
           ToolCatalog.admit_batch(
             Enum.map(contracts, &Contract.descriptor/1),
             Keyword.merge(opts, authority: authority)
           ) do
      by_name = Map.new(contracts, &{&1.tool_name, &1})
      admitted = Enum.map(bundle.accepted, &Map.fetch!(by_name, &1))

      {:ok,
       %{
         registry: bundle.registry,
         authority: bundle.authority,
         accepted: admitted,
         rejected: bundle.rejected,
         tools: bundle.tools,
         contracts: Map.new(admitted, &{&1.tool_name, &1})
       }}
    end
  end

  @spec register(ToolRegistry.t(), Contract.t()) :: {:ok, ToolRegistry.t()} | {:error, Error.t()}
  def register(%ToolRegistry{} = registry, contract) do
    ToolRegistry.register(registry, Contract.descriptor(contract))
  end

  defp normalize_contracts(contracts) do
    Enum.reduce_while(contracts, {:ok, []}, fn
      %{} = contract, {:ok, acc} ->
        case Contract.new(contract) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      contract, _ ->
        {:halt,
         {:error,
          Error.new(:validation, "Codex contract must be a map", details: %{received: contract})}}
    end)
    |> case do
      {:ok, contracts} -> {:ok, Enum.reverse(contracts)}
      error -> error
    end
  end

  defp ensure_unique_names(contracts) do
    names = Enum.map(contracts, & &1.tool_name)

    if length(names) == length(Enum.uniq(names)),
      do: :ok,
      else: {:error, Error.new(:validation, "Codex catalog contains duplicate canonical names")}
  end
end
