defmodule Backplane.Docs.Search do
  @moduledoc """
  Full-text search over doc chunks using PostgreSQL tsvector.
  """

  import Ecto.Query
  alias Backplane.Docs.{DocChunk, Project}
  alias Backplane.Repo

  @default_limit 20
  @default_max_tokens 8000

  # Chunk type weight multipliers for ranking.
  # moduledoc > function_doc > typespec > guide > code (PRD BP-2)
  @chunk_type_weights %{
    "moduledoc" => 1.5,
    "module_doc" => 1.5,
    "function_doc" => 1.3,
    "typespec" => 1.1,
    "guide" => 1.0,
    "code" => 0.8
  }
  @default_chunk_weight 1.0

  @doc """
  Search doc chunks for a project using full-text search.

  Options:
    - :limit — max results (default 20)
    - :max_tokens — token budget (default 8000)
    - :chunk_type — filter by chunk type
  """
  @spec query(String.t(), String.t() | nil, keyword()) :: [map()]
  def query(project_id, search_query, opts \\ [])
  def query(_project_id, "", _opts), do: []
  def query(_project_id, nil, _opts), do: []

  def query(project_id, search_query, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    chunk_type = Keyword.get(opts, :chunk_type)

    tsquery = sanitize_query(search_query)

    base =
      DocChunk
      |> where([c], c.project_id == ^project_id)
      |> where(
        [c],
        fragment("search_vector @@ websearch_to_tsquery('english', ?)", ^tsquery)
      )
      |> order_by(
        [c],
        desc: fragment("ts_rank(search_vector, websearch_to_tsquery('english', ?))", ^tsquery)
      )

    base =
      if chunk_type do
        base |> where([c], c.chunk_type == ^chunk_type)
      else
        base
      end

    base
    |> limit(^limit)
    |> select([c], %{
      id: c.id,
      source_path: c.source_path,
      module: c.module,
      function: c.function,
      chunk_type: c.chunk_type,
      content: c.content,
      tokens: c.tokens,
      rank: fragment("ts_rank(search_vector, websearch_to_tsquery('english', ?))", ^tsquery)
    })
    |> Repo.all()
    |> apply_chunk_type_weights()
    |> apply_token_budget(max_tokens)
  end

  @doc """
  List all projects with their chunk counts.
  """
  @spec list_projects() :: [map()]
  def list_projects do
    from(p in Project,
      left_join: c in DocChunk,
      on: c.project_id == p.id,
      group_by: p.id,
      select: %{
        id: p.id,
        repo: p.repo,
        ref: p.ref,
        description: p.description,
        last_indexed_at: p.last_indexed_at,
        chunk_count: count(c.id)
      }
    )
    |> Repo.all()
  end

  defp apply_chunk_type_weights(results) do
    results
    |> Enum.map(fn result ->
      weight = Map.get(@chunk_type_weights, result.chunk_type, @default_chunk_weight)
      %{result | rank: result.rank * weight}
    end)
    |> Enum.sort_by(& &1.rank, :desc)
  end

  defp apply_token_budget(results, max_tokens) do
    {selected, _remaining} =
      Enum.reduce(results, {[], max_tokens}, fn result, {acc, budget} ->
        tokens = result.tokens || 0

        if budget - tokens >= 0 do
          {[result | acc], budget - tokens}
        else
          # Skip this chunk but continue — a smaller chunk may still fit
          {acc, budget}
        end
      end)

    Enum.reverse(selected)
  end

  defp sanitize_query(query) do
    # websearch_to_tsquery handles most sanitization,
    # but strip null bytes just in case
    String.replace(query, <<0>>, "")
  end
end
