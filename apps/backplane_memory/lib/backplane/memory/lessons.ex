defmodule Backplane.Memory.Lessons do
  @moduledoc "First-class procedural lessons with exact-partition recall."

  import Ecto.Query

  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.Applications
  alias Backplane.Memory.Memories.Evidence
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Memories.RememberRequest
  alias Backplane.Memory.Projections.ProjectedSession
  alias Backplane.Memory.Recall.{Channels, QueryPlan}
  alias Backplane.Memory.Summaries.Summary

  @save_keys ~w(rule context project session_id idempotency_key)
  @partition_keys [:host_id, :client_id, :scope, :namespace]
  @automatic_source_kinds ~w(correction failure_remediation repeated_failure_remediation consolidation crystal)
  @admin_statuses ~w(candidate active disputed superseded archived)

  @doc "Returns a bounded lesson page for one exact memory partition."
  @spec list_admin(map() | keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_admin(partition, opts \\ [])

  def list_admin(partition, opts) when is_list(opts) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, filters} <- admin_filters(opts) do
      query =
        from(l in Lesson,
          join: m in Memory,
          on: m.id == l.memory_id,
          where:
            m.host_id == ^partition.host_id and m.client_id == ^partition.client_id and
              m.scope == ^partition.scope and m.namespace == ^partition.namespace
        )
        |> maybe_admin_status(filters.status)
        |> maybe_admin_project(filters.project)

      total = repo().aggregate(query, :count, :memory_id)

      rows =
        query
        |> order_by([l, _m], desc: l.updated_at, desc: l.memory_id)
        |> limit(^filters.per_page)
        |> offset(^((filters.page - 1) * filters.per_page))
        |> select([l, m], {l, m})
        |> repo().all()

      entries = admin_entries(rows)

      total_pages =
        if total == 0, do: 0, else: div(total + filters.per_page - 1, filters.per_page)

      {:ok,
       %{
         entries: entries,
         page: filters.page,
         per_page: filters.per_page,
         total: total,
         total_pages: total_pages
       }}
    end
  end

  def list_admin(_partition, _opts), do: {:error, :invalid_arguments}

  @doc "Returns lesson, memory, source, and evidence inside one exact partition."
  @spec get_admin(String.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def get_admin(memory_id, partition) when is_binary(memory_id) do
    with {:ok, partition} <- exact_partition(partition) do
      rows =
        from(l in Lesson,
          join: m in Memory,
          on: m.id == l.memory_id,
          where:
            l.memory_id == ^memory_id and m.host_id == ^partition.host_id and
              m.client_id == ^partition.client_id and m.scope == ^partition.scope and
              m.namespace == ^partition.namespace,
          select: {l, m},
          limit: 1
        )
        |> repo().all()

      case admin_entries(rows) do
        [entry] -> {:ok, entry}
        [] -> {:error, :not_found}
      end
    end
  end

  def get_admin(_memory_id, _partition), do: {:error, :not_found}

  @spec save(map(), map() | keyword(), map()) :: {:ok, Lesson.t()} | {:error, term()}
  def save(attrs, partition, audit_context)
      when is_map(attrs) and not is_struct(attrs) and is_map(audit_context) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, attrs} <- validate_save(attrs),
         {:ok, audit_context} <- validate_audit_context(audit_context) do
      attrs = Map.merge(attrs, audit_context)
      persist_manual(attrs, partition)
    end
  end

  def save(_attrs, _partition, _audit_context), do: {:error, :invalid_arguments}

  @doc "Creates an evidence-backed automatic lesson candidate in an exact partition."
  @spec create_candidate(map(), map() | keyword(), map()) ::
          {:ok, Lesson.t()} | {:error, term()}
  def create_candidate(attrs, partition, audit_context)
      when is_map(attrs) and not is_struct(attrs) and is_map(audit_context) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, attrs} <- validate_candidate(attrs),
         {:ok, audit_context} <- validate_audit_context(audit_context) do
      persist_candidate(Map.merge(attrs, audit_context), partition)
    end
  end

  def create_candidate(_attrs, _partition, _audit_context), do: {:error, :invalid_arguments}

  @doc "Promotes an evidence-backed candidate under an exact-partition row lock."
  @spec promote(String.t(), String.t(), String.t(), map() | keyword(), map()) ::
          {:ok, Lesson.t()} | {:error, term()}
  def promote(memory_id, reason, idempotency_key, partition, audit_context) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, memory_id} <- required(%{"memory_id" => memory_id}, "memory_id"),
         {:ok, reason} <- required(%{"reason" => reason}, "reason"),
         {:ok, idempotency_key} <- required(%{"key" => idempotency_key}, "key"),
         {:ok, audit_context} <- validate_audit_context(audit_context) do
      transition_candidate(memory_id, reason, idempotency_key, partition, audit_context)
    end
  end

  @doc "Evaluates the configured auto-promotion threshold triple for an existing candidate."
  def auto_promote(memory_id, idempotency_key, partition, audit_context) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, audit_context} <- validate_audit_context(audit_context) do
      repo().transaction(fn ->
        case locked_lesson(memory_id, partition) do
          nil ->
            repo().rollback(:not_found)

          {lesson, memory} ->
            case maybe_auto_promote(
                   lesson,
                   memory,
                   Map.merge(audit_context, %{
                     confidence: memory.confidence,
                     idempotency_key: idempotency_key
                   }),
                   partition
                 ) do
              {:ok, lesson} -> lesson
              {:error, reason} -> repo().rollback(reason)
            end
        end
      end)
    end
  end

  @legal_transitions %{
    "candidate" => ~w(active disputed archived),
    "active" => ~w(disputed superseded archived),
    "disputed" => ~w(active superseded archived),
    "archived" => ~w(active disputed),
    "superseded" => ~w(archived)
  }

  @doc "Performs a validated lesson lifecycle transition under an exact-partition row lock."
  @spec transition(String.t(), String.t(), String.t(), String.t(), map() | keyword(), map()) ::
          {:ok, Lesson.t()} | {:error, term()}
  def transition(memory_id, target, reason, idempotency_key, partition, audit_context) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, memory_id} <- required(%{"id" => memory_id}, "id"),
         {:ok, target} <- required(%{"target" => target}, "target"),
         true <- target in ~w(candidate active disputed superseded archived),
         {:ok, reason} <- required(%{"reason" => reason}, "reason"),
         {:ok, idempotency_key} <- required(%{"key" => idempotency_key}, "key"),
         {:ok, audit_context} <- validate_audit_context(audit_context) do
      persist_transition(memory_id, target, reason, idempotency_key, partition, audit_context)
    else
      false -> {:error, :invalid_transition}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_arguments}
    end
  end

  @strengthening_modes %{
    "explicit_confirmation" => "confirms",
    "verified_application" => "applies",
    "independent_evidence" => "supports"
  }

  @doc "Strengthens a lesson from an explicit, verified, independently identified signal."
  @spec strengthen(String.t(), String.t(), String.t(), map(), map() | keyword(), map()) ::
          {:ok, %{lesson: Lesson.t(), applied: boolean()}} | {:error, term()}
  def strengthen(memory_id, mode, idempotency_key, source, partition, audit_context) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, memory_id} <- required(%{"id" => memory_id}, "id"),
         {:ok, evidence_kind} <- Map.fetch(@strengthening_modes, mode),
         {:ok, idempotency_key} <- required(%{"key" => idempotency_key}, "key"),
         {:ok, source} <- resolve_strengthening_source(mode, source, partition),
         {:ok, audit_context} <- validate_audit_context(audit_context) do
      persist_strengthening(
        memory_id,
        mode,
        evidence_kind,
        idempotency_key,
        source,
        partition,
        audit_context
      )
    else
      :error -> {:error, :invalid_strengthening}
      {:error, _reason} = error -> error
    end
  end

  @doc "Applies one deterministic decay interval and archives only at the explicit age policy."
  @spec decay(map() | keyword(), DateTime.t(), keyword()) ::
          {:ok, %{decayed: non_neg_integer(), archived: non_neg_integer()}} | {:error, term()}
  def decay(partition, %DateTime{} = now, opts \\ []) when is_list(opts) do
    with {:ok, partition} <- exact_partition(partition),
         true <- Backplane.Memory.Config.lesson_decay_enabled?(),
         rate when is_number(rate) and rate > 0 and rate <= 1 <- Keyword.get(opts, :rate, 0.05),
         archive_days when is_integer(archive_days) and archive_days > 0 <-
           Keyword.get(opts, :archive_days, Backplane.Memory.Config.lesson_decay_archive_days()) do
      limit = Keyword.get(opts, :limit, 100)

      if is_integer(limit) and limit in 1..500,
        do: persist_decay(partition, now, rate / 1, archive_days, limit),
        else: {:error, :invalid_decay_policy}
    else
      false -> {:ok, %{decayed: 0, archived: 0}}
      _invalid -> {:error, :invalid_decay_policy}
    end
  end

  @spec recall(String.t(), map() | keyword(), keyword()) ::
          {:ok, [Backplane.Memory.Recall.Candidate.t()]} | {:error, term()}
  def recall(query, partition, opts \\ [])

  def recall(query, partition, opts) when is_binary(query) and is_list(opts) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, query} <- normalize_query(query),
         {:ok, limit} <- recall_limit(opts),
         {:ok, project} <- recall_project(opts) do
      with {:ok, plan} <-
             QueryPlan.new(Map.merge(partition, %{query: query, project: project})),
           {:ok, rows} <- Channels.lessons(plan, limit) do
        {:ok, Enum.map(rows, &elem(&1, 0))}
      end
    end
  end

  def recall(_query, _partition, _opts), do: {:error, :invalid_arguments}

  @doc "Returns bounded active lessons for an exact partition, ranked without reinforcing them."
  @spec top(map() | keyword(), keyword()) ::
          {:ok, [Backplane.Memory.Recall.Candidate.t()]} | {:error, term()}
  def top(partition, opts \\ [])

  def top(partition, opts) when is_list(opts) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, limit} <- recall_limit(opts),
         {:ok, project} <- recall_project(opts),
         {:ok, plan} <-
           QueryPlan.new(Map.merge(partition, %{query: "active lessons", project: project})),
         {:ok, rows} <- Channels.top_lessons(plan, limit) do
      {:ok, Enum.map(rows, &elem(&1, 0))}
    end
  end

  def top(_partition, _opts), do: {:error, :invalid_arguments}

  defp admin_filters(opts) do
    with [] <- Keyword.keys(opts) -- [:status, :project, :page, :per_page],
         status when is_nil(status) or status in @admin_statuses <- Keyword.get(opts, :status),
         {:ok, project} <- admin_project(Keyword.get(opts, :project)),
         page when is_integer(page) and page > 0 <- Keyword.get(opts, :page, 1),
         per_page when is_integer(per_page) and per_page in 1..100 <-
           Keyword.get(opts, :per_page, 25) do
      {:ok, %{status: status, project: project, page: page, per_page: per_page}}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp admin_project(nil), do: {:ok, nil}

  defp admin_project(project) when is_binary(project) do
    case String.trim(project) do
      "" -> {:ok, nil}
      value when byte_size(value) <= 512 -> {:ok, value}
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp admin_project(_project), do: {:error, :invalid_arguments}

  defp maybe_admin_status(query, nil), do: query
  defp maybe_admin_status(query, status), do: where(query, [l, _m], l.status == ^status)

  defp maybe_admin_project(query, nil), do: query

  defp maybe_admin_project(query, project) do
    where(query, [_l, m], fragment("?->>'project'", m.metadata) == ^project)
  end

  defp admin_entries([]), do: []

  defp admin_entries(rows) do
    memory_ids = Enum.map(rows, fn {lesson, _memory} -> lesson.memory_id end)

    evidence_by_memory =
      Map.new(memory_ids, fn memory_id ->
        evidence =
          repo().all(
            from(e in Evidence,
              where: e.memory_id == ^memory_id,
              order_by: [desc: e.created_at, desc: e.id],
              limit: 25
            )
          )

        {memory_id, evidence}
      end)

    Enum.map(rows, fn {lesson, memory} ->
      %{
        lesson: lesson,
        memory: memory,
        project: get_in(memory.metadata || %{}, ["project"]),
        source: lesson.source_kind,
        evidence: Map.get(evidence_by_memory, memory.id, [])
      }
    end)
  end

  defp persist_candidate(attrs, partition) do
    case repo().transaction(fn ->
           opts = [
             type: "procedural",
             scope: partition.scope,
             namespace: partition.namespace,
             host_id: partition.host_id,
             client_id: partition.client_id,
             agent_id: attrs.actor,
             session_id: attrs.session_id,
             idempotency_scope: partition.client_id,
             idempotency_key: attrs.idempotency_key,
             evidence: attrs.evidence,
             metadata: %{
               "project" => attrs.project,
               "lesson_context" => attrs.context,
               "source_kind" => attrs.source_kind,
               "lesson_extraction_kind" => attrs.extraction_kind
             }
           ]

           with {:ok, memory} <- Memories.remember(attrs.rule, opts),
                {:ok, memory} <- candidate_memory(memory, attrs.confidence),
                {:ok, lesson} <- insert_or_reuse_candidate(memory.id, attrs),
                {:ok, lesson} <- maybe_auto_promote(lesson, memory, attrs, partition) do
             Backplane.Memory.Audit.log_once(
               "lesson.candidate",
               attrs.actor,
               [memory.id],
               "#{partition.client_id}:#{attrs.idempotency_key}",
               lesson_audit_metadata(partition, attrs, %{
                 source_kind: attrs.source_kind,
                 extraction_kind: attrs.extraction_kind
               })
             )

             lesson
           else
             {:error, reason} -> repo().rollback(reason)
           end
         end) do
      {:ok, lesson} -> {:ok, lesson}
      {:error, reason} -> {:error, reason}
    end
  end

  defp candidate_memory(memory, confidence) do
    memory
    |> Ecto.Changeset.change(confidence: confidence, lifecycle_state: "candidate")
    |> repo().update()
  end

  defp insert_or_reuse_candidate(memory_id, attrs) do
    case repo().get(Lesson, memory_id) do
      nil ->
        %Lesson{}
        |> Lesson.changeset(%{
          memory_id: memory_id,
          status: "candidate",
          context: attrs.context,
          source_kind: attrs.source_kind
        })
        |> repo().insert()

      %Lesson{status: "candidate"} = lesson ->
        {:ok, lesson}

      %Lesson{} ->
        {:error, :lesson_closed_conflict}
    end
  end

  defp maybe_auto_promote(lesson, memory, attrs, partition) do
    if Backplane.Memory.Config.lesson_auto_promote?() and
         attrs.confidence >= Backplane.Memory.Config.lesson_promote_confidence() do
      evidence = repo().all(from(e in Evidence, where: e.memory_id == ^memory.id))
      minimum = Backplane.Memory.Config.lesson_promote_sources()

      diversity =
        evidence
        |> Enum.map(fn evidence ->
          {evidence.host_id, evidence.agent_id,
           evidence.source_session_id || evidence.session_id || evidence.source_request_id}
        end)
        |> Enum.uniq()
        |> length()

      if length(evidence) >= minimum and diversity >= minimum do
        transition_candidate(
          memory.id,
          "automatic threshold",
          "auto-promote:#{attrs.idempotency_key}",
          partition,
          Map.take(attrs, [:actor, :request_id, :correlation_id])
        )
      else
        {:ok, lesson}
      end
    else
      {:ok, lesson}
    end
  end

  defp transition_candidate(memory_id, reason, idempotency_key, partition, audit_context) do
    case repo().transaction(fn ->
           query =
             from(l in Lesson,
               join: m in Memory,
               on: m.id == l.memory_id,
               where:
                 l.memory_id == ^memory_id and m.host_id == ^partition.host_id and
                   m.client_id == ^partition.client_id and m.scope == ^partition.scope and
                   m.namespace == ^partition.namespace,
               select: {l, m},
               lock: "FOR UPDATE"
             )

           case repo().one(query) do
             nil ->
               repo().rollback(:not_found)

             {%Lesson{status: "active"} = lesson, _memory} ->
               lesson

             {%Lesson{status: "candidate"} = lesson, memory} ->
               if repo().exists?(from(e in Evidence, where: e.memory_id == ^memory.id)) do
                 now = DateTime.utc_now()

                 with {:ok, lesson} <-
                        lesson
                        |> Lesson.changeset(%{
                          status: "active",
                          promoted_at: now,
                          promoted_by: audit_context.actor,
                          promotion_reason: reason
                        })
                        |> repo().update(),
                      {:ok, _memory} <-
                        memory
                        |> Memory.lifecycle_changeset(%{lifecycle_state: "active"})
                        |> repo().update() do
                   Backplane.Memory.Audit.log_once(
                     "lesson.transition",
                     audit_context.actor,
                     [memory.id],
                     "#{partition.client_id}:#{idempotency_key}",
                     lesson_audit_metadata(partition, audit_context, %{
                       from: "candidate",
                       to: "active",
                       reason: reason,
                       request_id: audit_context.request_id,
                       correlation_id: audit_context.correlation_id
                     })
                   )

                   lesson
                 else
                   {:error, reason} -> repo().rollback(reason)
                 end
               else
                 repo().rollback(:promotion_requires_evidence)
               end

             {_lesson, _memory} ->
               repo().rollback(:invalid_transition)
           end
         end) do
      {:ok, lesson} -> {:ok, lesson}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_transition(memory_id, target, reason, idempotency_key, partition, audit_context) do
    case repo().transaction(fn ->
           case locked_lesson(memory_id, partition) do
             nil ->
               repo().rollback(:not_found)

             {%Lesson{status: ^target} = lesson, _memory} ->
               lesson

             {%Lesson{status: source} = lesson, memory} ->
               if target in Map.fetch!(@legal_transitions, source) do
                 lesson_attrs = %{status: target}

                 lesson_attrs =
                   if target == "active" do
                     Map.merge(lesson_attrs, %{
                       promoted_at: DateTime.utc_now(),
                       promoted_by: audit_context.actor,
                       promotion_reason: reason
                     })
                   else
                     lesson_attrs
                   end

                 with {:ok, lesson} <-
                        lesson |> Lesson.changeset(lesson_attrs) |> repo().update(),
                      {:ok, _memory} <-
                        memory
                        |> Memory.lifecycle_changeset(%{lifecycle_state: target})
                        |> repo().update() do
                   Backplane.Memory.Audit.log_once(
                     "lesson.transition",
                     audit_context.actor,
                     [memory.id],
                     "#{partition.client_id}:#{idempotency_key}",
                     lesson_audit_metadata(partition, audit_context, %{
                       from: source,
                       to: target,
                       reason: reason
                     })
                   )

                   lesson
                 else
                   {:error, reason} -> repo().rollback(reason)
                 end
               else
                 repo().rollback(:invalid_transition)
               end
           end
         end) do
      {:ok, lesson} -> {:ok, lesson}
      {:error, reason} -> {:error, reason}
    end
  end

  defp locked_lesson(memory_id, partition) do
    repo().one(
      from(l in Lesson,
        join: m in Memory,
        on: m.id == l.memory_id,
        where:
          l.memory_id == ^memory_id and m.host_id == ^partition.host_id and
            m.client_id == ^partition.client_id and m.scope == ^partition.scope and
            m.namespace == ^partition.namespace,
        select: {l, m},
        lock: "FOR UPDATE"
      )
    )
  end

  defp persist_strengthening(
         memory_id,
         mode,
         evidence_kind,
         idempotency_key,
         source,
         partition,
         audit_context
       ) do
    key = "#{partition.client_id}:#{memory_id}:#{idempotency_key}"

    transaction = fn record_application ->
      case locked_lesson(memory_id, partition) do
        nil ->
          repo().rollback(:not_found)

        {%Lesson{status: status}, _memory} when status in ["archived", "superseded"] ->
          repo().rollback(:invalid_transition)

        {lesson, memory} ->
          cond do
            source[:memory_id] == memory.id ->
              repo().rollback(:invalid_strengthening_source)

            audited?("lesson.strengthen", key) ->
              %{lesson: lesson, applied: false}

            evidence_exists?(memory.id, source.identity) ->
              %{lesson: lesson, applied: false}

            true ->
              apply_result =
                if mode == "verified_application" do
                  {:ok, record_application.()}
                else
                  {:ok, %{applied: true}}
                end

              with {:ok, %{applied: true}} <- apply_result,
                   {:ok, _evidence} <-
                     %Evidence{}
                     |> Evidence.changeset(
                       Map.merge(source.evidence, %{
                         memory_id: memory.id,
                         evidence_kind: evidence_kind,
                         support_score: 1.0
                       })
                     )
                     |> repo().insert(),
                   now = DateTime.utc_now(),
                   attrs =
                     %{last_reinforced_at: now, decay_rate: 0.0}
                     |> then(fn attrs ->
                       if mode == "verified_application",
                         do: Map.put(attrs, :last_applied_at, now),
                         else: attrs
                     end),
                   {1, _} <-
                     repo().update_all(
                       from(l in Lesson, where: l.memory_id == ^memory.id),
                       inc: [reinforcement_count: 1],
                       set: Map.to_list(attrs)
                     ) do
                lesson = repo().get!(Lesson, memory.id)

                Backplane.Memory.Audit.log_once(
                  "lesson.strengthen",
                  audit_context.actor,
                  [memory.id],
                  key,
                  lesson_audit_metadata(partition, audit_context, %{
                    mode: mode,
                    evidence_kind: evidence_kind,
                    source_type: elem(source.identity, 0),
                    source_id: elem(source.identity, 1)
                  })
                )

                case maybe_auto_promote(
                       lesson,
                       memory,
                       Map.merge(audit_context, %{
                         confidence: memory.confidence,
                         idempotency_key: idempotency_key
                       }),
                       partition
                     ) do
                  {:ok, lesson} -> %{lesson: lesson, applied: true}
                  {:error, reason} -> repo().rollback(reason)
                end
              else
                {:ok, %{applied: false}} -> %{lesson: lesson, applied: false}
                {:error, reason} -> repo().rollback(reason)
              end
          end
      end
    end

    result =
      if mode == "verified_application" do
        Applications.with_application(
          memory_id,
          idempotency_key,
          audit_context.actor,
          partition,
          transaction
        )
      else
        repo().transaction(fn -> transaction.(nil) end)
      end

    case result do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp evidence_exists?(memory_id, {:event, id}),
    do:
      repo().exists?(
        from(e in Evidence, where: e.memory_id == ^memory_id and e.source_event_id == ^id)
      )

  defp evidence_exists?(memory_id, {:observation, id}),
    do:
      repo().exists?(
        from(e in Evidence, where: e.memory_id == ^memory_id and e.source_observation_id == ^id)
      )

  defp evidence_exists?(memory_id, {:summary, id}),
    do:
      repo().exists?(
        from(e in Evidence, where: e.memory_id == ^memory_id and e.source_summary_id == ^id)
      )

  defp evidence_exists?(memory_id, {:request, id}),
    do:
      repo().exists?(
        from(e in Evidence, where: e.memory_id == ^memory_id and e.source_request_id == ^id)
      )

  defp evidence_exists?(memory_id, {:crystal, id}),
    do:
      repo().exists?(
        from(e in Evidence, where: e.memory_id == ^memory_id and e.source_crystal_id == ^id)
      )

  defp evidence_exists?(memory_id, {:session, session_id}),
    do:
      repo().exists?(
        from(e in Evidence,
          where: e.memory_id == ^memory_id and e.source_session_id == ^session_id
        )
      )

  defp resolve_strengthening_source(
         "verified_application",
         %{"source_session_id" => id},
         partition
       ),
       do: resolve_projected_session(id, partition)

  defp resolve_strengthening_source(mode, source, partition)
       when mode in ["explicit_confirmation", "independent_evidence"] and is_map(source) do
    case Enum.filter(
           ~w(source_event_id source_observation_id source_summary_id source_request_id source_crystal_id),
           &(is_binary(source[&1]) and String.trim(source[&1]) != "")
         ) do
      ["source_event_id"] -> resolve_event(source["source_event_id"], partition)
      ["source_observation_id"] -> resolve_observation(source["source_observation_id"], partition)
      ["source_summary_id"] -> resolve_summary(source["source_summary_id"], partition)
      ["source_request_id"] -> resolve_request(source["source_request_id"], partition)
      ["source_crystal_id"] -> resolve_crystal(source["source_crystal_id"], partition)
      _ -> {:error, :invalid_strengthening_source}
    end
  end

  defp resolve_strengthening_source(_mode, _source, _partition),
    do: {:error, :invalid_strengthening_source}

  defp resolve_event(id, partition) do
    case repo().one(
           from(event in Event,
             where:
               event.id == ^id and event.host_id == ^partition.host_id and
                 event.client_id == ^partition.client_id and event.scope == ^partition.scope and
                 event.namespace == ^partition.namespace,
             limit: 1
           )
         ) do
      %Event{} = event ->
        {:ok,
         %{
           identity: {:event, event.id},
           evidence: %{
             source_event_id: event.id,
             session_id: event.session_id,
             agent_id: event.agent_id,
             host_id: event.host_id
           }
         }}

      nil ->
        {:error, :strengthening_source_not_found}
    end
  end

  # Legacy observations carry only a session_id and cannot prove exact-partition ownership.
  # Callers must use a partition-bearing canonical event, summary, or request instead.
  defp resolve_observation(_id, _partition), do: {:error, :strengthening_source_not_found}

  defp resolve_summary(id, partition) do
    case repo().one(
           from(summary in Summary,
             join: session in ProjectedSession,
             on: session.subject_id == summary.subject_id,
             where:
               summary.id == ^id and session.host_id == ^partition.host_id and
                 session.client_id == ^partition.client_id and session.scope == ^partition.scope and
                 session.namespace == ^partition.namespace,
             select: {summary, session},
             limit: 1
           )
         ) do
      {%Summary{} = summary, %ProjectedSession{} = session} ->
        {:ok,
         %{
           identity: {:summary, summary.id},
           evidence: %{
             source_summary_id: summary.id,
             session_id: summary.session_id,
             agent_id: session.agent_id,
             host_id: session.host_id
           }
         }}

      nil ->
        {:error, :strengthening_source_not_found}
    end
  end

  defp resolve_request(id, partition) do
    case repo().one(
           from(request in RememberRequest,
             join: memory in Memory,
             on: memory.id == request.memory_id,
             where:
               request.id == ^id and memory.host_id == ^partition.host_id and
                 memory.client_id == ^partition.client_id and memory.scope == ^partition.scope and
                 memory.namespace == ^partition.namespace,
             select: {request, memory},
             limit: 1
           )
         ) do
      {%RememberRequest{} = request, %Memory{} = memory} ->
        {:ok,
         %{
           identity: {:request, request.id},
           memory_id: memory.id,
           evidence: %{
             source_request_id: request.id,
             session_id: memory.session_id,
             agent_id: memory.agent_id,
             host_id: memory.host_id
           }
         }}

      nil ->
        {:error, :strengthening_source_not_found}
    end
  end

  defp resolve_crystal(id, partition) do
    case repo().one(
           from(crystal in Backplane.Memory.Crystals.Crystal,
             where:
               crystal.id == ^id and crystal.host_id == ^partition.host_id and
                 crystal.client_id == ^partition.client_id and crystal.scope == ^partition.scope and
                 crystal.namespace == ^partition.namespace and crystal.status == "complete",
             limit: 1
           )
         ) do
      %Backplane.Memory.Crystals.Crystal{} = crystal ->
        {:ok,
         %{
           identity: {:crystal, crystal.id},
           evidence: %{
             source_crystal_id: crystal.id,
             session_id: crystal.source_session_id,
             host_id: crystal.host_id
           }
         }}

      nil ->
        {:error, :strengthening_source_not_found}
    end
  end

  defp resolve_projected_session(id, partition) do
    case repo().one(
           from(session in ProjectedSession,
             where:
               session.session_id == ^id and session.host_id == ^partition.host_id and
                 session.client_id == ^partition.client_id and session.scope == ^partition.scope and
                 session.namespace == ^partition.namespace,
             limit: 1
           )
         ) do
      %ProjectedSession{} = session ->
        {:ok,
         %{
           identity: {:session, session.session_id},
           evidence: %{
             source_session_id: session.session_id,
             session_id: session.session_id,
             agent_id: session.agent_id,
             host_id: session.host_id
           }
         }}

      nil ->
        {:error, :strengthening_source_not_found}
    end
  end

  defp audited?(operation, idempotency_key) do
    repo().exists?(
      from(r in "memory_audit_log",
        where: r.operation == ^operation,
        where: fragment("?->>'idempotency_key' = ?", r.metadata, ^idempotency_key)
      )
    )
  end

  defp persist_decay(partition, now, rate, archive_days, limit) do
    interval_start = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], now.time_zone)
    archive_before = DateTime.add(now, -archive_days, :day)

    case repo().transaction(fn ->
           rows =
             repo().all(
               from(l in Lesson,
                 join: m in Memory,
                 on: m.id == l.memory_id,
                 where:
                   m.host_id == ^partition.host_id and m.client_id == ^partition.client_id and
                     m.scope == ^partition.scope and m.namespace == ^partition.namespace and
                     l.status in ["active", "candidate", "disputed"] and
                     (is_nil(l.last_decayed_at) or l.last_decayed_at < ^interval_start),
                 order_by: [asc: l.memory_id],
                 limit: ^limit,
                 select: {l, m},
                 lock: "FOR UPDATE"
               )
             )

           Enum.reduce(rows, %{decayed: 0, archived: 0}, fn {lesson, memory}, counts ->
             activity_at =
               lesson.last_reinforced_at || lesson.last_applied_at || lesson.promoted_at ||
                 lesson.created_at

             archive? = DateTime.compare(activity_at, archive_before) != :gt
             target = if archive?, do: "archived", else: lesson.status

             {:ok, _lesson} =
               lesson
               |> Lesson.changeset(%{
                 status: target,
                 decay_rate: min(lesson.decay_rate + rate, 1.0),
                 last_decayed_at: now
               })
               |> repo().update()

             if archive? do
               {:ok, _memory} =
                 memory
                 |> Memory.lifecycle_changeset(%{lifecycle_state: "archived"})
                 |> repo().update()

               Backplane.Memory.Audit.log_once(
                 "lesson.transition",
                 "system:lesson-decay",
                 [memory.id],
                 "#{partition.client_id}:decay:#{Date.to_iso8601(DateTime.to_date(interval_start))}:#{memory.id}",
                 lesson_audit_metadata(
                   partition,
                   %{request_id: "decay", correlation_id: "decay"},
                   %{
                     from: lesson.status,
                     to: "archived",
                     reason: "decay policy"
                   }
                 )
               )
             end

             %{
               decayed: counts.decayed + 1,
               archived: counts.archived + if(archive?, do: 1, else: 0)
             }
           end)
         end) do
      {:ok, counts} -> {:ok, counts}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_manual(attrs, partition) do
    case repo().transaction(fn ->
           opts = [
             type: "procedural",
             scope: partition.scope,
             namespace: partition.namespace,
             host_id: partition.host_id,
             client_id: partition.client_id,
             agent_id: attrs.actor,
             session_id: attrs.session_id,
             idempotency_scope: partition.client_id,
             idempotency_key: attrs.idempotency_key,
             metadata: %{
               "project" => attrs.project,
               "lesson_context" => attrs.context,
               "source_kind" => "manual"
             }
           ]

           # remember/2 locks the canonical memory identity. Because its transaction is a
           # savepoint here, PostgreSQL retains that xact lock through the lesson mutation.
           with {:ok, memory} <- Memories.remember(attrs.rule, opts),
                :ok <- ensure_manual_save_state(memory.id),
                {:ok, memory} <- activate_eligible_memory(memory),
                {:ok, lesson} <- insert_or_reuse_active(memory.id, attrs) do
             Backplane.Memory.Audit.log_once(
               "lesson.save",
               attrs.actor,
               [memory.id],
               "#{partition.client_id}:#{attrs.idempotency_key}",
               %{
                 memory_id: memory.id,
                 lesson_status: lesson.status,
                 source_kind: lesson.source_kind,
                 host_id: partition.host_id,
                 client_id: partition.client_id,
                 scope: partition.scope,
                 namespace: partition.namespace,
                 project: attrs.project,
                 session_id: attrs.session_id,
                 request_id: attrs.request_id,
                 correlation_id: attrs.correlation_id
               }
             )

             lesson
           else
             {:error, reason} -> repo().rollback(reason)
           end
         end) do
      {:ok, lesson} -> {:ok, lesson}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_or_reuse_active(memory_id, attrs) do
    case repo().get(Lesson, memory_id) do
      nil ->
        now = DateTime.utc_now()

        %Lesson{}
        |> Lesson.changeset(%{
          memory_id: memory_id,
          status: "active",
          context: attrs.context,
          source_kind: "manual",
          promoted_at: now,
          promoted_by: attrs.actor,
          promotion_reason: "manual save"
        })
        |> repo().insert()

      %Lesson{status: "active"} = lesson ->
        {:ok, lesson}

      %Lesson{} ->
        {:error, :governed_state_conflict}
    end
  end

  defp ensure_manual_save_state(memory_id) do
    case repo().get(Lesson, memory_id) do
      nil -> :ok
      %Lesson{status: "active"} -> :ok
      %Lesson{} -> {:error, :governed_state_conflict}
    end
  end

  defp activate_eligible_memory(%Memory{lifecycle_state: "active"} = memory), do: {:ok, memory}
  defp activate_eligible_memory(%Memory{}), do: {:error, :governed_state_conflict}

  defp normalize_query(query) do
    case String.trim(query) do
      "" -> {:error, :invalid_arguments}
      value -> {:ok, value}
    end
  end

  defp recall_limit(opts) do
    case Keyword.get(opts, :limit, 10) do
      value when is_integer(value) and value in 1..100 -> {:ok, value}
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp recall_project(opts) do
    case Keyword.get(opts, :project) do
      nil -> {:ok, nil}
      value when is_binary(value) -> normalize_query(value)
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp validate_save(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    with [] <- Map.keys(attrs) -- @save_keys,
         {:ok, rule} <- required(attrs, "rule"),
         {:ok, context} <- required(attrs, "context"),
         {:ok, project} <- required(attrs, "project"),
         {:ok, idempotency_key} <- required(attrs, "idempotency_key"),
         {:ok, session_id} <- optional(attrs, "session_id") do
      {:ok,
       %{
         rule: rule,
         context: context,
         project: project,
         session_id: session_id,
         idempotency_key: idempotency_key
       }}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp validate_candidate(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    allowed = ~w(rule context project session_id idempotency_key source_kind confidence evidence)

    with [] <- Map.keys(attrs) -- allowed,
         {:ok, rule} <- required(attrs, "rule"),
         {:ok, context} <- required(attrs, "context"),
         {:ok, project} <- required(attrs, "project"),
         {:ok, idempotency_key} <- required(attrs, "idempotency_key"),
         {:ok, source_kind} <- required(attrs, "source_kind"),
         true <- source_kind in @automatic_source_kinds,
         {:ok, session_id} <- optional(attrs, "session_id"),
         confidence when is_number(confidence) and confidence >= 0 and confidence <= 1 <-
           attrs["confidence"],
         evidence when is_list(evidence) <- Map.get(attrs, "evidence", []) do
      {:ok,
       %{
         rule: rule,
         context: context,
         project: project,
         session_id: session_id,
         idempotency_key: idempotency_key,
         source_kind:
           if(source_kind in ["failure_remediation", "repeated_failure_remediation"],
             do: "correction",
             else: source_kind
           ),
         extraction_kind: source_kind,
         confidence: confidence / 1,
         evidence: evidence
       }}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp lesson_audit_metadata(partition, trace, details) do
    Map.merge(
      %{
        host_id: partition.host_id,
        client_id: partition.client_id,
        scope: partition.scope,
        namespace: partition.namespace,
        request_id: trace.request_id,
        correlation_id: trace.correlation_id
      },
      details
    )
  end

  defp validate_audit_context(context) do
    context = Map.new(context, fn {key, value} -> {to_string(key), value} end)

    with [] <- Map.keys(context) -- ~w(actor request_id correlation_id),
         {:ok, actor} <- required(context, "actor"),
         {:ok, request_id} <- required(context, "request_id"),
         {:ok, correlation_id} <- required(context, "correlation_id") do
      {:ok, %{actor: actor, request_id: request_id, correlation_id: correlation_id}}
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  defp required(attrs, key) do
    case attrs[key] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> :error
          normalized -> {:ok, normalized}
        end

      _invalid ->
        :error
    end
  end

  defp optional(attrs, key) do
    case attrs[key] do
      nil -> {:ok, nil}
      value -> required(%{key => value}, key)
    end
  end

  defp exact_partition(partition) when is_list(partition),
    do: partition |> Map.new() |> exact_partition()

  defp exact_partition(partition) when is_map(partition) do
    values =
      Map.new(@partition_keys, fn key -> {key, partition[key] || partition[to_string(key)]} end)

    if Enum.all?(values, fn {_key, value} -> is_binary(value) and String.trim(value) != "" end),
      do: {:ok, values},
      else: {:error, :unauthorized}
  end

  defp exact_partition(_partition), do: {:error, :unauthorized}
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
