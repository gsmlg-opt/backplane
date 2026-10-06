defmodule Backplane.Audio.StreamTest do
  use ExUnit.Case, async: true

  alias Backplane.Audio.Stream

  @policy %{"max_provider_event_bytes" => 1024, "max_output_bytes" => 32}

  test "decodes fragmented SSE MP3 chunks and suppresses an exact final aggregate" do
    first = event(1, "ffd8")
    second = event(1, "ffee")
    final = event(2, "ffd8ffee")
    input = first <> second <> final
    fragments = for <<byte <- input>>, do: <<byte>>

    {decoder, output} =
      Enum.reduce(fragments, {Stream.new(@policy), []}, fn fragment, {decoder, output} ->
        assert {:ok, decoder, chunks} = Stream.feed(decoder, fragment)
        {decoder, output ++ chunks}
      end)

    assert output == [<<0xFF, 0xD8>>, <<0xFF, 0xEE>>]
    assert {:ok, %{audio_bytes: 4, complete?: true}} = Stream.finish(decoder)
  end

  test "final aggregate with different bytes is rejected" do
    assert {:ok, decoder, [_]} = Stream.feed(Stream.new(@policy), event(1, "aabb"))
    assert {:error, %{code: "audio_ambiguous_final"}} = Stream.feed(decoder, event(2, "aacc"))
  end

  test "oversized unfinished events are bounded before JSON decoding" do
    assert {:error, %{code: "audio_event_too_large"}} =
             Stream.feed(Stream.new(@policy), String.duplicate("x", 1025))
  end

  test "truncated stream and malformed hex never complete" do
    assert {:error, %{code: "audio_incomplete_stream"}} =
             Stream.new(@policy) |> Stream.finish()

    assert {:error, %{code: "audio_invalid_hex"}} =
             Stream.feed(Stream.new(@policy), event(1, "xyz"))
  end

  test "split CRLF and comment heartbeats preserve exact audio and final aggregate" do
    input = ": heartbeat\r\n\r\n" <> event(1, "aabb") <> ": ping\r\n\r\n" <> event(2, "aabb")

    {state, audio} =
      Enum.reduce(for(<<b <- input>>, do: <<b>>), {Stream.new(@policy), []}, fn fragment,
                                                                                {state, chunks} ->
        assert {:ok, next, emitted} = Stream.feed(state, fragment)
        {next, chunks ++ emitted}
      end)

    assert IO.iodata_to_binary(audio) == <<0xAA, 0xBB>>
    assert {:ok, %{audio_bytes: 2}} = Stream.finish(state)
  end

  test "empty progress before, between and after chunks preserves audio and aggregate matching" do
    for data <- [
          %{"status" => 1, "audio" => ""},
          %{"status" => 1, "audio" => nil},
          %{"status" => 1}
        ] do
      progress = payload_event(%{"base_resp" => %{"status_code" => 0}, "data" => data})
      input = progress <> event(1, "aabb") <> progress <> event(1, "ccdd") <> progress

      for fragments <- [[input], for(<<byte <- input>>, do: <<byte>>)] do
        {state, chunks} = feed_fragments(fragments, @policy)
        assert chunks == [<<0xAA, 0xBB>>, <<0xCC, 0xDD>>]
        assert state.audio_bytes == 4
        assert state.event_count == 5
        refute state.complete?
        assert state.metadata == %{}
        assert {:ok, final, []} = Stream.feed(state, event(2, "aabbccdd"))
        assert {:ok, %{audio_bytes: 4, event_count: 6}} = Stream.finish(final)
      end
    end
  end

  test "progress leaves accumulated state unchanged except the event count" do
    assert {:ok, state, [_]} = Stream.feed(Stream.new(@policy), event(1, "aabb"))
    assert {:ok, next, []} = Stream.feed(state, event(1, ""))
    assert next == %{state | event_count: state.event_count + 1}
  end

  test "observed MiniMax chunk sizes followed by empty progress and empty completion succeed" do
    policy = %{"max_provider_event_bytes" => 20_000, "max_output_bytes" => 20_000}
    chunks = for size <- [4653, 8064, 1920], do: :binary.copy(<<0xAA>>, size)
    events = Enum.map(chunks, &event(1, Base.encode16(&1))) ++ [event(1, ""), event(2, "")]
    {state, emitted} = feed_fragments(events, policy)
    assert emitted == chunks
    assert {:ok, %{audio_bytes: 14_637, event_count: 5}} = Stream.finish(state)
  end

  test "progress never substitutes for audio or explicit completion" do
    for input <- [event(1, ""), event(1, "") <> event(2, ""), event(1, "aabb") <> event(1, "")] do
      assert {:ok, state, _} = Stream.feed(Stream.new(@policy), input)
      assert {:error, %{code: "audio_incomplete_stream"}} = Stream.finish(state)
    end
  end

  test "business errors before or after audio remain sanitized even with empty progress data" do
    rejected =
      payload_event(%{
        "base_resp" => %{"status_code" => 1004, "status_msg" => "private-provider-secret"},
        "data" => %{"status" => 1, "audio" => ""}
      })

    for prefix <- ["", event(1, "aabb") <> event(1, "")] do
      assert {:ok, state, _} = Stream.feed(Stream.new(@policy), prefix)
      assert {:error, %{code: "audio_provider_error"} = error} = Stream.feed(state, rejected)
      refute inspect(error) =~ "private-provider-secret"
    end
  end

  test "progress requires valid business status, data, audio encoding and explicit status one" do
    for {payload, code} <- [
          {%{"data" => %{"status" => 1, "audio" => ""}}, "audio_invalid_response"},
          {%{"base_resp" => %{"status_code" => 0}, "data" => nil}, "audio_invalid_response"},
          {%{"base_resp" => %{"status_code" => 0}, "data" => %{"audio" => ""}},
           "audio_invalid_response"},
          {%{"base_resp" => %{"status_code" => 0}, "data" => %{"status" => 0, "audio" => ""}},
           "audio_invalid_response"},
          {%{"base_resp" => %{"status_code" => 0}, "data" => %{"status" => "1", "audio" => ""}},
           "audio_invalid_response"},
          {%{"base_resp" => %{"status_code" => 0}, "data" => %{"status" => 1, "audio" => "zz"}},
           "audio_invalid_hex"}
        ] do
      assert {:error, %{code: ^code}} = Stream.feed(Stream.new(@policy), payload_event(payload))
    end
  end

  test "progress after completion fails both in one fragment and a later fragment" do
    assert {:ok, state, [_]} = Stream.feed(Stream.new(@policy), event(2, "aabb"))
    assert {:error, %{code: "audio_invalid_stream"}} = Stream.feed(state, event(1, ""))

    assert {:error, %{code: "audio_invalid_stream"}} =
             Stream.feed(Stream.new(@policy), event(2, "aabb") <> event(1, ""))
  end

  test "progress cannot bypass event, fragment or accumulated audio limits" do
    progress = event(1, "")

    assert {:error, %{code: "audio_event_too_large"}} =
             Stream.feed(Stream.new(%{@policy | "max_provider_event_bytes" => 32}), progress)

    assert {:error, %{code: "audio_stream_too_large"}} =
             Stream.feed(Stream.new(@policy), String.duplicate(progress, 300))

    assert {:ok, state, [_]} =
             Stream.feed(Stream.new(@policy), event(1, String.duplicate("aa", 32)))

    assert {:ok, state, []} = Stream.feed(state, progress)
    assert {:error, %{code: "audio_output_too_large"}} = Stream.feed(state, event(1, "bb"))
  end

  defp feed_fragments(fragments, policy) do
    Enum.reduce(fragments, {Stream.new(policy), []}, fn fragment, {state, chunks} ->
      assert {:ok, next, emitted} = Stream.feed(state, fragment)
      {next, chunks ++ emitted}
    end)
  end

  defp payload_event(payload), do: "data: " <> Jason.encode!(payload) <> "\r\n\r\n"

  defp event(status, audio) do
    payload = %{
      "base_resp" => %{"status_code" => 0},
      "data" => %{"status" => status, "audio" => audio}
    }

    "data: " <> Jason.encode!(payload) <> "\r\n\r\n"
  end
end
