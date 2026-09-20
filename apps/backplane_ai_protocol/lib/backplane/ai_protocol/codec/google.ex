defmodule Backplane.AiProtocol.Codec.Google do
  @moduledoc "Pure Google Gemini GenerateContent request, response, error, and SSE codec."
  @behaviour Backplane.AiProtocol.Codec

  alias Backplane.AiProtocol.{ContentBlock, Error, ProviderState, Request, Response, StreamEvent}
  alias Backplane.AiProtocol.Codec.Common

  @impl true
  def encode_request(%Request{model: model} = request, opts) when is_binary(model) do
    destination = Keyword.put(opts, :model, model)

    with :ok <- Common.reject_state_references(request),
         :ok <- validate_provider_states(request.input, destination),
         {:ok, contents} <- encode_contents(request.input),
         {:ok, declarations} <- encode_tools(request.tools),
         {:ok, system} <- encode_system(request.input) do
      wire = %{
        "model" => model,
        "contents" => contents,
        "stream" => Keyword.get(opts, :stream, false)
      }

      wire =
        if system == [], do: wire, else: Map.put(wire, "systemInstruction", %{"parts" => system})

      wire =
        if declarations == [],
          do: wire,
          else: Map.put(wire, "tools", [%{"functionDeclarations" => declarations}])

      config =
        Map.merge(
          stringify(request.settings || %{}),
          stringify(request.output_constraints || %{})
        )

      {:ok, if(config == %{}, do: wire, else: Map.put(wire, "generationConfig", config))}
    end
  end

  def encode_request(%Request{}, _opts),
    do: {:error, Error.invalid!("Google request model must be a concrete string")}

  @impl true
  def decode_response(status, _headers, body, opts) when status in 200..299 do
    with {:ok, document} <- Common.decode_json(body),
         :ok <- reject_provider_failure(document),
         {:ok, output, reason} <- decode_candidates(document["candidates"], opts),
         {:ok, usage} <- usage(document["usageMetadata"]),
         :ok <- require_completion(reason),
         {:ok, response} <-
           Response.new(%{
             output: output,
             stop_reason: reason,
             completeness: :complete,
             usage: usage,
             resolved_model: document["modelVersion"]
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

    Common.error(status, document, "Google")
  end

  @impl true
  def stream_new(opts), do: Common.stream_state(opts) |> Map.put(:next_tool_id, 0)
  @impl true
  def stream_feed(state, bytes), do: Common.feed(state, bytes, &decode_frame/2)
  @impl true
  def stream_finish(state, reason), do: Common.finish(state, reason, &decode_frame/2)

  defp encode_system(messages) do
    messages
    |> Enum.filter(fn
      %{role: role} -> role in [:system, :developer]
      _ -> false
    end)
    |> Enum.flat_map(& &1.content)
    |> Enum.map(&encode_part/1)
    |> collect()
  end

  defp encode_message(%{role: :tool} = message, call_names) do
    case Map.fetch(call_names, message.tool_call_id) do
      {:ok, name} ->
        key = if(message.status == :error, do: "error", else: "result")

        with {:ok, content} <- Common.tool_result_text(message.content) do
          {:ok,
           %{
             "role" => "user",
             "parts" => [
               %{
                 "functionResponse" => %{
                   "name" => name,
                   "response" => %{key => content}
                 }
               }
             ]
           }}
        end

      :error ->
        {:error, Error.invalid!("Google tool result has no matching tool call")}
    end
  end

  defp encode_message(message, _call_names) do
    with {:ok, parts} <- message.content |> Enum.map(&encode_part/1) |> collect(),
         do:
           {:ok,
            %{
              "role" => if(message.role == :assistant, do: "model", else: "user"),
              "parts" => parts
            }}
  end

  defp encode_part(%ContentBlock{type: :text, text: text}), do: {:ok, %{"text" => text}}

  defp encode_part(%ContentBlock{type: :reasoning, data: text}) when is_binary(text),
    do: {:ok, %{"text" => text, "thought" => true}}

  defp encode_part(%ContentBlock{type: :image, data: image}) do
    with {:ok, {media_type, data}} <- Common.image(image),
         do: {:ok, %{"inlineData" => %{"mimeType" => media_type, "data" => data}}}
  end

  defp encode_part(%ContentBlock{type: :tool_call, tool_call: call}) do
    with {:ok, args} <- Common.json_arguments(call.raw_arguments),
         do:
           {:ok,
            %{
              "functionCall" => %{
                "name" => call.name,
                "args" => args,
                "id" => call.native_id || call.id
              }
            }}
  end

  defp encode_part(%ContentBlock{
         type: :provider_state,
         state: %{kind: "google_thought_signature", payload: payload}
       })
       when is_map(payload),
       do:
         {:ok,
          %{
            "text" => payload["thinking"] || "",
            "thought" => true,
            "thoughtSignature" => payload["signature"]
          }}

  defp encode_part(_), do: {:error, Error.incompatible!("Google cannot preserve content block")}

  defp encode_tools(tools),
    do:
      tools
      |> Enum.map(fn tool ->
        {:ok,
         %{
           "name" => tool.name,
           "description" => tool.description || "",
           "parameters" => tool.input_schema || %{"type" => "object"}
         }}
      end)
      |> collect()

  defp encode_contents(messages) do
    Enum.reduce_while(messages, {:ok, [], %{}}, fn
      %{role: role}, {:ok, contents, names} when role in [:system, :developer] ->
        {:cont, {:ok, contents, names}}

      %ProviderState{}, _acc ->
        {:halt, {:error, Error.incompatible!("Google does not accept root provider state")}}

      message, {:ok, contents, names} ->
        case encode_message(message, names) do
          {:ok, wire} ->
            next_names =
              Enum.reduce(message.content, names, fn
                %ContentBlock{type: :tool_call, tool_call: call}, acc ->
                  Map.put(acc, call.id, call.name)

                _block, acc ->
                  acc
              end)

            {:cont, {:ok, contents ++ [wire], next_names}}

          error ->
            {:halt, error}
        end
    end)
    |> case do
      {:ok, contents, _names} -> {:ok, contents}
      error -> error
    end
  end

  defp decode_candidates(candidates, opts) when is_list(candidates) do
    if length(candidates) > 1 do
      {:error, Error.incompatible!("Google multiple candidates are not supported")}
    else
      candidates
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], :unknown}, fn
        {candidate, candidate_index}, {:ok, output, _}
        when is_map(candidate) ->
          parts = get_in(candidate, ["content", "parts"]) || []

          result =
            parts
            |> Enum.with_index()
            |> Enum.map(fn {part, part_index} ->
              decode_part(part, opts, candidate_index, part_index)
            end)
            |> collect()

          case result do
            {:ok, blocks} ->
              {:cont, {:ok, output ++ blocks, stop_reason(candidate["finishReason"])}}

            error ->
              {:halt, error}
          end

        _candidate, _acc ->
          {:halt, {:error, Error.invalid!("Google candidate must be an object")}}
      end)
    end
  end

  defp decode_candidates(_, _), do: {:error, Error.invalid!("Google candidates must be a list")}

  defp decode_part(
         %{"text" => text, "thought" => true, "thoughtSignature" => signature},
         opts,
         _candidate,
         _part
       )
       when is_binary(signature),
       do: signed_thought(text || "", signature, opts)

  defp decode_part(%{"thoughtSignature" => signature}, _opts, _candidate, _part)
       when is_binary(signature),
       do: {:error, Error.incompatible!("Google signed non-thought content cannot be preserved")}

  defp decode_part(%{"text" => text, "thought" => true}, _opts, _candidate, _part),
    do: ContentBlock.new(%{type: :reasoning, data: text})

  defp decode_part(%{"text" => text}, _opts, _candidate, _part),
    do: ContentBlock.new(%{type: :text, text: text})

  defp decode_part(
         %{"inlineData" => %{"mimeType" => media_type, "data" => data}},
         _opts,
         _candidate,
         _part
       ),
       do:
         ContentBlock.new(%{
           type: :image,
           data: %{"source" => "base64", "media_type" => media_type, "data" => data}
         })

  defp decode_part(%{"functionCall" => call}, _opts, candidate, part) when is_map(call),
    do:
      ContentBlock.new(%{
        type: :tool_call,
        tool_call: %{
          id: call["id"] || "google-#{candidate}-#{part}",
          native_id: call["id"],
          name: call["name"],
          raw_arguments: {:structured, call["args"] || %{}}
        }
      })

  defp decode_part(_, _, _, _),
    do: {:error, Error.incompatible!("Unsupported Google response content")}

  defp signed_thought(thinking, signature, opts) do
    affinity = Common.affinity(opts, "google")

    with {:ok, state} <-
           ProviderState.new(%{
             source_profile: affinity.profile,
             source_protocol: "google",
             kind: "google_thought_signature",
             affinity: affinity,
             payload: %{"thinking" => thinking, "signature" => signature}
           }),
         do: ContentBlock.new(%{type: :provider_state, state: state})
  end

  defp decode_frame(state, %{data: "[DONE]"}) do
    if state.terminal?,
      do: {:ok, %{state | done?: true}, []},
      else:
        {:ok, %{state | terminal?: true, done?: true},
         [%StreamEvent{type: :terminal, stop_reason: :stop, completeness: :complete}]}
  end

  defp decode_frame(state, %{data: data}) do
    with {:ok, event} <- Common.decode_json(data), do: google_event(state, event)
  end

  defp google_event(state, event) do
    case reject_provider_failure(event) do
      :ok ->
        if state.terminal? and (event["candidates"] || []) != [] do
          {:error, Error.incompatible!("Google emitted content after terminal state"), state}
        else
          with {:ok, state, events} <- google_candidates(state, event["candidates"] || [], []),
               {:ok, usage} <- usage(event["usageMetadata"]) do
            {:ok, state,
             events ++ if(usage, do: [%StreamEvent{type: :usage, usage: usage}], else: [])}
          end
        end

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp reject_provider_failure(%{"error" => _error}),
    do: {:error, stream_error("Google")}

  defp reject_provider_failure(%{"promptFeedback" => feedback} = document)
       when is_map(feedback) do
    if (document["candidates"] || []) == [] and not is_nil(feedback["blockReason"]) do
      {:error, Error.incompatible!("Google response was blocked by safety policy")}
    else
      :ok
    end
  end

  defp reject_provider_failure(_document), do: :ok

  defp stream_error(provider),
    do: %Error{
      kind: :upstream_error,
      stage: :response,
      message: "#{provider} provider stream failed",
      upstream_outcome: :known
    }

  defp google_candidates(state, [], events), do: {:ok, state, events}

  defp google_candidates(state, [candidate | rest], events) when is_map(candidate) do
    if rest != [] do
      {:error, Error.incompatible!("Google multiple candidates are not supported"), state}
    else
      index = candidate["index"] || 0
      parts = get_in(candidate, ["content", "parts"]) || []

      with {:ok, state, part_events} <- stream_parts(state, parts, index, []),
           {:ok, state, terminal} <- google_terminal(state, candidate["finishReason"]) do
        google_candidates(state, rest, events ++ part_events ++ terminal)
      end
    end
  end

  defp google_candidates(state, [_candidate | _rest], _events),
    do: {:error, Error.invalid!("Google candidate must be an object"), state}

  defp google_candidates(state, _candidates, _events),
    do: {:error, Error.invalid!("Google candidates must be a list"), state}

  defp stream_parts(state, [], _index, events), do: {:ok, state, events}

  defp stream_parts(state, [%{"text" => text, "thought" => true} = part | rest], index, events) do
    with {:ok, signature_events} <- signature_events(part, text, index, state.opts) do
      stream_parts(
        state,
        rest,
        index,
        events ++
          [%StreamEvent{type: :reasoning_delta, index: index, text: text}] ++ signature_events
      )
    end
  end

  defp stream_parts(
         state,
         [%{"thoughtSignature" => signature} | _rest],
         _index,
         _events
       )
       when is_binary(signature),
       do:
         {:error, Error.incompatible!("Google signed non-thought content cannot be preserved"),
          state}

  defp stream_parts(state, [%{"text" => text} = part | rest], index, events) do
    with {:ok, signature_events} <- signature_events(part, text, index, state.opts) do
      stream_parts(
        state,
        rest,
        index,
        events ++ [%StreamEvent{type: :text_delta, index: index, text: text}] ++ signature_events
      )
    end
  end

  defp stream_parts(
         state,
         [%{"inlineData" => %{"mimeType" => media_type, "data" => data}} = part | rest],
         index,
         events
       ) do
    with {:ok, block} <-
           ContentBlock.new(%{
             type: :image,
             data: %{"source" => "base64", "media_type" => media_type, "data" => data}
           }),
         {:ok, signature_events} <- signature_events(part, nil, index, state.opts) do
      stream_parts(
        state,
        rest,
        index,
        events ++ [%StreamEvent{type: :content, index: index, content: block}] ++ signature_events
      )
    end
  end

  defp stream_parts(state, [%{"functionCall" => call} = part | rest], index, events)
       when is_map(call) do
    id = call["id"] || "google-#{index}-#{state.next_tool_id}"

    pair = [
      %StreamEvent{
        type: :tool_call_start,
        index: index,
        call_id: id,
        native_id: call["id"],
        name: call["name"]
      },
      %StreamEvent{
        type: :tool_call_done,
        index: index,
        call_id: id,
        native_id: call["id"],
        name: call["name"],
        content: call["args"] || %{}
      }
    ]

    if is_binary(call["name"]) and call["name"] != "" and is_map(call["args"] || %{}) do
      with {:ok, signature_events} <- signature_events(part, nil, index, state.opts) do
        stream_parts(
          %{state | next_tool_id: state.next_tool_id + 1},
          rest,
          index,
          events ++ pair ++ signature_events
        )
      end
    else
      {:error, Error.invalid!("Google function call requires a name and object arguments"), state}
    end
  end

  defp stream_parts(state, [_ | _], _index, _events),
    do: {:error, Error.incompatible!("Unsupported Google stream content"), state}

  defp google_terminal(state, nil), do: {:ok, state, []}
  defp google_terminal(%{terminal?: true} = state, _), do: {:ok, state, []}

  defp google_terminal(state, reason),
    do:
      {:ok, %{state | terminal?: true},
       [%StreamEvent{type: :terminal, stop_reason: stop_reason(reason), completeness: :complete}]}

  defp usage(nil), do: {:ok, nil}

  defp usage(value) when is_map(value),
    do:
      Common.usage(%{
        mode: :snapshot,
        status: :complete,
        source: "google",
        input_tokens: value["promptTokenCount"],
        output_tokens: value["candidatesTokenCount"],
        cache_read_tokens: value["cachedContentTokenCount"],
        reasoning_tokens: value["thoughtsTokenCount"],
        native_total: value["totalTokenCount"]
      })

  defp usage(_), do: {:error, Error.invalid!("Google usage must be an object")}
  defp stop_reason("MAX_TOKENS"), do: :max_output_tokens

  defp stop_reason(reason)
       when reason in ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT"], do: :safety

  defp stop_reason("STOP"), do: :stop
  defp stop_reason(nil), do: :unknown
  defp stop_reason(_), do: :unknown

  defp validate_provider_states(items, opts) do
    Enum.reduce_while(items, :ok, fn
      %ProviderState{}, :ok ->
        {:halt, {:error, Error.incompatible!("Google does not accept root provider state")}}

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
        if state.kind == "google_thought_signature" do
          case Common.validate_state_affinity(state, "google", opts) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        else
          {:halt, {:error, Error.incompatible!("Unsupported Google provider state")}}
        end

      _block, :ok ->
        {:cont, :ok}
    end)
  end

  defp signature_events(%{"thoughtSignature" => signature}, thinking, index, opts)
       when is_binary(signature) do
    case signed_thought(thinking || "", signature, opts) do
      {:ok, %{state: provider_state}} ->
        {:ok, [%StreamEvent{type: :provider_state, index: index, provider_state: provider_state}]}

      error ->
        error
    end
  end

  defp signature_events(_part, _thinking, _index, _opts), do: {:ok, []}

  defp require_completion(:unknown),
    do: {:error, Error.invalid!("Google response has no completion reason")}

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
