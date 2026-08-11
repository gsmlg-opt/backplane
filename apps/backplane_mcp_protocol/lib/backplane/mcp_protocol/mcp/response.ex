defmodule Backplane.McpProtocol.MCP.Response do
  @moduledoc """
  Represents successful responses in the MCP protocol.

  This module provides a wrapper around JSON-RPC responses, handling
  domain-specific error semantics for MCP's "isError" field in results.

  ## Response Structure

  Each response includes:
  - `result`: The response data from the server
  - `id`: The request ID this response is associated with
  - `is_error`: Boolean flag indicating if this is a domain-level error

  ## Domain vs. Protocol Errors

  The MCP protocol distinguishes between two types of errors:

  1. Protocol errors: Standard JSON-RPC errors with error codes (handled by `Backplane.McpProtocol.MCP.Error`)
  2. Domain errors: Valid responses that indicate application-level errors with `isError: true`

  This module specifically handles domain errors, which are successful at the protocol level
  but indicate failures at the application level.

  ## Examples

  ```elixir
  # Create from a JSON-RPC response
  response = Backplane.McpProtocol.MCP.Response.from_json_rpc(%{"result" => %{"data" => "value"}, "id" => "req_123"})

  # Check if the response is successful or has a domain error
  if Backplane.McpProtocol.MCP.Response.success?(response) do
    # Handle success
  else
    # Handle domain error
  end

  # Unwrap the response to get the result or error
  case Backplane.McpProtocol.MCP.Response.unwrap(response) do
    {:ok, result} -> # Handle success
    {:error, error} -> # Handle domain error
  end
  ```
  """

  @type t :: %__MODULE__{
          result: term(),
          id: String.t() | integer(),
          is_error: boolean(),
          method: String.t() | nil,
          result_type: String.t() | nil
        }

  defstruct [:result, :id, :method, :result_type, is_error: false]

  @doc """
  Creates a Response struct from a JSON-RPC response.

  Automatically detects domain errors by checking for the "isError" field.

  ## Parameters

    * `response` - A map containing the JSON-RPC response

  ## Examples

      iex> Backplane.McpProtocol.MCP.Response.from_json_rpc(%{"result" => %{}, "id" => "req_123"})
      %Backplane.McpProtocol.MCP.Response{result: %{}, id: "req_123", is_error: false}
      
      iex> Backplane.McpProtocol.MCP.Response.from_json_rpc(%{"result" => %{"isError" => true}, "id" => "req_123"})
      %Backplane.McpProtocol.MCP.Response{result: %{"isError" => true}, id: "req_123", is_error: true}
  """
  @spec from_json_rpc(map()) :: t()
  def from_json_rpc(%{"result" => result, "id" => id}) do
    is_error = is_map(result) && Map.get(result, "isError", false)

    %__MODULE__{
      result: result,
      id: id,
      result_type: result_type(result),
      is_error: is_error
    }
  end

  @doc """
  Creates a response using the result requirements of a protocol version.

  The 2026-07-28 protocol defaults an omitted `resultType` on an object result
  to `complete`. Legacy versions preserve an omitted field as `nil`.
  """
  @spec from_json_rpc(map(), String.t()) ::
          {:ok, t()} | {:error, :missing_result_type | {:invalid_result_type, term()}}
  def from_json_rpc(%{"result" => result} = response, "2026-07-28") do
    case result_type(result) do
      nil when is_map(result) and not is_map_key(result, "resultType") ->
        {:ok, %{from_json_rpc(response) | result_type: "complete"}}

      nil ->
        {:error, :missing_result_type}

      result_type when is_binary(result_type) ->
        {:ok, from_json_rpc(response)}

      result_type ->
        {:error, {:invalid_result_type, result_type}}
    end
  end

  def from_json_rpc(response, _version), do: {:ok, from_json_rpc(response)}

  @doc """
  Unwraps the response, returning the raw result.

  Returns the raw result data regardless of whether it represents
  a success or domain error.

  ## Examples

      iex> response = Backplane.McpProtocol.MCP.Response.from_json_rpc(%{"result" => %{"data" => "value"}, "id" => "req_123"})
      iex> Backplane.McpProtocol.MCP.Response.unwrap(response)
      %{"data" => "value"}
      
      iex> error_response = Backplane.McpProtocol.MCP.Response.from_json_rpc(%{"result" => %{"isError" => true, "reason" => "not_found"}, "id" => "req_123"})
      iex> Backplane.McpProtocol.MCP.Response.unwrap(error_response)
      %{"isError" => true, "reason" => "not_found"}
  """
  @spec unwrap(t()) :: term()
  def unwrap(%__MODULE__{result: result}), do: result

  @doc """
  Checks if the response is successful (no domain error).

  ## Examples

      iex> response = Backplane.McpProtocol.MCP.Response.from_json_rpc(%{"result" => %{"data" => "value"}, "id" => "req_123"})
      iex> Backplane.McpProtocol.MCP.Response.success?(response)
      true
      
      iex> error_response = Backplane.McpProtocol.MCP.Response.from_json_rpc(%{"result" => %{"isError" => true}, "id" => "req_123"})
      iex> Backplane.McpProtocol.MCP.Response.success?(error_response)
      false
  """
  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{is_error: false}), do: true
  def success?(_), do: false

  @doc """
  Checks if the response has a domain error.

  ## Examples

      iex> response = Backplane.McpProtocol.MCP.Response.from_json_rpc(%{"result" => %{"data" => "value"}, "id" => "req_123"})
      iex> Backplane.McpProtocol.MCP.Response.error?(response)
      false
      
      iex> error_response = Backplane.McpProtocol.MCP.Response.from_json_rpc(%{"result" => %{"isError" => true}, "id" => "req_123"})
      iex> Backplane.McpProtocol.MCP.Response.error?(error_response)
      true
  """
  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{is_error: true}), do: true
  def error?(_), do: false

  @doc """
  Gets the result data from the response.

  This function returns the raw result regardless of whether it represents
  a success or domain error.

  ## Examples

      iex> response = Backplane.McpProtocol.MCP.Response.from_json_rpc(%{"result" => %{"data" => "value"}, "id" => "req_123"})
      iex> Backplane.McpProtocol.MCP.Response.get_result(response)
      %{"data" => "value"}
  """
  @spec get_result(t()) :: term()
  def get_result(%__MODULE__{result: result}), do: result

  @doc """
  Gets the request ID associated with this response.

  ## Examples

      iex> response = Backplane.McpProtocol.MCP.Response.from_json_rpc(%{"result" => %{}, "id" => "req_123"})
      iex> Backplane.McpProtocol.MCP.Response.get_id(response)
      "req_123"
  """
  @spec get_id(t()) :: String.t() | integer()
  def get_id(%__MODULE__{id: id}), do: id

  defp result_type(result) when is_map(result), do: Map.get(result, "resultType")
  defp result_type(_result), do: nil
end
