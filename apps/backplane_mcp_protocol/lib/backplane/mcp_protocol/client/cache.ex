defmodule Backplane.McpProtocol.Client.Cache do
  @moduledoc false

  alias Backplane.McpProtocol.Client.JSONSchemaConverter

  @tool_validators_key {__MODULE__, :tool_validators}

  # Public API

  @doc """
  Stores tool output validators in the cache.
  Clears existing validators before storing new ones.
  """
  @spec put_tool_validators(client_name :: String.t(), tools :: list(map())) :: :ok
  def put_tool_validators(client, tools) when is_binary(client) and is_list(tools) do
    table = ensure_table(client)
    :ets.delete_all_objects(table)

    tools
    |> Enum.filter(& &1["outputSchema"])
    |> Enum.flat_map(&fetch_tool_validator/1)
    |> then(&:ets.insert(table, &1))

    :ok
  end

  defp fetch_tool_validator(%{"outputSchema" => s, "name" => name}) when is_map(s) do
    case JSONSchemaConverter.validator(s) do
      {:ok, validator} -> [{name, validator}]
      {:error, _errors} -> []
    end
  end

  @doc """
  Gets a tool output validator from the cache.
  """
  @spec get_tool_validator(client_name :: String.t(), tool_name :: String.t()) ::
          JSONSchemaConverter.validator() | nil
  def get_tool_validator(client, tool_name) when is_binary(client) and is_binary(tool_name) do
    table = ensure_table(client)

    case :ets.lookup(table, tool_name) do
      [{^tool_name, validator}] -> validator
      [] -> nil
    end
  end

  @doc """
  Clears all tool validators from the cache.
  """
  @spec clear_tool_validators(client_name :: String.t()) :: :ok
  def clear_tool_validators(client) when is_binary(client) do
    case table(client) do
      nil -> :ok
      table -> :ets.delete_all_objects(table)
    end

    :ok
  end

  @doc """
  Cleans up all cache tables for a client process.
  Should be called when the client process terminates.
  """
  @spec cleanup(client_name :: String.t()) :: :ok
  def cleanup(client) when is_binary(client) do
    case Process.delete(tool_validators_key(client)) do
      nil -> :ok
      table -> :ets.delete(table)
    end

    :ok
  end

  # Private helpers

  @spec ensure_table(client_name :: String.t()) :: :ets.tid()
  defp ensure_table(client) do
    case table(client) do
      nil ->
        table = :ets.new(:tool_validators, [:private, :set, read_concurrency: true])
        Process.put(tool_validators_key(client), table)
        table

      table ->
        table
    end
  end

  defp table(client), do: Process.get(tool_validators_key(client))

  defp tool_validators_key(client), do: {@tool_validators_key, client}
end
