defmodule Backplane.Audio.Transcription do
  @moduledoc "Execute one authorized file transcription with request-owned media."

  alias Backplane.Audio.{AccessLifecycle, Error, Config}
  alias Backplane.Audio.Adapters.MiniMax
  alias Backplane.Audio.Media.{Capabilities, Session}

  def run(request, resolution, session, deadline) do
    AccessLifecycle.resolved(request[:observer], request, resolution)

    extension =
      request.file.filename |> Path.extname() |> String.trim_leading(".") |> String.downcase()

    policy = Config.policy()

    with {:ok, secret} <- MiniMax.credential(resolution),
         :ok <- input_capability(resolution.capabilities),
         :ok <- media_ready(policy),
         {:ok, path, input_bytes} <- Session.adopt_upload(session, request.file),
         {:ok, prepared} <-
           Session.prepare(session, :transcription, path, extension, %{accepted: [{:flac, :flac}]}),
         true <- prepared.bytes <= policy["upstream_upload_bytes"],
         _ <-
           AccessLifecycle.update(request[:observer], %{
             request_bytes: input_bytes,
             upstream_bytes: prepared.bytes
           }),
         {:ok, text, metadata} <-
           MiniMax.transcription(request, resolution, prepared, secret, deadline, policy) do
      {:ok, text,
       Map.merge(metadata, %{
         input_bytes: input_bytes,
         upstream_bytes: prepared.bytes,
         strategy: prepared.plan.strategy
       })}
    else
      false ->
        {:error,
         Error.new(
           413,
           "Prepared audio exceeds provider limit",
           "file",
           "audio_upload_too_large"
         ), %{}}

      {:error, %Error{} = error, metadata} ->
        {:error, error, metadata}

      {:error, %Error{} = error} ->
        {:error, error, %{}}
    end
  end

  defp media_ready(policy) do
    case Capabilities.probe(policy, :transcription) do
      %{ready?: true, formats: %{"flac" => true}} -> :ok
      _ -> {:error, Error.new(503, "Audio media unavailable", nil, "audio_unavailable")}
    end
  end

  defp input_capability(caps) do
    case caps["input_formats"] do
      nil ->
        :ok

      formats when is_list(formats) ->
        if "flac" in formats,
          do: :ok,
          else:
            {:error,
             Error.new(
               422,
               "Binding cannot prepare supported upstream audio",
               "model",
               "audio_input_format_unavailable"
             )}
    end
  end
end
