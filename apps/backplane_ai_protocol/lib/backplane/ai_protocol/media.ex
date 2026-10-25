defmodule Backplane.AiProtocol.Media do
  @moduledoc false

  alias Backplane.AiProtocol.{ContentBlock, Error, Validation}

  @types [:audio, :resource, :resource_link]
  @google_audio ~w(audio/wav audio/mpeg audio/mp3 audio/aiff audio/aac audio/ogg audio/flac)
  @mime ~r/\A[a-zA-Z0-9][a-zA-Z0-9!#$&^_.+-]*\/[a-zA-Z0-9][a-zA-Z0-9!#$&^_.+-]*(?:;[^\r\n]*)?\z/

  def validate(type, data, opts) when type in @types and is_map(data) do
    with :ok <- Validation.term(data, Keyword.get(opts, :limits, %{})),
         :ok <- Validation.reject_unknown(data, fields(type)),
         :ok <- validate_shape(type, data) do
      {:ok, data}
    end
  end

  def validate(_type, _data, _opts), do: invalid("Media data must be an object")

  def preflight(request, protocol) do
    Enum.reduce_while(request.input, :ok, fn
      %{role: role, content: blocks}, :ok ->
        case preflight_blocks(blocks, role, protocol) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _item, :ok ->
        {:cont, :ok}
    end)
  end

  def encode(%{type: type} = block, protocol) when type in @types do
    with {:ok, block} <- ContentBlock.new(block),
         :ok <- portable_metadata(block, protocol) do
      encode_media(block, protocol)
    end
  end

  defp preflight_blocks(blocks, role, protocol) do
    Enum.reduce_while(blocks, :ok, fn
      %{type: type} = block, :ok when type in @types ->
        case encode(block, protocol) do
          {:ok, _wire} when role == :user -> {:cont, :ok}
          {:ok, _wire} -> {:halt, unsupported(protocol, type, "message_role")}
          error -> {:halt, error}
        end

      _block, :ok ->
        {:cont, :ok}
    end)
  end

  defp fields(:audio), do: [:mime_type, :data, :uri]
  defp fields(:resource), do: [:uri, :mime_type, :text, :data]
  defp fields(:resource_link), do: [:uri, :name, :mime_type, :title, :description, :size]

  defp validate_shape(:audio, data) do
    with :ok <- mime(data["mime_type"]),
         true <- String.starts_with?(String.downcase(data["mime_type"]), "audio/"),
         :ok <- exactly_one_source(data, ["data", "uri"]),
         :ok <- optional_uri(data),
         :ok <- optional_base64(data, false) do
      :ok
    else
      false -> invalid("Audio MIME type must be audio/*")
      error -> error
    end
  end

  defp validate_shape(:resource, data) do
    with :ok <- uri(data["uri"]),
         :ok <- mime(data["mime_type"]),
         :ok <- at_most_one_source(data, ["text", "data"]),
         :ok <- optional_string(data, "text"),
         :ok <- optional_base64(data, true) do
      :ok
    end
  end

  defp validate_shape(:resource_link, data) do
    with :ok <- uri(data["uri"]),
         :ok <- nonempty_string(data["name"], "Resource link name"),
         :ok <- optional_mime(data),
         :ok <- optional_string(data, "title"),
         :ok <- optional_string(data, "description"),
         :ok <- optional_size(data) do
      :ok
    end
  end

  defp exactly_one_source(data, keys) do
    if Enum.count(keys, &Map.has_key?(data, &1)) == 1,
      do: :ok,
      else: invalid("Media requires exactly one inline data or URI source")
  end

  defp at_most_one_source(data, keys) do
    if Enum.count(keys, &Map.has_key?(data, &1)) <= 1,
      do: :ok,
      else: invalid("Resource cannot contain both text and inline data")
  end

  defp uri(value) when is_binary(value) and value != "" do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https", "gs"] ->
        nonempty_string(host, "Media URI host")

      {:ok, %URI{scheme: scheme, host: host, path: path}}
      when is_binary(scheme) and scheme != "" ->
        if (is_binary(host) and host != "") or (is_binary(path) and path != ""),
          do: :ok,
          else: invalid("Media URI must identify a resource")

      _ ->
        invalid("Media URI must be an absolute URI")
    end
  end

  defp uri(_value), do: invalid("Media URI must be an absolute URI")

  defp optional_uri(data) do
    if Map.has_key?(data, "uri"), do: uri(data["uri"]), else: :ok
  end

  defp mime(value) when is_binary(value) do
    if Regex.match?(@mime, value), do: :ok, else: invalid("Media MIME type is invalid")
  end

  defp mime(_value), do: invalid("Media MIME type is required")

  defp optional_mime(data) do
    if Map.has_key?(data, "mime_type"), do: mime(data["mime_type"]), else: :ok
  end

  defp optional_base64(data, empty?) do
    case Map.fetch(data, "data") do
      :error -> :ok
      {:ok, value} when is_binary(value) -> validate_base64(value, empty?)
      _ -> invalid("Inline media data must be base64")
    end
  end

  defp validate_base64(value, empty?) do
    case Base.decode64(value) do
      {:ok, decoded} when empty? or byte_size(decoded) > 0 -> :ok
      _ -> invalid("Inline media data must be valid base64")
    end
  end

  defp nonempty_string(value, _label) when is_binary(value) and value != "", do: :ok
  defp nonempty_string(_value, label), do: invalid("#{label} must be a non-empty string")

  defp optional_string(data, key) do
    case Map.fetch(data, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) -> :ok
      _ -> invalid("Media #{key} must be a string")
    end
  end

  defp optional_size(data) do
    case Map.fetch(data, "size") do
      :error -> :ok
      {:ok, value} when is_integer(value) and value >= 0 -> :ok
      _ -> invalid("Resource link size must be a nonnegative integer")
    end
  end

  defp portable_metadata(%{extensions: extensions, type: type}, protocol) do
    if extensions == %{}, do: :ok, else: unsupported(protocol, type, "media_metadata")
  end

  defp encode_media(%{type: :audio, data: %{"mime_type" => mime, "data" => data}}, :openai)
       when mime in ["audio/wav", "audio/mpeg"] do
    format = if mime == "audio/wav", do: "wav", else: "mp3"
    {:ok, %{"type" => "input_audio", "input_audio" => %{"data" => data, "format" => format}}}
  end

  defp encode_media(%{type: :audio, data: %{"mime_type" => mime, "data" => data}}, :google)
       when mime in @google_audio,
       do: {:ok, %{"inlineData" => %{"mimeType" => mime, "data" => data}}}

  defp encode_media(
         %{type: :resource, data: %{"mime_type" => mime, "uri" => uri} = data},
         :google
       )
       when map_size(data) == 2 do
    case URI.new(uri) do
      {:ok, %URI{scheme: scheme}} when scheme in ["http", "https", "gs"] ->
        {:ok, %{"fileData" => %{"mimeType" => mime, "fileUri" => uri}}}

      _ ->
        unsupported(:google, :resource, "resource_uri_scheme")
    end
  end

  defp encode_media(%{type: type}, protocol), do: unsupported(protocol, type, "media_form")

  defp unsupported(protocol, type, reason) do
    {:error,
     %{
       Error.incompatible!("Provider cannot preserve requested media content", %{
         "protocol" => Atom.to_string(protocol),
         "capability" => Atom.to_string(type),
         "reason" => reason
       })
       | upstream_outcome: :not_submitted
     }}
  end

  defp invalid(message), do: {:error, Error.invalid!(message)}
end
