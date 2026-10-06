defmodule Backplane.Audio.Media.Plan do
  @moduledoc "Deterministic media conversion plans with explicit output geometry."

  alias Backplane.Audio.Error

  @speech %{
    "mp3" => %{
      container: :mp3,
      codec: :mp3,
      mime: "audio/mpeg",
      extension: "mp3",
      rate: 24_000,
      channels: 1,
      encoder: "libmp3lame",
      muxer: "mp3"
    },
    "opus" => %{
      container: :ogg,
      codec: :opus,
      mime: "audio/ogg",
      extension: "opus",
      rate: 48_000,
      channels: 1,
      encoder: "libopus",
      muxer: "ogg"
    },
    "aac" => %{
      container: :adts,
      codec: :aac,
      mime: "audio/aac",
      extension: "aac",
      rate: 24_000,
      channels: 1,
      encoder: "aac",
      muxer: "adts"
    },
    "flac" => %{
      container: :flac,
      codec: :flac,
      mime: "audio/flac",
      extension: "flac",
      rate: 24_000,
      channels: 1,
      encoder: "flac",
      muxer: "flac"
    },
    "wav" => %{
      container: :wav,
      codec: :pcm_s16le,
      mime: "audio/wav",
      extension: "wav",
      rate: 24_000,
      channels: 1,
      encoder: "pcm_s16le",
      muxer: "wav"
    },
    "pcm" => %{
      container: :raw,
      codec: :pcm_s16le,
      mime: "application/octet-stream",
      extension: "pcm",
      rate: 24_000,
      channels: 1,
      encoder: "pcm_s16le",
      muxer: "s16le"
    }
  }

  def speech_profiles, do: @speech

  def speech(source, target, _capabilities, _policy) when is_map(source) do
    case @speech[target] do
      nil -> {:error, invalid("response_format", "unsupported_audio_format")}
      profile -> {:ok, build(source, profile, :speech)}
    end
  end

  def transcription(source, capabilities, _policy) when is_map(source) and is_map(capabilities) do
    accepted = Map.get(capabilities, :accepted, MapSet.new())
    accepted = if is_list(accepted), do: MapSet.new(accepted), else: accepted
    pair = {source.container, source.codec}

    cond do
      MapSet.member?(accepted, pair) ->
        {:ok,
         %{
           operation: :transcription,
           strategy: :passthrough,
           source: source,
           target: source,
           steps: []
         }}

      source.codec == :opus and MapSet.member?(accepted, {:ogg, :opus}) ->
        profile = %{
          container: :ogg,
          codec: :opus,
          mime: "audio/ogg",
          extension: "ogg",
          rate: source.sample_rate,
          channels: source.channels,
          muxer: "ogg"
        }

        {:ok, build(source, profile, :transcription)}

      true ->
        profile = %{
          container: :flac,
          codec: :flac,
          mime: "audio/flac",
          extension: "flac",
          rate: source.sample_rate,
          channels: source.channels,
          encoder: "flac",
          muxer: "flac"
        }

        {:ok, build(source, profile, :transcription)}
    end
  end

  defp build(source, target, operation) do
    strategy =
      cond do
        source.container == target.container and source.codec == target.codec and
          source.sample_rate == target.rate and source.channels == target.channels ->
          :passthrough

        source.codec == target.codec and source.sample_rate == target.rate and
            source.channels == target.channels ->
          :remux

        true ->
          :transcode
      end

    steps =
      case strategy do
        :passthrough ->
          []

        :remux ->
          [:streamcopy, {:mux, target.muxer}]

        :transcode ->
          [:decode] ++
            if(source.sample_rate == target.rate,
              do: [],
              else: [{:resample, source.sample_rate, target.rate}]
            ) ++
            if(source.channels == target.channels,
              do: [],
              else: [{:channels, source.channels, target.channels}]
            ) ++
            [{:encode, target.codec}, {:mux, target.muxer}]
      end

    %{operation: operation, strategy: strategy, source: source, target: target, steps: steps}
  end

  defp invalid(param, code), do: Error.new(400, "Unsupported audio format", param, code)
end
