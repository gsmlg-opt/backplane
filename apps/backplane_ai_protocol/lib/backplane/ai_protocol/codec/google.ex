defmodule Backplane.AiProtocol.Codec.Google do
  @moduledoc "Pure Google Gemini GenerateContent request, response, error, and SSE codec."
  @behaviour Backplane.AiProtocol.Codec

  alias Backplane.AiProtocol.{ContentBlock, Error, ProviderState, Request, Response, StreamEvent}
  alias Backplane.AiProtocol.Codec.Common

  @impl true
  def encode_request(%Request{model: model} = request, opts) when is_binary(model) do
    with {:ok, %{target: target, body: body}} <- encode_rest_request(request, opts) do
      {:ok, body |> Map.put("model", target.model) |> Map.put("stream", target.stream)}
    end
  end

  def encode_request(%Request{}, _opts),
    do: {:error, Error.invalid!("Google request model must be a concrete string")}

  @doc """
  Encodes Google GenerateContent as a transport target plus its native REST body.

  `model`, `operation`, and `stream` belong to the target and are deliberately absent from the
  body. `encode_request/2` remains the compatibility wrapper for the historical envelope.
  """
  @spec encode_rest_request(Request.t(), keyword()) ::
          {:ok, %{target: map(), body: map()}} | {:error, Error.t()}
  def encode_rest_request(%Request{model: model} = request, opts) when is_binary(model) do
    destination = Keyword.put(opts, :model, model)

    with :ok <- Common.reject_state_references(request),
         :ok <- validate_provider_states(request.input, destination),
         {:ok, contents} <- encode_contents(request.input),
         {:ok, declarations} <- encode_tools(request.tools),
         {:ok, system} <- encode_system(request.input),
         {:ok, config} <- generation_config(request.settings, request.output_constraints) do
      body = %{"contents" => contents}

      body =
        if system == [], do: body, else: Map.put(body, "systemInstruction", %{"parts" => system})

      body =
        if declarations == [],
          do: body,
          else: Map.put(body, "tools", [%{"functionDeclarations" => declarations}])

      body = if config == %{}, do: body, else: Map.put(body, "generationConfig", config)

      {:ok,
       %{
         target: %{
           operation: :generate_content,
           model: model,
           stream: Keyword.get(opts, :stream, false)
         },
         body: body
       }}
    end
  end

  def encode_rest_request(%Request{}, _opts),
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
  def stream_new(opts) do
    Common.stream_state(opts)
    |> Map.merge(%{
      next_tool_id: 0,
      content_finished?: false,
      protocol_complete?: false,
      transport_eof?: false,
      stop_reason: nil,
      unknown_finish_reason: nil,
      usage_snapshot: nil,
      part_positions: %{}
    })
  end

  @impl true
  def stream_feed(state, bytes), do: Common.feed(state, bytes, &decode_frame/2)
  @impl true
  def stream_finish(state, reason),
    do: Common.finish(state, reason, &decode_frame/2, &finish_stream/3)

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

  defp encode_message(%{role: :tool} = message, calls) do
    case Map.fetch(calls, message.tool_call_id) do
      {:ok, call} ->
        with {:ok, response} <- function_response(message) do
          function_response = %{"name" => call.name, "response" => response}

          function_response =
            if call.native_id,
              do: Map.put(function_response, "id", call.native_id),
              else: function_response

          {:ok,
           %{
             "role" => "user",
             "parts" => [%{"functionResponse" => function_response}]
           }}
        end

      :error ->
        {:error, Error.invalid!("Google tool result has no matching tool call")}
    end
  end

  defp encode_message(message, _calls) do
    with {:ok, parts} <- encode_parts(message.content),
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
    with {:ok, args} <- Common.json_arguments(call.raw_arguments) do
      function_call = %{"name" => call.name, "args" => args}

      function_call =
        if call.native_id, do: Map.put(function_call, "id", call.native_id), else: function_call

      {:ok, %{"functionCall" => function_call}}
    end
  end

  defp encode_part(%ContentBlock{
         type: :provider_state,
         state: %{kind: "google_thought_signature", payload: payload}
       })
       when is_map(payload),
       do: encode_provider_state(payload)

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
            next_calls =
              Enum.reduce(message.content, names, fn
                %ContentBlock{type: :tool_call, tool_call: call}, acc ->
                  Map.put(acc, call.id, call)

                _block, acc ->
                  acc
              end)

            {:cont, {:ok, append_content(contents, wire), next_calls}}

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
              {:cont,
               {:ok, output ++ List.flatten(blocks), stop_reason(candidate["finishReason"])}}

            error ->
              {:halt, error}
          end

        _candidate, _acc ->
          {:halt, {:error, Error.invalid!("Google candidate must be an object")}}
      end)
    end
  end

  defp decode_candidates(_, _), do: {:error, Error.invalid!("Google candidates must be a list")}

  defp decode_part(%{"thoughtSignature" => signature} = part, opts, candidate, part_index)
       when is_binary(signature) do
    with {:ok, block} <-
           decode_unsigned_part(Map.delete(part, "thoughtSignature"), candidate, part_index),
         {:ok, state} <- signed_part(part, opts, candidate, part_index) do
      {:ok, [block, state]}
    end
  end

  defp decode_part(part, _opts, candidate, part_index) do
    with {:ok, block} <- decode_unsigned_part(part, candidate, part_index), do: {:ok, [block]}
  end

  defp decode_unsigned_part(%{"text" => text, "thought" => true}, _candidate, _part),
    do: ContentBlock.new(%{type: :reasoning, data: text})

  defp decode_unsigned_part(%{"text" => text}, _candidate, _part),
    do: ContentBlock.new(%{type: :text, text: text})

  defp decode_unsigned_part(
         %{"inlineData" => %{"mimeType" => media_type, "data" => data}},
         _candidate,
         _part
       ),
       do:
         ContentBlock.new(%{
           type: :image,
           data: %{"source" => "base64", "media_type" => media_type, "data" => data}
         })

  defp decode_unsigned_part(%{"functionCall" => call}, candidate, part) when is_map(call),
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

  defp decode_unsigned_part(_, _, _),
    do: {:error, Error.incompatible!("Unsupported Google response content")}

  defp signed_part(part, opts, candidate, part_index) do
    affinity = Common.affinity(opts, "google")

    with :ok <- require_google_affinity(affinity),
         {:ok, state} <-
           ProviderState.new(%{
             source_profile: affinity.profile,
             source_protocol: "google",
             kind: "google_thought_signature",
             affinity: affinity,
             payload: %{
               "part" => part,
               "position" => %{"candidate" => candidate, "part" => part_index}
             }
           }),
         do: ContentBlock.new(%{type: :provider_state, state: state})
  end

  defp decode_frame(state, %{data: "[DONE]"}) do
    {:ok, %{state | done?: true}, []}
  end

  defp decode_frame(state, %{data: data}) do
    with {:ok, event} <- Common.decode_json(data), do: google_event(state, event)
  end

  defp google_event(state, event) do
    case reject_provider_failure(event) do
      :ok ->
        if state.content_finished? and candidate_content?(event["candidates"] || []) do
          {:error, Error.incompatible!("Google emitted content after finish reason"), state}
        else
          with {:ok, state, events} <- google_candidates(state, event["candidates"] || [], []),
               {:ok, state, usage_events} <- stream_usage(state, event["usageMetadata"]) do
            {:ok, state, events ++ usage_events}
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
      raw_parts = get_in(candidate, ["content", "parts"]) || []
      start_position = Map.get(state.part_positions, index, 0)
      parts = Enum.with_index(raw_parts, start_position)

      with {:ok, state, part_events} <- stream_parts(state, parts, index, []),
           {:ok, state} <- google_finish_reason(state, candidate["finishReason"]) do
        state = %{
          state
          | part_positions:
              Map.put(state.part_positions, index, start_position + length(raw_parts))
        }

        google_candidates(state, rest, events ++ part_events)
      end
    end
  end

  defp google_candidates(state, [_candidate | _rest], _events),
    do: {:error, Error.invalid!("Google candidate must be an object"), state}

  defp google_candidates(state, _candidates, _events),
    do: {:error, Error.invalid!("Google candidates must be a list"), state}

  defp stream_parts(state, [], _index, events), do: {:ok, state, events}

  defp stream_parts(
         state,
         [{%{"text" => text, "thought" => true} = part, position} | rest],
         index,
         events
       ) do
    with {:ok, signature_events} <- signature_events(part, index, position, state.opts) do
      stream_parts(
        state,
        rest,
        index,
        events ++
          [%StreamEvent{type: :reasoning_delta, index: index, text: text}] ++ signature_events
      )
    end
  end

  defp stream_parts(state, [{%{"text" => text} = part, position} | rest], index, events) do
    with {:ok, signature_events} <- signature_events(part, index, position, state.opts) do
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
         [
           {%{"inlineData" => %{"mimeType" => media_type, "data" => data}} = part, position}
           | rest
         ],
         index,
         events
       ) do
    with {:ok, block} <-
           ContentBlock.new(%{
             type: :image,
             data: %{"source" => "base64", "media_type" => media_type, "data" => data}
           }),
         {:ok, signature_events} <- signature_events(part, index, position, state.opts) do
      stream_parts(
        state,
        rest,
        index,
        events ++ [%StreamEvent{type: :content, index: index, content: block}] ++ signature_events
      )
    end
  end

  defp stream_parts(
         state,
         [{%{"functionCall" => call} = part, position} | rest],
         index,
         events
       )
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
      with {:ok, signature_events} <- signature_events(part, index, position, state.opts) do
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

  defp google_finish_reason(state, nil), do: {:ok, state}

  defp google_finish_reason(state, reason) do
    case stop_reason(reason) do
      :unknown -> {:ok, %{state | unknown_finish_reason: reason}}
      stop_reason -> {:ok, %{state | content_finished?: true, stop_reason: stop_reason}}
    end
  end

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
          case validate_google_state(state, opts) do
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

  defp signature_events(%{"thoughtSignature" => signature} = part, index, position, opts)
       when is_binary(signature) do
    case signed_part(part, opts, index, position) do
      {:ok, %{state: provider_state}} ->
        {:ok, [%StreamEvent{type: :provider_state, index: index, provider_state: provider_state}]}

      error ->
        error
    end
  end

  defp signature_events(_part, _index, _position, _opts), do: {:ok, []}

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

  defp encode_parts(blocks) do
    Enum.reduce_while(blocks, {:ok, [], 0}, fn block, {:ok, parts, next_position} ->
      case encode_part(block) do
        {:ok,
         %{
           "__google_exact_part__" => exact,
           "__google_position__" => %{"candidate" => 0, "part" => expected_position}
         }}
        when expected_position == next_position - 1 ->
          case parts do
            [previous | rest] ->
              if Map.delete(exact, "thoughtSignature") == previous do
                {:cont, {:ok, [exact | rest], next_position}}
              else
                {:halt,
                 {:error,
                  Error.incompatible!("Google thought signature moved from its original part")}}
              end

            [] ->
              {:halt,
               {:error, Error.incompatible!("Google thought signature has no original part")}}
          end

        {:ok, %{"__google_exact_part__" => _exact}} ->
          {:halt,
           {:error,
            Error.incompatible!("Google thought signature moved from its original position")}}

        {:ok, part} ->
          {:cont, {:ok, [part | parts], next_position + 1}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, parts, _next_position} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  defp encode_provider_state(%{
         "part" => %{"thoughtSignature" => signature} = part,
         "position" => position
       })
       when is_binary(signature),
       do: {:ok, %{"__google_exact_part__" => part, "__google_position__" => position}}

  defp encode_provider_state(_payload),
    do:
      {:error,
       Error.incompatible!("Google provider state requires an exact signed part and position")}

  defp function_response(%{extensions: %{"google::function_response" => response}})
       when is_map(response),
       do: {:ok, response}

  defp function_response(message) do
    key = if(message.status == :error, do: "error", else: "result")
    with {:ok, content} <- Common.tool_result_text(message.content), do: {:ok, %{key => content}}
  end

  defp append_content(contents, %{"role" => "user", "parts" => parts} = wire) do
    case List.last(contents) do
      %{"role" => "user", "parts" => previous_parts} = previous ->
        if function_response_parts?(previous_parts) and function_response_parts?(parts) do
          List.replace_at(contents, -1, %{previous | "parts" => previous_parts ++ parts})
        else
          contents ++ [wire]
        end

      _ ->
        contents ++ [wire]
    end
  end

  defp append_content(contents, wire), do: contents ++ [wire]

  defp function_response_parts?(parts),
    do: parts != [] and Enum.all?(parts, &match?(%{"functionResponse" => %{}}, &1))

  @settings %{
    "temperature" => "temperature",
    "top_p" => "topP",
    "top_k" => "topK",
    "max_output_tokens" => "maxOutputTokens",
    "stop_sequences" => "stopSequences",
    "presence_penalty" => "presencePenalty",
    "frequency_penalty" => "frequencyPenalty",
    "seed" => "seed"
  }
  @output_constraints %{
    "candidate_count" => "candidateCount",
    "response_mime_type" => "responseMimeType",
    "response_schema" => "responseSchema",
    "response_json_schema" => "responseJsonSchema",
    "response_modalities" => "responseModalities"
  }

  defp generation_config(settings, output_constraints) do
    with {:ok, settings} <- map_options(settings || %{}, :settings),
         {:ok, output} <- map_options(output_constraints || %{}, :output_constraints),
         config = Map.merge(settings, output),
         :ok <- validate_candidate_count(config),
         :ok <- validate_modalities(config) do
      {:ok, config}
    end
  end

  defp map_options(options, source) do
    allowed = if source == :settings, do: @settings, else: @output_constraints

    Enum.reduce_while(options, {:ok, %{}}, fn {key, value}, {:ok, mapped} ->
      canonical = to_string(key)

      case Map.fetch(allowed, canonical) do
        {:ok, google_key} -> {:cont, {:ok, Map.put(mapped, google_key, value)}}
        :error -> {:halt, option_error(source, canonical, "unsupported_google_mapping")}
      end
    end)
  end

  defp validate_candidate_count(%{"candidateCount" => 1}), do: :ok

  defp validate_candidate_count(%{"candidateCount" => _}),
    do: option_error(:output_constraints, "candidate_count", "canonical_subset_requires_one")

  defp validate_candidate_count(_), do: :ok
  defp validate_modalities(%{"responseModalities" => ["TEXT"]}), do: :ok

  defp validate_modalities(%{"responseModalities" => _}),
    do: option_error(:output_constraints, "response_modalities", "canonical_subset_requires_text")

  defp validate_modalities(_), do: :ok

  defp option_error(source, field, reason),
    do:
      {:error,
       Error.incompatible!("Google cannot map #{source}.#{field}", %{
         "field" => "#{source}.#{field}",
         "reason" => reason
       })}

  defp validate_google_state(state, opts) do
    with :ok <- require_google_affinity(state.affinity),
         :ok <- require_google_destination(opts) do
      Common.validate_state_affinity(state, "google", opts)
    end
  end

  defp require_google_affinity(affinity) do
    required = [
      profile: affinity.profile,
      endpoint: affinity.endpoint,
      account: affinity.account,
      model: affinity.model,
      credential_scope: affinity.credential_scope,
      credential_version: affinity.credential_version
    ]

    require_affinity_fields(required)
  end

  defp require_google_destination(opts) do
    require_affinity_fields(
      for field <- [:profile, :endpoint, :account, :model, :credential_scope, :credential_version],
          do: {field, Keyword.get(opts, field)}
    )
  end

  defp require_affinity_fields(fields) do
    case Enum.find(fields, fn {_field, value} -> not (is_binary(value) and value != "") end) do
      nil ->
        :ok

      {field, _} ->
        {:error,
         Error.incompatible!("Google signed part requires #{field} affinity", %{
           "field" => "affinity",
           "reason" => "missing_#{field}"
         })}
    end
  end

  defp stream_usage(state, nil), do: {:ok, state, []}

  defp stream_usage(state, metadata) do
    with {:ok, usage} <- usage(metadata) do
      if usage == state.usage_snapshot do
        {:ok, state, []}
      else
        {:ok, %{state | usage_snapshot: usage}, [%StreamEvent{type: :usage, usage: usage}]}
      end
    end
  end

  defp candidate_content?(candidates) when is_list(candidates) do
    Enum.any?(candidates, fn candidate ->
      is_map(candidate) and (get_in(candidate, ["content", "parts"]) || []) != []
    end)
  end

  defp candidate_content?(_), do: false

  defp finish_stream(state, events, :eof) do
    state = %{state | transport_eof?: true}

    cond do
      is_binary(state.unknown_finish_reason) ->
        {:error,
         Error.incompatible!("Google stream used unknown finish reason", %{
           "field" => "finishReason",
           "reason" => state.unknown_finish_reason
         }), state}

      state.content_finished? ->
        terminal = %StreamEvent{
          type: :terminal,
          stop_reason: state.stop_reason,
          completeness: :complete
        }

        {:ok, %{state | terminal?: true, protocol_complete?: true}, events ++ [terminal]}

      true ->
        {:error, incomplete_stream_error(:eof), state}
    end
  end

  defp finish_stream(state, _events, reason),
    do: {:error, incomplete_stream_error(reason), state}

  defp incomplete_stream_error(reason),
    do: %Error{
      kind: :upstream_error,
      stage: :response,
      message: "Provider stream ended before completion",
      upstream_outcome: if(reason == :cancelled, do: :unknown, else: :known),
      partial_output: %{}
    }
end
