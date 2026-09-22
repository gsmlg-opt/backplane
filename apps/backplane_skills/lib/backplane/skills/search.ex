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
    - :archive_only - only return archive-backed skills with canonical archive refs
  """
  @archive_ref_pattern "^sha256/[a-f0-9]{64}\\.tar\\.gz$"
  @spec query(String.t(), keyword()) :: [map()]
  def query(search_query, opts \\ []) do
    %{results: results} = query_page(search_query, Keyword.put(opts, :offset, 0))
    results
  end

  @doc """
  Search skills and return one deterministic offset-based page.

  The page fetches one extra result to determine whether another page exists.
  """
  @spec query_page(String.t(), keyword()) :: %{
          results: [map()],
          limit: pos_integer(),
          offset: non_neg_integer(),
          next_offset: non_neg_integer() | nil
        }
  def query_page(search_query, opts \\ []) do
    tags = Keyword.get(opts, :tags, [])
    limit = normalize_limit(Keyword.get(opts, :limit, 10))
    offset = normalize_offset(Keyword.get(opts, :offset, 0))
    archive_only? = Keyword.get(opts, :archive_only, false)

    results =
      Skill
      |> where([s], s.enabled == true)
      |> apply_text_search(search_query)
      |> apply_tag_filter(tags)
      |> apply_archive_filter(archive_only?)
      |> order_by_relevance(search_query)
      |> offset(^offset)
      |> limit(^(limit + 1))
      |> Repo.all()

    {page, remaining} = Enum.split(results, limit)

    %{
      results: Enum.map(page, &to_result/1),
      limit: limit,
      offset: offset,
      next_offset: if(remaining == [], do: nil, else: offset + limit)
    }
  end

  @max_query_length 500
  @max_page_size 100

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_page_size)
  defp normalize_limit(_limit), do: 10

  defp normalize_offset(offset) when is_integer(offset), do: max(offset, 0)
  defp normalize_offset(_offset), do: 0

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

  defp apply_archive_filter(query, true) do
    where(
      query,
      [s],
      s.source_kind == "archive" and not is_nil(s.archive_ref) and
        fragment("? ~ ?", s.archive_ref, ^@archive_ref_pattern)
    )
  end

  defp apply_archive_filter(query, _archive_only?), do: query

  defp order_by_relevance(query, search) when is_binary(search) and search != "" do
    sanitized = search |> String.replace(<<0>>, "") |> String.slice(0, @max_query_length)

    order_by(
      query,
      [s],
      desc: fragment("ts_rank(search_vector, plainto_tsquery('english', ?))", ^sanitized),
      asc: s.id
    )
  end

  defp order_by_relevance(query, _), do: order_by(query, [s], asc: s.name, asc: s.id)

  defp to_result(%Skill{} = s) do
    %{
      id: s.id,
      slug: s.slug,
      name: s.name,
      description: s.description,
      tags: s.tags,
      category: s.category,
      version: s.version,
      license: s.license,
      homepage: s.homepage,
      content_hash: s.content_hash,
      archive_ref: s.archive_ref,
      size_bytes: s.size_bytes,
      file_count: s.file_count,
      source_kind: s.source_kind,
      source_uri: s.source_uri,
      source_rev: s.source_rev,
      current_revision: s.current_revision
    }
  end
end
