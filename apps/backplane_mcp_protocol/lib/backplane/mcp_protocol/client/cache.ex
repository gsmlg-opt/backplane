defmodule Backplane.McpProtocol.Client.Cache do
  @moduledoc false

  use Backplane.McpProtocol.Logging

  alias Backplane.McpProtocol.Client.JSONSchemaConverter
  alias Backplane.McpProtocol.Protocol

  @tool_validators_key {__MODULE__, :tool_validators}

  # Public API

  @doc """
  Stores tool output validators in the cache.
  Clears existing validators before storing new ones.
  """
  @spec put_tool_validators(client_name :: String.t(), tools :: list(map())) :: :ok
  def put_tool_validators(client, tools) when is_binary(client) and is_list(tools) do
    store_tool_validators(client, tools, &JSONSchemaConverter.validator/1)
  end

  @doc """
  Stores tool output validators using the schema profile for the negotiated
  protocol version.
  """
  @spec put_tool_validators(
          client_name :: String.t(),
          tools :: list(map()),
          protocol_version :: Protocol.version()
        ) :: :ok
  def put_tool_validators(client, tools, protocol_version)
      when is_binary(client) and is_list(tools) and is_binary(protocol_version) do
    store_tool_validators(client, tools, validator_builder(protocol_version))
  end

  @doc false
  @spec compile_tool_validators(
          client_name :: String.t(),
          tools :: list(map()),
          protocol_version :: Protocol.version()
        ) :: list({String.t(), JSONSchemaConverter.validator()})
  def compile_tool_validators(client, tools, protocol_version)
      when is_binary(client) and is_list(tools) and is_binary(protocol_version) do
    build_tool_validators(client, tools, validator_builder(protocol_version))
  end

  @doc false
  @spec replace_tool_validators(
          client_name :: String.t(),
          list({String.t(), JSONSchemaConverter.validator()})
        ) :: :ok
  def replace_tool_validators(client, validators)
      when is_binary(client) and is_list(validators) do
    table = ensure_table(client)
    :ets.delete_all_objects(table)
    :ets.insert(table, validators)
    :ok
  end

  defp store_tool_validators(client, tools, validator_builder) do
    validators = build_tool_validators(client, tools, validator_builder)
    replace_tool_validators(client, validators)
  end

  defp build_tool_validators(client, tools, validator_builder) do
    tools
    |> Enum.filter(& &1["outputSchema"])
    |> Enum.flat_map(&fetch_tool_validator(client, &1, validator_builder))
  end

  defp validator_builder(protocol_version) do
    if Protocol.modern?(protocol_version) do
      &JSONSchemaConverter.validator_2020_12/1
    else
      &JSONSchemaConverter.validator/1
    end
  end

  defp fetch_tool_validator(
         client,
         %{"outputSchema" => schema, "name" => name},
         validator_builder
       )
       when is_map(schema) do
    case validator_builder.(schema) do
      {:ok, validator} ->
        [{name, validator}]

      {status, reason} when status in [:unsupported, :error] ->
        Logging.client_event("schema_validation_disabled", %{
          client: client,
          tool: name,
          reason: reason
        })

        []
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
