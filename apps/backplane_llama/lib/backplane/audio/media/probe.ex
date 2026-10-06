defmodule Backplane.Audio.Media.Probe do
  @moduledoc "Content-driven probing plus full bounded decode before upstream ASR."
  import Bitwise

  alias Backplane.Audio.Error
  alias Backplane.Audio.Media.{Runner, TempFiles}

  @asr_extensions ~w(flac mp3 mp4 mpeg mpga m4a ogg wav webm)
  @codec_names %{
    "mp3" => :mp3,
    "mp2" => :mp2,
    "aac" => :aac,
    "alac" => :alac,
    "opus" => :opus,
    "vorbis" => :vorbis,
    "flac" => :flac,
    "pcm_s16le" => :pcm_s16le
  }

  def inspect(handle, source, opts) when is_map(opts) do
    policy = Map.fetch!(opts, :policy)
    purpose = Map.get(opts, :purpose, :transcription)

    with :ok <- input_size(source, policy, purpose),
         :ok <- extension(opts, purpose),
         {:ok, demuxer, container} <- sniff(source, purpose, opts),
         :ok <- match_extension(container, opts, purpose),
         {:ok, result} <- inspect_content(handle, source, demuxer, container, purpose, policy) do
      {:ok, result}
    else
      {:error, %Error{code: "audio_media_failed"}} ->
        {:error, invalid("Audio could not be decoded", "audio_invalid_media")}

      {:error, %Error{} = error} ->
        {:error, error}

      _ ->
        {:error, invalid("Audio could not be decoded", "audio_invalid_media")}
    end
  end

  defp inspect_content(_handle, source, "s16le", :raw, :speech, policy) do
    size = File.stat!(source).size
    duration = size / 2 / 24_000

    if rem(size, 2) == 0 and div(size, 2) <= policy["max_decoded_samples"] do
      {:ok,
       %{
         container: :raw,
         codec: :pcm_s16le,
         sample_rate: 24_000,
         channels: 1,
         bytes: size,
         source: source,
         duration: duration,
         samples: div(size, 2),
         mime: "application/octet-stream",
         extension: "pcm"
       }}
    else
      {:error, invalid("Invalid raw PCM geometry or duration", "audio_invalid_media")}
    end
  end

  defp inspect_content(handle, source, demuxer, container, purpose, policy) do
    with {:ok, probe_path} <- TempFiles.path(handle, :probe),
         :ok <- TempFiles.reserve(handle, 1_000_000) do
      result =
        with {:ok, _path, _bytes} <- probe_file(handle, source, probe_path, demuxer, policy),
             {:ok, raw} <- File.read(probe_path),
             {:ok, metadata} <- parse(raw, container, source, purpose, policy),
             {:ok, actual} <- decode_validate(handle, source, demuxer, metadata, purpose, policy) do
          {:ok, Map.merge(metadata, actual)}
        else
          {:error, %Error{} = error} -> {:error, error}
          _ -> {:error, invalid("Audio could not be decoded", "audio_invalid_media")}
        end

      unless uncertain?(result) do
        File.rm(probe_path)
        TempFiles.release_reservation(handle, 1_000_000)
      end

      result
    end
  end

  defp input_size(source, policy, purpose) do
    bound =
      if purpose == :transcription,
        do: policy["upload_bytes"],
        else: policy["max_provider_response_bytes"]

    case File.lstat(source) do
      {:ok, %{type: :regular, size: size}} when size > 0 and size <= bound ->
        :ok

      {:ok, %{size: size}} when size > bound ->
        {:error, Error.new(413, "Audio input is too large", "file", "audio_input_too_large")}

      _ ->
        {:error, invalid("Audio input is empty or invalid", "audio_invalid_media")}
    end
  end

  defp extension(opts, :transcription) do
    ext = Map.get(opts, :extension)

    if ext in @asr_extensions,
      do: :ok,
      else:
        {:error,
         Error.new(415, "Unsupported audio file extension", "file", "unsupported_audio_format")}
  end

  defp extension(_opts, _purpose), do: :ok

  defp match_extension(container, %{extension: ext}, :transcription) do
    expected = %{
      "flac" => :flac,
      "mp3" => :mp3,
      "mpga" => :mp3,
      "mp4" => :mp4,
      "m4a" => :mp4,
      "mpeg" => :mpeg,
      "ogg" => :ogg,
      "wav" => :wav,
      "webm" => :webm
    }

    if expected[ext] == container,
      do: :ok,
      else: {:error, invalid("File contents do not match its format", "audio_invalid_media")}
  end

  defp match_extension(_, _, _), do: :ok

  defp sniff(path, purpose, opts) do
    case File.open(path, [:read, :binary], fn file -> IO.binread(file, 32) end) do
      {:ok, <<"fLaC", _::binary>>} ->
        {:ok, "flac", :flac}

      {:ok, <<"OggS", _::binary>>} ->
        {:ok, "ogg", :ogg}

      {:ok, <<"RIFF", _len::binary-size(4), "WAVE", _::binary>>} ->
        {:ok, "wav", :wav}

      {:ok, <<0x1A, 0x45, 0xDF, 0xA3, _::binary>>} ->
        {:ok, "matroska", :webm}

      {:ok, <<_size::binary-size(4), "ftyp", _::binary>>} ->
        {:ok, "mov", :mp4}

      {:ok, <<0, 0, 1, 0xBA, _::binary>>} ->
        {:ok, "mpeg", :mpeg}

      {:ok, <<"ID3", _::binary>>} ->
        {:ok, "mp3", :mp3}

      {:ok, <<0xFF, second, _::binary>>} ->
        cond do
          band(second, 0xF6) == 0xF0 and purpose == :speech -> {:ok, "aac", :adts}
          band(second, 0xE0) == 0xE0 -> {:ok, "mp3", :mp3}
          true -> raw_or_error(purpose, opts)
        end

      {:ok, _} ->
        raw_or_error(purpose, opts)

      _ ->
        {:error,
         Error.new(
           415,
           "Unsupported or unsafe audio container",
           "file",
           "unsupported_audio_format"
         )}
    end
  end

  defp raw_or_error(:speech, %{format: "pcm"}), do: {:ok, "s16le", :raw}

  defp raw_or_error(_, _),
    do:
      {:error,
       Error.new(415, "Unsupported or unsafe audio container", "file", "unsupported_audio_format")}

  defp probe_file(handle, source, output, demuxer, policy) do
    args = [
      "-v",
      "error",
      "-protocol_whitelist",
      "file,pipe",
      "-f",
      demuxer,
      "-show_streams",
      "-show_format",
      "-of",
      "json",
      "-o",
      output,
      "-i",
      source
    ]

    Runner.run(handle, %{mode: :probe, args: args, output: output, max_bytes: 1_000_000}, policy)
  end

  defp parse(raw, container, source, purpose, policy) do
    with {:ok, %{"streams" => streams} = payload} when is_list(streams) <- Jason.decode(raw),
         [audio] <- Enum.filter(streams, &(&1["codec_type"] == "audio")),
         :ok <- safe_tracks(streams),
         {:ok, codec} <- codec(audio["codec_name"], container, purpose),
         {rate, ""} <- Integer.parse(to_string(audio["sample_rate"] || "")),
         channels when is_integer(channels) <- audio["channels"],
         true <-
           rate > 0 and rate <= policy["max_sample_rate"] and channels > 0 and
             channels <= policy["max_channels"] do
      size = File.stat!(source).size

      {:ok,
       %{
         container: container,
         codec: codec,
         sample_rate: rate,
         channels: channels,
         bytes: size,
         reported_duration:
           numeric_duration(audio["duration"] || get_in(payload, ["format", "duration"])),
         source: source,
         mime: mime(container),
         extension: extension_for(container)
       }}
    else
      _ ->
        {:error, invalid("Audio contains no single supported audio track", "audio_invalid_media")}
    end
  end

  defp safe_tracks(streams) do
    if Enum.any?(streams, &(&1["codec_type"] in ["attachment", "data", "subtitle"])) do
      {:error, :unsafe_tracks}
    else
      :ok
    end
  end

  defp codec(name, container, purpose) do
    codec = @codec_names[name]

    allowed =
      case container do
        :flac -> [:flac]
        :ogg -> [:opus, :vorbis]
        :wav -> [:pcm_s16le]
        :webm -> [:opus, :vorbis]
        :mp4 -> [:aac, :alac]
        :mpeg -> [:mp2, :mp3]
        :mp3 -> [:mp3, :mp2]
        :adts when purpose == :speech -> [:aac]
        :raw when purpose == :speech -> [:pcm_s16le]
        _ -> []
      end

    if codec in allowed, do: {:ok, codec}, else: {:error, :unsupported_codec}
  end

  defp decode_validate(handle, source, demuxer, metadata, purpose, policy) do
    with {:ok, output} <- TempFiles.path(handle, :decoded) do
      max_bytes = policy["max_decoded_samples"] * metadata.channels * 2

      with :ok <- TempFiles.reserve(handle, max_bytes) do
        result =
          with {:ok, _path, bytes} <-
                 Runner.run(
                   handle,
                   %{
                     mode: :convert,
                     args: [
                       "-nostdin",
                       "-hide_banner",
                       "-v",
                       "error",
                       "-threads",
                       "1",
                       "-filter_threads",
                       "1",
                       "-xerror",
                       "-err_detect",
                       "explode",
                       "-protocol_whitelist",
                       "file,pipe",
                       "-f",
                       demuxer,
                       "-i",
                       source,
                       "-map",
                       "0:a:0",
                       "-vn",
                       "-sn",
                       "-dn",
                       "-c:a",
                       "pcm_s16le",
                       "-f",
                       "s16le",
                       output
                     ],
                     output: output,
                     max_bytes: max_bytes
                   },
                   policy
                 ) do
            samples = div(bytes, 2 * metadata.channels)
            duration = samples / metadata.sample_rate

            cond do
              rem(bytes, 2 * metadata.channels) != 0 ->
                {:error, invalid("Invalid decoded audio geometry", "audio_invalid_media")}

              samples > policy["max_decoded_samples"] ->
                {:error, invalid("Audio exceeds decoded sample limit", "audio_sample_limit")}

              purpose == :transcription and duration > policy["input_duration_seconds"] ->
                {:error, invalid("Audio exceeds duration limit", "audio_duration_limit")}

              metadata.reported_duration &&
                  abs(metadata.reported_duration - duration) > max(2.0, duration * 0.05) ->
                {:error,
                 invalid("Audio duration metadata is inconsistent", "audio_invalid_media")}

              true ->
                {:ok, %{samples: samples, duration: duration}}
            end
          else
            {:error, %Error{} = error} ->
              {:error, error}
          end

        unless uncertain?(result) do
          File.rm(output)
          TempFiles.release_reservation(handle, max_bytes)
        end

        result
      end
    end
  end

  defp numeric_duration(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp numeric_duration(_), do: nil
  defp uncertain?({:error, %Error{code: "audio_cleanup_uncertain"}}), do: true
  defp uncertain?(_), do: false
  defp mime(:flac), do: "audio/flac"
  defp mime(:ogg), do: "audio/ogg"
  defp mime(:wav), do: "audio/wav"
  defp mime(:webm), do: "audio/webm"
  defp mime(:mp4), do: "audio/mp4"
  defp mime(:mpeg), do: "audio/mpeg"
  defp mime(:mp3), do: "audio/mpeg"
  defp mime(:adts), do: "audio/aac"

  defp extension_for(:mp4), do: "m4a"
  defp extension_for(:mpeg), do: "mpeg"
  defp extension_for(:adts), do: "aac"
  defp extension_for(container), do: Atom.to_string(container)

  defp invalid(message, code), do: Error.new(400, message, "file", code)
end
