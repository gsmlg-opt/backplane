defmodule Backplane.SkillProtocol.Parser do
  @moduledoc "Bounded, raw-preserving Skill document parser."

  alias Backplane.SkillProtocol.{Document, Error}

  @default_max_document_bytes 2 * 1024 * 1024
  @default_max_frontmatter_bytes 256 * 1024
  @default_max_nesting_depth 32
  @known_fields ~w(name description license compatibility metadata version allowed-tools disable-model-invocation user-invocable argument-hint)

  @spec parse(binary(), keyword()) :: {:ok, Document.t()} | {:error, Error.t()}
  def parse(bytes, opts \\ [])

  def parse(bytes, opts) when is_binary(bytes) do
    with :ok <- validate_encoding(bytes),
         :ok <-
           limit(
             byte_size(bytes),
             opts[:max_document_bytes] || @default_max_document_bytes,
             :document_bytes
           ),
         {:ok, frontmatter, body} <- split_frontmatter(bytes),
         :ok <-
           limit(
             byte_size(frontmatter),
             opts[:max_frontmatter_bytes] || @default_max_frontmatter_bytes,
             :frontmatter_bytes
           ),
         {:ok, metadata} <-
           parse_yaml(frontmatter, opts[:max_nesting_depth] || @default_max_nesting_depth) do
      extensions = Map.drop(metadata, @known_fields)

      {:ok,
       %Document{
         raw: bytes,
         frontmatter_raw: frontmatter,
         body_raw: body,
         metadata: metadata,
         extensions: extensions,
         name: metadata["name"],
         description: metadata["description"],
         version: metadata["version"],
         license: metadata["license"],
         compatibility: metadata["compatibility"]
       }}
    end
  end

  def parse(_bytes, _opts), do: error(:invalid_document, "document must be bytes")

  defp validate_encoding(bytes) do
    if String.valid?(bytes),
      do: :ok,
      else: error(:invalid_encoding, "document is not valid UTF-8")
  end

  defp split_frontmatter(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: split_frontmatter(rest)

  defp split_frontmatter(bytes) do
    case Regex.run(~r/\A\s*?---[\t ]*\r?\n(.*?)(?:\r?\n)---[\t ]*(?:\r?\n|\z)(.*)\z/s, bytes,
           capture: :all_but_first
         ) do
      [frontmatter, body] -> {:ok, frontmatter, body}
      _ -> error(:missing_frontmatter, "document must begin with YAML frontmatter")
    end
  end

  defp parse_yaml(frontmatter, max_depth) do
    case Formata.decode(frontmatter, :yaml, max_depth: max_depth) do
      {:ok, metadata} when is_map(metadata) and map_size(metadata) > 0 ->
        {:ok, stringify_keys(metadata)}

      {:ok, _} ->
        error(:malformed_frontmatter, "frontmatter must be a mapping")

      {:error, [%Formata.Error{code: :duplicate_key, path: path, details: %{key: key}}]} ->
        error(:duplicate_key, "frontmatter contains a duplicate key",
          context: %{path: path ++ [key]}
        )

      {:error, [%Formata.Error{code: :limit_exceeded, details: %{max: maximum}}]} ->
        error(:limit_exceeded, "frontmatter exceeds YAML limit", context: %{limit: maximum})

      {:error, _} ->
        error(:malformed_frontmatter, "frontmatter is malformed YAML")
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp limit(actual, maximum, _kind) when actual <= maximum, do: :ok

  defp limit(actual, maximum, kind),
    do:
      error(:limit_exceeded, "#{kind} exceeds limit",
        context: %{actual: actual, limit: maximum, budget: kind}
      )

  defp error(code, message, opts \\ []), do: {:error, Error.new(code, :parse, message, opts)}
end
