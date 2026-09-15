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
         {:ok, pairs} <- parse_yaml(frontmatter),
         :ok <- reject_duplicates(pairs),
         metadata <- pairs_to_data(pairs),
         :ok <- nesting_limit(metadata, opts[:max_nesting_depth] || @default_max_nesting_depth) do
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

  defp parse_yaml(frontmatter) do
    case YamlElixir.read_from_string(frontmatter, maps_as_keywords: true) do
      {:ok, pairs} when is_list(pairs) ->
        if keyword_pairs?(pairs),
          do: {:ok, pairs},
          else: error(:malformed_frontmatter, "frontmatter must be a mapping")

      {:ok, _} ->
        error(:malformed_frontmatter, "frontmatter must be a mapping")

      {:error, _} ->
        error(:malformed_frontmatter, "frontmatter is malformed YAML")
    end
  end

  defp reject_duplicates(value), do: reject_duplicates(value, [])

  defp reject_duplicates(list, path) when is_list(list) do
    if keyword_pairs?(list) do
      keys = Enum.map(list, &elem(&1, 0))

      case duplicate(keys) do
        nil ->
          Enum.reduce_while(list, :ok, &check_pair(&1, &2, path))

        key ->
          error(:duplicate_key, "frontmatter contains a duplicate key",
            context: %{path: Enum.reverse([key | path])}
          )
      end
    else
      Enum.reduce_while(Enum.with_index(list), :ok, fn {item, index}, :ok ->
        case reject_duplicates(item, [index | path]) do
          :ok -> {:cont, :ok}
          {:error, _} = result -> {:halt, result}
        end
      end)
    end
  end

  defp reject_duplicates(_value, _path), do: :ok

  defp check_pair({key, value}, :ok, path) do
    case reject_duplicates(value, [key | path]) do
      :ok -> {:cont, :ok}
      {:error, _} = result -> {:halt, result}
    end
  end

  defp duplicate(keys) do
    Enum.reduce_while(keys, MapSet.new(), fn key, seen ->
      if MapSet.member?(seen, key), do: {:halt, key}, else: {:cont, MapSet.put(seen, key)}
    end)
    |> case do
      %MapSet{} -> nil
      key -> key
    end
  end

  defp pairs_to_data(list) when is_list(list) do
    if keyword_pairs?(list) do
      Map.new(list, fn {key, value} -> {to_string(key), pairs_to_data(value)} end)
    else
      Enum.map(list, &pairs_to_data/1)
    end
  end

  defp pairs_to_data(value), do: value
  defp keyword_pairs?([]), do: false
  defp keyword_pairs?(list), do: Enum.all?(list, &match?({_, _}, &1))

  defp nesting_limit(value, max), do: nesting_limit(value, 0, max)

  defp nesting_limit(_value, depth, max) when depth > max,
    do: error(:limit_exceeded, "frontmatter nesting exceeds limit", context: %{limit: max})

  defp nesting_limit(map, depth, max) when is_map(map),
    do: reduce_nested(Map.values(map), depth, max)

  defp nesting_limit(list, depth, max) when is_list(list), do: reduce_nested(list, depth, max)
  defp nesting_limit(_value, _depth, _max), do: :ok

  defp reduce_nested(values, depth, max) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case nesting_limit(value, depth + 1, max) do
        :ok -> {:cont, :ok}
        {:error, _} = result -> {:halt, result}
      end
    end)
  end

  defp limit(actual, maximum, _kind) when actual <= maximum, do: :ok

  defp limit(actual, maximum, kind),
    do:
      error(:limit_exceeded, "#{kind} exceeds limit",
        context: %{actual: actual, limit: maximum, budget: kind}
      )

  defp error(code, message, opts \\ []), do: {:error, Error.new(code, :parse, message, opts)}
end
