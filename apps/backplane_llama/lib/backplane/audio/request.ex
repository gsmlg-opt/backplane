defmodule Backplane.Audio.Request do
  @moduledoc """
  Pure audio request validation. Input length counts Unicode scalar values.
  Optional response/stream formats, language and unsupported options treat nil
  and the empty string as absent. Speed accepts nil, but not an empty string;
  transcription stream accepts nil, false or the multipart string "false".
  """

  alias Backplane.Audio.Error

  @speech_formats ~w(mp3 opus aac flac wav pcm)
  @result_formats ~w(json text)
  @unsupported_speech ~w(instructions)
  @unsupported_transcription ~w(prompt temperature timestamp_granularities speaker chunking_strategy include logprobs)

  def speech(params) when is_map(params) do
    with :ok <- required_string(params, "model"),
         :ok <- required_string(params, "input"),
         :ok <- required_string(params, "voice"),
         :ok <- max_characters(params["input"]),
         :ok <- choice(params, "response_format", @speech_formats, "mp3"),
         :ok <- choice(params, "stream_format", ["audio"], "audio"),
         :ok <- speed(params),
         :ok <- no_meaningful_options(params, @unsupported_speech),
         :ok <-
           known_keys(
             params,
             ~w(model input voice response_format speed stream_format instructions)
           ) do
      {:ok,
       %{
         model: params["model"],
         input: params["input"],
         voice: params["voice"],
         response_format: blank_as_nil(params["response_format"]) || "mp3",
         speed: params["speed"] || 1.0,
         stream_format: blank_as_nil(params["stream_format"]) || "audio"
       }}
    end
  end

  def speech(_), do: {:error, Error.new(400, "Expected a JSON object", nil, "invalid_request")}

  def transcription(params) when is_map(params) do
    with :ok <- required_string(params, "model"),
         :ok <- required_upload(params),
         :ok <- choice(params, "response_format", @result_formats, "json"),
         :ok <- stream(params),
         :ok <- language(params),
         :ok <- no_meaningful_options(params, @unsupported_transcription),
         :ok <-
           known_keys(
             params,
             ~w(model file response_format stream language) ++ @unsupported_transcription
           ) do
      {:ok,
       %{
         model: params["model"],
         file: params["file"],
         response_format: blank_as_nil(params["response_format"]) || "json",
         language: blank_as_nil(params["language"])
       }}
    end
  end

  def transcription(_),
    do: {:error, Error.new(400, "Expected multipart fields", nil, "invalid_request")}

  defp required_string(params, key) do
    case params[key] do
      value when is_binary(value) ->
        if String.trim(value) != "",
          do: :ok,
          else: invalid(key, "is required", "missing_required_parameter")

      _ ->
        invalid(key, "is required", "missing_required_parameter")
    end
  end

  defp required_upload(%{"file" => %Plug.Upload{}}), do: :ok
  defp required_upload(_), do: invalid("file", "is required", "missing_required_parameter")

  defp max_characters(input) when is_binary(input) do
    if length(String.to_charlist(input)) <= 4096,
      do: :ok,
      else: invalid("input", "exceeds 4096 characters", "input_too_long")
  end

  defp choice(params, key, choices, _default) do
    case blank_as_nil(params[key]) do
      nil ->
        :ok

      value ->
        if value in choices,
          do: :ok,
          else: invalid(key, "is unsupported", "unsupported_parameter")
    end
  end

  defp speed(params) do
    case params["speed"] do
      nil -> :ok
      value when is_number(value) and value >= 0.25 and value <= 4.0 -> :ok
      _ -> invalid("speed", "must be between 0.25 and 4.0", "invalid_parameter")
    end
  end

  defp stream(params) do
    case params["stream"] do
      nil -> :ok
      false -> :ok
      "false" -> :ok
      _ -> invalid("stream", "streaming transcription is unsupported", "unsupported_parameter")
    end
  end

  defp language(params) do
    case blank_as_nil(params["language"]) do
      nil ->
        :ok

      value when is_binary(value) ->
        if Regex.match?(~r/^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{2,8})*$/, value),
          do: :ok,
          else: invalid("language", "must be a language tag", "invalid_parameter")

      _ ->
        invalid("language", "must be a language tag", "invalid_parameter")
    end
  end

  defp no_meaningful_options(params, keys) do
    case Enum.find(keys, &(not is_nil(blank_as_nil(params[&1])))) do
      nil -> :ok
      key -> invalid(key, "is unsupported", "unsupported_parameter")
    end
  end

  defp known_keys(params, keys) do
    case Map.keys(params) |> Enum.find(&(&1 not in keys)) do
      nil -> :ok
      key -> invalid(to_string(key), "is unsupported", "unsupported_parameter")
    end
  end

  defp blank_as_nil(value) when value in [nil, ""], do: nil
  defp blank_as_nil(value), do: value

  defp invalid(param, reason, code),
    do: {:error, Error.new(400, "#{param} #{reason}", param, code)}
end
