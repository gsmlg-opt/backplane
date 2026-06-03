defmodule BackplaneMemory.Memories.Search do
  @moduledoc """
  Vector recall over `bpm_memories.embedding` using pgvector cosine distance.

  Embedding is generated through an injectable function so tests can run without
  the LLM proxy. Production callers use the default `Embedding.Client.embed/3`.

  `hybrid_recall/2` prefers vector search when it is configured and available,
  and falls back to full-text search when vector search is not ready.
  """

  import Ecto.Query

  alias BackplaneMemory.Embedding.Client
  alias BackplaneMemory.Memories.Memory, as: M
  alias Pgvector.HalfVector

  @default_limit 10
  # RRF constant
  @rrf_k 60

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @type result :: %{
          id: String.t(),
          content: String.t(),
          scope: String.t(),
          memory_type: String.t(),
          agent_id: String.t(),
          host_id: String.t(),
          tags: [String.t()],
          metadata: map(),
          inserted_at: DateTime.t(),
          distance: float(),
          confidence: float()
        }

  @doc """
  Recall the most similar memories to `query` ranked by cosine distance.

  Options:
  - `:limit` (default #{@default_limit})
  - `:scope`, `:agent_id`, `:host_id`, `:tag` — equality / membership filters
  - `:embed_fn` — `(texts, mode, opts) -> {:ok, [vector]} | {:error, term}`, defaults to `Embedding.Client.embed/3`
  """
  @spec recall(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def recall(query, opts \\ []) when is_binary(query) do
    embed_fn = Keyword.get(opts, :embed_fn, &Client.embed/3)
    limit = Keyword.get(opts, :limit, @default_limit)

    with {:ok, [vector]} <- embed_fn.([query], :query, []) do
      hv = HalfVector.new(vector)

      rows =
        M
        |> where([m], is_nil(m.deleted_at) and not is_nil(m.embedding))
        |> apply_filters(opts)
        |> order_by([m], fragment("? <=> ?", m.embedding, ^hv))
        |> limit(^limit)
        |> select([m], %{
          id: m.id,
          content: m.content,
          scope: m.scope,
          memory_type: m.memory_type,
          agent_id: m.agent_id,
          host_id: m.host_id,
          tags: m.tags,
          metadata: m.metadata,
          inserted_at: m.inserted_at,
          distance: fragment("? <=> ?", m.embedding, ^hv),
          confidence: m.confidence
        })
        |> repo().all()

      writeback_fn =
        Keyword.get(opts, :writeback_fn, &BackplaneMemory.Workers.AccessWritebackWorker.enqueue/1)

      if rows != [], do: writeback_fn.(Enum.map(rows, & &1.id))

      {:ok, rows}
    end
  end

  defp apply_filters(query, opts) do
    Enum.reduce(opts, query, &apply_filter/2)
  end

  defp apply_filter({:scope, v}, q) when is_binary(v) and v != "",
    do: where(q, [m], m.scope == ^v)

  defp apply_filter({:agent_id, v}, q) when is_binary(v) and v != "",
    do: where(q, [m], m.agent_id == ^v)

  defp apply_filter({:host_id, v}, q) when is_binary(v) and v != "",
    do: where(q, [m], m.host_id == ^v)

  defp apply_filter({:tag, v}, q) when is_binary(v) and v != "",
    do: where(q, [m], ^v in m.tags)

  defp apply_filter({:min_confidence, v}, q) when is_float(v),
    do: where(q, [m], m.confidence >= ^v)

  defp apply_filter(_, q), do: q

  @doc """
  Vector-preferred recall with full-text fallback.

  When vector search is configured and returns rows, only vector rows are
  returned. When vector search is unavailable, fails, or has no embedded rows
  for the active filters, recall degrades to FTS-only and does not expose
  embedder/provider errors to clients.

  FTS fallback uses Reciprocal Rank Fusion (RRF) across expanded text queries.
  Returns top-N results deduped by memory ID.

  Options:
  - `:limit` (default #{@default_limit})
  - `:embed_fn` — injectable embed function (same as `recall/2`)
  - other opts forwarded to `recall/2` as filters
  """
  @spec hybrid_recall(String.t(), keyword()) :: {:ok, [result()]}
  def hybrid_recall(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, @default_limit)
    queries = maybe_expand_query(query, opts)

    result =
      case vector_recall(queries, opts) do
        {:ok, rows} when rows != [] ->
          rows
          |> rerank_results(query, opts)
          |> Enum.take(limit)

        _ ->
          text_recall(query, queries, opts)
      end

    writeback_fn =
      Keyword.get(opts, :writeback_fn, &BackplaneMemory.Workers.AccessWritebackWorker.enqueue/1)

    if result != [], do: writeback_fn.(Enum.map(result, & &1.id))

    {:ok, result}
  end

  defp maybe_expand_query(query, opts) do
    enabled = Backplane.Settings.get("memory.query_expansion_enabled") == "true"

    llm_module =
      Keyword.get(
        opts,
        :llm_module,
        Application.get_env(:backplane_memory, :llm_module, BackplaneMemory.LLM)
      )

    if enabled do
      case llm_module.expand_query(query) do
        {:ok, queries} -> Enum.uniq([query | queries])
        {:skip, _} -> [query]
      end
    else
      [query]
    end
  end

  defp maybe_rerank(query, candidates, opts) do
    enabled = Backplane.Settings.get("memory.reranker_enabled") == "true"

    llm_module =
      Keyword.get(
        opts,
        :llm_module,
        Application.get_env(:backplane_memory, :llm_module, BackplaneMemory.LLM)
      )

    k = Application.get_env(:backplane_memory, :reranker_top_k, 20)

    if enabled and length(candidates) > 0 do
      top_k = Enum.take(candidates, k)

      case llm_module.rerank(query, top_k) do
        {:ok, reranked} -> reranked
        {:skip, _} -> candidates
      end
    else
      candidates
    end
  end

  defp dedup_by_id(rows) do
    rows |> Enum.uniq_by(& &1.id)
  end

  defp vector_recall(queries, opts) do
    if vector_search_configured?(opts) do
      rows =
        queries
        |> Enum.flat_map(fn q ->
          case recall(q, Keyword.put(opts, :writeback_fn, fn _ids -> :ok end)) do
            {:ok, rows} -> rows
            {:error, _reason} -> []
          end
        end)
        |> dedup_by_id()

      {:ok, rows}
    else
      {:error, :vector_search_not_configured}
    end
  end

  defp vector_search_configured?(opts) do
    Keyword.has_key?(opts, :embed_fn) or
      Client.configured?()
  end

  defp text_recall(query, queries, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    queries
    |> Enum.map(&fts_search(&1, opts))
    |> rrf_fuse()
    |> rerank_results(query, opts)
    |> Enum.take(limit)
  end

  defp fts_search(query, opts) do
    M
    |> where([m], is_nil(m.deleted_at))
    |> where([m], fragment("? @@ plainto_tsquery('english', ?)", m.search_tsv, ^query))
    |> apply_filters(opts)
    |> order_by([m],
      desc: fragment("ts_rank(?, plainto_tsquery('english', ?))", m.search_tsv, ^query),
      desc: m.inserted_at
    )
    |> limit(50)
    |> select([m], %{
      id: m.id,
      content: m.content,
      scope: m.scope,
      memory_type: m.memory_type,
      agent_id: m.agent_id,
      host_id: m.host_id,
      tags: m.tags,
      metadata: m.metadata,
      inserted_at: m.inserted_at,
      distance: 0.0,
      confidence: m.confidence
    })
    |> repo().all()
  end

  defp rerank_results(results, query, opts) do
    maybe_rerank(query, results, opts)
  end

  # RRF: score = sum(1 / (k + rank)) across streams, multiplied by confidence; rank is 1-based
  defp rrf_fuse(streams) do
    streams
    |> Enum.flat_map(fn stream ->
      stream
      |> Enum.with_index(1)
      |> Enum.map(fn {row, rank} -> {row.id, row, 1.0 / (@rrf_k + rank)} end)
    end)
    |> Enum.group_by(fn {id, _row, _score} -> id end)
    |> Enum.map(fn {_id, entries} ->
      total_score = Enum.reduce(entries, 0.0, fn {_, _, score}, acc -> acc + score end)

      # Prefer the row with the smallest real (non-zero) distance (i.e. vector result)
      best_row =
        entries
        |> Enum.map(fn {_, row, _} -> row end)
        |> Enum.min_by(fn row -> if row.distance > 0.0, do: row.distance, else: 1.0 end)

      final_score = total_score * best_row.confidence
      {final_score, best_row}
    end)
    |> Enum.sort_by(fn {score, _} -> score end, :desc)
    |> Enum.map(fn {_score, row} -> row end)
  end
end
