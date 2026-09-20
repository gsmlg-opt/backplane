defmodule Backplane.AiProtocol.Codec.OpenAI do
  @moduledoc "Pure OpenAI Chat Completions request, response, error, and SSE codec."
  @behaviour Backplane.AiProtocol.Codec

  alias Backplane.AiProtocol.{ContentBlock, Error, ProviderState, Request, Response, StreamEvent}
  alias Backplane.AiProtocol.Codec.Common

  @impl true
  def encode_request(%Request{model: model} = request, opts) when is_binary(model) do
    destination = Keyword.put(opts, :model, model)

    with :ok <- Common.reject_state_references(request),
         :ok <-
           Common.reject_reserved(request.settings, request.output_constraints, [
             "model",
             "messages",
             "tools",
             "stream",
             "reasoning_split"
           ]),
         :ok <- validate_provider_states(request.input, destination),
         {:ok, messages} <- request.input |> Enum.map(&encode_message/1) |> collect(),
         {:ok, tools} <- encode_tools(request.tools) do
      wire = %{
        "model" => model,
        "messages" => messages,
        "stream" => Keyword.get(opts, :stream, false)
      }

      wire = if tools == [], do: wire, else: Map.put(wire, "tools", tools)

      wire =
        wire
        |> Map.merge(stringify(request.settings || %{}))
        |> Map.merge(stringify(request.output_constraints || %{}))

      wire =
        case request.extensions["minimax::reasoning_split"] do
          nil -> wire
          value -> Map.put(wire, "reasoning_split", value)
        end

      {:ok, wire}
    end
  end

  def encode_request(%Request{}, _opts),
    do: {:error, Error.invalid!("OpenAI request model must be a concrete string")}

  @impl true
  def decode_response(status, _headers, body, opts) when status in 200..299 do
    with {:ok, document} <- Common.decode_json(body),
         {:ok, output, reason} <- decode_choices(document["choices"], opts),
         {:ok, usage} <- usage(document["usage"]),
         :ok <- require_completion(reason),
         {:ok, response} <-
           Response.new(%{
             output: output,
             stop_reason: reason,
             completeness: :complete,
             usage: usage,
             resolved_model: document["model"]
           }) do
      {:ok, response}
    end
  end

  def decode_response(status, headers, body, opts), do: decode_error(status, headers, body, opts)

  @impl true
  def decode_error(status, _headers, body, _opts) do
    document =
      case Common.decode_json(body) do
        {:ok, value} -> value
        _ -> %{}
      end

    Common.error(status, document, "OpenAI")
  end

  @impl true
  def stream_new(opts), do: Common.stream_state(opts)
  @impl true
  def stream_feed(state, bytes), do: Common.feed(state, bytes, &decode_frame/2)
  @impl true
  def stream_finish(state, reason), do: Common.finish(state, reason, &decode_frame/2)

  defp encode_message(%{role: :tool} = message) do
    with {:ok, content} <- Common.tool_result_text(message.content) do
      {:ok,
       %{
         "role" => "tool",
         "tool_call_id" => message.tool_call_id,
         "content" => content
       }}
    end
  end

  defp encode_message(%ProviderState{}),
    do: {:error, Error.incompatible!("OpenAI does not accept root provider state")}

  defp encode_message(message) do
    with {:ok, content, tool_calls, reasoning, details} <-
           encode_blocks(message.content, [], [], [], []) do
      wire = %{
        "role" => Atom.to_string(message.role),
        "content" => if(content == [], do: nil, else: content)
      }

      wire = if tool_calls == [], do: wire, else: Map.put(wire, "tool_calls", tool_calls)

      wire =
        if reasoning == [],
          do: wire,
          else: Map.put(wire, "reasoning_content", Enum.join(reasoning, ""))

      wire = if details == [], do: wire, else: Map.put(wire, "reasoning_details", details)
      {:ok, wire}
    end
  end

  defp encode_blocks([], content, calls, reasoning, details),
    do:
      {:ok, Enum.reverse(content), Enum.reverse(calls), Enum.reverse(reasoning),
       Enum.reverse(details)}

  defp encode_blocks(
         [%ContentBlock{type: :text, text: text} | rest],
         content,
         calls,
         reasoning,
         details
       ),
       do:
         encode_blocks(
           rest,
           [%{"type" => "text", "text" => text} | content],
           calls,
           reasoning,
           details
         )

  defp encode_blocks(
         [%ContentBlock{type: :image, data: image} | rest],
         content,
         calls,
         reasoning,
         details
       ) do
    with {:ok, {media_type, data}} <- Common.image(image),
         do:
           encode_blocks(
             rest,
             [
               %{
                 "type" => "image_url",
                 "image_url" => %{"url" => "data:#{media_type};base64,#{data}"}
               }
               | content
             ],
             calls,
             reasoning,
             details
           )
  end

  defp encode_blocks(
         [%ContentBlock{type: :reasoning, data: text} | rest],
         content,
         calls,
         reasoning,
         details
       )
       when is_binary(text), do: encode_blocks(rest, content, calls, [text | reasoning], details)

  defp encode_blocks(
         [%ContentBlock{type: :tool_call, tool_call: call} | rest],
         content,
         calls,
         reasoning,
         details
       ) do
    args =
      case call.raw_arguments do
        {:json, json} -> json
        {:structured, map} -> Jason.encode!(map)
      end

    wire = %{
      "id" => call.native_id || call.id,
      "type" => "function",
      "function" => %{"name" => call.name, "arguments" => args}
    }

    encode_blocks(rest, content, [wire | calls], reasoning, details)
  end

  defp encode_blocks(
         [
           %ContentBlock{
             type: :provider_state,
             state: %{kind: "minimax_reasoning_details", payload: payload}
           }
           | rest
         ],
         content,
         calls,
         reasoning,
         details
       ),
       do: encode_blocks(rest, content, calls, reasoning, [payload | details])

  defp encode_blocks(_, _, _, _, _),
    do: {:error, Error.incompatible!("OpenAI cannot preserve content block")}

  defp encode_tools(tools),
    do:
      tools
      |> Enum.map(fn tool ->
        {:ok,
         %{
           "type" => "function",
           "function" => %{
             "name" => tool.name,
             "description" => tool.description || "",
             "parameters" => tool.input_schema || %{"type" => "object"}
           }
         }}
      end)
      |> collect()

  defp decode_choices(choices, opts) when is_list(choices) do
    if length(choices) > 1 do
      {:error, Error.incompatible!("OpenAI multiple choices are not supported")}
    else
      Enum.reduce_while(choices, {:ok, [], :unknown}, fn
        choice, {:ok, output, _reason} when is_map(choice) ->
          case decode_message(choice["message"] || %{}, opts) do
            {:ok, blocks} ->
              {:cont, {:ok, output ++ blocks, stop_reason(choice["finish_reason"])}}

            error ->
              {:halt, error}
          end

        _choice, _acc ->
          {:halt, {:error, Error.invalid!("OpenAI choice must be an object")}}
      end)
    end
  end

  defp decode_choices(_, _), do: {:error, Error.invalid!("OpenAI choices must be a list")}

  defp decode_message(%{"refusal" => refusal}, _opts) when not is_nil(refusal),
    do: {:error, Error.incompatible!("OpenAI response refusal cannot be preserved")}

  defp decode_message(message, opts) when is_map(message) do
    content =
      case message["content"] do
        nil -> []
        text when is_binary(text) -> [%{type: :text, text: text}]
        parts when is_list(parts) -> Enum.map(parts, &decode_content_part/1)
        _ -> [:invalid]
      end

    reasoning =
      if is_binary(message["reasoning_content"]),
        do: [%{type: :reasoning, data: message["reasoning_content"]}],
        else: []

    details =
      if is_nil(message["reasoning_details"]),
        do: [],
        else: [
          %{
            type: :provider_state,
            state: provider_state("minimax_reasoning_details", message["reasoning_details"], opts)
          }
        ]

    calls = Enum.map(message["tool_calls"] || [], &decode_tool_call/1)

    (content ++ reasoning ++ details ++ calls)
    |> Enum.map(fn
      :invalid -> {:error, Error.incompatible!("Unsupported OpenAI response content")}
      attrs -> ContentBlock.new(attrs)
    end)
    |> collect()
  end

  defp decode_message(_, _), do: {:error, Error.invalid!("OpenAI message must be an object")}

  defp decode_content_part(%{"type" => "text", "text" => text}), do: %{type: :text, text: text}
  defp decode_content_part(_), do: :invalid

  defp decode_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}),
    do: %{
      type: :tool_call,
      tool_call: %{id: id, native_id: id, name: name, raw_arguments: {:json, args}}
    }

  defp decode_tool_call(_), do: :invalid

  defp decode_frame(state, %{data: "[DONE]"}) do
    if state.terminal? do
      {:ok, %{state | done?: true}, []}
    else
      with {:ok, done_events} <- complete_tools(state.tool_calls) do
        {:ok, %{state | terminal?: true, done?: true},
         done_events ++
           [%StreamEvent{type: :terminal, stop_reason: :stop, completeness: :complete}]}
      end
    end
  end

  defp decode_frame(state, %{data: data}) do
    with {:ok, event} <- Common.decode_json(data), do: openai_event(state, event)
  end

  defp openai_event(state, %{"error" => _error}),
    do: {:error, stream_error("OpenAI"), state}

  defp openai_event(state, event) do
    if state.terminal? and (event["choices"] || []) != [] do
      {:error, Error.incompatible!("OpenAI emitted content after terminal state"), state}
    else
      with {:ok, state, events} <- decode_choice_deltas(state, event["choices"] || [], []),
           {:ok, usage} <- usage(event["usage"]) do
        usage_events = if usage, do: [%StreamEvent{type: :usage, usage: usage}], else: []
        {:ok, state, events ++ usage_events}
      end
    end
  end

  defp decode_choice_deltas(state, [], events), do: {:ok, state, events}

  defp decode_choice_deltas(state, choices, _events)
       when is_list(choices) and length(choices) > 1,
       do:
         {:error, Error.incompatible!("OpenAI multiple streamed choices are not supported"),
          state}

  defp decode_choice_deltas(state, [choice | rest], events) do
    if is_map(choice) do
      index = choice["index"] || 0
      delta = choice["delta"] || %{}

      if is_map(delta) do
        events =
          if is_binary(delta["content"]),
            do: events ++ [%StreamEvent{type: :text_delta, index: index, text: delta["content"]}],
            else: events

        events =
          if is_binary(delta["reasoning_content"]),
            do:
              events ++
                [
                  %StreamEvent{
                    type: :reasoning_delta,
                    index: index,
                    text: delta["reasoning_content"]
                  }
                ],
            else: events

        if is_nil(delta["refusal"]) do
          with {:ok, state, reasoning_events} <- reasoning_detail_events(state, index, delta),
               {:ok, state, tool_events} <-
                 decode_tool_deltas(state, delta["tool_calls"] || [], []),
               {:ok, state, terminal_events} <- maybe_terminal(state, choice["finish_reason"]) do
            decode_choice_deltas(
              state,
              rest,
              events ++ reasoning_events ++ tool_events ++ terminal_events
            )
          end
        else
          {:error, Error.incompatible!("OpenAI stream refusal cannot be preserved"), state}
        end
      else
        {:error, Error.invalid!("OpenAI delta must be an object"), state}
      end
    else
      {:error, Error.invalid!("OpenAI choice must be an object"), state}
    end
  end

  defp decode_choice_deltas(state, _choices, _events),
    do: {:error, Error.invalid!("OpenAI choices must be a list"), state}

  defp stream_error(provider),
    do: %Error{
      kind: :upstream_error,
      stage: :response,
      message: "#{provider} provider stream failed",
      upstream_outcome: :known
    }

  defp decode_tool_deltas(state, [], events), do: {:ok, state, events}

  defp decode_tool_deltas(state, [delta | rest], events) do
    if is_map(delta) do
      index = delta["index"]
      function = delta["function"] || %{}
      old = Map.get(state.tool_calls, index, %{id: nil, name: nil, arguments: ""})

      with {:ok, id} <- append_fragment(old.id, delta["id"], "id"),
           {:ok, name} <- append_fragment(old.name, function["name"], "name"),
           {:ok, arguments} <-
             append_fragment(old.arguments, function["arguments"], "arguments") do
        next = %{id: id, name: name, arguments: arguments}

        event = %StreamEvent{
          type: :tool_call_delta,
          index: index,
          call_id: next.id,
          native_id: next.id,
          name: next.name,
          arguments_delta: function["arguments"] || ""
        }

        decode_tool_deltas(
          %{state | tool_calls: Map.put(state.tool_calls, index, next)},
          rest,
          events ++ [event]
        )
      else
        {:error, error} -> {:error, error, state}
      end
    else
      {:error, Error.invalid!("OpenAI tool delta must be an object"), state}
    end
  end

  defp decode_tool_deltas(state, _deltas, _events),
    do: {:error, Error.invalid!("OpenAI tool deltas must be a list"), state}

  defp append_fragment(nil, nil, _field), do: {:ok, nil}
  defp append_fragment(value, nil, _field) when is_binary(value), do: {:ok, value}
  defp append_fragment(nil, fragment, _field) when is_binary(fragment), do: {:ok, fragment}

  defp append_fragment(value, fragment, _field)
       when is_binary(value) and is_binary(fragment),
       do: {:ok, value <> fragment}

  defp append_fragment(_value, _fragment, field),
    do: {:error, Error.invalid!("OpenAI tool #{field} delta must be a string")}

  defp maybe_terminal(state, nil), do: {:ok, state, []}
  defp maybe_terminal(%{terminal?: true} = state, _reason), do: {:ok, state, []}

  defp maybe_terminal(state, reason) do
    with {:ok, done_events} <- complete_tools(state.tool_calls) do
      terminal = %StreamEvent{
        type: :terminal,
        stop_reason: stop_reason(reason),
        completeness: :complete
      }

      {:ok, %{state | terminal?: true}, done_events ++ [terminal]}
    end
  end

  defp complete_tools(tools) do
    tools
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {index, tool}, {:ok, acc} ->
      case {tool.id, tool.name, Jason.decode(tool.arguments)} do
        {id, name, {:ok, value}}
        when is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(value) ->
          {:cont,
           {:ok,
            acc ++
              [
                %StreamEvent{
                  type: :tool_call_done,
                  index: index,
                  call_id: tool.id,
                  native_id: tool.id,
                  name: tool.name,
                  content: value
                }
              ]}}

        _ ->
          {:halt, {:error, Error.invalid!("OpenAI tool arguments are not complete JSON")}}
      end
    end)
  end

  defp usage(nil), do: {:ok, nil}

  defp usage(value) when is_map(value),
    do:
      Common.usage(%{
        mode: :snapshot,
        status: :complete,
        source: "openai",
        input_tokens: value["prompt_tokens"],
        output_tokens: value["completion_tokens"],
        cache_read_tokens: get_in(value, ["prompt_tokens_details", "cached_tokens"]),
        reasoning_tokens: get_in(value, ["completion_tokens_details", "reasoning_tokens"]),
        native_total: value["total_tokens"]
      })

  defp usage(_), do: {:error, Error.invalid!("OpenAI usage must be an object")}
  defp stop_reason("tool_calls"), do: :tool_use
  defp stop_reason("length"), do: :max_output_tokens
  defp stop_reason("content_filter"), do: :safety
  defp stop_reason("stop"), do: :stop
  defp stop_reason(nil), do: :unknown
  defp stop_reason(_), do: :unknown

  defp provider_state(kind, payload, opts) do
    affinity = Common.affinity(opts, "openai")

    {:ok, state} =
      ProviderState.new(%{
        source_profile: affinity.profile,
        source_protocol: "openai",
        kind: kind,
        affinity: affinity,
        payload: payload
      })

    state
  end

  defp validate_provider_states(items, opts) do
    Enum.reduce_while(items, :ok, fn
      %ProviderState{}, :ok ->
        {:halt, {:error, Error.incompatible!("OpenAI does not accept root provider state")}}

      message, :ok ->
        case validate_message_states(message.content, opts) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
    end)
  end

  defp validate_message_states(blocks, opts) do
    Enum.reduce_while(blocks, :ok, fn
      %ContentBlock{type: :provider_state, state: state}, :ok ->
        if state.kind == "minimax_reasoning_details" do
          case Common.validate_state_affinity(state, "openai", opts) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        else
          {:halt, {:error, Error.incompatible!("Unsupported OpenAI provider state")}}
        end

      _block, :ok ->
        {:cont, :ok}
    end)
  end

  defp reasoning_detail_events(state, index, delta) do
    case delta["reasoning_details"] do
      nil ->
        {:ok, state, []}

      details when is_map(details) or is_list(details) ->
        provider_state = provider_state("minimax_reasoning_details", details, state.opts)

        {:ok, state,
         [%StreamEvent{type: :provider_state, index: index, provider_state: provider_state}]}

      _ ->
        {:error, Error.invalid!("OpenAI reasoning_details must be an object or list"), state}
    end
  end

  defp require_completion(:unknown),
    do: {:error, Error.invalid!("OpenAI response has no completion reason")}

  defp require_completion(_reason), do: :ok

  defp collect(results) do
    result =
      Enum.reduce_while(results, {:ok, []}, fn
        {:ok, item}, {:ok, acc} -> {:cont, {:ok, [item | acc]}}
        {:error, _} = error, _acc -> {:halt, error}
      end)

    case result do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
