defmodule Backplane.AiProtocol.Codec.Anthropic do
  @moduledoc "Pure Anthropic Messages request, response, error, and SSE codec."
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
             "system",
             "tools",
             "stream"
           ]),
         {:ok, messages} <- encode_messages(request.input, destination),
         {:ok, tools} <- encode_tools(request.tools) do
      system =
        request.input
        |> Enum.filter(fn
          %{role: role} -> role in [:system, :developer]
          _ -> false
        end)
        |> Enum.flat_map(& &1.content)
        |> Enum.map(&encode_block(&1, destination))
        |> collect()

      with {:ok, system} <- system do
        wire = %{
          "model" => model,
          "messages" => messages,
          "stream" => Keyword.get(opts, :stream, false)
        }

        wire = if system == [], do: wire, else: Map.put(wire, "system", system)
        wire = if tools == [], do: wire, else: Map.put(wire, "tools", tools)
        {:ok, merge_settings(wire, request)}
      end
    end
  end

  def encode_request(%Request{}, _opts),
    do: {:error, Error.invalid!("Anthropic request model must be a concrete string")}

  @impl true
  def decode_response(status, _headers, body, opts) when status in 200..299 do
    with {:ok, document} <- Common.decode_json(body),
         {:ok, output} <- decode_blocks(document["content"], opts),
         {:ok, usage} <- usage(document["usage"]),
         {:ok, reason} <- completion_reason(document["stop_reason"]),
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

    Common.error(status, document, "Anthropic")
  end

  @impl true
  def stream_new(opts) do
    Common.stream_state(opts)
    |> Map.put(:blocks, %{})
    |> Map.put(:stop_reason, nil)
  end

  @impl true
  def stream_feed(state, bytes), do: Common.feed(state, bytes, &decode_frame/2)

  @impl true
  def stream_finish(state, reason), do: Common.finish(state, reason, &decode_frame/2)

  defp encode_messages(messages, opts) do
    messages
    |> Enum.reject(fn
      %{role: role} -> role in [:system, :developer]
      _ -> false
    end)
    |> Enum.map(fn
      %ProviderState{} ->
        {:error, Error.incompatible!("Anthropic does not accept root provider state")}

      %{role: :tool} = message ->
        encode_tool_result(message, opts)

      message ->
        with {:ok, content} <-
               message.content |> Enum.map(&encode_block(&1, opts)) |> collect(),
             do: {:ok, %{"role" => role(message.role), "content" => content}}
    end)
    |> collect()
  end

  defp encode_tool_result(message, opts) do
    with {:ok, content} <-
           message.content |> Enum.map(&encode_block(&1, opts)) |> collect() do
      {:ok,
       %{
         "role" => "user",
         "content" => [
           %{
             "type" => "tool_result",
             "tool_use_id" => message.tool_call_id,
             "is_error" => message.status == :error,
             "content" => content
           }
         ]
       }}
    end
  end

  defp encode_block(%ContentBlock{type: :text, text: text}, _opts),
    do: {:ok, %{"type" => "text", "text" => text}}

  defp encode_block(%ContentBlock{type: :reasoning, data: text}, _opts) when is_binary(text),
    do: {:ok, %{"type" => "thinking", "thinking" => text}}

  defp encode_block(%ContentBlock{type: :image, data: image}, _opts) do
    with {:ok, {media_type, data}} <- Common.image(image),
         do:
           {:ok,
            %{
              "type" => "image",
              "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
            }}
  end

  defp encode_block(%ContentBlock{type: :tool_call, tool_call: call}, _opts) do
    with {:ok, input} <- Common.json_arguments(call.raw_arguments),
         do:
           {:ok,
            %{
              "type" => "tool_use",
              "id" => call.native_id || call.id,
              "name" => call.name,
              "input" => input
            }}
  end

  defp encode_block(
         %ContentBlock{
           type: :provider_state,
           state: %{kind: "anthropic_signed_thinking", payload: payload} = state
         },
         opts
       )
       when is_map(payload) do
    with :ok <- Common.validate_state_affinity(state, "anthropic", opts) do
      {:ok,
       %{
         "type" => "thinking",
         "thinking" => payload["thinking"],
         "signature" => payload["signature"]
       }}
    end
  end

  defp encode_block(_, _opts),
    do: {:error, Error.incompatible!("Anthropic cannot preserve content block")}

  defp encode_tools(tools),
    do:
      tools
      |> Enum.map(fn tool ->
        {:ok,
         %{
           "name" => tool.name,
           "description" => tool.description || "",
           "input_schema" => tool.input_schema || %{"type" => "object"}
         }}
      end)
      |> collect()

  defp decode_blocks(blocks, opts) when is_list(blocks),
    do: blocks |> Enum.map(&decode_block(&1, opts)) |> collect()

  defp decode_blocks(_, _), do: {:error, Error.invalid!("Anthropic content must be a list")}

  defp decode_block(%{"type" => "text", "text" => text}, _opts),
    do: ContentBlock.new(%{type: :text, text: text})

  defp decode_block(
         %{"type" => "thinking", "thinking" => thinking, "signature" => signature},
         opts
       ),
       do: signed_thinking(thinking, signature, opts)

  defp decode_block(%{"type" => "thinking", "thinking" => thinking}, _opts),
    do: ContentBlock.new(%{type: :reasoning, data: thinking})

  defp decode_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}, _opts),
    do:
      ContentBlock.new(%{
        type: :tool_call,
        tool_call: %{id: id, native_id: id, name: name, raw_arguments: {:structured, input}}
      })

  defp decode_block(_, _),
    do: {:error, Error.incompatible!("Unsupported Anthropic response content")}

  defp signed_thinking(thinking, signature, opts)
       when is_binary(thinking) and is_binary(signature) do
    affinity = Common.affinity(opts, "anthropic")

    with {:ok, state} <-
           ProviderState.new(%{
             source_profile: affinity.profile,
             source_protocol: "anthropic",
             kind: "anthropic_signed_thinking",
             affinity: affinity,
             payload: %{"thinking" => thinking, "signature" => signature}
           }),
         do: ContentBlock.new(%{type: :provider_state, state: state})
  end

  defp decode_frame(state, %{data: data}) do
    with {:ok, event} <- Common.decode_json(data), do: anthropic_event(state, event)
  end

  defp anthropic_event(%{terminal?: true} = state, %{"type" => type})
       when type in [
              "message_start",
              "content_block_start",
              "content_block_delta",
              "content_block_stop"
            ],
       do: {:error, Error.incompatible!("Anthropic emitted content after terminal state"), state}

  defp anthropic_event(state, %{"type" => "message_start", "message" => message}) do
    case usage(message["usage"]) do
      {:ok, nil} -> {:ok, state, []}
      {:ok, usage} -> {:ok, state, [%StreamEvent{type: :usage, usage: usage}]}
      {:error, error} -> {:error, error, state}
    end
  end

  defp anthropic_event(state, %{
         "type" => "content_block_start",
         "index" => index,
         "content_block" => block
       }) do
    entry = %{
      type: block["type"],
      id: block["id"],
      name: block["name"],
      arguments: "",
      initial_input: block["input"],
      thinking: block["thinking"] || "",
      signature: block["signature"],
      closed: false
    }

    events =
      if entry.type == "tool_use",
        do: [
          %StreamEvent{
            type: :tool_call_start,
            index: index,
            call_id: entry.id,
            native_id: entry.id,
            name: entry.name
          }
        ],
        else: []

    {:ok, put_in(state.blocks[index], entry), events}
  end

  defp anthropic_event(state, %{
         "type" => "content_block_delta",
         "index" => index,
         "delta" => delta
       }) do
    entry =
      Map.get(state.blocks, index, %{
        type: nil,
        arguments: "",
        initial_input: nil,
        thinking: "",
        signature: nil,
        closed: false
      })

    case delta["type"] do
      "text_delta" ->
        {:ok, state, [%StreamEvent{type: :text_delta, index: index, text: delta["text"]}]}

      "thinking_delta" ->
        {:ok,
         put_in(state.blocks[index], %{
           entry
           | thinking: entry.thinking <> (delta["thinking"] || "")
         }), [%StreamEvent{type: :reasoning_delta, index: index, text: delta["thinking"]}]}

      "signature_delta" ->
        {:ok,
         put_in(state.blocks[index], %{
           entry
           | signature: (entry.signature || "") <> (delta["signature"] || "")
         }), []}

      "input_json_delta" ->
        {:ok,
         put_in(state.blocks[index], %{
           entry
           | arguments: entry.arguments <> (delta["partial_json"] || "")
         }),
         [
           %StreamEvent{
             type: :tool_call_delta,
             index: index,
             call_id: entry.id,
             native_id: entry.id,
             name: entry.name,
             arguments_delta: delta["partial_json"]
           }
         ]}

      _ ->
        {:error, Error.incompatible!("Unsupported Anthropic stream delta"), state}
    end
  end

  defp anthropic_event(state, %{"type" => "content_block_stop", "index" => index}) do
    case state.blocks[index] do
      %{type: "tool_use"} = entry ->
        case complete_arguments(entry) do
          {:ok, value} ->
            state = put_in(state.blocks[index].closed, true)

            {:ok, state,
             [
               %StreamEvent{
                 type: :tool_call_done,
                 index: index,
                 call_id: entry.id,
                 native_id: entry.id,
                 name: entry.name,
                 content: value
               }
             ]}

          _ ->
            {:error, Error.invalid!("Anthropic tool arguments are not complete JSON"), state}
        end

      %{type: "thinking", signature: signature, thinking: thinking} when is_binary(signature) ->
        state = put_in(state.blocks[index].closed, true)

        case signed_thinking(thinking, signature, state.opts) do
          {:ok, %{state: provider_state}} ->
            {:ok, state,
             [%StreamEvent{type: :provider_state, index: index, provider_state: provider_state}]}

          {:error, error} ->
            {:error, error, state}
        end

      _ ->
        {:ok, put_in(state.blocks[index].closed, true), []}
    end
  end

  defp anthropic_event(state, %{"type" => "message_delta"} = event) do
    state =
      case get_in(event, ["delta", "stop_reason"]) do
        value when is_binary(value) -> %{state | stop_reason: stop_reason(value)}
        _ -> state
      end

    case usage(event["usage"]) do
      {:ok, nil} -> {:ok, state, []}
      {:ok, usage} -> {:ok, state, [%StreamEvent{type: :usage, usage: usage}]}
      {:error, error} -> {:error, error, state}
    end
  end

  defp anthropic_event(%{terminal?: false} = state, %{"type" => "message_stop"}) do
    if Enum.any?(state.blocks, fn {_index, block} ->
         block.type == "tool_use" and not block.closed
       end) do
      {:error, Error.invalid!("Anthropic tool arguments ended before content_block_stop"), state}
    else
      {:ok, %{state | terminal?: true},
       [
         %StreamEvent{
           type: :terminal,
           stop_reason: state.stop_reason || :stop,
           completeness: :complete
         }
       ]}
    end
  end

  defp anthropic_event(state, %{"type" => "message_stop"}), do: {:ok, state, []}
  defp anthropic_event(state, %{"type" => "ping"}), do: {:ok, state, []}

  defp anthropic_event(%{terminal?: true} = state, _event),
    do: {:error, Error.incompatible!("Anthropic emitted content after terminal state"), state}

  defp anthropic_event(state, %{"type" => "error"} = event) do
    {:error, elem(Common.error(500, event, "Anthropic"), 1), state}
  end

  defp anthropic_event(state, _),
    do: {:error, Error.incompatible!("Unsupported Anthropic stream event"), state}

  defp usage(nil), do: {:ok, nil}

  defp usage(value) when is_map(value),
    do:
      Common.usage(%{
        mode: :snapshot,
        status: :complete,
        source: "anthropic",
        input_tokens: value["input_tokens"],
        output_tokens: value["output_tokens"],
        cache_read_tokens: value["cache_read_input_tokens"],
        cache_write_tokens: value["cache_creation_input_tokens"]
      })

  defp usage(_), do: {:error, Error.invalid!("Anthropic usage must be an object")}

  defp completion_reason(reason) when is_binary(reason), do: {:ok, stop_reason(reason)}

  defp completion_reason(_reason),
    do: {:error, Error.invalid!("Anthropic response has no completion reason")}

  defp stop_reason("tool_use"), do: :tool_use
  defp stop_reason("max_tokens"), do: :max_output_tokens
  defp stop_reason("refusal"), do: :refusal
  defp stop_reason(_), do: :stop
  defp role(:assistant), do: "assistant"
  defp role(_), do: "user"

  defp complete_arguments(%{arguments: "", initial_input: input}) when is_map(input),
    do: {:ok, input}

  defp complete_arguments(%{arguments: arguments}) do
    case Jason.decode(arguments) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, Error.invalid!("Anthropic tool arguments are not complete JSON")}
    end
  end

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

  defp merge_settings(wire, request),
    do:
      wire
      |> Map.merge(stringify(request.settings || %{}))
      |> Map.merge(stringify(request.output_constraints || %{}))

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
