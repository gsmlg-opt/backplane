defmodule Backplane.Memory.Memories do
  @moduledoc "Context API: remember, get, forget, stats."

  import Ecto.Query

  alias Backplane.Memory.Memories.Memory, as: MemorySchema

  alias Backplane.Memory.Memories.{
    Applications,
    Attribution,
    CanonicalRequest,
    Evidence,
    Relation,
    RememberRequest
  }

  alias Backplane.Memory.Memories.Verification
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Config
  alias Backplane.Memory.Projections.ProjectedObservation
  alias Backplane.Memory.Privacy.Filter
  alias Backplane.Memory.Summaries.SourceEvent
  alias Backplane.Memory.Embedding.Client, as: EmbeddingClient
  alias Backplane.Memory.Workers.{EmbedWorker, RelationClassifierWorker}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

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
    :application_count,
    :accessed_at,
    :superseded_by,
    :expires_at,
    :deleted_at,
    :lifecycle_state,
    :namespace,
    :inserted_at,
    :updated_at
  ]

  @evidence_source_fields [
    :source_event_id,
    :source_observation_id,
    :source_summary_id,
    :source_request_id,
    :source_crystal_id,
    :source_session_id
  ]
  @evidence_input_fields @evidence_source_fields ++
                           [
                             :session_id,
                             :agent_id,
                             :host_id,
                             :evidence_kind,
                             :support_score,
                             :excerpt
                           ]
  @evidence_string_fields Map.new(@evidence_input_fields, &{Atom.to_string(&1), &1})

  @doc """
  Persist a memory. Reuses an exact candidate within the complete memory partition.
  Options: type (default "semantic"), scope (default "global"), agent_id, host_id,
           client_id, session_id, tags, metadata, and typed durable evidence.
  """
  @spec remember(String.t(), keyword()) :: {:ok, MemorySchema.t()} | {:error, term()}
  def remember(content, opts \\ []) do
    metadata = %{action: "remember", scope: Keyword.get(opts, :scope, "global")}

    :telemetry.span([:backplane, :memory, :access], metadata, fn ->
      result =
        with :ok <- validate_idempotency_options(opts),
             {:ok, evidence} <- normalize_evidence(Keyword.get(opts, :evidence, [])),
             {:ok, filtered} <- Filter.apply(content),
             attrs = build_attrs(filtered, opts),
             {:ok, request_hash} <- CanonicalRequest.hash(attrs, evidence) do
          persist_remember(attrs, opts, request_hash, evidence)
        end

      status =
        case result do
          {:ok, mem} -> %{status: :ok, memory_id: mem.id}
          {:error, reason} -> %{status: :error, error: inspect(reason)}
          _ -> %{status: :ok}
        end

      {result, Map.merge(metadata, status)}
    end)
  end

  @doc "Return a memory's ordered durable evidence chain and row-derived counts."
  @spec verify(String.t()) :: {:error, :unauthorized}
  def verify(_memory_id), do: {:error, :unauthorized}

  @spec verify(String.t(), map() | keyword()) :: {:ok, map()} | {:error, :not_found}
  def verify(memory_id, partition) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, memory} <- get_any(memory_id, partition) do
      {:ok, Verification.build(memory, partition)}
    end
  end

  @doc "Record one successful, explicitly identified application of a procedural memory."
  @spec record_application(String.t(), String.t(), String.t(), map() | keyword()) ::
          {:ok, %{application_count: non_neg_integer(), applied: boolean()}}
          | {:error, :not_found | :not_applicable | :invalid_application | :unauthorized}
  def record_application(memory_id, application_id, applied_by, partition)
      when is_binary(memory_id) do
    Applications.record(memory_id, application_id, applied_by, partition)
  end

  def record_application(_memory_id, _application_id, _applied_by, _partition),
    do: {:error, :invalid_application}

  if Mix.env() == :test do
    @doc false
    def trusted_verify(memory_id) do
      with {:ok, memory} <- get_any_unpartitioned(memory_id) do
        {:ok, Verification.build(memory, partition_identity(memory))}
      end
    end
  end

  @doc "List a memory's durable evidence in creation and ID order."
  @spec list_evidence(String.t()) :: [map()]
  def list_evidence(memory_id) do
    Evidence
    |> where([e], e.memory_id == ^memory_id)
    |> order_by([e], asc: e.created_at, asc: e.id)
    |> repo().all()
    |> Enum.map(&evidence_view/1)
  end

  @doc "Fetch a non-deleted memory by id."
  @spec get(String.t()) :: {:error, :unauthorized}
  def get(_id), do: {:error, :unauthorized}

  @spec get(String.t(), map() | keyword()) ::
          {:ok, MemorySchema.t()} | {:error, :not_found | :unauthorized}
  def get(id, partition) do
    with {:ok, partition} <- exact_partition(partition) do
      get_partitioned(id, partition)
    end
  end

  if Mix.env() == :test do
    @doc false
    def trusted_get(id), do: get_unpartitioned(id)
  end

  defp get_partitioned(id, partition) do
    metadata = %{action: "get", memory_id: id}

    :telemetry.span([:backplane, :memory, :access], metadata, fn ->
      query =
        from(m in MemorySchema,
          where:
            m.id == ^id and is_nil(m.deleted_at) and m.host_id == ^partition.host_id and
              m.client_id == ^partition.client_id and m.scope == ^partition.scope and
              m.namespace == ^partition.namespace,
          select: struct(m, ^@non_vector_fields)
        )

      result =
        case repo().one(query) do
          nil -> {:error, :not_found}
          mem -> {:ok, mem}
        end

      status =
        case result do
          {:ok, _} -> %{status: :ok}
          {:error, :not_found} -> %{status: :not_found}
        end

      {result, Map.merge(metadata, status)}
    end)
  end

  if Mix.env() == :test do
    defp get_unpartitioned(id) do
      case repo().one(
             from(m in MemorySchema,
               where: m.id == ^id and is_nil(m.deleted_at),
               select: struct(m, ^@non_vector_fields)
             )
           ) do
        nil -> {:error, :not_found}
        memory -> {:ok, memory}
      end
    end
  end

  defp get_any(id, partition) do
    case repo().one(
           from(m in MemorySchema,
             where:
               m.id == ^id and m.host_id == ^partition.host_id and
                 m.client_id == ^partition.client_id and m.scope == ^partition.scope and
                 m.namespace == ^partition.namespace,
             select: struct(m, ^@non_vector_fields)
           )
         ) do
      nil -> {:error, :not_found}
      memory -> {:ok, memory}
    end
  end

  if Mix.env() == :test do
    defp get_any_unpartitioned(id) do
      case repo().one(
             from(m in MemorySchema, where: m.id == ^id, select: struct(m, ^@non_vector_fields))
           ) do
        nil -> {:error, :not_found}
        memory -> {:ok, memory}
      end
    end
  end

  @doc "Soft-delete (or hard-delete if enabled) a memory by id. Writes an audit entry."
  @spec forget(String.t()) :: {:error, :unauthorized}
  def forget(_id), do: {:error, :unauthorized}

  @spec forget(String.t(), map() | keyword()) ::
          :ok | {:error, :not_found | :provenance_retained | :unauthorized}
  def forget(id, partition) do
    with {:ok, partition} <- exact_partition(partition) do
      forget_partitioned(id, partition)
    end
  end

  @doc "Always soft-delete a memory in an exact partition. Writes the ordinary forget audit."
  @spec tombstone(String.t(), map() | keyword()) ::
          :ok | {:error, :not_found | :unauthorized}
  def tombstone(id, partition) do
    with {:ok, partition} <- exact_partition(partition) do
      tombstone_partitioned(id, partition)
    end
  end

  if Mix.env() == :test do
    @doc false
    def trusted_forget(id), do: forget_unpartitioned(id)
  end

  defp forget_partitioned(id, partition) do
    metadata = %{action: "forget", memory_id: id}

    :telemetry.span([:backplane, :memory, :access], metadata, fn ->
      result =
        case repo().transaction(fn -> forget_locked!(id, partition) end) do
          {:ok, :ok} -> :ok
          {:ok, {:denied, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end

      status =
        case result do
          :ok -> %{status: :ok}
          {:error, :not_found} -> %{status: :not_found}
          {:error, :provenance_retained} -> %{status: :provenance_retained}
        end

      {result, Map.merge(metadata, status)}
    end)
  end

  defp tombstone_partitioned(id, partition) do
    metadata = %{action: "forget", memory_id: id}

    :telemetry.span([:backplane, :memory, :access], metadata, fn ->
      result =
        case repo().transaction(fn -> tombstone_locked!(id, partition) end) do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end

      status =
        case result do
          :ok -> %{status: :ok}
          {:error, :not_found} -> %{status: :not_found}
        end

      {result, Map.merge(metadata, status)}
    end)
  end

  if Mix.env() == :test do
    defp forget_unpartitioned(id) do
      case repo().transaction(fn -> forget_locked!(id, nil) end) do
        {:ok, :ok} -> :ok
        {:ok, {:denied, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp forget_locked!(id, partition) do
    memory = lock_active_memory(id, partition)

    hard_delete? = hard_delete_enabled?()

    cond do
      is_nil(memory) ->
        repo().rollback(:not_found)

      hard_delete? and provenance_retained?(memory.id) ->
        Backplane.Memory.Audit.log(
          "hard_delete",
          "system",
          [memory.id],
          memory_audit_metadata(memory, %{
            request_id: Ecto.UUID.generate(),
            result: "denied",
            reason: "provenance_retained"
          })
        )

        {:denied, :provenance_retained}

      hard_delete? ->
        repo().delete!(memory)

        Backplane.Memory.Audit.log(
          "hard_delete",
          "system",
          [memory.id],
          memory_audit_metadata(memory, %{
            request_id: Ecto.UUID.generate(),
            result: "deleted"
          })
        )

        :ok

      true ->
        soft_tombstone_locked!(memory)
    end
  end

  defp tombstone_locked!(id, partition) do
    case lock_active_memory(id, partition) do
      nil -> repo().rollback(:not_found)
      memory -> soft_tombstone_locked!(memory)
    end
  end

  defp lock_active_memory(id, partition) do
    MemorySchema
    |> where([m], m.id == ^id and is_nil(m.deleted_at))
    |> select([m], struct(m, ^@non_vector_fields))
    |> lock("FOR UPDATE")
    |> apply_exact_partition(partition)
    |> repo().one()
  end

  defp soft_tombstone_locked!(memory) do
    memory
    |> MemorySchema.lifecycle_changeset(%{
      deleted_at: DateTime.utc_now(),
      lifecycle_state: "tombstoned",
      superseded_by: nil
    })
    |> repo().update!()

    Backplane.Memory.Audit.log(
      "forget",
      "system",
      [memory.id],
      memory_audit_metadata(memory, %{
        request_id: Ecto.UUID.generate(),
        from: memory.lifecycle_state,
        to: "tombstoned",
        result: "deleted"
      })
    )

    :ok
  end

  defp provenance_retained?(memory_id) do
    repo().exists?(from(e in Evidence, where: e.memory_id == ^memory_id)) or
      repo().exists?(from(r in RememberRequest, where: r.memory_id == ^memory_id)) or
      repo().exists?(from(m in MemorySchema, where: m.superseded_by == ^memory_id)) or
      repo().exists?(
        from(r in Relation,
          where: r.source_memory_id == ^memory_id or r.target_memory_id == ^memory_id
        )
      )
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
  @spec list(keyword()) :: []
  def list(_opts \\ []), do: []

  @spec list(keyword(), map() | keyword()) :: [MemorySchema.t()]
  def list(opts, partition) do
    case exact_partition(partition) do
      {:ok, partition} -> list_partitioned(opts, partition)
      {:error, :unauthorized} -> []
    end
  end

  if Mix.env() == :test do
    @doc false
    def trusted_list(opts \\ []), do: list_partitioned(opts, nil)
  end

  defp list_partitioned(opts, partition) do
    metadata = %{
      action: "list",
      limit: Keyword.get(opts, :limit, 50),
      offset: Keyword.get(opts, :offset, 0)
    }

    :telemetry.span([:backplane, :memory, :access], metadata, fn ->
      limit = Keyword.get(opts, :limit, 50)
      offset = Keyword.get(opts, :offset, 0)

      result =
        MemorySchema
        |> apply_list_filters(opts)
        |> apply_exact_partition(partition)
        |> order_by([m], desc: m.inserted_at)
        |> limit(^limit)
        |> offset(^offset)
        |> select([m], struct(m, ^@non_vector_fields))
        |> repo().all()

      {result, Map.put(metadata, :count, length(result))}
    end)
  end

  @doc "Fail-closed legacy count boundary. Use count/2 with an exact partition."
  @spec count(keyword()) :: 0
  def count(_opts \\ []), do: 0

  @spec count(keyword(), map() | keyword()) :: non_neg_integer()
  def count(opts, partition) do
    case exact_partition(partition) do
      {:ok, partition} -> count_partitioned(opts, partition)
      {:error, :unauthorized} -> 0
    end
  end

  if Mix.env() == :test do
    @doc false
    def trusted_count(opts \\ []), do: count_partitioned(opts, nil)
  end

  defp count_partitioned(opts, partition) do
    MemorySchema
    |> apply_list_filters(opts)
    |> apply_exact_partition(partition)
    |> repo().aggregate(:count, :id)
  end

  @doc "Deprecated compatibility no-op. Contradictions require explicit durable relations."
  @deprecated "Use Backplane.Memory.Memories.Relations.create_candidate/3"
  @spec maybe_detect_contradiction(String.t(), String.t()) :: {:ok, :reduced | :no_change}
  def maybe_detect_contradiction(_mem1_id, _mem2_id), do: {:ok, :no_change}

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
  @spec team_share(String.t(), String.t()) :: {:error, :unauthorized}
  def team_share(_memory_id, _team_id), do: {:error, :unauthorized}

  @spec team_share(String.t(), String.t(), map() | keyword()) ::
          :ok | {:error, :not_found | :unauthorized}
  def team_share(memory_id, team_id, partition) when is_binary(team_id) do
    with {:ok, partition} <- exact_partition(partition) do
      team_share_partitioned(memory_id, team_id, partition)
    end
  end

  defp team_share_partitioned(memory_id, team_id, partition) do
    case repo().update_all(
           from(m in MemorySchema,
             where:
               m.id == ^memory_id and is_nil(m.deleted_at) and
                 m.host_id == ^partition.host_id and m.client_id == ^partition.client_id and
                 m.scope == ^partition.scope and m.namespace == ^partition.namespace
           ),
           set: [namespace: "team:#{team_id}"]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  @doc "Return recent shared memories in a team namespace, newest first."
  @spec team_feed(String.t(), pos_integer()) :: []
  def team_feed(_team_id, _limit \\ 20), do: []

  @spec team_feed(String.t(), pos_integer(), map() | keyword()) :: [MemorySchema.t()]
  def team_feed(team_id, limit, partition) when is_binary(team_id) do
    with {:ok, partition} <- exact_partition(partition) do
      team_feed_partitioned(team_id, limit, partition)
    else
      {:error, :unauthorized} -> []
    end
  end

  defp team_feed_partitioned(team_id, limit, partition) do
    namespace = "team:#{team_id}"

    repo().all(
      from(m in MemorySchema,
        where:
          m.namespace == ^namespace and is_nil(m.deleted_at) and
            m.host_id == ^partition.host_id and m.client_id == ^partition.client_id and
            m.scope == ^partition.scope,
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

  defp apply_list_filter({:host_id, v}, q) when is_binary(v) and v != "",
    do: where(q, [m], m.host_id == ^v)

  defp apply_list_filter({:client_id, v}, q) when is_binary(v) and v != "",
    do: where(q, [m], m.client_id == ^v)

  defp apply_list_filter({:agent_id, v}, q) when is_binary(v) and v != "",
    do: where(q, [m], m.agent_id == ^v)

  defp apply_list_filter({:tag, v}, q) when is_binary(v) and v != "",
    do: where(q, [m], ^v in m.tags)

  defp apply_list_filter({:q, v}, q) when is_binary(v) and v != "" do
    pattern = "%" <> v <> "%"
    where(q, [m], ilike(m.content, ^pattern))
  end

  defp apply_list_filter(_, q), do: q

  if Mix.env() == :test do
    defp apply_exact_partition(query, nil), do: query
  end

  defp apply_exact_partition(query, partition) do
    where(
      query,
      [m],
      m.host_id == ^partition.host_id and m.client_id == ^partition.client_id and
        m.scope == ^partition.scope and m.namespace == ^partition.namespace
    )
  end

  defp exact_partition(partition) when is_list(partition) do
    partition |> Map.new() |> exact_partition()
  end

  defp exact_partition(partition) when is_map(partition) do
    values = %{
      host_id: Map.get(partition, :host_id) || Map.get(partition, "host_id"),
      client_id: Map.get(partition, :client_id) || Map.get(partition, "client_id"),
      scope: Map.get(partition, :scope) || Map.get(partition, "scope"),
      namespace: Map.get(partition, :namespace) || Map.get(partition, "namespace")
    }

    if Enum.all?(Map.values(values), &(is_binary(&1) and &1 != "")) do
      {:ok, values}
    else
      {:error, :unauthorized}
    end
  end

  defp exact_partition(_partition), do: {:error, :unauthorized}

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
      metadata: Keyword.get(opts, :metadata, %{}),
      namespace: Keyword.get(opts, :namespace, "private")
    }
  end

  defp find_duplicate(attrs) do
    project = Attribution.project(attrs.metadata)

    MemorySchema
    |> where([m], m.content_hash == ^:crypto.hash(:sha256, attrs.content))
    |> where([m], m.host_id == ^attrs.host_id)
    |> where([m], m.scope == ^attrs.scope)
    |> where([m], m.namespace == ^attrs.namespace)
    |> where([m], m.memory_type == ^attrs.memory_type)
    |> where(
      [m],
      fragment(
        "COALESCE(CASE WHEN jsonb_typeof(?->'project') = 'string' THEN ?->>'project' ELSE '' END, '')",
        m.metadata,
        m.metadata
      ) == ^project
    )
    |> where([m], fragment("COALESCE(?, '')", m.client_id) == ^(attrs.client_id || ""))
    |> where([m], is_nil(m.deleted_at))
    |> select([m], struct(m, ^@non_vector_fields))
    |> lock("FOR KEY SHARE")
    |> limit(1)
    |> repo().one()
  end

  defp persist_remember(attrs, opts, request_hash, typed_evidence) do
    {scope, key, retryable?} = request_identity(opts)

    result =
      repo().transaction(fn ->
        if retryable? do
          advisory_lock!("remember-request", [scope, key])
        end

        case repo().one(
               from(r in RememberRequest,
                 where: r.idempotency_scope == ^scope and r.idempotency_key == ^key
               )
             ) do
          %RememberRequest{request_hash: ^request_hash, memory_id: memory_id} = request
          when retryable? ->
            {repo().get!(MemorySchema, memory_id), false, false, request}

          %RememberRequest{} ->
            repo().rollback(:idempotency_conflict)

          nil ->
            {memory, inserted?} = find_or_insert_candidate!(attrs)

            request =
              %RememberRequest{}
              |> RememberRequest.changeset(%{
                idempotency_scope: scope,
                idempotency_key: key,
                request_hash: request_hash,
                memory_id: memory.id
              })
              |> repo().insert!()

            %Evidence{}
            |> Evidence.changeset(%{
              memory_id: memory.id,
              source_request_id: request.id,
              session_id: attrs.session_id,
              agent_id: attrs.agent_id,
              host_id: attrs.host_id,
              evidence_kind: "supports",
              support_score: 1.0,
              excerpt: attrs.content
            })
            |> repo().insert!()

            insert_typed_evidence!(memory.id, typed_evidence)

            {memory, inserted?, true, request}
        end
        |> then(fn {memory, inserted?, evidence_changed?, request} ->
          Backplane.Memory.Audit.log_once(
            "remember",
            memory.agent_id,
            [memory.id],
            request.id,
            memory_audit_metadata(memory, %{
              request_id: request.id,
              result: if(inserted?, do: "created", else: "reinforced")
            })
          )

          {memory, inserted?, evidence_changed?}
        end)
      end)

    case result do
      {:ok, {memory, inserted?, evidence_changed?}} ->
        if inserted? and embeddings_enabled?(), do: EmbedWorker.enqueue(memory.id)

        if evidence_changed? and relation_classifiable?(memory) and
             Config.relation_classifier_enabled?(),
           do: enqueue_relation_classifier(memory, evidence_revision(memory.id))

        {:ok, memory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp relation_classifiable?(memory), do: memory.memory_type in ~w(semantic procedural)

  defp evidence_revision(memory_id) do
    query = from(e in Evidence, where: e.memory_id == ^memory_id)
    count = repo().aggregate(query, :count, :id)

    latest_id =
      query
      |> order_by([e], desc: e.created_at, desc: e.id)
      |> limit(1)
      |> select([e], e.id)
      |> repo().one()

    "#{count}:#{latest_id}"
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp enqueue_relation_classifier(memory, evidence_revision) do
    enqueue =
      Application.get_env(
        :backplane_memory,
        :relation_classifier_enqueue,
        &RelationClassifierWorker.enqueue/3
      )

    result =
      if is_function(enqueue, 3) do
        enqueue.(memory.id, evidence_revision, partition_identity(memory))
      else
        enqueue.(memory.id, evidence_revision)
      end

    case result do
      {:ok, _job} -> :ok
      {:error, _reason} -> emit_classifier_enqueue_error(memory.id, :queue_error)
      _unexpected -> emit_classifier_enqueue_error(memory.id, :unexpected_result)
    end
  rescue
    _error -> emit_classifier_enqueue_error(memory.id, :exception)
  end

  defp partition_identity(memory) do
    %{
      host_id: memory.host_id,
      client_id: memory.client_id,
      scope: memory.scope,
      namespace: memory.namespace
    }
  end

  defp memory_audit_metadata(memory, details) do
    trace = provenance_trace(memory)

    %{
      host_id: memory.host_id,
      client_id: memory.client_id,
      scope: memory.scope,
      namespace: memory.namespace,
      request_id: List.first(trace.request_ids),
      request_ids: trace.request_ids,
      correlation_id: List.first(trace.correlation_ids),
      correlation_ids: trace.correlation_ids
    }
    |> Map.merge(details)
  end

  @doc false
  def provenance_trace(memory) do
    evidence =
      repo().all(
        from(e in Evidence,
          where: e.memory_id == ^memory.id,
          select: %{
            source_event_id: e.source_event_id,
            source_observation_id: e.source_observation_id,
            source_summary_id: e.source_summary_id,
            source_request_id: e.source_request_id,
            source_session_id: e.source_session_id
          }
        )
      )

    request_ids =
      evidence
      |> Enum.map(& &1.source_request_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    event_ids =
      evidence
      |> Enum.flat_map(&[&1.source_event_id, &1.source_observation_id])
      |> Enum.reject(&is_nil/1)

    summary_ids = evidence |> Enum.map(& &1.source_summary_id) |> Enum.reject(&is_nil/1)
    session_ids = evidence |> Enum.map(& &1.source_session_id) |> Enum.reject(&is_nil/1)

    summary_event_ids =
      if summary_ids == [] do
        []
      else
        repo().all(
          from(link in SourceEvent,
            where: link.summary_id in ^summary_ids,
            select: link.event_id
          )
        )
      end

    observation_event_ids =
      if event_ids == [] do
        []
      else
        repo().all(
          from(observation in ProjectedObservation,
            where: observation.event_id in ^event_ids,
            select: observation.event_id
          )
        )
      end

    event_ids = Enum.uniq(event_ids ++ summary_event_ids ++ observation_event_ids)

    correlation_ids =
      Event
      |> where(
        [event],
        event.host_id == ^memory.host_id and
          (event.id in ^event_ids or event.session_id in ^session_ids)
      )
      |> where([event], not is_nil(event.correlation_id))
      |> select([event], event.correlation_id)
      |> repo().all()
      |> Enum.uniq()
      |> Enum.sort()

    %{request_ids: request_ids, correlation_ids: correlation_ids}
  end

  defp emit_classifier_enqueue_error(memory_id, reason_class) do
    :telemetry.execute(
      [:backplane, :memory, :relation_classifier, :enqueue],
      %{count: 1},
      %{memory_id: memory_id, status: :error, reason_class: reason_class}
    )

    :ok
  end

  defp insert_typed_evidence!(memory_id, evidence) do
    Enum.each(evidence, fn attrs ->
      changeset = Evidence.changeset(%Evidence{}, Map.put(attrs, :memory_id, memory_id))

      case repo().insert(changeset, on_conflict: :nothing) do
        {:ok, _evidence} -> ensure_stored_evidence_matches!(memory_id, attrs)
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
  end

  defp ensure_stored_evidence_matches!(memory_id, attrs) do
    stored =
      Evidence
      |> where([e], e.memory_id == ^memory_id)
      |> evidence_source_query(evidence_source_identity(attrs))
      |> repo().one!()
      |> Map.from_struct()
      |> Map.take(@evidence_input_fields)

    if stored == attrs, do: :ok, else: repo().rollback(:conflicting_evidence)
  end

  defp evidence_source_query(query, {:event, id}),
    do: where(query, [e], e.source_event_id == ^id)

  defp evidence_source_query(query, {:observation, id}),
    do: where(query, [e], e.source_observation_id == ^id)

  defp evidence_source_query(query, {:summary, id}),
    do: where(query, [e], e.source_summary_id == ^id)

  defp evidence_source_query(query, {:request, id}),
    do: where(query, [e], e.source_request_id == ^id)

  defp evidence_source_query(query, {:crystal, id}),
    do: where(query, [e], e.source_crystal_id == ^id)

  defp evidence_source_query(query, {:session, host_id, session_id}),
    do: where(query, [e], e.host_id == ^host_id and e.source_session_id == ^session_id)

  defp normalize_evidence(evidence) when is_list(evidence) do
    evidence
    |> Enum.reduce_while({:ok, %{}}, fn item, {:ok, sources} ->
      with {:ok, normalized} <- normalize_evidence_item(item) do
        identity = evidence_source_identity(normalized)

        case Map.fetch(sources, identity) do
          :error -> {:cont, {:ok, Map.put(sources, identity, normalized)}}
          {:ok, ^normalized} -> {:cont, {:ok, sources}}
          {:ok, _conflicting} -> {:halt, {:error, :conflicting_evidence}}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, sources} ->
        {:ok, sources |> Map.values() |> Enum.sort_by(&evidence_source_identity/1)}

      error ->
        error
    end
  end

  defp normalize_evidence(_evidence), do: {:error, :invalid_evidence}

  defp normalize_evidence_item(item) when is_map(item) and not is_struct(item) do
    with {:ok, attrs} <- normalize_evidence_keys(item),
         :ok <- validate_evidence_source(attrs),
         changeset =
           Evidence.changeset(
             %Evidence{},
             Map.put(attrs, :memory_id, "00000000-0000-0000-0000-000000000000")
           ),
         {:ok, evidence} <- Ecto.Changeset.apply_action(changeset, :validate) do
      {:ok, evidence |> Map.from_struct() |> Map.take(@evidence_input_fields)}
    else
      _ -> {:error, :invalid_evidence}
    end
  end

  defp normalize_evidence_item(_item), do: {:error, :invalid_evidence}

  defp normalize_evidence_keys(item) do
    Enum.reduce_while(item, {:ok, %{}}, fn
      {key, value}, {:ok, attrs} when key in @evidence_input_fields ->
        {:cont, {:ok, Map.put(attrs, key, value)}}

      {key, value}, {:ok, attrs} when is_binary(key) ->
        case Map.fetch(@evidence_string_fields, key) do
          {:ok, field} -> {:cont, {:ok, Map.put(attrs, field, value)}}
          :error -> {:halt, {:error, :invalid_evidence}}
        end

      _, _acc ->
        {:halt, {:error, :invalid_evidence}}
    end)
  end

  defp validate_evidence_source(attrs) do
    sources = Enum.filter(@evidence_source_fields, &(not is_nil(Map.get(attrs, &1))))

    case sources do
      [:source_session_id] -> validate_session_source(attrs)
      [_source] -> :ok
      _ -> {:error, :invalid_evidence}
    end
  end

  defp validate_session_source(%{source_session_id: session_id, host_id: host_id})
       when is_binary(session_id) and is_binary(host_id) do
    if String.trim(session_id) != "" and String.trim(host_id) != "" do
      :ok
    else
      {:error, :invalid_evidence}
    end
  end

  defp validate_session_source(_attrs), do: {:error, :invalid_evidence}

  defp evidence_source_identity(%{source_event_id: id}) when not is_nil(id),
    do: {:event, id}

  defp evidence_source_identity(%{source_observation_id: id}) when not is_nil(id),
    do: {:observation, id}

  defp evidence_source_identity(%{source_summary_id: id}) when not is_nil(id),
    do: {:summary, id}

  defp evidence_source_identity(%{source_request_id: id}) when not is_nil(id),
    do: {:request, id}

  defp evidence_source_identity(%{source_crystal_id: id}) when not is_nil(id),
    do: {:crystal, id}

  defp evidence_source_identity(%{source_session_id: session_id, host_id: host_id}),
    do: {:session, host_id, session_id}

  defp request_identity(opts) do
    case Keyword.fetch(opts, :idempotency_key) do
      {:ok, key} -> {Keyword.fetch!(opts, :idempotency_scope), key, true}
      :error -> {"unkeyed", Ecto.UUID.generate(), false}
    end
  end

  defp find_or_insert_candidate!(attrs) do
    advisory_lock!("memory-candidate", [
      Base.encode16(:crypto.hash(:sha256, attrs.content)),
      attrs.host_id,
      attrs.scope,
      attrs.namespace,
      attrs.memory_type,
      Attribution.project(attrs.metadata),
      attrs.client_id || ""
    ])

    case find_duplicate(attrs) do
      %MemorySchema{} = memory ->
        {memory, false}

      nil ->
        case repo().insert(MemorySchema.changeset(%MemorySchema{}, attrs)) do
          {:ok, memory} -> {memory, true}
          {:error, changeset} -> repo().rollback(changeset)
        end
    end
  end

  defp advisory_lock!(domain, parts) do
    <<lock_key::signed-64, _rest::binary>> =
      :crypto.hash(:sha256, :erlang.term_to_binary([domain | parts], [:deterministic]))

    repo().query!("SELECT pg_advisory_xact_lock($1::bigint)", [lock_key])
    :ok
  end

  defp validate_idempotency_options(opts) do
    case Keyword.fetch(opts, :idempotency_key) do
      :error ->
        :ok

      {:ok, key} when not is_binary(key) ->
        {:error, :invalid_idempotency_key}

      {:ok, key} ->
        cond do
          String.trim(key) == "" -> {:error, :invalid_idempotency_key}
          not Keyword.has_key?(opts, :idempotency_scope) -> {:error, :idempotency_scope_required}
          not is_binary(opts[:idempotency_scope]) -> {:error, :idempotency_scope_required}
          String.trim(opts[:idempotency_scope]) == "" -> {:error, :idempotency_scope_required}
          true -> :ok
        end
    end
  end

  defp evidence_view(evidence) do
    {source_type, source_id} = evidence_source(evidence)

    evidence
    |> Map.take([
      :id,
      :memory_id,
      :session_id,
      :agent_id,
      :host_id,
      :evidence_kind,
      :support_score,
      :excerpt,
      :created_at
    ])
    |> Map.merge(%{source_type: source_type, source_id: source_id})
  end

  defp evidence_source(%Evidence{source_event_id: id}) when not is_nil(id), do: {"event", id}

  defp evidence_source(%Evidence{source_observation_id: id}) when not is_nil(id),
    do: {"observation", id}

  defp evidence_source(%Evidence{source_summary_id: id}) when not is_nil(id), do: {"summary", id}
  defp evidence_source(%Evidence{source_request_id: id}) when not is_nil(id), do: {"request", id}

  defp evidence_source(%Evidence{host_id: host, source_session_id: session}),
    do: {"session", "#{host}:#{session}"}

  defp embeddings_enabled? do
    EmbeddingClient.configured?()
  end
end
