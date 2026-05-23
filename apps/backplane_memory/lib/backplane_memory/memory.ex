defmodule BackplaneMemory.Memory do
  @moduledoc "Context API: remember, get, forget, stats."

  import Ecto.Query

  alias Backplane.Repo
  alias BackplaneMemory.Memories.Memory, as: MemorySchema
  alias BackplaneMemory.Privacy.Filter
  alias BackplaneMemory.Workers.EmbedWorker

  @dedup_window_seconds 86_400

  @non_vector_fields [
    :id,
    :content,
    :memory_type,
    :scope,
    :agent_id,
    :host_id,
    :client_id,
    :session_id,
    :tags,
    :metadata,
    :embedding_model,
    :content_hash,
    :confidence,
    :access_count,
    :accessed_at,
    :superseded_by,
    :expires_at,
    :deleted_at,
    :inserted_at,
    :updated_at
  ]

  @doc """
  Persist a memory. Deduplicates by sha256(content) within the same scope over a 24-hour window.
  Options: type (default "semantic"), scope (default "global"), agent_id, host_id,
           client_id, session_id, tags, metadata.
  """
  @spec remember(String.t(), keyword()) :: {:ok, MemorySchema.t()} | {:error, term()}
  def remember(content, opts \\ []) do
    with {:ok, filtered} <- Filter.apply(content) do
      attrs = build_attrs(filtered, opts)
      hash = :crypto.hash(:sha256, filtered)

      case find_duplicate(hash, attrs.scope) do
        %MemorySchema{} = existing ->
          {:ok, existing}

        nil ->
          %MemorySchema{}
          |> MemorySchema.changeset(attrs)
          |> Repo.insert()
          |> tap_enqueue_embed()
      end
    end
  end

  @doc "Fetch a non-deleted memory by id."
  @spec get(String.t()) :: {:ok, MemorySchema.t()} | {:error, :not_found}
  def get(id) do
    query =
      from(m in MemorySchema,
        where: m.id == ^id and is_nil(m.deleted_at),
        select: struct(m, ^@non_vector_fields)
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      mem -> {:ok, mem}
    end
  end

  @doc "Soft-delete a memory by id."
  @spec forget(String.t()) :: :ok | {:error, :not_found}
  def forget(id) do
    case Repo.one(
           from(m in MemorySchema,
             where: m.id == ^id and is_nil(m.deleted_at),
             select: struct(m, ^@non_vector_fields)
           )
         ) do
      nil ->
        {:error, :not_found}

      mem ->
        mem
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Repo.update!()

        :ok
    end
  end

  @doc "Return counts grouped by memory_type (non-deleted rows only)."
  @spec stats() :: [%{memory_type: String.t(), count: integer()}]
  def stats do
    MemorySchema
    |> where([m], is_nil(m.deleted_at))
    |> group_by([m], m.memory_type)
    |> select([m], %{memory_type: m.memory_type, count: count(m.id)})
    |> Repo.all()
  end

  defp build_attrs(content, opts) do
    %{
      content: content,
      memory_type: Keyword.get(opts, :type, "semantic"),
      scope: Keyword.get(opts, :scope, "global"),
      agent_id: Keyword.get(opts, :agent_id, ""),
      host_id: Keyword.get(opts, :host_id, ""),
      client_id: Keyword.get(opts, :client_id),
      session_id: Keyword.get(opts, :session_id),
      tags: Keyword.get(opts, :tags, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp find_duplicate(content_hash, scope) do
    window_start = DateTime.add(DateTime.utc_now(), -@dedup_window_seconds, :second)

    MemorySchema
    |> where([m], m.content_hash == ^content_hash)
    |> where([m], m.scope == ^scope)
    |> where([m], is_nil(m.deleted_at))
    |> where([m], m.inserted_at >= ^window_start)
    |> select([m], struct(m, ^@non_vector_fields))
    |> limit(1)
    |> Repo.one()
  end

  defp tap_enqueue_embed({:ok, mem} = result) do
    EmbedWorker.enqueue(mem.id)
    result
  end

  defp tap_enqueue_embed(error), do: error
end
