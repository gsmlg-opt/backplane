defmodule Backplane.Skills.Search do
  @moduledoc """
  Full-text search for skills using PostgreSQL tsvector.
  Optionally reranks results using embedding similarity when configured.
  """

  import Ecto.Query
  alias Backplane.Repo
  alias Backplane.Skills.Skill
  alias Backplane.Utils

  @doc """
  Search skills by query string with optional filters.

  Options:
    - :tags - list of tags (AND match)
    - :tools - list of required tools (AND match)
    - :source - source type filter (e.g., "git", "local", "db")
    - :limit - max results (default 10)
    - :rerank - enable semantic reranking via embeddings (default: true when configured)
  """
  @spec query(String.t(), keyword()) :: [map()]
  def query(search_query, opts \\ []) do
    tags = Keyword.get(opts, :tags, [])
    tools = Keyword.get(opts, :tools, [])
    source = Keyword.get(opts, :source)
    limit = Keyword.get(opts, :limit, 10)
    rerank? = Keyword.get(opts, :rerank, Backplane.Embeddings.configured?())

    # Over-fetch when reranking to give semantic similarity more candidates
    db_limit = if rerank?, do: limit * 3, else: limit

    results =
      Skill
      |> where([s], s.enabled == true)
      |> apply_text_search(search_query)
      |> apply_tag_filter(tags)
      |> apply_tools_filter(tools)
      |> apply_source_filter(source)
      |> order_by_relevance(search_query)
      |> limit(^db_limit)
      |> Repo.all()

    results =
      if rerank? and is_binary(search_query) and search_query != "" do
        apply_semantic_reranking(results, search_query)
      else
        results
      end

    results
    |> Enum.take(limit)
    |> Enum.map(&to_result/1)
  end

  @max_query_length 500

  defp apply_text_search(query, search) when is_binary(search) and search != "" do
    sanitized = search |> String.replace(<<0>>, "") |> String.slice(0, @max_query_length)

    where(
      query,
      [s],
      fragment("search_vector @@ plainto_tsquery('english', ?)", ^sanitized)
    )
  end

  defp apply_text_search(query, _), do: query

  defp apply_tag_filter(query, tags) when tags in [nil, []], do: query

  defp apply_tag_filter(query, tags) do
    where(query, [s], fragment("tags @> ?::text[]", ^tags))
  end

  defp apply_tools_filter(query, tools) when tools in [nil, []], do: query

  defp apply_tools_filter(query, tools) do
    where(query, [s], fragment("tools @> ?::text[]", ^tools))
  end

  defp apply_source_filter(query, nil), do: query

  defp apply_source_filter(query, source) do
    # Match exact or prefix (e.g., "git" matches "git:elixir-patterns")
    escaped = Utils.escape_like(source)
    where(query, [s], s.source == ^source or like(s.source, ^"#{escaped}:%"))
  end

  defp order_by_relevance(query, search) when is_binary(search) and search != "" do
    sanitized = search |> String.replace(<<0>>, "") |> String.slice(0, @max_query_length)

    order_by(
      query,
      [s],
      desc: fragment("ts_rank(search_vector, plainto_tsquery('english', ?))", ^sanitized)
    )
  end

  defp order_by_relevance(query, _), do: order_by(query, [s], asc: s.name)

  @tsvector_weight 0.7
  @cosine_weight 0.3

  defp apply_semantic_reranking(results, query_text) do
    has_embeddings? = Enum.any?(results, fn s -> s.embedding != nil end)

    if has_embeddings? do
      case Backplane.Embeddings.embed(query_text) do
        {:ok, query_vec} ->
          # Compute ts_rank-equivalent score for blending (use position as proxy)
          total = length(results)

          results
          |> Enum.with_index()
          |> Enum.map(fn {skill, idx} ->
            # Normalize tsvector rank to 0..1 based on position
            ts_score = (total - idx) / total

            cosine_sim =
              if skill.embedding do
                cosine_similarity(query_vec, embedding_to_list(skill.embedding))
              else
                0.0
              end

            blended = @tsvector_weight * ts_score + @cosine_weight * cosine_sim
            {skill, blended}
          end)
          |> Enum.sort_by(fn {_, score} -> score end, :desc)
          |> Enum.map(fn {skill, _} -> skill end)

        {:error, _} ->
          results
      end
    else
      results
    end
  end

  defp cosine_similarity(a, b) when length(a) == length(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    mag_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    mag_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if mag_a == 0.0 or mag_b == 0.0, do: 0.0, else: dot / (mag_a * mag_b)
  end

  defp cosine_similarity(_, _), do: 0.0

  defp embedding_to_list(%Pgvector{} = v), do: Pgvector.to_list(v)
  defp embedding_to_list(v) when is_list(v), do: v
  defp embedding_to_list(_), do: []

  defp to_result(%Skill{} = s) do
    %{
      id: s.id,
      name: s.name,
      description: s.description,
      tags: s.tags,
      version: s.version,
      source: s.source
    }
  end
end
