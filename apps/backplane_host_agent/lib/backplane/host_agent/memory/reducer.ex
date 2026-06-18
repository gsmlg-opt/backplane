defmodule Backplane.HostAgent.Memory.Reducer do
  @moduledoc """
  Pure helpers for local host-agent memory validation, JSON normalization,
  keyword recall, and deterministic hit ranking.
  """

  @default_scope "proj_local"
  @max_limit 100

  @doc "Returns the lowercase SHA-256 hex digest for memory content."
  def content_hash(content) when is_binary(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end

  @doc "Resolves write scope from memory config and rejects caller drift."
  def resolve_scope(args, config) when is_map(args) and is_map(config) do
    bound_scope = config_value(config, :bound_scope) || @default_scope

    case optional_trimmed(args, "scope") do
      nil -> {:ok, bound_scope}
      ^bound_scope -> {:ok, bound_scope}
      _other -> {:error, :invalid_scope}
    end
  end

  @doc "Normalizes tag and metadata inputs and returns JSON text for storage."
  def normalize_facets(args) when is_map(args) do
    with {:ok, tags} <- normalize_tags(value(args, "tags", [])),
         {:ok, metadata} <- normalize_metadata(value(args, "metadata", %{})),
         {:ok, tags_json} <- encode_json(tags),
         {:ok, metadata_json} <- encode_json(metadata) do
      {:ok,
       %{
         tags: tags,
         metadata: metadata,
         tags_json: tags_json,
         metadata_json: metadata_json
       }}
    end
  end

  def normalize_tags(nil), do: {:ok, []}

  def normalize_tags(tags) when is_list(tags) do
    normalized =
      tags
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, normalized}
  end

  def normalize_tags(_tags), do: {:error, {:invalid_args, "tags must be a list of strings"}}

  def normalize_metadata(nil), do: {:ok, %{}}

  def normalize_metadata(metadata) when is_map(metadata) do
    normalized = stringify_keys(metadata)

    case Jason.encode(normalized) do
      {:ok, _json} -> {:ok, normalized}
      {:error, _reason} -> {:error, {:invalid_args, "metadata must be JSON encodable"}}
    end
  end

  def normalize_metadata(_metadata), do: {:error, {:invalid_args, "metadata must be an object"}}

  @doc "Returns an escaped, lowercase LIKE pattern using backslash as escape."
  def like_pattern(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.downcase()
    |> String.graphemes()
    |> Enum.map(fn
      "\\" -> "\\\\"
      "%" -> "\\%"
      "_" -> "\\_"
      char -> char
    end)
    |> Enum.join()
    |> then(&"%#{&1}%")
  end

  @doc "Validates a required, non-empty string argument."
  def required_string(args, key) when is_map(args) do
    case optional_trimmed(args, key) do
      nil -> {:error, {:invalid_args, "#{key} is required"}}
      value -> {:ok, value}
    end
  end

  @doc "Returns a trimmed optional string argument."
  def optional_string(args, key) when is_map(args), do: optional_trimmed(args, key)

  @doc "Returns a bounded integer limit."
  def limit(args, default \\ 10, max \\ @max_limit) do
    args
    |> value("limit", default)
    |> normalize_integer(default, 1, max)
  end

  @doc "Returns a non-negative integer offset."
  def offset(args) do
    args
    |> value("offset", 0)
    |> normalize_integer(0, 0, 1_000_000)
  end

  @doc "Formats and rank-merges recall rows."
  def rank_hits(rows, query, limit) when is_list(rows) and is_binary(query) do
    prepared_query = String.downcase(String.trim(query))
    tokens = query_tokens(prepared_query)

    rows
    |> Enum.map(&ranked_hit(&1, prepared_query, tokens))
    |> Enum.sort_by(fn {hit, rank} ->
      {
        -rank.text_score,
        source_rank(hit["source"]),
        -rank.confidence,
        rank.newer_sort_key,
        hit["id"]
      }
    end)
    |> Enum.take(limit)
    |> Enum.map(fn {hit, _rank} -> hit end)
  end

  @doc "Formats a DB row as a JSON-compatible memory hit/item."
  def row_to_item(row, score \\ 0.0) when is_map(row) do
    %{
      "id" => row["id"],
      "content" => row["content"],
      "scope" => row["scope"],
      "source" => row["source"] || "local",
      "quality" => "degraded",
      "tags" => decode_json(row["tags"], []),
      "metadata" => decode_json(row["metadata"], %{}),
      "score" => score
    }
  end

  def value(map, key, default \\ nil) when is_map(map) and is_binary(key) do
    Map.get(map, key, Map.get(map, String.to_atom(key), default))
  end

  def encode_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, {:invalid_args, "value must be JSON encodable"}}
    end
  end

  def decode_json(nil, default), do: default

  def decode_json(json, default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  end

  def decode_json(_json, default), do: default

  defp ranked_hit(row, query, tokens) do
    content = row["content"] || ""
    content_downcase = String.downcase(content)
    text_score = text_score(content_downcase, query, tokens)
    confidence = numeric(row["confidence"], 1.0)
    timestamp = row["inserted_at"] || row["updated_at"] || ""
    score = text_score + confidence / 100.0

    hit = row_to_item(row, Float.round(score, 6))

    {hit,
     %{
       text_score: text_score,
       confidence: confidence,
       newer_sort_key: newer_sort_key(timestamp)
     }}
  end

  defp text_score(content, query, _tokens) when query != "" do
    if String.contains?(content, query) do
      2.0
    else
      0.0
    end
  end

  defp text_score(_content, _query, []), do: 0.0

  defp text_score(content, _query, tokens) do
    matches = Enum.count(tokens, &String.contains?(content, &1))
    matches / max(length(tokens), 1)
  end

  defp query_tokens(query) do
    query
    |> String.split(~r/\s+/, trim: true)
    |> Enum.uniq()
  end

  defp source_rank("hub_fact"), do: 0
  defp source_rank(:hub_fact), do: 0
  defp source_rank(_source), do: 1

  defp newer_sort_key(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> -DateTime.to_unix(datetime, :microsecond)
      _ -> 0
    end
  end

  defp newer_sort_key(_timestamp), do: 0

  defp optional_trimmed(args, key) do
    case value(args, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp config_value(config, key), do: Map.get(config, key, Map.get(config, Atom.to_string(key)))

  defp normalize_integer(value, _default, min, max) when is_integer(value) do
    value |> Kernel.max(min) |> Kernel.min(max)
  end

  defp normalize_integer(value, default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> normalize_integer(parsed, default, min, max)
      _ -> default
    end
  end

  defp normalize_integer(_value, default, _min, _max), do: default

  defp stringify_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_keys(value)} end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp numeric(value, _default) when is_integer(value), do: value * 1.0
  defp numeric(value, _default) when is_float(value), do: value

  defp numeric(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> default
    end
  end

  defp numeric(_value, default), do: default
end
