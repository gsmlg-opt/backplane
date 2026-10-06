defmodule Backplane.Audio.RequestTest do
  use ExUnit.Case, async: true

  alias Backplane.Audio.Request

  @speech %{"model" => "tts", "input" => "hello", "voice" => "default"}

  test "speech validates Unicode codepoints and supported options" do
    assert {:ok, %{response_format: "mp3", speed: 1.0}} = Request.speech(@speech)
    assert {:ok, _} = Request.speech(Map.put(@speech, "input", String.duplicate("é", 4096)))

    assert {:error, %{param: "input", code: "input_too_long"}} =
             Request.speech(Map.put(@speech, "input", String.duplicate("é", 4097)))

    # A combining mark counts as a codepoint. This is deliberate and stable.
    assert {:error, %{param: "input"}} =
             Request.speech(Map.put(@speech, "input", String.duplicate("e\u0301", 2049)))

    assert {:ok, %{response_format: "mp3"}} =
             Request.speech(Map.merge(@speech, %{"response_format" => "", "instructions" => nil}))

    assert {:error, %{param: "instructions"}} =
             Request.speech(Map.put(@speech, "instructions", "be cheerful"))

    assert {:error, %{param: "stream_format"}} =
             Request.speech(Map.put(@speech, "stream_format", "sse"))
  end

  test "transcription rejects meaningful unsupported fields and stream true" do
    upload = %Plug.Upload{path: "/tmp/test", filename: "test.wav", content_type: "audio/wav"}
    params = %{"model" => "asr", "file" => upload}
    assert {:ok, %{response_format: "json"}} = Request.transcription(params)

    assert {:ok, %{response_format: "json"}} =
             Request.transcription(Map.merge(params, %{"response_format" => "", "prompt" => ""}))

    assert {:error, %{param: "stream"}} = Request.transcription(Map.put(params, "stream", "true"))

    assert {:error, %{param: "temperature"}} =
             Request.transcription(Map.put(params, "temperature", "0.1"))
  end

  test "optional absent, nil and empty values have the documented meaning" do
    for value <- [nil, ""] do
      assert {:ok, _} =
               Request.speech(
                 Map.merge(@speech, %{
                   "response_format" => value,
                   "instructions" => value,
                   "stream_format" => value
                 })
               )
    end

    for speed <- [0.25, 4.0],
        do: assert({:ok, _} = Request.speech(Map.put(@speech, "speed", speed)))

    for speed <- ["", "1", 0.24, 4.1],
        do: assert({:error, %{param: "speed"}} = Request.speech(Map.put(@speech, "speed", speed)))

    for value <- [nil, "", %{"id" => "custom"}],
        do: assert({:error, %{param: "voice"}} = Request.speech(Map.put(@speech, "voice", value)))

    upload = %Plug.Upload{path: "/tmp/not-read", filename: "x.wav"}
    params = %{"model" => "asr", "file" => upload}

    for value <- [nil, ""] do
      assert {:ok, %{language: nil}} =
               Request.transcription(Map.merge(params, %{"language" => value, "prompt" => value}))
    end

    for value <- [nil, false, "false"],
        do: assert({:ok, _} = Request.transcription(Map.put(params, "stream", value)))

    for value <- [true, "true", ""],
        do:
          assert(
            {:error, %{param: "stream"}} = Request.transcription(Map.put(params, "stream", value))
          )

    for format <- ~w(verbose_json srt vtt diarized_json),
        do:
          assert(
            {:error, %{param: "response_format"}} =
              Request.transcription(Map.put(params, "response_format", format))
          )
  end
end
