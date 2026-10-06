defmodule Backplane.Audio.Media.Convert do
  @moduledoc "Executes deterministic file-backed remux and transcode plans."

  alias Backplane.Audio.Error
  alias Backplane.Audio.Media.{Probe, Runner, TempFiles}

  def prepare(_handle, %{strategy: :passthrough, source: source, target: target} = plan, policy) do
    bound =
      if plan.operation == :transcription,
        do: policy["upstream_upload_bytes"],
        else: policy["max_output_bytes"]

    if source.bytes <= bound,
      do: {:ok, %{path: source.source, bytes: source.bytes, mime: target.mime, plan: plan}},
      else:
        {:error, Error.new(413, "Prepared audio is too large", "file", "audio_output_too_large")}
  end

  def prepare(handle, %{source: source, target: target} = plan, policy) do
    bound =
      if plan.operation == :transcription,
        do: policy["upstream_upload_bytes"],
        else: policy["max_output_bytes"]

    with {:ok, staging} <- TempFiles.path(handle, :staging),
         {:ok, output} <- TempFiles.path(handle, :output),
         :ok <- TempFiles.reserve(handle, bound) do
      result =
        with {:ok, _file, bytes} <-
               Runner.run(
                 handle,
                 %{
                   mode: :convert,
                   args: args(source.source, staging, plan),
                   output: staging,
                   max_bytes: bound
                 },
                 policy
               ),
             {:ok, verified} <-
               Probe.inspect(handle, staging, %{
                 purpose: :speech,
                 format: target.extension,
                 policy: policy
               }),
             :ok <- verify_output(verified, source, target),
             :ok <- File.rename(staging, output) do
          TempFiles.release_reservation(handle, bound - bytes)
          {:ok, %{path: output, bytes: bytes, mime: target.mime, plan: plan}}
        else
          {:error, %Error{} = error} -> {:error, error}
          _ -> {:error, Error.new(502, "Audio conversion failed", nil, "audio_media_failed")}
        end

      case result do
        {:error, %Error{code: "audio_cleanup_uncertain"}} ->
          :ok

        {:error, _} ->
          File.rm(staging)
          File.rm(output)
          TempFiles.release_reservation(handle, bound)

        _ ->
          :ok
      end

      result
    end
  end

  defp verify_output(verified, source, target) do
    if verified.container == target.container and verified.codec == target.codec and
         verified.sample_rate == target.rate and verified.channels == target.channels and
         abs(verified.duration - source.duration) <= max(0.25, source.duration * 0.02) do
      :ok
    else
      {:error,
       Error.new(502, "Audio conversion result failed validation", nil, "audio_media_failed")}
    end
  end

  defp args(source, output, %{source: metadata, target: target, strategy: strategy}) do
    [
      "-nostdin",
      "-hide_banner",
      "-v",
      "error",
      "-threads",
      "1",
      "-filter_threads",
      "1",
      "-protocol_whitelist",
      "file,pipe",
      "-f",
      demuxer(metadata.container)
    ] ++
      input_geometry(metadata) ++
      [
        "-i",
        source,
        "-map",
        "0:a:0",
        "-vn",
        "-sn",
        "-dn"
      ] ++
      codec_args(strategy, target) ++ ["-f", target.muxer, output]
  end

  defp input_geometry(%{container: :raw}), do: ["-ar", "24000", "-ac", "1"]
  defp input_geometry(_), do: []

  defp codec_args(:remux, _target), do: ["-c:a", "copy"]

  defp codec_args(:transcode, target) do
    base = [
      "-c:a",
      target.encoder,
      "-ar",
      Integer.to_string(target.rate),
      "-ac",
      Integer.to_string(target.channels)
    ]

    case target.codec do
      :mp3 -> base ++ ["-b:a", "128k"]
      :opus -> base ++ ["-b:a", "64k", "-application", "audio"]
      :aac -> base ++ ["-profile:a", "aac_low", "-b:a", "96k"]
      :flac -> base ++ ["-compression_level", "5"]
      _ -> base
    end
  end

  def demuxer(:flac), do: "flac"
  def demuxer(:ogg), do: "ogg"
  def demuxer(:wav), do: "wav"
  def demuxer(:webm), do: "matroska"
  def demuxer(:mp4), do: "mov"
  def demuxer(:mpeg), do: "mpeg"
  def demuxer(:mp3), do: "mp3"
  def demuxer(:adts), do: "aac"
  def demuxer(:raw), do: "s16le"
end
