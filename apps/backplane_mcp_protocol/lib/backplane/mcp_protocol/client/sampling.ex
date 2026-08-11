defmodule Backplane.McpProtocol.Client.Sampling do
  @moduledoc false

  use Backplane.McpProtocol.Logging

  alias Backplane.McpProtocol.Client.State
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.MCP.Message
  alias Backplane.McpProtocol.Telemetry

  @doc false
  @spec resolve(map(), State.t()) :: {:ok, map()} | {:error, Error.t()}
  def resolve(params, %State{} = state) when is_map(params) do
    with callback when is_function(callback, 1) <- State.get_sampling_callback(state),
         {:ok, result} <- invoke_callback(callback, params),
         :ok <- validate_modern_result(result) do
      {:ok, result}
    else
      _failure -> sanitized_resolution_error()
    end
  rescue
    _exception -> sanitized_resolution_error()
  catch
    _kind, _reason -> sanitized_resolution_error()
  end

  def resolve(_params, %State{}), do: sanitized_resolution_error()

  @spec handle_request(msg :: map, State.t()) :: State.t()
  def handle_request(%{"id" => id} = msg, state) do
    params = Map.get(msg, "params", %{})

    case validate_sampling_capability(state) do
      :ok ->
        handle_sampling_with_callback(id, params, state)

      {:error, reason} ->
        send_sampling_error(id, reason, "capability_disabled", %{}, state)
    end
  end

  defp validate_sampling_capability(state) do
    if Map.has_key?(state.capabilities, "sampling") do
      :ok
    else
      {:error, "Client does not have sampling capability enabled"}
    end
  end

  defp invoke_callback(callback, params) do
    case callback.(params) do
      {:ok, result} when is_map(result) -> {:ok, result}
      _invalid -> :error
    end
  end

  defp validate_modern_result(%{"role" => role, "content" => content, "model" => model} = result)
       when role in ["user", "assistant"] and is_binary(model) do
    if bare_result?(result) and valid_content?(content) and
         valid_optional?(result, "stopReason", &is_binary/1) and
         valid_optional?(result, "_meta", &valid_meta?/1) and strict_json?(result) do
      :ok
    else
      :error
    end
  end

  defp validate_modern_result(_result), do: :error

  defp bare_result?(result) do
    Enum.all?(["id", "jsonrpc", "resultType", :id, :jsonrpc, :resultType], fn key ->
      not Map.has_key?(result, key)
    end)
  end

  defp valid_content?(content) when is_map(content), do: valid_sampling_block?(content)
  defp valid_content?(content) when is_list(content), do: Enum.all?(content, &valid_sampling_block?/1)
  defp valid_content?(_content), do: false

  defp valid_sampling_block?(%{"type" => "text", "text" => text} = block) when is_binary(text),
    do: valid_common_block?(block)

  defp valid_sampling_block?(%{"type" => "image", "data" => data, "mimeType" => mime_type} = block)
       when is_binary(data) and is_binary(mime_type),
       do: valid_common_block?(block)

  defp valid_sampling_block?(%{"type" => "audio", "data" => data, "mimeType" => mime_type} = block)
       when is_binary(data) and is_binary(mime_type),
       do: valid_common_block?(block)

  defp valid_sampling_block?(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input} = block)
       when is_binary(id) and is_binary(name) and is_map(input),
       do: strict_json?(input) and valid_optional?(block, "_meta", &valid_meta?/1)

  defp valid_sampling_block?(%{"type" => "tool_result", "toolUseId" => tool_use_id, "content" => content} = block)
       when is_binary(tool_use_id) and is_list(content) do
    Enum.all?(content, &valid_tool_result_block?/1) and
      valid_optional?(block, "isError", &is_boolean/1) and
      valid_optional?(block, "structuredContent", &strict_json?/1) and
      valid_optional?(block, "_meta", &valid_meta?/1)
  end

  defp valid_sampling_block?(_block), do: false

  defp valid_tool_result_block?(%{"type" => type} = block) when type in ["text", "image", "audio"],
    do: valid_sampling_block?(block)

  defp valid_tool_result_block?(%{"type" => "resource_link", "name" => name, "uri" => uri} = block)
       when is_binary(name) and is_binary(uri) do
    valid_absolute_uri?(uri) and
      valid_optional?(block, "title", &is_binary/1) and
      valid_optional?(block, "description", &is_binary/1) and
      valid_optional?(block, "mimeType", &is_binary/1) and
      valid_optional?(block, "icons", &valid_icons?/1) and
      valid_optional?(block, "size", &is_number/1) and
      valid_common_block?(block)
  end

  defp valid_tool_result_block?(%{"type" => "resource", "resource" => resource} = block) when is_map(resource) do
    valid_embedded_resource?(resource) and valid_common_block?(block)
  end

  defp valid_tool_result_block?(_block), do: false

  defp valid_embedded_resource?(%{"uri" => uri} = resource) when is_binary(uri) do
    valid_absolute_uri?(uri) and
      valid_optional?(resource, "mimeType", &is_binary/1) and
      valid_optional?(resource, "_meta", &valid_meta?/1) and
      (match?(
         {{:ok, text}, :error} when is_binary(text),
         {Map.fetch(resource, "text"), Map.fetch(resource, "blob")}
       ) or
         match?(
           {:error, {:ok, blob}} when is_binary(blob),
           {Map.fetch(resource, "text"), Map.fetch(resource, "blob")}
         ))
  end

  defp valid_embedded_resource?(_resource), do: false

  defp valid_common_block?(block) do
    valid_optional?(block, "annotations", &valid_annotations?/1) and
      valid_optional?(block, "_meta", &valid_meta?/1)
  end

  defp valid_annotations?(annotations) when is_map(annotations) do
    valid_optional?(annotations, "audience", &valid_audience?/1) and
      valid_optional?(annotations, "priority", &valid_priority?/1) and
      valid_optional?(annotations, "lastModified", &is_binary/1) and
      strict_json?(annotations)
  end

  defp valid_annotations?(_annotations), do: false

  defp valid_audience?(audience) when is_list(audience) do
    Enum.all?(audience, &(&1 in ["user", "assistant"]))
  end

  defp valid_audience?(_audience), do: false

  defp valid_priority?(priority) do
    is_number(priority) and priority >= 0 and priority <= 1
  end

  defp valid_icons?(icons) when is_list(icons), do: Enum.all?(icons, &valid_icon?/1)
  defp valid_icons?(_icons), do: false

  defp valid_icon?(%{"src" => src} = icon) when is_binary(src) do
    valid_absolute_uri?(src) and
      valid_optional?(icon, "mimeType", &is_binary/1) and
      valid_optional?(icon, "sizes", &string_list?/1) and
      valid_optional?(icon, "theme", &(&1 in ["dark", "light"])) and
      strict_json?(icon)
  end

  defp valid_icon?(_icon), do: false

  defp string_list?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  defp string_list?(_values), do: false

  defp valid_absolute_uri?(value) do
    match?({:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "", URI.new(value))
  end

  defp valid_meta?(meta) when is_map(meta), do: strict_json?(meta)
  defp valid_meta?(_meta), do: false

  defp strict_json?(nil), do: true
  defp strict_json?(value) when is_boolean(value) or is_binary(value) or is_number(value), do: true
  defp strict_json?(values) when is_list(values), do: Enum.all?(values, &strict_json?/1)

  defp strict_json?(value) when is_map(value) do
    Enum.all?(value, fn {key, child} -> is_binary(key) and strict_json?(child) end)
  end

  defp strict_json?(_value), do: false

  defp valid_optional?(map, key, validator) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, value} -> validator.(value)
    end
  end

  defp sanitized_resolution_error do
    {:error,
     Error.protocol(:internal_error, %{
       message: "Sampling input resolution failed"
     })}
  end

  defp handle_sampling_with_callback(id, params, state) do
    case State.get_sampling_callback(state) do
      nil ->
        send_sampling_error(
          id,
          "No sampling callback registered",
          "sampling_not_configured",
          %{},
          state
        )

      callback when is_function(callback, 1) ->
        execute_sampling_callback(id, params, callback, state)
    end
  end

  defp execute_sampling_callback(id, params, callback, state) do
    Task.start(fn ->
      try do
        case callback.(params) do
          {:ok, result} ->
            handle_sampling_result(id, result, state)

          {:error, message} ->
            send_sampling_error(id, message, "sampling_error", %{}, state)
        end
      rescue
        e ->
          error_message = "Sampling callback error: #{Exception.message(e)}"

          send_sampling_error(
            id,
            error_message,
            "sampling_callback_error",
            %{},
            state
          )
      end
    end)

    state
  end

  defp handle_sampling_result(id, result, state) do
    case Message.encode_sampling_response(%{"result" => result}, id) do
      {:ok, validated} ->
        send_sampling_response(id, validated, state)

      {:error, [%Peri.Error{} | _] = errors} ->
        error_message = "Invalid sampling response"

        send_sampling_error(
          id,
          error_message,
          "invalid_sampling_response",
          errors,
          state
        )

      {:error, reason} ->
        error_message = "Invalid sampling response: #{reason}"

        send_sampling_error(
          id,
          error_message,
          "invalid_sampling_response",
          reason,
          state
        )
    end
  end

  defp send_sampling_response(id, response, state) do
    transport = state.transport
    :ok = transport.layer.send_message(transport.name, response, timeout: state.timeout)

    Telemetry.execute(
      Telemetry.event_client_response(),
      %{system_time: System.system_time()},
      %{id: id, method: "sampling/createMessage"}
    )
  end

  defp send_sampling_error(id, message, code, reason, %{transport: transport} = state) do
    error = %Error{code: -1, message: message, data: %{"reason" => reason}}
    {:ok, response} = Error.to_json_rpc(error, id)
    :ok = transport.layer.send_message(transport.name, response, timeout: state.timeout)

    Logging.client_event(
      "sampling_error",
      %{
        id: id,
        error_code: code,
        error_message: message
      },
      level: :error
    )

    Telemetry.execute(
      Telemetry.event_client_error(),
      %{system_time: System.system_time()},
      %{id: id, method: "sampling/createMessage", error_code: code}
    )

    state
  end
end
