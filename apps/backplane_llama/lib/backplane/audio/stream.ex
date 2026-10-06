defmodule Backplane.Audio.Stream do
  @moduledoc "Bounded MiniMax SSE decoder for incremental MP3 audio."

  alias Backplane.Audio.{AccessLifecycle, Error}

  defstruct observer: nil,
            buffer: <<>>,
            audio_bytes: 0,
            audio_hash: nil,
            complete?: false,
            event_count: 0,
            max_event_bytes: 1_000_000,
            max_audio_bytes: 100_000_000,
            metadata: %{}

  def new(policy, observer \\ nil) do
    %__MODULE__{
      observer: observer,
      audio_hash: :crypto.hash_init(:sha256),
      max_event_bytes: policy["max_provider_event_bytes"],
      max_audio_bytes: policy["max_output_bytes"]
    }
  end

  def feed(%__MODULE__{} = state, fragment) when is_binary(fragment) do
    cond do
      state.complete? and fragment != <<>> ->
        {:error, invalid("Unexpected audio after final event", "audio_invalid_stream")}

      byte_size(fragment) > 16_384 ->
        {:error, invalid("Provider stream fragment is too large", "audio_stream_too_large")}

      true ->
        parse_events(%{state | buffer: state.buffer <> fragment}, [])
    end
  end

  def finish(%__MODULE__{complete?: true, buffer: buffer, audio_bytes: bytes} = state)
      when buffer in [<<>>, "\n", "\r\n"] and bytes > 0,
      do: {:ok, state}

  def finish(_),
    do: {:error, invalid("Provider audio stream ended early", "audio_incomplete_stream")}

  defp parse_events(state, chunks) do
    case next_event(state.buffer) do
      {:ok, event, rest} ->
        cond do
          byte_size(event) > state.max_event_bytes ->
            {:error, invalid("Provider event is too large", "audio_event_too_large")}

          true ->
            case decode_event(%{state | buffer: rest}, event) do
              {:ok, next, nil} -> parse_events(next, chunks)
              {:ok, next, chunk} -> parse_events(next, [chunk | chunks])
              error -> error
            end
        end

      :more when byte_size(state.buffer) <= state.max_event_bytes ->
        {:ok, state, Enum.reverse(chunks)}

      :more ->
        {:error, invalid("Provider event is too large", "audio_event_too_large")}
    end
  end

  defp next_event(buffer) do
    case :binary.match(buffer, ["\r\n\r\n", "\n\n", "\r\n\n", "\n\r\n"]) do
      {index, length} ->
        {:ok, binary_part(buffer, 0, index),
         binary_part(buffer, index + length, byte_size(buffer) - index - length)}

      :nomatch ->
        :more
    end
  end

  defp decode_event(%__MODULE__{complete?: true}, _event),
    do: {:error, invalid("Unexpected event after final audio", "audio_invalid_stream")}

  defp decode_event(state, event) do
    if event
       |> String.replace("\r\n", "\n")
       |> String.split("\n")
       |> Enum.all?(fn line -> line == "" or String.starts_with?(line, ":") end) do
      {:ok, state, nil}
    else
      decode_data_event(state, event)
    end
  end

  defp decode_data_event(state, event) do
    data =
      event
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&String.trim_leading(String.replace_prefix(&1, "data:", "")))
      |> Enum.join("\n")

    with true <- data != "",
         {:ok, payload} <- Jason.decode(data),
         :ok <- business_status(payload),
         {:ok, chunk} <- audio(payload),
         {:ok, next, emitted} <- apply_event(state, payload, chunk) do
      AccessLifecycle.provider_metadata(next.observer, next.metadata)
      {:ok, %{next | event_count: next.event_count + 1}, emitted}
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> {:error, invalid("Malformed provider audio event", "audio_invalid_stream")}
    end
  end

  defp business_status(%{"base_resp" => %{"status_code" => 0}}), do: :ok

  defp business_status(%{"base_resp" => %{"status_code" => code}}) when is_integer(code),
    do:
      {:error,
       Error.new(
         502,
         "Provider rejected audio synthesis",
         nil,
         "audio_provider_error",
         "api_error"
       )}

  defp business_status(_),
    do: {:error, invalid("Provider audio status is missing", "audio_invalid_response")}

  defp audio(%{"data" => %{"audio" => value}}) when is_binary(value) do
    cond do
      rem(byte_size(value), 2) != 0 ->
        {:error, invalid("Invalid provider audio hex", "audio_invalid_hex")}

      true ->
        case Base.decode16(value, case: :mixed) do
          {:ok, chunk} -> {:ok, chunk}
          :error -> {:error, invalid("Invalid provider audio hex", "audio_invalid_hex")}
        end
    end
  end

  defp audio(%{"data" => %{"audio" => nil}}), do: {:ok, <<>>}

  defp audio(%{"data" => data}) when is_map(data) and not is_map_key(data, "audio"),
    do: {:ok, <<>>}

  defp audio(_), do: {:error, invalid("Provider audio is missing", "audio_invalid_response")}

  defp apply_event(state, %{"data" => %{"status" => 1}}, <<>>),
    do: {:ok, state, nil}

  defp apply_event(state, %{"data" => %{"status" => 1}}, chunk) do
    bytes = state.audio_bytes + byte_size(chunk)

    if bytes <= state.max_audio_bytes do
      {:ok,
       %{state | audio_bytes: bytes, audio_hash: :crypto.hash_update(state.audio_hash, chunk)},
       chunk}
    else
      {:error, invalid("Provider audio exceeds output limit", "audio_output_too_large")}
    end
  end

  defp apply_event(state, %{"data" => %{"status" => 2}} = payload, <<>>) do
    {:ok, %{state | complete?: true, metadata: safe_metadata(payload)}, nil}
  end

  defp apply_event(
         %__MODULE__{audio_bytes: 0} = state,
         %{"data" => %{"status" => 2}} = payload,
         chunk
       ) do
    if byte_size(chunk) <= state.max_audio_bytes do
      {:ok,
       %{
         state
         | complete?: true,
           audio_bytes: byte_size(chunk),
           audio_hash: :crypto.hash_update(state.audio_hash, chunk),
           metadata: safe_metadata(payload)
       }, chunk}
    else
      {:error, invalid("Provider audio exceeds output limit", "audio_output_too_large")}
    end
  end

  defp apply_event(state, %{"data" => %{"status" => 2}} = payload, chunk) do
    matching_aggregate? =
      byte_size(chunk) == state.audio_bytes and
        :crypto.hash(:sha256, chunk) == :crypto.hash_final(state.audio_hash)

    if matching_aggregate? do
      {:ok, %{state | complete?: true, metadata: safe_metadata(payload)}, nil}
    else
      {:error, invalid("Ambiguous final provider audio", "audio_ambiguous_final")}
    end
  end

  defp apply_event(_state, _payload, _chunk),
    do: {:error, invalid("Invalid provider audio status", "audio_invalid_response")}

  defp safe_metadata(payload) do
    extra = if is_map(payload["extra_info"]), do: payload["extra_info"], else: %{}

    %{
      trace_id: safe_trace(payload["trace_id"]),
      usage_characters: safe_integer(extra["usage_characters"], 10_000),
      duration_ms: safe_number(extra["audio_length"], 3_600_000)
    }
  end

  defp safe_trace(value) when is_binary(value) and byte_size(value) <= 128 do
    if Regex.match?(~r/\A[A-Za-z0-9_.:\/-]+\z/, value), do: value, else: nil
  end

  defp safe_trace(_), do: nil

  defp safe_integer(value, limit) when is_integer(value) and value >= 0 and value <= limit,
    do: value

  defp safe_integer(_, _), do: nil

  defp safe_number(value, limit) when is_number(value) and value >= 0 and value <= limit,
    do: value

  defp safe_number(_, _), do: nil

  defp invalid(message, code), do: Error.new(502, message, nil, code, "api_error")
end
