defmodule BackplaneMemory.Memories.Search do
  @moduledoc """
  Vector recall over `bpm_memories.embedding` using pgvector cosine distance.

  Embedding is generated through an injectable function so tests can run without
  the LLM proxy. Production callers use the default `Embedding.Client.embed/3`.
  """

  import Ecto.Query

  alias BackplaneMemory.Embedding.Client
  alias BackplaneMemory.Memories.Memory, as: M
  alias Pgvector.HalfVector

  @default_limit 10

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
end
