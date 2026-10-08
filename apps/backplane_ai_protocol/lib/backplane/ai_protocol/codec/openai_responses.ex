defmodule Backplane.AiProtocol.Codec.OpenAIResponses do
  @moduledoc """
  Pure Responses codec for text, JSON function and raw custom tools.

  Canonical `namespace::name` identities use native namespace declarations and call fields.
  Unsupported content and unresolved state fail before transport. This codec does not execute
  tools or grant authority. Hosts own dispatch and capability selection.
  """
  @behaviour Backplane.AiProtocol.Codec

  alias Backplane.AiProtocol.{
    ContentBlock,
    Error,
    Request,
    Response,
    Serialization,
    StreamEvent,
    ToolCall,
    Usage,
    Validation
  }

  alias Backplane.AiProtocol.Codec.Common

  @impl true
  def encode_request(%Request{model: model} = request, opts) when is_binary(model) do
    with :ok <- Common.reject_state_references(request),
         :ok <-
           Common.reject_reserved(
             request.settings,
             request.output_constraints,
             ~w(model input tools stream)
           ),
         {:ok, input} <- encode_input(request),
         {:ok, tools} <- encode_tools(request.tools) do
      wire = %{"model" => model, "input" => input, "stream" => Keyword.get(opts, :stream, false)}
      wire = if tools == [], do: wire, else: Map.put(wire, "tools", tools)

      with {:ok, settings} <- portable(request.settings || %{}),
           {:ok, constraints} <- portable(request.output_constraints || %{}) do
        {:ok, wire |> Map.merge(settings) |> Map.merge(constraints)}
      end
    end
  end

  def encode_request(_request, _opts), do: invalid("Responses model must be a concrete string")

  defp encode_input(request) do
    calls =
      for %{content: blocks} <- request.input,
          %{type: :tool_call, tool_call: call} <- blocks,
          do: call

    with :ok <- unique_ids(calls) do
      kinds = Map.new(calls, fn call -> {call.id, argument_kind(call.raw_arguments)} end)

      collect(request.input, &encode_message(&1, kinds))
      |> case do
        {:ok, messages} -> {:ok, List.flatten(messages)}
        error -> error
      end
    end
  end

  defp encode_message(%{role: :tool} = message, kinds) do
    with {:ok, kind} <- fetch_kind(kinds, message.tool_call_id),
         {:ok, text} <- Common.tool_result_text(message.content) do
      type = if kind == :custom, do: "custom_tool_call_output", else: "function_call_output"
      {:ok, [%{"type" => type, "call_id" => message.tool_call_id, "output" => text}]}
    end
  end

  defp encode_message(%{role: role, content: blocks}, _kinds) do
    collect(blocks, fn
      %ContentBlock{type: :text, text: text} ->
        type = if role == :assistant, do: "output_text", else: "input_text"

        {:ok,
         %{
           "type" => "message",
           "role" => to_string(role),
           "content" => [%{"type" => type, "text" => text}]
         }}

      %ContentBlock{type: :tool_call, tool_call: call} when role == :assistant ->
        encode_call(call)

      _ ->
        Common.unsupported("responses_content")
    end)
  end

  defp encode_message(_state, _kinds), do: Common.unsupported("provider_state")

  defp fetch_kind(kinds, id) do
    case Map.fetch(kinds, id) do
      {:ok, kind} -> {:ok, kind}
      :error -> invalid("Responses tool result requires a preceding typed tool call")
    end
  end

  defp encode_call(call) do
    identity = native_identity(call.name) |> Map.put("call_id", call.id)

    case call.raw_arguments do
      {:custom, input} ->
        {:ok, Map.merge(identity, %{"type" => "custom_tool_call", "input" => input})}

      arguments ->
        with {:ok, object} <- Common.json_arguments(arguments),
             {:ok, json} <- Jason.encode(object),
             do: {:ok, Map.merge(identity, %{"type" => "function_call", "arguments" => json})}
    end
  end

  defp encode_tools(tools) do
    collect(tools || [], fn tool ->
      identity = native_identity(tool.name)

      declaration = %{
        "name" => identity["name"],
        "type" => if(tool.input_kind == :custom, do: "custom", else: "function")
      }

      declaration =
        if tool.description,
          do: Map.put(declaration, "description", tool.description),
          else: declaration

      value =
        if tool.input_kind == :custom,
          do: tool.format,
          else: tool.input_schema || %{"type" => "object"}

      key = if tool.input_kind == :custom, do: "format", else: "parameters"

      with {:ok, value} <- portable(value) do
        declaration = if value, do: Map.put(declaration, key, value), else: declaration
        {:ok, {identity["namespace"], declaration}}
      end
    end)
    |> case do
      {:ok, declarations} ->
        {tools, _seen} =
          Enum.reduce(declarations, {[], MapSet.new()}, fn
            {nil, tool}, {acc, seen} ->
              {acc ++ [tool], seen}

            {namespace, _}, {acc, seen} ->
              if MapSet.member?(seen, namespace) do
                {acc, seen}
              else
                nested = for {^namespace, tool} <- declarations, do: tool

                {acc ++ [%{"type" => "namespace", "name" => namespace, "tools" => nested}],
                 MapSet.put(seen, namespace)}
              end
          end)

        {:ok, tools}

      error ->
        error
    end
  end

  @impl true
  def decode_response(status, _headers, body, opts) when status in 200..299 do
    with {:ok, document} <- Common.decode_json(body),
         :ok <- Validation.term(document, Keyword.get(opts, :limits, %{})),
         true <- document["status"] in ["completed", "incomplete"],
         {:ok, output} <- decode_output(document["output"], opts),
         :ok <- unique_ids(for %{tool_call: call} <- output, call != nil, do: call),
         {:ok, usage} <- usage(document["usage"]),
         {:ok, response} <-
           Response.new(%{
             output: output,
             stop_reason: stop_reason(document, output),
             completeness: if(document["status"] == "completed", do: :complete, else: :partial),
             usage: usage,
             resolved_model: document["model"]
           }) do
      {:ok, response}
    else
      false -> invalid("Responses document is missing a supported terminal status")
      error -> error
    end
  end

  def decode_response(status, headers, body, opts), do: decode_error(status, headers, body, opts)

  @impl true
  def decode_error(status, headers, body, opts),
    do: Backplane.AiProtocol.Codec.OpenAI.decode_error(status, headers, body, opts)

  defp decode_output(output, opts) when is_list(output) do
    collect(output, fn
      %{"type" => type} = item when type in ["function_call", "custom_tool_call"] ->
        with {:ok, call} <- decode_call(item, opts),
             do: {:ok, [%ContentBlock{type: :tool_call, tool_call: call}]}

      %{"type" => "message", "content" => content} when is_list(content) ->
        collect(content, fn
          %{"type" => "output_text", "text" => text} ->
            ContentBlock.new(%{type: :text, text: text}, opts)

          %{"type" => "refusal", "refusal" => text} ->
            ContentBlock.new(%{type: :refusal, text: text}, opts)

          _ ->
            Common.unsupported("responses_content")
        end)

      _ ->
        Common.unsupported("responses_output")
    end)
    |> case do
      {:ok, blocks} -> {:ok, List.flatten(blocks)}
      error -> error
    end
  end

  defp decode_output(_, _opts), do: invalid("Responses output must be a list")

  defp decode_call(item, opts) do
    with {:ok, name} <- canonical_identity(item),
         {:ok, raw} <- decode_arguments(item),
         :ok <- bound_input(elem(raw, 1), opts),
         {:ok, call} <-
           ToolCall.new(
             %{id: item["call_id"], native_id: item["id"], name: name, raw_arguments: raw},
             opts
           ),
         do: {:ok, call}
  end

  defp decode_arguments(%{"type" => "custom_tool_call", "input" => input}) when is_binary(input),
    do: {:ok, {:custom, input}}

  defp decode_arguments(%{"type" => "function_call", "arguments" => args}) when is_binary(args) do
    with {:ok, _object} <- Common.json_arguments({:json, args}), do: {:ok, {:json, args}}
  end

  defp decode_arguments(_), do: invalid("Responses tool input has an invalid encoding")

  @impl true
  def stream_new(opts), do: Common.stream_state(opts) |> Map.put(:call_ids, MapSet.new())
  @impl true
  def stream_feed(state, bytes), do: Common.feed(state, bytes, &decode_frame/2)
  @impl true
  def stream_finish(state, reason), do: Common.finish(state, reason, &decode_frame/2)

  defp decode_frame(%{terminal?: true} = state, _frame),
    do: {:error, Error.invalid!("Responses event follows terminal"), state}

  defp decode_frame(state, %{data: data}) do
    with {:ok, event} <- Common.decode_json(data),
         :ok <- Validation.term(event, Keyword.get(state.opts, :limits, %{})) do
      decode_event(state, event)
    else
      {:error, error} -> {:error, error, state}
    end
  end

  defp decode_event(
         state,
         %{"type" => "response.output_item.added", "item" => %{"type" => type} = item} = event
       )
       when type in ["custom_tool_call", "function_call"] do
    id = item["id"]

    initial =
      if type == "custom_tool_call", do: item["input"] || "", else: item["arguments"] || ""

    with {:ok, name} <- canonical_identity(item),
         {:ok, _call} <-
           ToolCall.new(
             %{id: item["call_id"], native_id: id, name: name, raw_arguments: {:custom, initial}},
             state.opts
           ),
         :ok <- bound_input(initial, state.opts),
         :ok <- bound_retained(state, id, initial),
         true <-
           is_binary(id) and id != "" and not Map.has_key?(state.tool_calls, id) and
             not MapSet.member?(state.call_ids, item["call_id"]) do
      tool = %{item: item, input: initial, index: event["output_index"], done?: false}

      next = %{
        state
        | tool_calls: Map.put(state.tool_calls, id, tool),
          call_ids: MapSet.put(state.call_ids, item["call_id"])
      }

      {:ok, next, [stream_event(:tool_call_start, tool)]}
    else
      false -> {:error, Error.invalid!("Responses duplicate or missing tool identity"), state}
      {:error, error} -> {:error, error, state}
    end
  end

  defp decode_event(state, %{"type" => type} = event)
       when type in [
              "response.custom_tool_call_input.delta",
              "response.function_call_arguments.delta"
            ] do
    with {:ok, tool} <- fetch_tool(state, event["item_id"]),
         true <- not tool.done? and matches_kind?(tool, type),
         delta when is_binary(delta) <- event["delta"],
         input = tool.input <> delta,
         :ok <- bound_input(input, state.opts),
         :ok <- bound_retained(state, event["item_id"], input) do
      tool = %{tool | input: input}
      next = %{state | tool_calls: Map.put(state.tool_calls, event["item_id"], tool)}
      {:ok, next, [%{stream_event(:tool_call_delta, tool) | arguments_delta: delta}]}
    else
      {:error, error} -> {:error, error, state}
      _ -> {:error, Error.invalid!("Responses invalid tool input delta"), state}
    end
  end

  defp decode_event(state, %{"type" => type} = event)
       when type in [
              "response.custom_tool_call_input.done",
              "response.function_call_arguments.done"
            ] do
    with {:ok, tool} <- fetch_tool(state, event["item_id"]),
         true <- not tool.done? and matches_kind?(tool, type) do
      key = if tool.item["type"] == "custom_tool_call", do: "input", else: "arguments"
      complete_tool(state, event["item_id"], Map.put(tool.item, key, event[key]))
    else
      {:error, error} -> {:error, error, state}
      _ -> {:error, Error.invalid!("Responses duplicate or mismatched tool completion"), state}
    end
  end

  defp decode_event(state, %{
         "type" => "response.output_item.done",
         "item" => %{"type" => type} = item
       })
       when type in ["custom_tool_call", "function_call"],
       do: complete_tool(state, item["id"], item)

  defp decode_event(state, %{"type" => "response.output_text.delta", "delta" => text})
       when is_binary(text),
       do: {:ok, state, [%StreamEvent{type: :text_delta, text: text}]}

  defp decode_event(state, %{"type" => type, "response" => response})
       when type in ["response.completed", "response.incomplete"] do
    with {:ok, decoded} <- decode_response(200, [], response, state.opts),
         :ok <- validate_terminal_tools(state, decoded.output) do
      events = if decoded.usage, do: [%StreamEvent{type: :usage, usage: decoded.usage}], else: []

      {:ok, %{state | terminal?: true},
       events ++
         [
           %StreamEvent{
             type: :terminal,
             stop_reason: decoded.stop_reason,
             completeness: decoded.completeness
           }
         ]}
    else
      {:error, error} -> {:error, error, state}
    end
  end

  defp decode_event(state, %{"type" => type} = event) when type in ["error", "response.failed"] do
    {:error, error} = Common.error(502, event, "OpenAI Responses")
    {:error, error, state}
  end

  defp decode_event(state, %{"type" => type})
       when type in ~w(response.created response.in_progress response.output_item.added response.output_item.done response.content_part.added response.content_part.done response.output_text.done),
       do: {:ok, state, []}

  defp decode_event(state, _),
    do: {:error, Error.invalid!("Unsupported Responses stream event"), state}

  defp complete_tool(state, id, item) do
    with {:ok, tool} <- fetch_tool(state, id),
         {:ok, call} <- decode_call(item, state.opts),
         true <-
           call.id == tool.item["call_id"] and call.name == canonical_name(tool.item) and
             item["type"] == tool.item["type"],
         input = elem(call.raw_arguments, 1),
         :ok <- bound_retained(state, id, input),
         true <- tool.input == "" or tool.input == input do
      if tool.done? do
        if tool.input == input,
          do: {:ok, state, []},
          else: {:error, Error.invalid!("Responses tool completion changed input"), state}
      else
        tool = %{tool | input: input, done?: true}
        block = %ContentBlock{type: :tool_call, tool_call: call}

        {:ok, %{state | tool_calls: Map.put(state.tool_calls, id, tool)},
         [%{stream_event(:tool_call_done, tool) | content: block}]}
      end
    else
      false ->
        {:error,
         Error.invalid!("Responses tool completion conflicts with accumulated input or identity"),
         state}

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp validate_terminal_tools(state, output) do
    calls = for %{tool_call: call} <- output, call != nil, do: call

    if Enum.all?(state.tool_calls, fn {_id, tool} -> tool.done? end) and
         MapSet.new(calls, & &1.id) == state.call_ids and
         Enum.all?(calls, fn call ->
           Enum.any?(state.tool_calls, fn {_id, tool} ->
             tool.item["call_id"] == call.id and canonical_name(tool.item) == call.name and
               tool.input == elem(call.raw_arguments, 1) and
               tool.item["type"] == "custom_tool_call" ==
                 (argument_kind(call.raw_arguments) == :custom)
           end)
         end),
       do: :ok,
       else: invalid("Responses terminal has incomplete or conflicting tool calls")
  end

  defp stream_event(type, tool),
    do: %StreamEvent{
      type: type,
      index: tool.index,
      call_id: tool.item["call_id"],
      native_id: tool.item["id"],
      name: canonical_name(tool.item),
      extensions: %{
        "openai_responses::input_kind" =>
          if(tool.item["type"] == "custom_tool_call", do: "custom", else: "function")
      }
    }

  defp fetch_tool(state, id) do
    case Map.fetch(state.tool_calls, id) do
      {:ok, tool} -> {:ok, tool}
      :error -> invalid("Responses tool event has an unknown item identity")
    end
  end

  defp matches_kind?(tool, type),
    do: tool.item["type"] == "custom_tool_call" == String.contains?(type, "custom_tool_call")

  defp bound_input(input, opts) when is_binary(input) do
    limit = Keyword.get(opts, :max_tool_input_bytes, Validation.default_limits().max_string_bytes)

    if byte_size(input) <= limit,
      do: Validation.term(input, Keyword.get(opts, :limits, %{})),
      else: invalid("Responses tool input exceeds byte limit")
  end

  defp bound_input(_, _opts), do: invalid("Responses tool input must be a string")

  defp bound_retained(state, id, input) do
    count = map_size(state.tool_calls) + if(Map.has_key?(state.tool_calls, id), do: 0, else: 1)

    bytes =
      Enum.reduce(state.tool_calls, byte_size(input), fn
        {^id, _tool}, sum -> sum
        {_id, tool}, sum -> sum + byte_size(tool.input)
      end)

    cond do
      count > Keyword.get(state.opts, :max_tool_calls, 128) ->
        invalid("Responses tool count exceeds limit")

      bytes > Keyword.get(state.opts, :max_total_tool_input_bytes, 1_048_576) ->
        invalid("Responses total tool input exceeds byte limit")

      true ->
        :ok
    end
  end

  defp native_identity(name) do
    case String.split(name, "::") do
      [name] -> %{"name" => name}
      [namespace, name] -> %{"namespace" => namespace, "name" => name}
    end
  end

  defp canonical_identity(%{"name" => name} = item) when is_binary(name) do
    case item["namespace"] do
      nil ->
        if String.contains?(name, "::"),
          do: invalid("Responses native tool name must be unqualified"),
          else: {:ok, name}

      namespace when is_binary(namespace) and namespace != "" ->
        if String.contains?(namespace, "::") or String.contains?(name, "::"),
          do: invalid("Responses native namespace and name must be separate"),
          else: {:ok, namespace <> "::" <> name}

      _ ->
        invalid("Responses tool namespace must be a string")
    end
  end

  defp canonical_identity(_), do: invalid("Responses tool name must be a string")

  defp canonical_name(item) do
    {:ok, name} = canonical_identity(item)
    name
  end

  defp argument_kind({:custom, _}), do: :custom
  defp argument_kind(_), do: :function

  defp unique_ids(calls) do
    if MapSet.size(MapSet.new(calls, & &1.id)) == length(calls),
      do: :ok,
      else: invalid("Duplicate tool call ID")
  end

  defp portable(value) do
    with {:ok, json} <- Serialization.to_json(value), do: Serialization.from_json(json)
  end

  defp usage(nil), do: {:ok, nil}

  defp usage(value) when is_map(value) do
    Usage.new(%{
      mode: :snapshot,
      status:
        if(is_integer(value["input_tokens"]) and is_integer(value["output_tokens"]),
          do: :complete,
          else: :partial
        ),
      source: "openai_responses",
      input_tokens: value["input_tokens"],
      output_tokens: value["output_tokens"],
      native_total: value["total_tokens"],
      cache_read_tokens: get_in(value, ["input_tokens_details", "cached_tokens"]),
      reasoning_tokens: get_in(value, ["output_tokens_details", "reasoning_tokens"])
    })
  end

  defp usage(_), do: invalid("Responses usage must be an object")
  defp stop_reason(%{"status" => "incomplete"}, _output), do: :max_output_tokens

  defp stop_reason(_document, output) do
    cond do
      Enum.any?(output, &(&1.type == :tool_call)) -> :tool_use
      Enum.any?(output, &(&1.type == :refusal)) -> :refusal
      true -> :stop
    end
  end

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp invalid(message), do: {:error, Error.invalid!(message)}
end
