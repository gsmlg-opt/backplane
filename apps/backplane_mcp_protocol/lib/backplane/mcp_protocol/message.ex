defmodule Backplane.McpProtocol.Message do
  @moduledoc """
  MCP message framing and validation helpers.
  """

  @jsonrpc "2.0"

  @request_methods ~w(
    initialize
    ping
    tools/list
    tools/call
    resources/list
    resources/read
    resources/subscribe
    resources/unsubscribe
    prompts/list
    prompts/get
    completion/complete
  )

  @notification_methods ~w(
    notifications/initialized
    notifications/cancelled
    notifications/progress
    notifications/message
    notifications/resources/updated
    notifications/resources/list_changed
    notifications/tools/list_changed
    notifications/prompts/list_changed
  )

  @log_levels ~w(debug info notice warning error critical alert emergency)

  @spec decode(String.t()) :: {:ok, [map()]} | {:error, term()}
  def decode(data) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, &decode_line/2)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_message(term()) :: {:ok, map()} | {:error, :invalid_message}
  def validate_message(%{"jsonrpc" => @jsonrpc} = message) do
    cond do
      request?(message) -> validate_request(message)
      notification?(message) -> validate_notification(message)
      response?(message) -> {:ok, message}
      error?(message) -> validate_error(message)
      true -> {:error, :invalid_message}
    end
  end

  def validate_message(_message), do: {:error, :invalid_message}

  @spec encode_request(map(), term()) :: {:ok, String.t()} | {:error, term()}
  def encode_request(%{"method" => _method} = request, id) do
    request
    |> Map.put("jsonrpc", @jsonrpc)
    |> Map.put("id", id)
    |> validate_and_encode()
  end

  @spec encode_notification(map()) :: {:ok, String.t()} | {:error, term()}
  def encode_notification(%{"method" => _method} = notification) do
    notification
    |> Map.put("jsonrpc", @jsonrpc)
    |> Map.delete("id")
    |> validate_and_encode()
  end

  @spec encode_progress_notification(map()) :: {:ok, String.t()} | {:error, term()}
  def encode_progress_notification(params) when is_map(params) do
    encode_notification(%{"method" => "notifications/progress", "params" => params})
  end

  @spec encode_log_message(String.t(), term(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def encode_log_message(level, data, logger \\ nil) when level in @log_levels do
    params =
      %{"level" => level, "data" => data}
      |> maybe_put("logger", logger)

    encode_notification(%{"method" => "notifications/message", "params" => params})
  end

  @spec request?(term()) :: boolean()
  def request?(%{"jsonrpc" => @jsonrpc, "method" => method} = message)
      when is_binary(method) do
    Map.has_key?(message, "id")
  end

  def request?(_message), do: false

  @spec notification?(term()) :: boolean()
  def notification?(%{"jsonrpc" => @jsonrpc, "method" => method} = message)
      when is_binary(method) do
    not Map.has_key?(message, "id")
  end

  def notification?(_message), do: false

  @spec response?(term()) :: boolean()
  def response?(%{"jsonrpc" => @jsonrpc, "id" => id} = message) do
    not is_nil(id) and Map.has_key?(message, "result") and not Map.has_key?(message, "method")
  end

  def response?(_message), do: false

  @spec error?(term()) :: boolean()
  def error?(%{"jsonrpc" => @jsonrpc, "error" => error, "id" => _id}) when is_map(error), do: true
  def error?(_message), do: false

  defp decode_line(line, {:ok, messages}) do
    with {:ok, decoded} <- Jason.decode(line),
         {:ok, message} <- validate_message(decoded) do
      {:cont, {:ok, [message | messages]}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp validate_and_encode(message) do
    with {:ok, valid_message} <- validate_message(message),
         {:ok, json} <- Jason.encode(valid_message) do
      {:ok, json <> "\n"}
    end
  end

  defp validate_request(%{"method" => "initialize", "params" => params} = message)
       when is_map(params) do
    required? =
      is_binary(params["protocolVersion"]) and is_map(params["capabilities"]) and
        valid_implementation?(params["clientInfo"])

    if required?, do: {:ok, message}, else: {:error, :invalid_message}
  end

  defp validate_request(%{"method" => "tools/call", "params" => %{"name" => name}} = message)
       when is_binary(name) do
    {:ok, message}
  end

  defp validate_request(%{"method" => method} = message) when method in @request_methods do
    {:ok, message}
  end

  defp validate_request(_message), do: {:error, :invalid_message}

  defp validate_notification(
         %{"method" => "notifications/progress", "params" => params} = message
       )
       when is_map(params) do
    if Map.has_key?(params, "progressToken") and Map.has_key?(params, "progress") do
      {:ok, message}
    else
      {:error, :invalid_message}
    end
  end

  defp validate_notification(%{"method" => "notifications/message", "params" => params} = message)
       when is_map(params) do
    if params["level"] in @log_levels and Map.has_key?(params, "data") do
      {:ok, message}
    else
      {:error, :invalid_message}
    end
  end

  defp validate_notification(
         %{"method" => "notifications/cancelled", "params" => params} = message
       )
       when is_map(params) do
    if Map.has_key?(params, "requestId"), do: {:ok, message}, else: {:error, :invalid_message}
  end

  defp validate_notification(
         %{"method" => "notifications/resources/updated", "params" => params} = message
       )
       when is_map(params) do
    if is_binary(params["uri"]), do: {:ok, message}, else: {:error, :invalid_message}
  end

  defp validate_notification(%{"method" => method} = message)
       when method in @notification_methods do
    {:ok, message}
  end

  defp validate_notification(_message), do: {:error, :invalid_message}

  defp validate_error(%{"error" => %{"code" => code, "message" => message}} = error)
       when is_integer(code) and is_binary(message) do
    {:ok, error}
  end

  defp validate_error(_message), do: {:error, :invalid_message}

  defp valid_implementation?(%{"name" => name, "version" => version})
       when is_binary(name) and is_binary(version),
       do: true

  defp valid_implementation?(_implementation), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
