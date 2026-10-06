defmodule Backplane.Audio.Media.PlanTest do
  use ExUnit.Case, async: true

  alias Backplane.Audio.Media.Plan

  @source %{
    container: :flac,
    codec: :flac,
    sample_rate: 24_000,
    channels: 1,
    duration: 1.0,
    bytes: 10_000,
    source: "/private/input"
  }

  test "six speech profiles are explicit and preserve direct FLAC" do
    assert Map.keys(Plan.speech_profiles()) |> Enum.sort() == ~w(aac flac mp3 opus pcm wav)

    for format <- ~w(mp3 opus aac flac wav pcm) do
      assert {:ok, plan} = Plan.speech(@source, format, %{}, %{})

      assert plan.target.mime in ~w(audio/mpeg audio/ogg audio/aac audio/flac audio/wav application/octet-stream)

      assert plan.target.rate > 0
      assert plan.target.channels == 1
      assert plan.target.muxer in ~w(mp3 ogg adts flac wav s16le)
    end

    assert {:ok, %{strategy: :passthrough}} = Plan.speech(@source, "flac", %{}, %{})
    assert {:ok, %{strategy: :transcode, steps: steps}} = Plan.speech(@source, "opus", %{}, %{})
    assert {:resample, 24_000, 48_000} in steps
  end

  test "ASR remux requires an explicit accepted codec/container pair" do
    webm = %{@source | container: :webm, codec: :opus, sample_rate: 48_000}

    assert {:ok, %{strategy: :transcode, target: %{container: :flac}}} =
             Plan.transcription(webm, %{}, %{})

    assert {:ok, %{strategy: :remux, steps: [:streamcopy, {:mux, "ogg"}]}} =
             Plan.transcription(webm, %{accepted: [{:ogg, :opus}]}, %{})

    assert {:ok, %{strategy: :passthrough}} =
             Plan.transcription(@source, %{accepted: [{:flac, :flac}]}, %{})
  end
end
