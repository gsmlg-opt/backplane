defmodule Backplane.LLM.ContentTiming do
  @moduledoc false

  alias Backplane.AiProtocol.SSE

  @max_total_bytes 8_388_608
  @max_events 10_000
  @max_parse_time_us 250_000
  @feed_slice_bytes 65_536

  def new do
    %{
      framer: SSE.new(max_frame_bytes: 1_048_576, max_buffer_bytes: 2_097_152),
      bytes: 0,
      events: 0,
      parse_time_us: 0,
      first_content_at: nil,
      unavailable: false
    }
  end

  def feed(%{framer: nil} = timing, _chunk, _now, _protocol), do: timing

  def feed(%{first_content_at: first} = timing, _chunk, _now, _protocol)
      when not is_nil(first),
      do: timing

  def feed(timing, chunk, now, protocol) do
    started = System.monotonic_time(:microsecond)
    timing = %{timing | bytes: timing.bytes + byte_size(chunk)}

    timing =
      if timing.bytes > @max_total_bytes do
        unavailable(timing)
      else
        observe_slices(timing, chunk, now, protocol)
      end

    elapsed = max(System.monotonic_time(:microsecond) - started, 0)
    timing = %{timing | parse_time_us: timing.parse_time_us + elapsed}

    if timing.parse_time_us > @max_parse_time_us,
      do: unavailable(timing),
      else: timing
  end

  defp observe_slices(%{framer: nil} = timing, _chunk, _now, _protocol), do: timing

  defp observe_slices(timing, chunk, now, protocol) when byte_size(chunk) > @feed_slice_bytes do
    <<slice::binary-size(@feed_slice_bytes), rest::binary>> = chunk
    timing |> observe_chunk(slice, now, protocol) |> observe_slices(rest, now, protocol)
  end

  defp observe_slices(timing, chunk, now, protocol),
    do: observe_chunk(timing, chunk, now, protocol)

  defp observe_chunk(timing, chunk, now, protocol) do
    case SSE.feed(timing.framer, chunk) do
      {:ok, framer, events} ->
        timing = %{timing | framer: framer, events: timing.events + length(events)}

        if timing.events > @max_events do
          unavailable(timing)
        else
          observe_events(timing, events, now, protocol)
        end

      {:error, _error, framer} ->
        unavailable(%{timing | framer: framer})
    end
  end

  defp observe_events(timing, events, now, protocol) do
    Enum.reduce_while(events, timing, fn event, timing ->
      case Jason.decode(event.data) do
        {:ok, document} when is_map(document) ->
          timing =
            if content?(protocol, document),
              do: %{timing | first_content_at: now, framer: nil},
              else: timing

          if timing.first_content_at,
            do: {:halt, timing},
            else: {:cont, timing}

        _ ->
          if event.data == "[DONE]",
            do: {:cont, timing},
            else: {:halt, unavailable(timing)}
      end
    end)
  end

  defp unavailable(timing),
    do: %{timing | unavailable: true, first_content_at: nil, framer: nil}

  defp content?(:openai_responses, %{"type" => type, "delta" => delta})
       when type in [
              "response.output_text.delta",
              "response.refusal.delta",
              "response.reasoning_text.delta",
              "response.reasoning_summary_text.delta",
              "response.function_call_arguments.delta"
            ],
       do: nonempty?(delta)

  defp content?(:google_antigravity, %{"response" => response}) when is_map(response),
    do: content?(:google_generate_content, response)

  defp content?(protocol, %{"candidates" => candidates})
       when protocol in [:google_generate_content, :google_antigravity] and is_list(candidates),
       do: Enum.any?(candidates, &google_content?/1)

  defp content?(protocol, %{"choices" => choices})
       when protocol in [:legacy, :compact] and is_list(choices),
       do: Enum.any?(choices, &chat_content?/1)

  defp content?(protocol, %{"type" => "content_block_delta", "delta" => delta})
       when protocol in [:legacy, :compact] and is_map(delta),
       do: Enum.any?(["text", "thinking", "partial_json"], &nonempty?(delta[&1]))

  defp content?(protocol, %{"type" => "content_block_start", "content_block" => block})
       when protocol in [:legacy, :compact] and is_map(block) do
    nonempty?(block["text"]) or nonempty?(block["thinking"]) or
      (block["type"] == "tool_use" and is_map(block["input"]) and map_size(block["input"]) > 0)
  end

  defp content?(_protocol, _document), do: false

  defp chat_content?(%{"delta" => delta}) when is_map(delta) do
    Enum.any?(["content", "reasoning_content", "reasoning", "refusal"], &nonempty?(delta[&1])) or
      Enum.any?(List.wrap(delta["tool_calls"]), &tool_arguments?/1) or
      tool_arguments?(%{"function" => delta["function_call"]})
  end

  defp chat_content?(_choice), do: false

  defp tool_arguments?(%{"function" => %{"arguments" => args}}), do: nonempty?(args)
  defp tool_arguments?(_tool), do: false

  defp google_content?(%{"content" => %{"parts" => parts}}) when is_list(parts),
    do: Enum.any?(parts, &google_part?/1)

  defp google_content?(_candidate), do: false

  defp google_part?(%{"text" => text}), do: nonempty?(text)

  defp google_part?(%{"functionCall" => %{"args" => args}})
       when is_map(args),
       do: map_size(args) > 0

  defp google_part?(_part), do: false

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
end
