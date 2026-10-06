defmodule Backplane.Audio.Adapters.MiniMax do
  @moduledoc "MiniMax's native TTS and file-transcription wire contracts."

  alias Backplane.Audio.{AccessLifecycle, Error, HTTP, Stream}
  alias Backplane.Settings.Credentials
  alias Backplane.Settings.Credentials.Vault

  def credential(%{credential_ref: name}) when is_binary(name) do
    case Vault.get(name) do
      %{kind: kind, metadata: metadata} when kind in ["llm", "service"] ->
        auth_type = Map.get(metadata || %{}, "auth_type")

        if auth_type in [nil, "api_key"] do
          case Credentials.fetch(name) do
            {:ok, secret} when is_binary(secret) and secret != "" ->
              {:ok, secret}

            _ ->
              {:error,
               invalid(503, "Provider credential unavailable", "audio_credential_unavailable")}
          end
        else
          {:error,
           invalid(503, "Provider credential is incompatible", "audio_credential_invalid")}
        end

      _ ->
        {:error, invalid(503, "Provider credential unavailable", "audio_credential_unavailable")}
    end
  end

  def credential(_),
    do: {:error, invalid(503, "Provider credential unavailable", "audio_credential_unavailable")}

  def speech(
        request,
        %{
          resolution: resolution,
          voice: voice,
          secret: secret,
          deadline: deadline,
          policy: policy,
          native_format: native_format
        },
        stream?,
        consumer,
        acc
      ) do
    payload = %{
      model: resolution.model,
      text: request.input,
      stream: stream?,
      output_format: "hex",
      voice_setting: %{voice_id: voice, speed: request.speed},
      audio_setting: %{format: native_format, sample_rate: 24_000, channel: 1}
    }

    payload =
      if stream?,
        do: Map.put(payload, :stream_options, %{exclude_aggregated_audio: true}),
        else: payload

    headers = [
      {"authorization", "Bearer " <> secret},
      {"content-type", "application/json"},
      {"accept", if(stream?, do: "text/event-stream", else: "application/json")}
    ]

    if stream? do
      decoder = Stream.new(policy, request[:observer])

      initial = %{
        decoder: decoder,
        acc: acc,
        first_audio: <<>>,
        validated?: false,
        response_mode: nil,
        error_body: <<>>,
        error_limit:
          Enum.min([
            65_536,
            policy["max_provider_event_bytes"],
            policy["max_provider_response_bytes"]
          ])
      }

      receiver = fn fragment, response, state ->
        AccessLifecycle.first_byte(request[:observer])
        mode = state.response_mode || stream_response_mode(response.headers)
        receive_speech_fragment(fragment, request, consumer, %{state | response_mode: mode})
      end

      case observed_post(
             request,
             fn ->
               HTTP.post(
                 resolution.api_origin,
                 "/v1/t2a_v2",
                 headers,
                 Jason.encode!(payload),
                 deadline,
                 policy["max_provider_response_bytes"],
                 receiver,
                 initial
               )
             end,
             initial
           ) do
        {:ok, _, _, %{response_mode: :sse, decoder: decoder, acc: acc, validated?: validated?}} ->
          case Stream.finish(decoder) do
            {:ok, decoder} when validated? ->
              {:ok, acc,
               Map.merge(decoder.metadata, %{output_bytes: decoder.audio_bytes, strategy: :stream})}

            {:ok, _} ->
              {:error, invalid(502, "Invalid MP3 stream", "audio_invalid_response"), acc,
               %{strategy: :stream}}

            {:error, error} ->
              {:error, error, acc, %{strategy: :stream, uncertain_execution: true}}
          end

        {:ok, _, _, state} ->
          {:error, decode_stream_rejection(state), state.acc,
           %{strategy: :stream, uncertain_execution: true}}

        {:error, error, %{acc: acc}} ->
          {:error, error, acc, %{strategy: :stream, uncertain_execution: true}}
      end
    else
      receiver = fn fragment, chunks ->
        AccessLifecycle.first_byte(request[:observer])
        {:ok, [fragment | chunks]}
      end

      case observed_post(
             request,
             fn ->
               HTTP.post(
                 resolution.api_origin,
                 "/v1/t2a_v2",
                 headers,
                 Jason.encode!(payload),
                 deadline,
                 policy["max_provider_response_bytes"],
                 receiver,
                 []
               )
             end,
             []
           ) do
        {:ok, _, _, chunks} ->
          with {:ok, audio, metadata} <-
                 decode_speech(IO.iodata_to_binary(Enum.reverse(chunks)), policy),
               :ok <- observe_metadata(request, metadata),
               _ <-
                 AccessLifecycle.update(request[:observer], %{upstream_bytes: byte_size(audio)}),
               {:ok, acc} <- consumer.({:chunk, audio}, acc) do
            {:ok, acc,
             Map.merge(metadata, %{output_bytes: byte_size(audio), strategy: :buffered})}
          else
            {:error, %Error{} = error} ->
              {:error, error, acc, %{strategy: :buffered, uncertain_execution: true}}

            {:error, %Error{} = error, next_acc} ->
              {:error, error, next_acc, %{strategy: :buffered, uncertain_execution: true}}
          end

        {:error, error, _} ->
          {:error, error, acc, %{strategy: :buffered, uncertain_execution: true}}
      end
    end
  end

  def transcription(request, resolution, prepared, secret, deadline, policy) do
    extension = prepared.plan.target.extension
    mime = prepared.mime

    multipart =
      Req.Utils.encode_form_multipart([
        {"model", resolution.model},
        {"response_format", "json"},
        {"file",
         {File.stream!(prepared.path, 32_768), filename: "audio.#{extension}", content_type: mime}}
      ])

    headers = [
      {"authorization", "Bearer " <> secret},
      {"content-type", multipart.content_type},
      {"accept", "application/json"}
    ]

    headers = if request.language, do: [{"language", request.language} | headers], else: headers

    receiver = fn fragment, chunks ->
      AccessLifecycle.first_byte(request[:observer])
      {:ok, [fragment | chunks]}
    end

    case observed_post(
           request,
           fn ->
             HTTP.post(
               resolution.api_origin,
               "/v1/speech_to_text",
               headers,
               {:enumerable, multipart.size, multipart.body},
               deadline,
               policy["max_provider_response_bytes"],
               receiver,
               []
             )
           end,
           []
         ) do
      {:ok, _, _, chunks} ->
        case decode_transcription(IO.iodata_to_binary(Enum.reverse(chunks))) do
          {:ok, text, metadata} ->
            observe_metadata(request, metadata)
            {:ok, text, metadata}

          {:error, error} ->
            {:error, error, %{uncertain_execution: true}}
        end

      {:error, error, _} ->
        {:error, error, %{uncertain_execution: true}}
    end
  end

  defp observed_post(request, send_request, initial) do
    observer = request[:observer]

    case AccessLifecycle.dispatched(observer) do
      :ok ->
        AccessLifecycle.measure(observer, :upstream_ms, send_request)

      {:error, :closed} ->
        {:error, invalid(504, "Audio deadline expired", "audio_deadline"), initial}
    end
  end

  defp observe_metadata(request, metadata) do
    AccessLifecycle.provider_metadata(request[:observer], metadata)
    :ok
  end

  defp stream_response_mode(headers) do
    types =
      for {name, value} <- headers, String.downcase(name) == "content-type" do
        value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
      end

    case types do
      ["text/event-stream"] ->
        :sse

      ["application/json"] ->
        :json

      ["application/" <> subtype] ->
        if String.ends_with?(subtype, "+json"), do: :json, else: :invalid

      _ ->
        :invalid
    end
  end

  defp receive_speech_fragment(fragment, request, consumer, %{response_mode: :sse} = state) do
    with {:ok, decoder, chunks} <- Stream.feed(state.decoder, fragment),
         :ok <- observe_metadata(request, decoder.metadata),
         _ <- AccessLifecycle.update(request[:observer], %{upstream_bytes: decoder.audio_bytes}),
         {:ok, next} <- emit_checked_chunks(chunks, consumer, %{state | decoder: decoder}) do
      {:ok, next}
    else
      {:error, %Error{} = error} -> {:error, error, state}
      {:error, reason, next} -> {:error, reason, next}
    end
  end

  defp receive_speech_fragment(fragment, _request, _consumer, %{response_mode: :json} = state) do
    if byte_size(state.error_body) + byte_size(fragment) <= state.error_limit do
      {:ok, %{state | error_body: state.error_body <> fragment}}
    else
      {:error, invalid_stream_response(), state}
    end
  end

  defp receive_speech_fragment(_fragment, _request, _consumer, state),
    do: {:error, invalid_stream_response(), state}

  defp decode_stream_rejection(%{response_mode: :json, error_body: body}) do
    case Jason.decode(body) do
      {:ok, %{"base_resp" => %{"status_code" => code}}} when is_integer(code) and code != 0 ->
        invalid(502, "Provider rejected audio synthesis", "audio_provider_error")

      _ ->
        invalid_stream_response()
    end
  end

  defp decode_stream_rejection(_state), do: invalid_stream_response()

  defp invalid_stream_response,
    do: invalid(502, "Invalid provider streaming response", "audio_invalid_response")

  defp emit_chunks([], _consumer, acc), do: {:ok, acc}

  defp emit_chunks([chunk | rest], consumer, acc) do
    case consumer.({:chunk, chunk}, acc) do
      {:ok, next} -> emit_chunks(rest, consumer, next)
      {:error, reason, next} -> {:error, reason, next}
    end
  end

  defp emit_checked_chunks([], _consumer, state), do: {:ok, state}

  defp emit_checked_chunks(chunks, consumer, %{validated?: true} = state) do
    case emit_chunks(chunks, consumer, state.acc) do
      {:ok, acc} -> {:ok, %{state | acc: acc}}
      {:error, reason, acc} -> {:error, reason, %{state | acc: acc}}
    end
  end

  defp emit_checked_chunks([chunk | rest], consumer, state) do
    combined = state.first_audio <> chunk

    cond do
      byte_size(combined) > 65_536 ->
        {:error, invalid(502, "Invalid MP3 stream", "audio_invalid_response"), state}

      mp3_start(combined) == :more ->
        emit_checked_chunks(rest, consumer, %{state | first_audio: combined})

      mp3_start(combined) == :ok ->
        case consumer.({:chunk, combined}, state.acc) do
          {:ok, acc} ->
            emit_checked_chunks(rest, consumer, %{
              state
              | first_audio: <<>>,
                validated?: true,
                acc: acc
            })

          {:error, reason, acc} ->
            {:error, reason, %{state | acc: acc}}
        end

      true ->
        {:error, invalid(502, "Invalid MP3 stream", "audio_invalid_response"), state}
    end
  end

  defp mp3_start(bytes) when byte_size(bytes) < 4, do: :more
  defp mp3_start(<<"ID3", _::binary>> = bytes) when byte_size(bytes) < 10, do: :more

  defp mp3_start(<<"ID3", _version::binary-size(2), flags, a, b, c, d, _::binary>> = bytes) do
    if Enum.all?([a, b, c, d], &(&1 < 128)) and flags < 128 do
      offset = 10 + a * 2_097_152 + b * 16_384 + c * 128 + d

      if byte_size(bytes) < offset + 4,
        do: :more,
        else: bytes |> binary_part(offset, byte_size(bytes) - offset) |> mp3_start()
    else
      :invalid
    end
  end

  defp mp3_start(bytes) do
    case mp3_frame_size(bytes) do
      {:ok, frame_bytes} when byte_size(bytes) < frame_bytes + 4 ->
        :more

      {:ok, frame_bytes} ->
        next = binary_part(bytes, frame_bytes, byte_size(bytes) - frame_bytes)
        if match?({:ok, _}, mp3_frame_size(next)), do: :ok, else: :invalid

      :invalid ->
        :invalid
    end
  end

  defp mp3_frame_size(<<0xFF, second, third, _fourth, _::binary>>) do
    version = Bitwise.band(second, 0x18)
    layer = Bitwise.band(second, 0x06)
    bitrate_index = Bitwise.bsr(Bitwise.band(third, 0xF0), 4)
    sample_index = Bitwise.bsr(Bitwise.band(third, 0x0C), 2)
    padding = Bitwise.bsr(Bitwise.band(third, 0x02), 1)

    if Bitwise.band(second, 0xE0) == 0xE0 and version != 0x08 and layer == 0x02 and
         bitrate_index in 1..14 and sample_index in 0..2 do
      bitrates =
        if version == 0x18,
          do: [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
          else: [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

      rates =
        case version do
          0x18 -> [44_100, 48_000, 32_000]
          0x10 -> [22_050, 24_000, 16_000]
          _ -> [11_025, 12_000, 8_000]
        end

      factor = if version == 0x18, do: 144, else: 72

      {:ok,
       div(factor * Enum.at(bitrates, bitrate_index - 1) * 1_000, Enum.at(rates, sample_index)) +
         padding}
    else
      :invalid
    end
  end

  defp mp3_frame_size(_), do: :invalid

  defp decode_speech(body, policy) do
    with {:ok, %{"base_resp" => %{"status_code" => 0}, "data" => %{"audio" => hex}} = payload} <-
           Jason.decode(body),
         true <- is_binary(hex) and rem(byte_size(hex), 2) == 0,
         {:ok, audio} <- Base.decode16(hex, case: :mixed),
         true <- byte_size(audio) > 0 and byte_size(audio) <= policy["max_output_bytes"] do
      extra = if is_map(payload["extra_info"]), do: payload["extra_info"], else: %{}

      {:ok, audio,
       safe_metadata(payload["trace_id"], extra["usage_characters"], extra["audio_length"])}
    else
      {:ok, %{"base_resp" => %{"status_code" => code}}} when code != 0 ->
        {:error, invalid(502, "Provider rejected audio synthesis", "audio_provider_error")}

      _ ->
        {:error, invalid(502, "Invalid provider audio response", "audio_invalid_response")}
    end
  end

  defp decode_transcription(body) do
    with {:ok, %{"text" => text} = payload} <- Jason.decode(body),
         :ok <- asr_status(payload),
         true <- is_binary(text) and String.valid?(text) do
      {:ok, text,
       safe_metadata(payload["trace_id"], nil, nil)
       |> Map.put(:duration_seconds, safe_number(payload["duration"], 500))}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      _ ->
        {:error,
         invalid(502, "Invalid provider transcription response", "audio_invalid_response")}
    end
  end

  defp asr_status(%{"base_resp" => %{"status_code" => 0}}), do: :ok

  defp asr_status(%{"base_resp" => %{"status_code" => code}}) when is_integer(code),
    do: {:error, invalid(502, "Provider rejected transcription", "audio_provider_error")}

  defp asr_status(%{"base_resp" => _}),
    do: {:error, invalid(502, "Invalid provider transcription status", "audio_invalid_response")}

  defp asr_status(_), do: :ok

  defp safe_metadata(trace, characters, duration) do
    %{
      trace_id:
        if(
          is_binary(trace) and byte_size(trace) <= 128 and
            Regex.match?(~r/\A[A-Za-z0-9_.:\/-]+\z/, trace),
          do: trace,
          else: nil
        ),
      usage_characters:
        if(is_integer(characters) and characters >= 0 and characters <= 10_000,
          do: characters,
          else: nil
        ),
      duration_ms: safe_number(duration, 3_600_000)
    }
  end

  defp safe_number(value, maximum) when is_number(value) and value >= 0 and value <= maximum,
    do: value

  defp safe_number(_, _), do: nil

  defp invalid(status, message, code), do: Error.new(status, message, nil, code, "api_error")
end
