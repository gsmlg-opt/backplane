defmodule Backplane.AiProtocol.Codec.Anthropic do
  @moduledoc """
  Pure Anthropic Messages request, response, error, and SSE codec.

  `prepare_request/2` explicitly projects custom and namespaced tools into native
  Anthropic JSON functions. Keep its returned `codec_options` with that HTTP
  request and pass them unchanged to `decode_response/4` or `stream_new/1`.
  The context is an immutable request-scoped value, never a global registry.

  Legal names retain their spelling. Other canonical names use `bp_` followed by
  the first 60 lowercase hexadecimal SHA-256 digits; all declarations and history
  are collision-checked together. Custom input is exactly `{"input": string}`;
  decoding and replay preserve the original string without whitespace changes.
  Original descriptions remain a verbatim prefix; a metadata section appends the
  canonical identity, input kind, custom format and all tool extensions as JSON.
  `extensions["codex::output_schema"]` can carry a Codex output schema. Formats,
  grammar and output schemas are advisory metadata, not Anthropic enforcement.

  Projected custom stream calls emit a canonical name at start, buffer the JSON
  wrapper, then emit one raw custom delta and a canonical `ContentBlock` at done.
  Their events carry `extensions["anthropic::input_kind"] == "custom"`. Ordinary
  function done events retain their existing input-map content shape.

  `encode_request/2` keeps its strict default and rejects custom/namespaced tools
  unless supplied the options returned by `prepare_request/2`. Nonrepresentable
  input, stale/invalid contexts and unknown response aliases fail explicitly.
  """
  @behaviour Backplane.AiProtocol.Codec

  alias Backplane.AiProtocol.{ContentBlock, Error, ProviderState, Request, Response, StreamEvent}
  alias Backplane.AiProtocol.Codec.Common
  alias Backplane.AiProtocol.Codec.Anthropic.ToolProjection

  @doc "Builds an explicit reversible tool projection and its matching decode options."
  @spec prepare_request(Request.t(), keyword()) ::
          {:ok, %{body: map(), codec_options: keyword()}} | {:error, Error.t()}
  def prepare_request(request, opts \\ [])

  def prepare_request(%Request{} = request, opts) do
    with {:ok, projection} <- ToolProjection.new(request),
         options = ToolProjection.options(opts, projection),
         {:ok, body} <- encode_request(request, options) do
      {:ok, %{body: body, codec_options: options}}
    end
  end

  def prepare_request(_, _),
    do: {:error, Error.invalid!("Anthropic preparation requires a Request")}

  @impl true
  def encode_request(%Request{model: model} = request, opts) when is_binary(model) do
    destination = Keyword.put(opts, :model, model)

    with {:ok, projection} <- ToolProjection.for_request(request, opts),
         :ok <- Backplane.AiProtocol.Media.preflight(request, :anthropic, opts),
         :ok <- reject_unprojected_tools(request, projection),
         :ok <- Common.reject_state_references(request),
         :ok <-
           Common.reject_reserved(request.settings, request.output_constraints, [
             "model",
             "messages",
             "system",
             "tools",
             "stream"
           ]),
         {:ok, messages} <- encode_messages(request.input, destination),
         {:ok, tools} <- encode_tools(request.tools, projection) do
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
        ToolProjection.project_choice(merge_settings(wire, request), projection)
      end
    end
  end

  def encode_request(%Request{}, _opts),
    do: {:error, Error.invalid!("Anthropic request model must be a concrete string")}

  @impl true
  def decode_response(status, _headers, body, opts) when status in 200..299 do
    with {:ok, projection} <- ToolProjection.from_options(opts),
         {:ok, document} <- Common.decode_json(body),
         {:ok, output} <-
           decode_blocks(
             document["content"],
             Keyword.put(opts, :decoded_tool_projection, projection)
           ),
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
    {projection, error} =
      case ToolProjection.from_options(opts) do
        {:ok, projection} -> {projection, nil}
        {:error, error} -> {nil, error}
      end

    Common.stream_state(opts)
    |> Map.put(:blocks, %{})
    |> Map.put(:stop_reason, nil)
    |> Map.put(:tool_projection, projection)
    |> Map.put(:projection_error, error)
    |> Map.put(:tool_input_bytes, 0)
  end

  @impl true
  def stream_feed(%{projection_error: %Error{} = error} = state, _bytes),
    do: {:error, error, state}

  def stream_feed(state, bytes), do: Common.feed(state, bytes, &decode_frame/2)

  @impl true
  def stream_finish(%{projection_error: %Error{} = error} = state, _reason),
    do: {:error, error, state}

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
               message.content |> Enum.map(&encode_message_block(&1, message, opts)) |> collect(),
             do: {:ok, %{"role" => role(message.role), "content" => content}}
    end)
    |> collect()
  end

  defp encode_tool_result(message, opts) do
    with {:ok, content} <-
           message.content |> Enum.map(&encode_message_block(&1, message, opts)) |> collect() do
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

  defp encode_message_block(%ContentBlock{type: type} = block, message, opts)
       when type in [:audio, :resource, :resource_link],
       do: Backplane.AiProtocol.Media.encode(block, :anthropic, message, opts)

  defp encode_message_block(block, _message, opts), do: encode_block(block, opts)

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

  defp encode_block(%ContentBlock{type: :tool_call, tool_call: call}, opts) do
    with {:ok, projection} <- ToolProjection.from_options(opts),
         {:ok, identity} <- ToolProjection.encode_name(call.name, projection),
         {:ok, input} <- ToolProjection.encode_arguments(call.raw_arguments, identity),
         do:
           {:ok,
            %{
              "type" => "tool_use",
              "id" => call.native_id || call.id,
              "name" => identity.wire_name,
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

  defp reject_unprojected_tools(request, nil), do: Common.reject_custom_tools(request)
  defp reject_unprojected_tools(_request, _projection), do: :ok

  defp encode_tools(tools, projection),
    do: tools |> Enum.map(&ToolProjection.encode_tool(&1, projection)) |> collect()

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

  defp decode_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}, opts) do
    with {:ok, identity} <-
           ToolProjection.decode_name(name, Keyword.get(opts, :decoded_tool_projection)),
         {:ok, arguments} <- ToolProjection.decode_arguments(input, identity) do
      ContentBlock.new(%{
        type: :tool_call,
        tool_call: %{id: id, native_id: id, name: identity.name, raw_arguments: arguments}
      })
    end
  end

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
    state = Common.observe_model(state, message["model"])

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
    with :ok <- valid_block_start(state, index, block),
         {:ok, identity} <- stream_identity(block, state.tool_projection) do
      entry = %{
        type: block["type"],
        id: block["id"],
        name: identity.name,
        input_kind: identity.input_kind,
        arguments: "",
        initial_input: block["input"],
        input_bytes: 0,
        thinking: block["thinking"] || "",
        signature: block["signature"],
        closed: false
      }

      events =
        if entry.type == "tool_use",
          do: [tool_stream_event(:tool_call_start, index, entry)],
          else: []

      with {:ok, bytes} <- initial_tool_input_bytes(entry),
           {:ok, entry, state} <- check_tool_budget(state, entry, bytes, true) do
        {:ok, put_in(state.blocks[index], entry), events}
      else
        {:error, error} -> {:error, error, state}
      end
    else
      {:error, error} -> {:error, error, state}
    end
  end

  defp anthropic_event(state, %{
         "type" => "content_block_delta",
         "index" => index,
         "delta" => delta
       }) do
    entry =
      Map.get(state.blocks, index, %{
        type: nil,
        input_kind: :function,
        arguments: "",
        initial_input: nil,
        input_bytes: 0,
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
        if entry.type == "tool_use" and not entry.closed and is_binary(delta["partial_json"]) do
          events =
            if entry.input_kind == :custom,
              do: [],
              else: [
                %{
                  tool_stream_event(:tool_call_delta, index, entry)
                  | arguments_delta: delta["partial_json"]
                }
              ]

          bytes = byte_size(entry.arguments) + byte_size(delta["partial_json"])
          bytes = if bytes == 0, do: entry.input_bytes, else: bytes

          with {:ok, entry, state} <- check_tool_budget(state, entry, bytes, false) do
            {:ok,
             put_in(state.blocks[index], %{
               entry
               | arguments: entry.arguments <> delta["partial_json"],
                 initial_input:
                   if(bytes > 0 and delta["partial_json"] != "",
                     do: nil,
                     else: entry.initial_input
                   )
             }), events}
          else
            {:error, error} -> {:error, error, state}
          end
        else
          {:error, Error.invalid!("Anthropic tool arguments delta has no open tool block"), state}
        end

      _ ->
        {:error, Error.incompatible!("Unsupported Anthropic stream delta"), state}
    end
  end

  defp anthropic_event(state, %{"type" => "content_block_stop", "index" => index}) do
    case state.blocks[index] do
      nil ->
        {:error, Error.invalid!("Anthropic content block stop has no matching start"), state}

      %{closed: true} ->
        {:error, Error.invalid!("Anthropic tool block was already completed"), state}

      %{type: "tool_use"} = entry ->
        with {:ok, value} <- complete_arguments(entry),
             {:ok, events} <- completed_tool_events(index, entry, value) do
          {:ok, put_in(state.blocks[index].closed, true), events}
        else
          {:error, error} -> {:error, error, state}
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

  defp valid_block_start(state, index, block)
       when is_integer(index) and index >= 0 and is_map(block) do
    cond do
      Map.has_key?(state.blocks, index) ->
        {:error, Error.invalid!("Anthropic content block index was already started")}

      block["type"] not in ["text", "thinking", "tool_use"] ->
        {:error, Error.incompatible!("Unsupported Anthropic stream content block")}

      block["type"] == "tool_use" and
          not (is_binary(block["id"]) and byte_size(block["id"]) in 1..256) ->
        {:error, Error.invalid!("Anthropic tool call identity is invalid")}

      block["type"] == "tool_use" and
          Enum.any?(state.blocks, fn {_index, entry} ->
            entry.type == "tool_use" and entry.id == block["id"]
          end) ->
        {:error, Error.invalid!("Anthropic tool call identity was already started")}

      true ->
        :ok
    end
  end

  defp valid_block_start(_state, _index, _block),
    do: {:error, Error.invalid!("Anthropic content block identity is invalid")}

  defp initial_tool_input_bytes(%{type: "tool_use", initial_input: input}) when is_map(input) do
    case Jason.encode(input) do
      {:ok, text} -> {:ok, byte_size(text)}
      _ -> {:error, Error.invalid!("Anthropic initial tool input cannot be encoded")}
    end
  end

  defp initial_tool_input_bytes(_entry), do: {:ok, 0}

  defp check_tool_budget(state, %{type: "tool_use"} = entry, bytes, new?) do
    total = state.tool_input_bytes - entry.input_bytes + bytes
    count = Enum.count(state.blocks, fn {_index, block} -> block.type == "tool_use" end)
    count = if new?, do: count + 1, else: count

    with {:ok, per_call} <- tool_limit(state.opts, :max_tool_input_bytes, 262_144),
         {:ok, all_calls} <- tool_limit(state.opts, :max_total_tool_input_bytes, 1_048_576),
         {:ok, calls} <- tool_limit(state.opts, :max_tool_calls, 128),
         :ok <- within_tool_limit(bytes, per_call, "Anthropic tool input exceeds byte limit"),
         :ok <-
           within_tool_limit(total, all_calls, "Anthropic total tool input exceeds byte limit"),
         :ok <- within_tool_limit(count, calls, "Anthropic tool count exceeds limit") do
      {:ok, %{entry | input_bytes: bytes}, %{state | tool_input_bytes: total}}
    end
  end

  defp check_tool_budget(state, entry, _bytes, _new?), do: {:ok, entry, state}

  defp tool_limit(opts, key, default) do
    case Keyword.get(opts, key, default) do
      limit when is_integer(limit) and limit > 0 -> {:ok, limit}
      _ -> {:error, Error.invalid!("Anthropic tool limits must be positive integers")}
    end
  end

  defp within_tool_limit(value, limit, _message) when value <= limit, do: :ok
  defp within_tool_limit(_value, _limit, message), do: {:error, Error.invalid!(message)}

  defp stream_identity(%{"type" => "tool_use", "name" => name}, projection),
    do: ToolProjection.decode_name(name, projection)

  defp stream_identity(_block, _projection), do: {:ok, %{name: nil, input_kind: :function}}

  defp tool_stream_event(type, index, entry) do
    %StreamEvent{
      type: type,
      index: index,
      call_id: entry.id,
      native_id: entry.id,
      name: entry.name,
      extensions:
        if(entry.input_kind == :custom, do: %{"anthropic::input_kind" => "custom"}, else: %{})
    }
  end

  defp completed_tool_events(index, %{input_kind: :custom} = entry, value) do
    with {:ok, {:custom, text} = arguments} <- ToolProjection.decode_arguments(value, entry),
         {:ok, block} <-
           ContentBlock.new(%{
             type: :tool_call,
             tool_call: %{
               id: entry.id,
               native_id: entry.id,
               name: entry.name,
               raw_arguments: arguments
             }
           }) do
      {:ok,
       [
         %{tool_stream_event(:tool_call_delta, index, entry) | arguments_delta: text},
         %{tool_stream_event(:tool_call_done, index, entry) | content: block}
       ]}
    end
  end

  defp completed_tool_events(index, entry, value),
    do: {:ok, [%{tool_stream_event(:tool_call_done, index, entry) | content: value}]}

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
