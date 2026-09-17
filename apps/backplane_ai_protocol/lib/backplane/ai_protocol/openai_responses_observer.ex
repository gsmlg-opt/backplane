defmodule Backplane.AiProtocol.OpenAIResponsesObserver do
  @moduledoc """
  Bounded native observer for OpenAI Responses JSON and SSE response bytes.

  Observation never authorizes or submits a request and never rewrites native payloads.
  """

  alias Backplane.AiProtocol.{Error, SSE, Serialization}

  @default_max_total_bytes 8_388_608
  @default_max_frame_bytes 1_048_576
  @default_max_buffer_bytes 2_097_152
  @feed_slice_bytes 65_536
  @default_max_diagnostics 32
  @diagnostics_truncated "diagnostics_truncated"

  defstruct framer: nil,
            max_total_bytes: @default_max_total_bytes,
            max_diagnostics: @default_max_diagnostics,
            bytes_seen: 0,
            input_truncated: false,
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
            diagnostics: [],
            diagnostics_truncated: false

  @type t :: %__MODULE__{}

  @known_events ~w(response.created response.in_progress response.output_item.added response.output_item.done response.content_part.added response.content_part.done response.output_text.delta response.output_text.done response.refusal.delta response.refusal.done response.function_call_arguments.delta response.function_call_arguments.done response.completed response.incomplete response.failed error)

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      framer:
        opts
        |> Keyword.put_new(:max_frame_bytes, @default_max_frame_bytes)
        |> Keyword.put_new(:max_buffer_bytes, @default_max_buffer_bytes)
        |> SSE.new(),
      max_total_bytes:
        positive_limit(Keyword.get(opts, :max_total_bytes), @default_max_total_bytes),
      max_diagnostics:
        positive_limit(Keyword.get(opts, :max_diagnostics), @default_max_diagnostics)
    }
  end

  @spec feed(t(), term()) :: t()
  def feed(%__MODULE__{input_truncated: true} = state, _chunk), do: state

  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    next_size = state.bytes_seen + byte_size(chunk)

    if next_size > state.max_total_bytes do
      state
      |> incomplete("response_bytes_exceeded")
      |> Map.put(:input_truncated, true)
    else
      state = %{state | bytes_seen: next_size}
      observe_slices(state, chunk)
    end
  end

  def feed(%__MODULE__{} = state, _), do: incomplete(state, "invalid_chunk")

  @spec finish(t(), atom()) :: t()
  def finish(%__MODULE__{protocol_terminal: terminal} = state, _reason) when not is_nil(terminal),
    do: state

  def finish(%__MODULE__{input_truncated: true} = state, reason) do
    put_terminal(state, terminal_for_reason(reason))
  end

  def finish(%__MODULE__{} = state, reason) do
    state = observe_finish(state)

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
              safely_observe_document(%{state | bytes_seen: byte_size(body)}, value, status)

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
      input_truncated: state.input_truncated,
      events_seen: state.events_seen,
      diagnostics: Enum.reverse(state.diagnostics),
      diagnostics_truncated: state.diagnostics_truncated
    }
  end

  # Transport chunks may contain many complete events; bound pending frames, not whole batches.
  defp observe_slices(%{framer: %{closed?: true}} = state, _chunk), do: state

  defp observe_slices(state, chunk) when byte_size(chunk) > @feed_slice_bytes do
    <<slice::binary-size(@feed_slice_bytes), rest::binary>> = chunk
    state |> observe_chunk(slice) |> observe_slices(rest)
  end

  defp observe_slices(state, chunk), do: observe_chunk(state, chunk)

  defp observe_chunk(state, chunk) do
    case SSE.feed(state.framer, chunk) do
      {:ok, framer, events} ->
        Enum.reduce(events, %{state | framer: framer}, &observe_sse/2)

      {:error, %Error{} = error, framer} ->
        state
        |> Map.put(:framer, framer)
        |> incomplete("invalid_sse")
        |> incomplete(framer_diagnostic(error))
    end
  rescue
    _error -> incomplete(state, "observer_exception")
  end

  defp observe_finish(state) do
    case SSE.finish(state.framer) do
      {:ok, framer, events} ->
        Enum.reduce(events, %{state | framer: framer}, &observe_sse/2)

      {:error, %Error{} = error, framer} ->
        state
        |> Map.put(:framer, framer)
        |> incomplete("invalid_sse_eof")
        |> incomplete(framer_diagnostic(error))
    end
  rescue
    _error -> incomplete(state, "observer_exception")
  end

  defp framer_diagnostic(%Error{message: "SSE frame exceeds " <> _}),
    do: "sse_frame_bytes_exceeded"

  defp framer_diagnostic(%Error{message: "SSE buffer exceeds " <> _}),
    do: "sse_buffer_bytes_exceeded"

  defp framer_diagnostic(_), do: "sse_framer_error"

  defp safely_observe_document(state, document, status) do
    observe_document(state, document, status)
  rescue
    _error -> incomplete(state, "observer_exception")
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
    |> validate_response_container(event)
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
  end

  defp response_value(%{"response" => response}) when is_map(response), do: response
  defp response_value(event), do: event

  defp put_usage(state, value) when is_map(value) do
    case Map.fetch(value, "usage") do
      {:ok, usage} when is_map(usage) -> put_usage_map(state, usage)
      {:ok, nil} -> state
      {:ok, _invalid} -> incomplete(state, "invalid_usage")
      :error -> state
    end
  end

  defp put_provider_id(state, value) do
    id = value["id"] || response_id(value["response"])
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
    case value["incomplete_details"] do
      details when is_map(details) ->
        put_finish_reason(state, details["reason"] || value["stop_reason"])

      nil ->
        put_finish_reason(state, value["stop_reason"])

      _invalid ->
        incomplete(state, "invalid_incomplete_details")
    end
  end

  defp put_error(state, %{"error" => error}) when is_map(error) do
    %{state | error_code: safe_code(error["code"]), error_type: safe_code(error["type"])}
  end

  defp put_error(state, %{"error" => nil}), do: state
  defp put_error(state, %{"error" => _invalid}), do: incomplete(state, "invalid_error")

  defp put_error(state, error) when is_map(error) do
    %{state | error_code: safe_code(error["code"]), error_type: safe_code(error["type"])}
  end

  defp put_document_tools(state, %{"output" => output}) when is_list(output),
    do: Enum.reduce(output, state, &put_output_item/2)

  defp put_document_tools(state, %{"output" => nil}), do: state
  defp put_document_tools(state, %{"output" => _invalid}), do: incomplete(state, "invalid_output")
  defp put_document_tools(state, _), do: state

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

  defp put_tool_event(state, %{"type" => "response.function_call_arguments.delta"}),
    do: incomplete(state, "invalid_tool_arguments_delta")

  defp put_tool_event(state, %{
         "type" => "response.function_call_arguments.done",
         "item_id" => id,
         "arguments" => args
       })
       when is_binary(id) and is_binary(args) do
    finish_tool(state, id, args)
  end

  defp put_tool_event(state, %{"type" => "response.function_call_arguments.done"}),
    do: incomplete(state, "invalid_tool_arguments_done")

  defp put_tool_event(state, %{"item" => item}) when is_map(item),
    do: put_output_item(item, state)

  defp put_tool_event(state, %{"item" => _invalid}),
    do: incomplete(state, "invalid_output_item")

  defp put_tool_event(state, _), do: state

  defp put_output_item(%{"type" => "function_call"} = item, state) do
    id = item["id"] || item["call_id"]

    if is_binary(id) do
      {state, arguments} = tool_arguments(state, item)
      {state, call_id} = optional_binary(state, item["call_id"], "invalid_tool_call_id")
      {state, name} = optional_binary(state, item["name"], "invalid_tool_name")

      tool = %{
        id: id,
        call_id: call_id,
        name: name,
        arguments: arguments,
        complete: false
      }

      state = %{state | tool_calls: Map.put(state.tool_calls, id, tool)}

      if item["status"] == "completed" do
        finish_tool(state, id, arguments)
      else
        state
      end
    else
      incomplete(state, "tool_call_missing_id")
    end
  end

  defp put_output_item(%{"type" => "refusal"}, state),
    do: %{state | finish_reason: "refusal"}

  defp put_output_item(%{"type" => "message", "content" => content}, state)
       when is_list(content) do
    if Enum.any?(content, &match?(%{"type" => "refusal"}, &1)),
      do: %{state | finish_reason: "refusal"},
      else: state
  end

  defp put_output_item(%{"type" => "message", "content" => _invalid}, state),
    do: incomplete(state, "invalid_output_content")

  defp put_output_item(item, state) when is_map(item), do: state
  defp put_output_item(_item, state), do: incomplete(state, "invalid_output_item")

  defp update_tool(state, id, fun) do
    initial = %{id: id, call_id: nil, name: nil, arguments: "", complete: false}
    %{state | tool_calls: Map.update(state.tool_calls, id, fun.(initial), fun)}
  end

  defp finish_tool(state, id, arguments) when is_binary(arguments) do
    tool = Map.get(state.tool_calls, id, empty_tool(id))

    case Jason.decode(arguments) do
      {:ok, value} when is_map(value) ->
        %{
          state
          | tool_calls:
              Map.put(state.tool_calls, id, %{tool | arguments: arguments, complete: true})
        }

      _ ->
        state
        |> Map.put(
          :tool_calls,
          Map.put(state.tool_calls, id, %{tool | arguments: arguments, complete: false})
        )
        |> incomplete("invalid_tool_arguments")
    end
  end

  defp incomplete(state, diagnostic) do
    state = %{
      state
      | observation_status: :incomplete,
        usage_status: usage_status(%{state | observation_status: :incomplete})
    }

    retain_diagnostic(state, diagnostic)
  end

  defp terminal_for_reason(:cancelled), do: :cancelled
  defp terminal_for_reason(:error), do: :failed
  defp terminal_for_reason(_), do: :interrupted
  defp choose(nil, old), do: old
  defp choose(value, _old), do: value
  defp safe_code(value) when is_binary(value), do: String.slice(value, 0, 128)
  defp safe_code(_), do: nil

  defp validate_response_container(state, event) do
    case Map.fetch(event, "response") do
      {:ok, response} when is_map(response) -> state
      {:ok, _invalid} -> incomplete(state, "invalid_response")
      :error -> state
    end
  end

  defp put_usage_map(state, usage) do
    {state, input} = counter(state, usage, "input_tokens")
    {state, output} = counter(state, usage, "output_tokens")
    {state, total} = counter(state, usage, "total_tokens")
    {state, cached} = detail_counter(state, usage, "input_tokens_details", "cached_tokens")

    {state, reasoning} =
      detail_counter(state, usage, "output_tokens_details", "reasoning_tokens")

    state = %{
      state
      | input_tokens: choose(input, state.input_tokens),
        output_tokens: choose(output, state.output_tokens),
        cached_tokens: choose(cached, state.cached_tokens),
        reasoning_tokens: choose(reasoning, state.reasoning_tokens),
        native_total: choose(total, state.native_total)
    }

    %{state | usage_status: usage_status(state)}
  end

  defp counter(state, map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {state, value}
      {:ok, nil} -> {state, nil}
      {:ok, _invalid} -> {incomplete(state, "invalid_#{key}"), nil}
      :error -> {state, nil}
    end
  end

  defp detail_counter(state, usage, details_key, counter_key) do
    case Map.fetch(usage, details_key) do
      {:ok, details} when is_map(details) -> counter(state, details, counter_key)
      {:ok, nil} -> {state, nil}
      {:ok, _invalid} -> {incomplete(state, "invalid_#{details_key}"), nil}
      :error -> {state, nil}
    end
  end

  defp usage_status(%{observation_status: :complete, input_tokens: input, output_tokens: output})
       when is_integer(input) and is_integer(output),
       do: :complete

  defp usage_status(state) do
    if Enum.any?(
         [
           state.input_tokens,
           state.output_tokens,
           state.cached_tokens,
           state.reasoning_tokens,
           state.native_total
         ],
         &is_integer/1
       ),
       do: :partial,
       else: :unknown
  end

  defp response_id(response) when is_map(response), do: response["id"]
  defp response_id(_response), do: nil

  defp put_finish_reason(state, reason) when is_binary(reason),
    do: %{state | finish_reason: reason}

  defp put_finish_reason(state, _reason), do: state

  defp tool_arguments(state, item) do
    case Map.fetch(item, "arguments") do
      {:ok, arguments} when is_binary(arguments) -> {state, arguments}
      :error -> {state, ""}
      {:ok, _invalid} -> {incomplete(state, "invalid_tool_arguments"), ""}
    end
  end

  defp optional_binary(state, value, _diagnostic) when is_binary(value) or is_nil(value),
    do: {state, value}

  defp optional_binary(state, _value, diagnostic), do: {incomplete(state, diagnostic), nil}

  defp empty_tool(id),
    do: %{id: id, call_id: nil, name: nil, arguments: "", complete: false}

  defp retain_diagnostic(%{diagnostics_truncated: true} = state, _diagnostic), do: state

  defp retain_diagnostic(state, diagnostic) do
    cond do
      diagnostic in state.diagnostics ->
        state

      length(state.diagnostics) < state.max_diagnostics ->
        %{state | diagnostics: [diagnostic | state.diagnostics]}

      true ->
        retained =
          state.diagnostics
          |> Enum.reverse()
          |> Enum.take(state.max_diagnostics - 1)

        %{
          state
          | diagnostics: Enum.reverse(retained ++ [@diagnostics_truncated]),
            diagnostics_truncated: true
        }
    end
  end

  defp positive_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, default), do: default
end
