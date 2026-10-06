defmodule Backplane.Audio.Media.FormatTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Backplane.Audio.Config
  alias Backplane.Audio.Media.{Plan, Runner, Session}

  @asr [
    {"flac", "flac", "flac"},
    {"mp3", "libmp3lame", "mp3"},
    {"mpga", "libmp3lame", "mp3"},
    {"mp4", "aac", "mp4"},
    {"m4a", "aac", "ipod"},
    {"m4a", "alac", "ipod"},
    {"mpeg", "mp2", "mpeg"},
    {"ogg", "libopus", "ogg"},
    {"ogg", "vorbis", "ogg"},
    {"webm", "libopus", "webm"},
    {"wav", "pcm_s16le", "wav"}
  ]

  setup do
    assert Runner.ready?(),
           "audio launcher, ffprobe, and FFmpeg must be installed for real codec tests"

    :ok
  end

  test "all six speech responses have real decodable bytes and explicit profiles" do
    for format <- ~w(mp3 opus aac flac wav pcm) do
      {:ok, session} = Session.start(self(), Config.policy())
      {:ok, input} = Session.input_path(session)
      assert :ok = Session.reserve_input(session, 1_000_000)

      ffmpeg!([
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:sample_rate=24000:duration=1",
        "-c:a",
        "flac",
        "-ar",
        "24000",
        "-ac",
        "1",
        "-f",
        "flac",
        input
      ])

      assert {:ok, artifact} = Session.prepare(session, :speech, input, format)
      assert artifact.bytes > 0
      assert File.stat!(artifact.path).size == artifact.bytes
      assert artifact.mime == mime(format)
      assert_decoder!(artifact.path, format)
      profile = Plan.speech_profiles()[format]

      if format == "pcm" do
        assert abs(artifact.bytes / 2 / 24_000 - 1.0) < 0.05
      else
        {json, 0} =
          System.cmd(Runner.executable(:probe), [
            "-v",
            "error",
            "-show_streams",
            "-of",
            "json",
            artifact.path
          ])

        [stream] = Jason.decode!(json)["streams"]
        assert stream["sample_rate"] == Integer.to_string(profile.rate)
        assert stream["channels"] == profile.channels
      end

      assert abs(artifact.plan.source.duration - 1.0) < 0.1
      assert :ok = Session.release(session)
      refute File.exists?(artifact.path)
    end
  end

  test "nine ASR families with their representative codec combinations are decoded before preparation" do
    for {extension, codec, muxer} <- @asr do
      {:ok, session} = Session.start(self(), Config.policy())
      {:ok, input} = Session.input_path(session)
      assert :ok = Session.reserve_input(session, 2_000_000)

      # FFmpeg's built-in Vorbis encoder avoids an optional libvorbis dependency.
      # It requires stereo and explicit experimental encoder opt-in.
      encoder_options = if codec == "vorbis", do: ["-strict", "experimental"], else: []
      channels = if codec == "vorbis", do: "2", else: "1"

      ffmpeg!(
        [
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:sample_rate=24000:duration=0.5",
          "-c:a",
          codec,
          "-ar",
          "24000",
          "-ac",
          channels
        ] ++ encoder_options ++ ["-f", muxer, input]
      )

      assert {:ok, artifact} = Session.prepare(session, :transcription, input, extension, %{})
      assert artifact.bytes > 0
      assert artifact.mime == "audio/flac"
      assert artifact.plan.strategy in [:passthrough, :transcode]
      assert_decoder!(artifact.path, "flac")
      assert :ok = Session.release(session)
    end
  end

  test "filename and MIME hints do not override content inspection" do
    {:ok, session} = Session.start(self(), Config.policy())
    {:ok, input} = Session.input_path(session)
    assert :ok = Session.reserve_input(session, 1_000_000)
    ffmpeg!(["-f", "lavfi", "-i", "sine=duration=0.2", "-c:a", "flac", "-f", "flac", input])

    assert {:error, %{code: "audio_invalid_media"}} =
             Session.prepare(session, :transcription, input, "mp3", %{})

    assert {:error, %{code: "unsupported_audio_format"}} =
             Session.prepare(session, :transcription, input, "pcm", %{})

    assert :ok = Session.release(session)
  end

  test "truncated MP4 and video-only input are rejected before provider use" do
    {:ok, session} = Session.start(self(), Config.policy())
    {:ok, input} = Session.input_path(session)
    assert :ok = Session.reserve_input(session, 2_000_000)
    ffmpeg!(["-f", "lavfi", "-i", "sine=duration=0.5", "-c:a", "aac", "-f", "mp4", input])
    {:ok, bytes} = File.read(input)
    File.write!(input, binary_part(bytes, 0, div(byte_size(bytes), 3)))
    assert {:error, _} = Session.prepare(session, :transcription, input, "mp4", %{})
    assert :ok = Session.release(session)

    {:ok, session} = Session.start(self(), Config.policy())
    {:ok, input} = Session.input_path(session)
    assert :ok = Session.reserve_input(session, 2_000_000)

    ffmpeg!([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=16x16:rate=1:duration=1",
      "-an",
      "-c:v",
      "mpeg4",
      "-f",
      "mp4",
      input
    ])

    assert {:error, %{code: "audio_invalid_media"}} =
             Session.prepare(session, :transcription, input, "mp4", %{})

    assert :ok = Session.release(session)
  end

  test "verified WebM Opus remux preserves audio and prepared byte bounds apply to passthrough" do
    {:ok, session} = Session.start(self(), Config.policy())
    {:ok, input} = Session.input_path(session)
    :ok = Session.reserve_input(session, 1_000_000)
    ffmpeg!(["-f", "lavfi", "-i", "sine=duration=0.5", "-c:a", "libopus", "-f", "webm", input])

    assert {:ok, artifact} =
             Session.prepare(session, :transcription, input, "webm", %{accepted: [{:ogg, :opus}]})

    assert artifact.plan.strategy == :remux
    assert_decoder!(artifact.path, "opus")
    :ok = Session.release(session)

    policy = Map.put(Config.policy(), "upstream_upload_bytes", 32)
    {:ok, session} = Session.start(self(), policy)
    {:ok, input} = Session.input_path(session)
    :ok = Session.reserve_input(session, 1_000_000)
    ffmpeg!(["-f", "lavfi", "-i", "sine=duration=0.2", "-c:a", "flac", "-f", "flac", input])

    assert {:error, %{code: "audio_output_too_large"}} =
             Session.prepare(session, :transcription, input, "flac", %{accepted: [{:flac, :flac}]})

    :ok = Session.release(session)
  end

  test "transcoding cannot hide an upstream byte bound" do
    policy = Map.put(Config.policy(), "upstream_upload_bytes", 1000)
    {:ok, session} = Session.start(self(), policy)
    {:ok, input} = Session.input_path(session)
    :ok = Session.reserve_input(session, 1_000_000)
    ffmpeg!(["-f", "lavfi", "-i", "sine=duration=0.5", "-c:a", "libopus", "-f", "ogg", input])

    assert {:error, %{code: "audio_output_too_large"}} =
             Session.prepare(session, :transcription, input, "ogg", %{})

    :ok = Session.release(session)
  end

  test "speech duration uses its sample budget rather than ASR duration policy" do
    policy = Map.put(Config.policy(), "input_duration_seconds", 1)
    {:ok, session} = Session.start(self(), policy)
    {:ok, input} = Session.input_path(session)
    :ok = Session.reserve_input(session, 1_000_000)

    ffmpeg!([
      "-f",
      "lavfi",
      "-i",
      "sine=duration=2",
      "-c:a",
      "flac",
      "-ar",
      "24000",
      "-ac",
      "1",
      "-f",
      "flac",
      input
    ])

    assert {:ok, artifact} = Session.prepare(session, :speech, input, "flac")
    assert artifact.plan.source.duration > 1.9

    assert {:error, %{code: "audio_duration_limit"}} =
             Session.prepare(session, :transcription, input, "flac")

    :ok = Session.release(session)
  end

  test "ambiguous tracks and forged FLAC duration are rejected" do
    {:ok, session} = Session.start(self(), Config.policy())
    {:ok, input} = Session.input_path(session)
    :ok = Session.reserve_input(session, 2_000_000)

    ffmpeg!([
      "-f",
      "lavfi",
      "-i",
      "sine=duration=0.5",
      "-map",
      "0:a",
      "-map",
      "0:a",
      "-c:a",
      "aac",
      "-f",
      "mp4",
      input
    ])

    assert {:error, %{code: "audio_invalid_media"}} =
             Session.prepare(session, :transcription, input, "mp4")

    :ok = Session.release(session)
    {:ok, session} = Session.start(self(), Config.policy())
    {:ok, input} = Session.input_path(session)
    :ok = Session.reserve_input(session, 2_000_000)
    ffmpeg!(["-f", "lavfi", "-i", "sine=duration=0.5", "-c:a", "flac", "-f", "flac", input])
    <<prefix::binary-size(18), geometry::64, tail::binary>> = File.read!(input)
    forged = (geometry &&& bnot((1 <<< 36) - 1)) ||| 44_100 * 100
    File.write!(input, <<prefix::binary, forged::64, tail::binary>>)

    assert {:error, %{code: "audio_invalid_media"}} =
             Session.prepare(session, :transcription, input, "flac")

    :ok = Session.release(session)
  end

  defp assert_decoder!(path, "pcm") do
    assert rem(File.stat!(path).size, 2) == 0
    ffmpeg!(["-f", "s16le", "-ar", "24000", "-ac", "1", "-i", path, "-f", "null", "/dev/null"])
  end

  defp assert_decoder!(path, "wav") do
    {:ok, <<"RIFF", size::little-32, "WAVE", _::binary>>} = File.read(path)
    assert size + 8 == File.stat!(path).size
    ffmpeg!(["-i", path, "-f", "null", "/dev/null"])
  end

  defp assert_decoder!(path, _format), do: ffmpeg!(["-i", path, "-f", "null", "/dev/null"])

  defp ffmpeg!(args) do
    {output, status} =
      System.cmd(
        Runner.executable(:convert),
        ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"] ++ args,
        stderr_to_stdout: true
      )

    assert status == 0, output
    :ok
  end

  defp mime("mp3"), do: "audio/mpeg"
  defp mime("opus"), do: "audio/ogg"
  defp mime("aac"), do: "audio/aac"
  defp mime("flac"), do: "audio/flac"
  defp mime("wav"), do: "audio/wav"
  defp mime("pcm"), do: "application/octet-stream"
end
