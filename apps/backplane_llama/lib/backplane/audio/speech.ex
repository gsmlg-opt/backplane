defmodule Backplane.Audio.Speech do
  @moduledoc "Execute one authorized speech request using the selected MiniMax binding."

  alias Backplane.Audio.{AccessLifecycle, Error, Resolver}
  alias Backplane.Audio.Adapters.MiniMax
  alias Backplane.Audio.Media.{Capabilities, Session}

  def run(request, resolution, session, deadline, consumer, acc) when is_function(consumer, 2) do
    observer = request[:observer]
    AccessLifecycle.resolved(observer, request, resolution)
    AccessLifecycle.update(observer, %{output_format: request.response_format})
    policy = Backplane.Audio.Config.policy()

    with {:ok, voice} <- Resolver.resolve_voice(resolution, request.voice),
         {:ok, secret} <- MiniMax.credential(resolution),
         {:ok, native} <- native_format(request, resolution.capabilities),
         %{ready?: true, formats: formats} <- Capabilities.probe(policy, :speech),
         true <- formats[request.response_format] == true do
      stream? =
        request.response_format == "mp3" and native == "mp3" and
          resolution.capabilities["streaming"] != false

      AccessLifecycle.update(observer, %{
        stream: stream?,
        strategy: :native,
        sample_rate: 24_000,
        channels: 1
      })

      execution = %{
        resolution: resolution,
        voice: voice,
        secret: secret,
        deadline: deadline,
        policy: policy,
        native_format: native
      }

      if stream? do
        MiniMax.speech(request, execution, true, consumer, acc)
      else
        buffered(request, execution, session, consumer, acc)
      end
    else
      {:error, %Error{} = error} -> {:error, error, acc, %{}}
      _ -> {:error, Error.new(503, "Audio media unavailable", nil, "audio_unavailable"), acc, %{}}
    end
  end

  defp buffered(request, %{policy: policy} = execution, session, consumer, acc) do
    with {:ok, path} <- Session.input_path(session),
         :ok <- Session.reserve_input(session, policy["max_output_bytes"]),
         {:ok, io} <- File.open(path, [:write, :binary, :raw]) do
      result =
        try do
          writer = fn {:chunk, bytes}, total ->
            if total + byte_size(bytes) <= policy["max_output_bytes"] do
              case :file.write(io, bytes) do
                :ok ->
                  {:ok, total + byte_size(bytes)}

                _ ->
                  {:error,
                   Error.new(503, "Audio storage unavailable", nil, "audio_storage_unavailable"),
                   total}
              end
            else
              {:error, Error.new(502, "Provider audio too large", nil, "audio_output_too_large"),
               total}
            end
          end

          MiniMax.speech(request, execution, false, writer, 0)
        after
          File.close(io)
        end

      case result do
        {:ok, _bytes, metadata} ->
          case Session.prepare(session, :speech, path, request.response_format) do
            {:ok, artifact} ->
              metadata =
                Map.merge(metadata, %{
                  output_bytes: artifact.bytes,
                  strategy: artifact.plan.strategy
                })

              case consumer.({:file, artifact}, acc) do
                {:ok, next} -> {:ok, next, metadata}
                {:error, %Error{} = error, next} -> {:error, error, next, metadata}
              end

            {:error, %Error{} = error} ->
              {:error, error, acc, Map.put(metadata, :strategy, :buffered)}
          end

        {:error, error, _bytes, metadata} ->
          {:error, error, acc, metadata}
      end
    else
      {:error, %Error{} = error} ->
        {:error, error, acc, %{}}

      _ ->
        {:error, Error.new(503, "Audio storage unavailable", nil, "audio_storage_unavailable"),
         acc, %{}}
    end
  end

  defp native_format(request, caps) do
    supported = caps["native_formats"] || ["mp3", "flac"]

    native =
      cond do
        request.response_format == "mp3" and "mp3" in supported ->
          request.response_format

        "flac" in supported ->
          "flac"

        request.response_format == "wav" and "wav" in supported ->
          "wav"

        true ->
          nil
      end

    if native do
      {:ok, native}
    else
      {:error,
       Error.new(
         503,
         "No compatible lossless native audio format",
         "model",
         "audio_native_format_unavailable"
       )}
    end
  end
end
