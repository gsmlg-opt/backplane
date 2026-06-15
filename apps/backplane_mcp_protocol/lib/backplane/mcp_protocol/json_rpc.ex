defmodule Backplane.McpProtocol.JsonRpc do
  @moduledoc """
  Helpers for JSON-RPC 2.0 request and response envelopes.
  """

  @jsonrpc "2.0"
  @invalid_request -32_600

  @spec request(String.t(), map() | nil, keyword()) :: map()
  def request(method, params \\ nil, opts \\ []) when is_binary(method) do
    %{"jsonrpc" => @jsonrpc, "id" => Keyword.get(opts, :id), "method" => method}
    |> maybe_put_params(params)
  end

  @spec notification(String.t(), map() | nil) :: map()
  def notification(method, params \\ nil) when is_binary(method) do
    %{"jsonrpc" => @jsonrpc, "method" => method}
    |> maybe_put_params(params)
  end

  @spec result(term(), map()) :: map()
  def result(id, result) when is_map(result) do
    %{"jsonrpc" => @jsonrpc, "id" => id, "result" => result}
  end

  @spec error(term(), integer(), String.t(), term()) :: map()
  def error(id, code, message, data \\ nil) when is_integer(code) and is_binary(message) do
    error = %{"code" => code, "message" => message}
    error = if is_nil(data), do: error, else: Map.put(error, "data", data)

    %{"jsonrpc" => @jsonrpc, "id" => id, "error" => error}
  end

  @spec validate_request(term()) :: {:ok, map()} | {:error, integer(), String.t()}
  def validate_request(%{"jsonrpc" => @jsonrpc, "method" => method} = request)
      when is_binary(method) do
    {:ok, request}
  end

  def validate_request(_request), do: {:error, @invalid_request, "Invalid Request"}

  defp maybe_put_params(envelope, nil), do: envelope
  defp maybe_put_params(envelope, params), do: Map.put(envelope, "params", params)
end
