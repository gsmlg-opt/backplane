defmodule Backplane.Audio.Media.Capabilities do
  @moduledoc "Runs the actual sandbox and codec paths used by audio requests."

  alias Backplane.Audio.{Config, Error}
  alias Backplane.Audio.Media.{Plan, Probe, Runner, TempFiles}

  @asr_profiles [
    {"flac/flac", "flac-flac.flac", "flac", :flac, :flac},
    {"mp3/mp3", "mp3-mp3.mp3", "mp3", :mp3, :mp3},
    {"mpga/mp3", "mpga-mp3.mpga", "mpga", :mp3, :mp3},
    {"mp4/aac", "mp4-aac.mp4", "mp4", :mp4, :aac},
    {"m4a/aac", "m4a-aac.m4a", "m4a", :mp4, :aac},
    {"m4a/alac", "m4a-alac.m4a", "m4a", :mp4, :alac},
    {"mpeg/mp2", "mpeg-mp2.mpeg", "mpeg", :mpeg, :mp2},
    {"ogg/opus", "ogg-opus.ogg", "ogg", :ogg, :opus},
    {"ogg/vorbis", "ogg-vorbis.ogg", "ogg", :ogg, :vorbis},
    {"webm/opus", "webm-opus.webm", "webm", :webm, :opus},
    {"wav/pcm_s16le", "wav-pcm_s16le.wav", "wav", :wav, :pcm_s16le}
  ]

  def probe(policy \\ Config.policy(), mode \\ :full)
      when mode in [:full, :speech, :transcription] do
    with true <- Config.policy_valid?(),
         true <- Runner.ready?(),
         true <- TempFiles.ready?(),
         {:ok, handle} <- TempFiles.create(self(), policy) do
      try do
        if TempFiles.reserve(handle, 1_000_000) == :ok,
          do: do_probe(handle, policy, mode),
          else: unavailable()
      after
        # A pinned handle is quarantined, never immediately unlinked.
        TempFiles.release(handle)
      end
    else
      _ -> unavailable()
    end
  end

  defp do_probe(handle, policy, mode) do
    profiles =
      if mode == :transcription,
        do: Map.take(Plan.speech_profiles(), ["flac"]),
        else: Plan.speech_profiles()

    with {:ok, :ready} <- Runner.selftest(handle, policy) do
      {formats, safe?} =
        check_profiles(profiles, fn {format, profile} ->
          {format, codec_available?(handle, format, profile, policy)}
        end)

      {asr_formats, _safe?} =
        if mode == :full and safe?,
          do: check_profiles(@asr_profiles, &asr_available?(handle, &1, policy)),
          else: {%{}, safe?}

      %{
        ready?:
          complete?(formats, map_size(profiles)) and
            (mode != :full or complete?(asr_formats, length(@asr_profiles))),
        sandbox: :ready,
        formats: formats,
        asr_formats: asr_formats
      }
    else
      _ -> unavailable()
    end
  end

  defp check_profiles(profiles, check) do
    Enum.reduce_while(profiles, {%{}, true}, fn profile, {acc, _safe?} ->
      case check.(profile) do
        {name, {:error, %Error{code: "audio_cleanup_uncertain"}}} ->
          {:halt, {Map.put(acc, name, false), false}}

        {name, result} ->
          {:cont, {Map.put(acc, name, result == true), true}}
      end
    end)
  end

  defp complete?(formats, count),
    do: map_size(formats) == count and Enum.all?(formats, fn {_, ready?} -> ready? end)

  defp unavailable,
    do: %{ready?: false, sandbox: :unavailable, formats: %{}, asr_formats: %{}}

  defp asr_available?(handle, {name, fixture, extension, container, codec}, policy) do
    {:ok, input} = TempFiles.path(handle, :input)
    source = Application.app_dir(:backplane_llama, "priv/audio/readiness/#{fixture}")

    result =
      with {:ok, %{size: size}} when size in 1..1_000_000 <- File.stat(source),
           :ok <- TempFiles.reserve(handle, size) do
        result =
          with :ok <- File.cp(source, input),
               {:ok, metadata} <-
                 Probe.inspect(handle, input, %{
                   purpose: :transcription,
                   extension: extension,
                   policy: policy
                 }) do
            metadata.container == container and metadata.codec == codec and metadata.samples > 0
          else
            {:error, %Error{code: "audio_cleanup_uncertain"}} = error -> error
            _ -> false
          end

        unless match?({:error, %Error{code: "audio_cleanup_uncertain"}}, result) do
          File.rm(input)
          TempFiles.release_reservation(handle, size)
        end

        result
      else
        _ -> false
      end

    {name, result}
  end

  defp codec_available?(handle, format, profile, policy) do
    {:ok, output} = TempFiles.path(handle, :staging)
    File.rm(output)

    args = [
      "-nostdin",
      "-hide_banner",
      "-v",
      "error",
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:sample_rate=24000:duration=0.25",
      "-c:a",
      profile.encoder,
      "-ar",
      Integer.to_string(profile.rate),
      "-ac",
      Integer.to_string(profile.channels),
      "-f",
      profile.muxer,
      output
    ]

    result =
      with {:ok, _path, _bytes} <-
             Runner.run(
               handle,
               %{mode: :convert, args: args, output: output, max_bytes: 1_000_000},
               policy
             ),
           {:ok, metadata} <-
             Probe.inspect(handle, output, %{purpose: :speech, format: format, policy: policy}) do
        metadata.container == profile.container and metadata.codec == profile.codec and
          metadata.sample_rate == profile.rate and metadata.channels == profile.channels
      else
        {:error, %Error{code: "audio_cleanup_uncertain"}} = error -> error
        _ -> false
      end

    unless match?({:error, %Error{code: "audio_cleanup_uncertain"}}, result) do
      File.rm(output)
    end

    result
  end
end
