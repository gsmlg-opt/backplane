defmodule Backplane.Skills.Search do
  @moduledoc """
  Full-text search for skills using PostgreSQL tsvector.
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
  """
  @spec query(String.t(), keyword()) :: [map()]
  def query(search_query, opts \\ []) do
    tags = Keyword.get(opts, :tags, [])
    tools = Keyword.get(opts, :tools, [])
    source = Keyword.get(opts, :source)
    limit = Keyword.get(opts, :limit, 10)

    Skill
    |> where([s], s.enabled == true)
    |> apply_text_search(search_query)
    |> apply_tag_filter(tags)
    |> apply_tools_filter(tools)
    |> apply_source_filter(source)
    |> order_by_relevance(search_query)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&to_result/1)
  end

  defp apply_text_search(query, search) when is_binary(search) and search != "" do
    where(
      query,
      [s],
      fragment("search_vector @@ plainto_tsquery('english', ?)", ^search)
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
    order_by(
      query,
      [s],
      desc: fragment("ts_rank(search_vector, plainto_tsquery('english', ?))", ^search)
    )
  end

  defp order_by_relevance(query, _), do: order_by(query, [s], asc: s.name)

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
