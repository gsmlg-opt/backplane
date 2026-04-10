defmodule Backplane.Skills.Search do
  @moduledoc """
  Full-text search for skills using PostgreSQL tsvector.
  """

  import Ecto.Query
  alias Backplane.Repo
  alias Backplane.Skills.Skill

  @doc """
  Search skills by query string with optional filters.

  Options:
    - :tags - list of tags (AND match)
    - :limit - max results (default 10)
  """
  @spec query(String.t(), keyword()) :: [map()]
  def query(search_query, opts \\ []) do
    tags = Keyword.get(opts, :tags, [])
    limit = Keyword.get(opts, :limit, 10)

    Skill
    |> where([s], s.enabled == true)
    |> apply_text_search(search_query)
    |> apply_tag_filter(tags)
    |> order_by_relevance(search_query)
    |> limit(^limit)
    |> Repo.all()
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

  defp order_by_relevance(query, search) when is_binary(search) and search != "" do
    sanitized = search |> String.replace(<<0>>, "") |> String.slice(0, @max_query_length)

    order_by(
      query,
      [s],
      desc: fragment("ts_rank(search_vector, plainto_tsquery('english', ?))", ^sanitized)
    )
  end

  defp order_by_relevance(query, _), do: order_by(query, [s], asc: s.name)

  defp to_result(%Skill{} = s) do
    %{
      id: s.id,
      name: s.name,
      description: s.description,
      tags: s.tags
    }
  end
end
