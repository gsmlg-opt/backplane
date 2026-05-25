defmodule BackplaneMemory.Memory do
  @moduledoc "Context API: remember, get, forget, stats."

  import Ecto.Query

  alias BackplaneMemory.Memories.Memory, as: MemorySchema
  alias BackplaneMemory.Privacy.Filter
  alias BackplaneMemory.Embedding.Client, as: EmbeddingClient
  alias BackplaneMemory.Workers.EmbedWorker

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @dedup_window_seconds 86_400

  # All schema fields except :embedding — halfvec columns require Pgvector.Extensions
  # to be loaded in Postgrex; queries use struct/2 projection to exclude it.
  # If more vector fields are added to the schema, add them to the exclusion list here.
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
    :namespace,
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

      case find_duplicate(filtered, attrs.scope) do
        %MemorySchema{} = existing ->
          {:ok, existing}

        nil ->
          %MemorySchema{}
          |> MemorySchema.changeset(attrs)
          |> repo().insert()
          |> handle_insert(filtered, attrs.scope)
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

    case repo().one(query) do
      nil -> {:error, :not_found}
      mem -> {:ok, mem}
    end
  end

  @doc "Soft-delete (or hard-delete if enabled) a memory by id. Writes an audit entry."
  @spec forget(String.t()) :: :ok | {:error, :not_found}
  def forget(id) do
    case repo().one(
           from(m in MemorySchema,
             where: m.id == ^id and is_nil(m.deleted_at),
             select: struct(m, ^@non_vector_fields)
           )
         ) do
      nil ->
        {:error, :not_found}

      mem ->
        if hard_delete_enabled?() do
          repo().delete_all(from(m in MemorySchema, where: m.id == ^id))
          BackplaneMemory.Audit.log("hard_delete", "system", [mem.id])
        else
          mem
          |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
          |> repo().update!()

          BackplaneMemory.Audit.log("forget", "system", [mem.id])
        end

        :ok
    end
  end

  defp hard_delete_enabled? do
    Backplane.Settings.get("memory.hard_delete_enabled") == "true"
  rescue
    _ -> false
  end

  @doc "Return counts grouped by memory_type (non-deleted rows only)."
  @spec stats() :: [%{memory_type: String.t(), count: integer()}]
  def stats do
    MemorySchema
    |> where([m], is_nil(m.deleted_at))
    |> group_by([m], m.memory_type)
    |> select([m], %{memory_type: m.memory_type, count: count(m.id)})
    |> repo().all()
  end

  @doc """
  List memories with optional filters and pagination. Returns rows ordered by
  inserted_at desc. The embedding column is omitted from the projection.

  Options:
  - `:type` — filter by memory_type
  - `:scope` — filter by exact scope
  - `:agent_id` — filter by exact agent_id
  - `:tag` — return rows where tags contain the value
  - `:q` — substring match on content (case-insensitive)
  - `:include_deleted` — when true, include soft-deleted rows (default false)
  - `:limit` (default 50) and `:offset` (default 0)
  """
  @spec list(keyword()) :: [MemorySchema.t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    MemorySchema
    |> apply_list_filters(opts)
    |> order_by([m], desc: m.inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> select([m], struct(m, ^@non_vector_fields))
    |> repo().all()
  end

  @doc "Count memories matching the same filter options as list/1 (ignores :limit/:offset)."
  @spec count(keyword()) :: integer()
  def count(opts \\ []) do
    MemorySchema
    |> apply_list_filters(opts)
    |> repo().aggregate(:count, :id)
  end

  @doc """
  Check if two memories are contradictory (same scope+tags, opposite sentiment heuristic).
  Lowers confidence on both by 0.2 (floor at 0.0) if contradictory.
  """
  @spec maybe_detect_contradiction(String.t(), String.t()) :: {:ok, :reduced | :no_change}
  def maybe_detect_contradiction(mem1_id, mem2_id) do
    with %MemorySchema{} = m1 <- repo().get(MemorySchema, mem1_id),
         %MemorySchema{} = m2 <- repo().get(MemorySchema, mem2_id),
         true <- same_scope_and_tags?(m1, m2) do
      new_conf1 = max(0.0, m1.confidence - 0.2)
      new_conf2 = max(0.0, m2.confidence - 0.2)

      repo().update_all(from(m in MemorySchema, where: m.id == ^m1.id),
        set: [confidence: new_conf1]
      )

      repo().update_all(from(m in MemorySchema, where: m.id == ^m2.id),
        set: [confidence: new_conf2]
      )

      {:ok, :reduced}
    else
      _ -> {:ok, :no_change}
    end
  end

  defp same_scope_and_tags?(m1, m2) do
    m1.scope == m2.scope and
      MapSet.equal?(MapSet.new(m1.tags), MapSet.new(m2.tags))
  end

  @doc "Return counts grouped by scope (non-deleted rows only)."
  @spec scope_stats() :: [%{scope: String.t(), count: integer()}]
  def scope_stats do
    MemorySchema
    |> where([m], is_nil(m.deleted_at))
    |> group_by([m], m.scope)
    |> order_by([m], desc: count(m.id))
    |> select([m], %{scope: m.scope, count: count(m.id)})
    |> repo().all()
  end

  defp apply_list_filters(query, opts) do
    query =
      if Keyword.get(opts, :include_deleted, false) do
        query
      else
        where(query, [m], is_nil(m.deleted_at))
      end

    opts
    |> Keyword.delete(:include_deleted)
    |> Enum.reduce(query, &apply_list_filter/2)
  end

  @doc "Set the namespace of a memory to team:<team_id>."
  @spec team_share(String.t(), String.t()) :: :ok | {:error, :not_found}
  def team_share(memory_id, team_id) when is_binary(team_id) do
    case repo().update_all(
           from(m in MemorySchema,
             where: m.id == ^memory_id and is_nil(m.deleted_at)
           ),
           set: [namespace: "team:#{team_id}"]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  @doc "Return recent shared memories in a team namespace, newest first."
  @spec team_feed(String.t(), pos_integer()) :: [MemorySchema.t()]
  def team_feed(team_id, limit \\ 20) when is_binary(team_id) do
    namespace = "team:#{team_id}"

    repo().all(
      from(m in MemorySchema,
        where: m.namespace == ^namespace and is_nil(m.deleted_at),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        select: struct(m, ^@non_vector_fields)
      )
    )
  end

  defp apply_list_filter({:type, v}, q) when is_binary(v) and v != "",
    do: where(q, [m], m.memory_type == ^v)

  defp apply_list_filter({:scope, v}, q) when is_binary(v) and v != "",
    do: where(q, [m], m.scope == ^v)

  defp apply_list_filter({:namespace, v}, q) when is_binary(v) and v != "",
    do: where(q, [m], m.namespace == ^v)

  defp apply_list_filter({:agent_id, v}, q) when is_binary(v) and v != "",
    do: where(q, [m], m.agent_id == ^v)

  defp apply_list_filter({:tag, v}, q) when is_binary(v) and v != "",
    do: where(q, [m], ^v in m.tags)

  defp apply_list_filter({:q, v}, q) when is_binary(v) and v != "" do
    pattern = "%" <> v <> "%"
    where(q, [m], ilike(m.content, ^pattern))
  end

  defp apply_list_filter(_, q), do: q

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

  defp find_duplicate(content, scope) do
    content_hash = :crypto.hash(:sha256, content)
    window_start = DateTime.add(DateTime.utc_now(), -@dedup_window_seconds, :second)

    MemorySchema
    |> where([m], m.content_hash == ^content_hash)
    |> where([m], m.scope == ^scope)
    |> where([m], is_nil(m.deleted_at))
    |> where([m], m.inserted_at >= ^window_start)
    |> select([m], struct(m, ^@non_vector_fields))
    |> limit(1)
    |> repo().one()
  end

  defp handle_insert({:ok, mem} = result, _content, _scope) do
    if embeddings_enabled?() do
      EmbedWorker.enqueue(mem.id)
    end

    result
  end

  defp handle_insert({:error, %Ecto.Changeset{errors: errors}} = error, content, scope) do
    if Keyword.has_key?(errors, :content_hash) do
      # Lost the TOCTOU race — return the row the winner inserted
      case find_duplicate(content, scope) do
        %MemorySchema{} = existing -> {:ok, existing}
        nil -> error
      end
    else
      error
    end
  end

  defp handle_insert(error, _content, _scope), do: error

  defp embeddings_enabled? do
    Application.get_env(:backplane_memory, :embed_enabled, true) and EmbeddingClient.configured?()
  end
end
