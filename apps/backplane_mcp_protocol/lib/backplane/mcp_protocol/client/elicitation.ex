defmodule Backplane.McpProtocol.Client.Elicitation do
  @moduledoc false

  use Backplane.McpProtocol.Logging

  alias Backplane.McpProtocol.Client.State
  alias Backplane.McpProtocol.MCP.ElicitationSchema
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.MCP.Message
  alias Backplane.McpProtocol.Telemetry

  @doc false
  @spec resolve(map(), State.t()) :: {:ok, map()} | {:error, Error.t()}
  def resolve(params, %State{} = state) when is_map(params) do
    with callback when is_function(callback, 2) <- State.get_elicitation_callback(state),
         {:ok, result} <- resolve_with_callback(params, callback),
         true <- bare_result?(result),
         {:ok, _encoded} <- Message.encode_elicitation_response(%{"result" => result}, "mrtr") do
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

  @spec handle_request(msg :: map(), State.t()) :: State.t()
  def handle_request(%{"id" => id} = msg, state) do
    params = Map.get(msg, "params", %{})

    case validate_elicitation_capability(state) do
      :ok ->
        handle_elicitation_with_callback(id, params, state)

      {:error, reason} ->
        send_elicitation_error(id, reason, "capability_disabled", %{}, state)
    end
  end

  defp validate_elicitation_capability(state) do
    if Map.has_key?(state.capabilities, "elicitation") do
      :ok
    else
      {:error, "Client does not have elicitation capability enabled"}
    end
  end

  defp resolve_with_callback(%{"mode" => "url", "message" => message, "url" => url}, callback) do
    context = %{"mode" => "url", "url" => url}

    case callback.(message, context) do
      {:accept, content} when is_map(content) -> {:ok, %{"action" => "accept"}}
      :decline -> {:ok, %{"action" => "decline"}}
      :cancel -> {:ok, %{"action" => "cancel"}}
      _invalid -> :error
    end
  end

  defp resolve_with_callback(%{"message" => message, "requestedSchema" => requested_schema}, callback) do
    case callback.(message, requested_schema) do
      {:accept, content} when is_map(content) ->
        case ElicitationSchema.validate_content(content, requested_schema) do
          :ok -> {:ok, %{"action" => "accept", "content" => content}}
          {:error, _reason} -> :error
        end

      :decline ->
        {:ok, %{"action" => "decline"}}

      :cancel ->
        {:ok, %{"action" => "cancel"}}

      _invalid ->
        :error
    end
  end

  defp resolve_with_callback(_params, _callback), do: :error

  defp bare_result?(result) do
    Enum.all?(["id", "jsonrpc", "resultType", :id, :jsonrpc, :resultType], fn key ->
      not Map.has_key?(result, key)
    end)
  end

  defp sanitized_resolution_error do
    {:error,
     Error.protocol(:internal_error, %{
       message: "Elicitation input resolution failed"
     })}
  end

  defp handle_elicitation_with_callback(id, params, state) do
    case State.get_elicitation_callback(state) do
      nil ->
        send_elicitation_error(
          id,
          "No elicitation callback registered",
          "elicitation_not_configured",
          %{},
          state
        )

      callback when is_function(callback, 2) ->
        execute_elicitation_callback(id, params, callback, state)
    end
  end

  defp execute_elicitation_callback(id, params, callback, state) do
    message = Map.get(params, "message", "")
    requested_schema = Map.get(params, "requestedSchema", %{})

    Task.start(fn ->
      try do
        case callback.(message, requested_schema) do
          {:accept, content} when is_map(content) ->
            handle_accept(id, content, requested_schema, state)

          :decline ->
            send_elicitation_response(id, %{"action" => "decline"}, state)

          :cancel ->
            send_elicitation_response(id, %{"action" => "cancel"}, state)

          {:error, reason} ->
            send_elicitation_error(id, reason, "elicitation_error", %{}, state)
        end
      rescue
        e ->
          send_elicitation_error(
            id,
            "Elicitation callback error: #{Exception.message(e)}",
            "elicitation_callback_error",
            %{},
            state
          )
      end
    end)

    state
  end

  defp handle_accept(id, content, requested_schema, state) do
    case ElicitationSchema.validate_content(content, requested_schema) do
      :ok ->
        send_elicitation_response(id, %{"action" => "accept", "content" => content}, state)

      {:error, reason} ->
        send_elicitation_error(
          id,
          "Elicitation content does not match requested schema: #{reason}",
          "invalid_elicitation_content",
          %{},
          state
        )
    end
  end

  defp send_elicitation_response(id, result, state) do
    case Message.encode_elicitation_response(%{"result" => result}, id) do
      {:ok, encoded} ->
        transport = state.transport
        :ok = transport.layer.send_message(transport.name, encoded, timeout: state.timeout)

        Telemetry.execute(
          Telemetry.event_client_response(),
          %{system_time: System.system_time()},
          %{id: id, method: "elicitation/create"}
        )

      {:error, [%Peri.Error{} | _] = errors} ->
        send_elicitation_error(
          id,
          "Invalid elicitation response",
          "invalid_elicitation_response",
          errors,
          state
        )

      {:error, reason} ->
        send_elicitation_error(
          id,
          "Invalid elicitation response: #{inspect(reason)}",
          "invalid_elicitation_response",
          reason,
          state
        )
    end
  end

  defp send_elicitation_error(id, message, code, reason, %{transport: transport} = state) do
    error = %Error{code: -1, message: message, data: %{"reason" => reason}}
    {:ok, response} = Error.to_json_rpc(error, id)
    :ok = transport.layer.send_message(transport.name, response, timeout: state.timeout)

    Logging.client_event(
      "elicitation_error",
      %{id: id, error_code: code, error_message: message},
      level: :error
    )

    Telemetry.execute(
      Telemetry.event_client_error(),
      %{system_time: System.system_time()},
      %{id: id, method: "elicitation/create", error_code: code}
    )

    state
  end
end
