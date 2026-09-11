defmodule Backplane.AiProtocol.OpenAIResponsesObserver do
  @moduledoc """
  Bounded native observer for OpenAI Responses JSON and SSE response bytes.

  Observation never authorizes or submits a request and never rewrites native payloads.
  """

  alias Backplane.AiProtocol.{Error, SSE, Serialization}

  defstruct framer: nil,
            max_total_bytes: 8_388_608,
            bytes_seen: 0,
            events_seen: 0,
            protocol_terminal: nil,
            terminal_count: 0,
            observation_status: :complete,
            usage_status: :unknown,
            input_tokens: nil,
            output_tokens: nil,
            cached_tokens: nil,
            reasoning_tokens: nil,
            native_total: nil,
            finish_reason: nil,
            provider_request_id: nil,
            error_code: nil,
            error_type: nil,
            tool_calls: %{},
            diagnostics: []

  @type t :: %__MODULE__{}

  @known_events ~w(response.created response.in_progress response.output_item.added response.output_item.done response.content_part.added response.content_part.done response.output_text.delta response.output_text.done response.refusal.delta response.refusal.done response.function_call_arguments.delta response.function_call_arguments.done response.completed response.incomplete response.failed error)

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      framer: SSE.new(opts),
      max_total_bytes: Keyword.get(opts, :max_total_bytes, 8_388_608)
    }
  end

  @spec feed(t(), binary()) :: t()
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    next_size = state.bytes_seen + byte_size(chunk)

    if next_size > state.max_total_bytes do
      incomplete(state, "response_bytes_exceeded")
    else
      state = %{state | bytes_seen: next_size}

      case SSE.feed(state.framer, chunk) do
        {:ok, framer, events} -> Enum.reduce(events, %{state | framer: framer}, &observe_sse/2)
        {:error, %Error{}, framer} -> incomplete(%{state | framer: framer}, "invalid_sse")
      end
    end
  end

  def feed(%__MODULE__{} = state, _), do: incomplete(state, "invalid_chunk")

  @spec finish(t(), atom()) :: t()
  def finish(%__MODULE__{protocol_terminal: terminal} = state, _reason) when not is_nil(terminal),
    do: state

  def finish(%__MODULE__{} = state, reason) do
    state =
      case SSE.finish(state.framer) do
        {:ok, framer, events} -> Enum.reduce(events, %{state | framer: framer}, &observe_sse/2)
        {:error, %Error{}, framer} -> incomplete(%{state | framer: framer}, "invalid_sse_eof")
      end

    if state.protocol_terminal do
      state
    else
      state
      |> incomplete("missing_protocol_terminal")
      |> put_terminal(terminal_for_reason(reason))
    end
  end

  @spec observe_response(non_neg_integer(), binary(), keyword()) :: map()
  def observe_response(status, body, opts \\ []) when is_integer(status) and is_binary(body) do
    state = new(opts)

    state =
      cond do
        byte_size(body) > state.max_total_bytes ->
          incomplete(state, "response_bytes_exceeded")

        not String.valid?(body) ->
          incomplete(state, "invalid_utf8")

        true ->
          case Serialization.from_json(body, max_encoded_bytes: state.max_total_bytes) do
            {:ok, value} when is_map(value) ->
              observe_document(%{state | bytes_seen: byte_size(body)}, value, status)

            _ ->
              incomplete(%{state | bytes_seen: byte_size(body)}, "invalid_json")
          end
      end

    facts(state)
  end

  @spec facts(t()) :: map()
  def facts(%__MODULE__{} = state) do
    %{
      implementation: __MODULE__,
      observation_status: state.observation_status,
      protocol_terminal: state.protocol_terminal,
      terminal_count: state.terminal_count,
      usage_status: state.usage_status,
      input_tokens: state.input_tokens,
      output_tokens: state.output_tokens,
      cached_tokens: state.cached_tokens,
      reasoning_tokens: state.reasoning_tokens,
      native_total: state.native_total,
      finish_reason: state.finish_reason,
      provider_request_id: state.provider_request_id,
      error_code: state.error_code,
      error_type: state.error_type,
      tool_calls: state.tool_calls |> Map.values() |> Enum.sort_by(& &1.id),
      bytes_seen: state.bytes_seen,
      events_seen: state.events_seen,
      diagnostics: Enum.reverse(state.diagnostics)
    }
  end

  defp observe_sse(%{data: "[DONE]"}, state), do: state

  defp observe_sse(%{data: data}, state) do
    case Serialization.from_json(data, max_encoded_bytes: state.framer.max_frame_bytes) do
      {:ok, event} when is_map(event) ->
        observe_event(%{state | events_seen: state.events_seen + 1}, event)

      _ ->
        incomplete(state, "invalid_event_json")
    end
  end

  defp observe_event(state, %{"type" => type} = event) when type in @known_events do
    state
    |> put_provider_id(event)
    |> put_usage(response_value(event))
    |> put_tool_event(event)
    |> put_event_terminal(type, event)
  end

  defp observe_event(state, _), do: incomplete(state, "unknown_event")

  defp observe_document(state, document, status) do
    state =
      state
      |> put_provider_id(document)
      |> put_usage(document)
      |> put_document_tools(document)
      |> put_error(document)

    terminal =
      cond do
        status not in 200..299 ->
          :failed

        document["status"] == "completed" ->
          :completed

        document["status"] == "incomplete" ->
          :incomplete

        document["status"] in ["failed", "cancelled"] ->
          String.to_existing_atom(document["status"])

        document["error"] ->
          :failed

        true ->
          :unknown
      end

    state
    |> maybe_finish_reason(document)
    |> put_terminal(terminal)
    |> then(fn state ->
      if terminal == :unknown, do: incomplete(state, "unknown_document_terminal"), else: state
    end)
  rescue
    ArgumentError -> state |> incomplete("invalid_terminal") |> put_terminal(:unknown)
  end

  defp response_value(%{"response" => response}) when is_map(response), do: response
  defp response_value(event), do: event

  defp put_usage(state, %{"usage" => usage}) when is_map(usage) do
    input = integer(usage["input_tokens"])
    output = integer(usage["output_tokens"])
    total = integer(usage["total_tokens"])

    %{
      state
      | input_tokens: choose(input, state.input_tokens),
        output_tokens: choose(output, state.output_tokens),
        cached_tokens:
          choose(
            integer(get_in(usage, ["input_tokens_details", "cached_tokens"])),
            state.cached_tokens
          ),
        reasoning_tokens:
          choose(
            integer(get_in(usage, ["output_tokens_details", "reasoning_tokens"])),
            state.reasoning_tokens
          ),
        native_total: choose(total, state.native_total),
        usage_status:
          if(is_integer(input) or is_integer(output), do: :complete, else: state.usage_status)
    }
  end

  defp put_usage(state, _), do: state

  defp put_provider_id(state, value) do
    id = value["id"] || get_in(value, ["response", "id"])
    if is_binary(id), do: %{state | provider_request_id: id}, else: state
  end

  defp put_event_terminal(state, "response.completed", event),
    do: state |> maybe_finish_reason(response_value(event)) |> put_terminal(:completed)

  defp put_event_terminal(state, "response.incomplete", event),
    do: state |> maybe_finish_reason(response_value(event)) |> put_terminal(:incomplete)

  defp put_event_terminal(state, "response.failed", event),
    do: state |> put_error(response_value(event)) |> put_terminal(:failed)

  defp put_event_terminal(state, "error", event),
    do: state |> put_error(event) |> put_terminal(:failed)

  defp put_event_terminal(state, "response.refusal.done", _event),
    do: %{state | finish_reason: "refusal"}

  defp put_event_terminal(state, _type, _event), do: state

  defp put_terminal(%{protocol_terminal: nil} = state, terminal),
    do: %{state | protocol_terminal: terminal, terminal_count: 1}

  defp put_terminal(state, _terminal), do: state

  defp maybe_finish_reason(state, value) do
    reason = get_in(value, ["incomplete_details", "reason"]) || value["stop_reason"]
    if is_binary(reason), do: %{state | finish_reason: reason}, else: state
  end

  defp put_error(state, %{"error" => error}) when is_map(error) do
    %{state | error_code: safe_code(error["code"]), error_type: safe_code(error["type"])}
  end

  defp put_error(state, error) when is_map(error) do
    %{state | error_code: safe_code(error["code"]), error_type: safe_code(error["type"])}
  end

  defp put_document_tools(state, %{"output" => output}) when is_list(output),
    do: Enum.reduce(output, state, &put_output_item/2)

  defp put_document_tools(state, _), do: state

  defp put_tool_event(state, %{"item" => item}) when is_map(item),
    do: put_output_item(item, state)

  defp put_tool_event(state, %{
         "type" => "response.function_call_arguments.delta",
         "item_id" => id,
         "delta" => delta
       })
       when is_binary(id) and is_binary(delta) do
    update_tool(state, id, fn tool ->
      %{tool | arguments: tool.arguments <> delta, complete: false}
    end)
  end

  defp put_tool_event(state, %{
         "type" => "response.function_call_arguments.done",
         "item_id" => id,
         "arguments" => args
       })
       when is_binary(id) and is_binary(args) do
    update_tool(state, id, fn tool -> finish_tool(%{tool | arguments: args}) end)
  end

  defp put_tool_event(state, _), do: state

  defp put_output_item(%{"type" => "function_call"} = item, state) do
    id = item["id"] || item["call_id"]

    if is_binary(id) do
      tool = %{
        id: id,
        call_id: item["call_id"],
        name: item["name"],
        arguments: item["arguments"] || "",
        complete: false
      }

      tool = if item["status"] == "completed", do: finish_tool(tool), else: tool
      %{state | tool_calls: Map.put(state.tool_calls, id, tool)}
    else
      incomplete(state, "tool_call_missing_id")
    end
  end

  defp put_output_item(_item, state), do: state

  defp update_tool(state, id, fun) do
    initial = %{id: id, call_id: nil, name: nil, arguments: "", complete: false}
    %{state | tool_calls: Map.update(state.tool_calls, id, fun.(initial), fun)}
  end

  defp finish_tool(tool) do
    case Jason.decode(tool.arguments) do
      {:ok, value} when is_map(value) -> %{tool | complete: true}
      _ -> %{tool | complete: false}
    end
  end

  defp incomplete(state, diagnostic) do
    %{
      state
      | observation_status: :incomplete,
        usage_status: if(state.usage_status == :complete, do: :partial, else: state.usage_status),
        diagnostics: [diagnostic | state.diagnostics]
    }
  end

  defp terminal_for_reason(:cancelled), do: :cancelled
  defp terminal_for_reason(:error), do: :failed
  defp terminal_for_reason(_), do: :interrupted
  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_), do: nil
  defp choose(nil, old), do: old
  defp choose(value, _old), do: value
  defp safe_code(value) when is_binary(value), do: String.slice(value, 0, 128)
  defp safe_code(_), do: nil
end
