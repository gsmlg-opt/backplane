defmodule BackplaneMemory.Memories.Search do
  @moduledoc """
  Vector recall over `bpm_memories.embedding` using pgvector cosine distance.

  Embedding is generated through an injectable function so tests can run without
  the LLM proxy. Production callers use the default `Embedding.Client.embed/3`.

  `hybrid_recall/2` fuses three streams — vector, FTS, and graph — via RRF.
  """

  import Ecto.Query

  alias BackplaneMemory.Embedding.Client
  alias BackplaneMemory.Graph.BFS
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
          distance: float()
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
          distance: fragment("? <=> ?", m.embedding, ^hv)
        })
        |> repo().all()

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

  defp apply_filter(_, q), do: q

  @doc """
  Hybrid recall fusing three ranked streams via Reciprocal Rank Fusion (RRF).

  Streams:
  1. Vector recall (`recall/2`) — ranked by cosine distance
  2. FTS — `plainto_tsquery` match on `search_tsv`
  3. Graph — BFS from nouns in query; returns memories referenced in
     `source_observation_ids` of matched nodes

  RRF score = sum(1 / (#{@rrf_k} + rank)) across all streams.
  Returns top-N results deduped by memory ID, ordered by descending score.

  Options:
  - `:limit` (default #{@default_limit})
  - `:embed_fn` — injectable embed function (same as `recall/2`)
  - other opts forwarded to `recall/2` as filters
  """
  @spec hybrid_recall(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def hybrid_recall(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, @default_limit)

    vector_stream =
      case recall(query, opts) do
        {:ok, rows} -> rows
        {:error, _} -> []
      end

    fts_stream = fts_search(query, opts)

    graph_stream = graph_search(query)

    fused =
      [vector_stream, fts_stream, graph_stream]
      |> rrf_fuse()
      |> Enum.take(limit)

    {:ok, fused}
  end

  defp fts_search(query, opts) do
    M
    |> where([m], is_nil(m.deleted_at))
    |> where([m], fragment("? @@ plainto_tsquery('english', ?)", m.search_tsv, ^query))
    |> apply_filters(opts)
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
      distance: 0.0
    })
    |> repo().all()
  end

  defp graph_search(query) do
    # Use each word as a potential entity name for BFS
    words =
      query
      |> String.split(~r/\s+/, trim: true)
      |> Enum.filter(&(String.length(&1) > 3))

    obs_ids =
      words
      |> Enum.flat_map(fn word ->
        case BFS.query(word, 1) do
          {:ok, %{nodes: nodes}} -> Enum.flat_map(nodes, & &1.source_observation_ids)
          _ -> []
        end
      end)
      |> Enum.uniq()

    if obs_ids == [] do
      []
    else
      M
      |> where([m], m.id in ^obs_ids and is_nil(m.deleted_at))
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
        distance: 0.0
      })
      |> repo().all()
    end
  end

  # RRF: score = sum(1 / (k + rank)) across streams; rank is 1-based
  defp rrf_fuse(streams) do
    streams
    |> Enum.flat_map(fn stream ->
      stream
      |> Enum.with_index(1)
      |> Enum.map(fn {row, rank} -> {row.id, row, 1.0 / (@rrf_k + rank)} end)
    end)
    |> Enum.group_by(fn {id, _row, _score} -> id end)
    |> Enum.map(fn {_id, entries} ->
      {_id, row, _} = hd(entries)
      total_score = Enum.reduce(entries, 0.0, fn {_, _, score}, acc -> acc + score end)
      {total_score, row}
    end)
    |> Enum.sort_by(fn {score, _} -> score end, :desc)
    |> Enum.map(fn {_score, row} -> row end)
  end
end
