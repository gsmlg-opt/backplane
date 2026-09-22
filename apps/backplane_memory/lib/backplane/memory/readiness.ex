defmodule Backplane.Memory.Readiness do
  @moduledoc "Fail-closed database qualification for revisioned host memory cutover."
  alias Backplane.Memory.EdgeSync.SnapshotBuilder

  @roots ~w(
    bpm_events bpm_streams bpm_memories bpm_observations memory_sessions
    bpm_projected_observations bpm_projected_sessions memory_summaries memory_crystals
    memory_profiles memory_graph_nodes memory_graph_edges memory_activity_daily
    memory_activity_subject_contributions memory_replay_events memory_recall_runs
    memory_actions memory_leases memory_signals memory_slots memory_import_batches
    bpm_projection_states bpm_projection_snapshots bpm_host_memory_revocations
  )

  # Keep this inventory in step with migration 20260905000003's @children.
  @children [
    {"bpm_memory_remember_requests", "bpm_memories", "memory_id"},
    {"bpm_memory_evidence", "bpm_memories", "memory_id"},
    {"bpm_memory_relations", "bpm_memories", "source_memory_id"},
    {"bpm_memory_relation_evidence", "bpm_memory_relations", "relation_id"},
    {"memory_lessons", "bpm_memories", "memory_id"},
    {"memory_crystal_source_events", "memory_crystals", "crystal_id"},
    {"memory_crystal_source_summaries", "memory_crystals", "crystal_id"},
    {"memory_crystal_source_actions", "memory_crystals", "crystal_id"},
    {"memory_crystal_lessons", "memory_crystals", "crystal_id"},
    {"memory_summary_source_events", "memory_summaries", "summary_id"},
    {"memory_action_edges", "memory_actions", "source_id"},
    {"memory_facets", "bpm_memories", "memory_id"},
    {"memory_recall_candidates", "memory_recall_runs", "recall_run_id"}
  ]

  @checks [
    {:host_mappings, :host_mappings_sql},
    {:root_inventory, :root_inventory_sql},
    {:child_inventory, :child_inventory_sql},
    {:audit_inventory, :audit_inventory_sql},
    {:job_inventory, :job_inventory_sql},
    {:initial_snapshots, :initial_snapshots_sql},
    {:issue_dispositions, :issue_dispositions_sql}
  ]

  @spec edge_cutover() :: {:ok, map()} | {:error, map()}
  def edge_cutover do
    {failures, error_types} =
      Enum.reduce(@checks, {[], %{}}, fn {name, sql_function}, {failures, errors} ->
        try do
          statements = apply(__MODULE__, sql_function, [])

          complete? =
            Enum.all?(List.wrap(statements), &clear?/1) and
              (name != :initial_snapshots or initial_snapshot_integrity?())

          if complete?, do: {failures, errors}, else: {[name | failures], errors}
        rescue
          error -> {[name | failures], Map.put(errors, name, exception_type(error))}
        catch
          kind, _ -> {[name | failures], Map.put(errors, name, Atom.to_string(kind))}
        end
      end)

    failures = Enum.reverse(failures)

    report = %{
      status: if(failures == [], do: :ready, else: :blocked),
      failures: failures,
      error_types: error_types
    }

    if failures == [], do: {:ok, report}, else: {:error, report}
  end

  defp clear?(sql) do
    case repo().query!(sql) do
      %{rows: [[false]]} -> true
      _ -> false
    end
  end

  defp exception_type(error), do: error.__struct__ |> Module.split() |> Enum.join(".")

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  def host_mappings_sql do
    """
    SELECT EXISTS (
      SELECT 1 FROM skill_hosts h
      LEFT JOIN bpm_memory_spaces s
        ON s.id = md5('backplane-memory-space:host:' || h.id::text)::uuid
       AND s.kind = 'private' AND s.status = 'active'
      LEFT JOIN bpm_memory_space_legacy_aliases a
        ON a.alias_type = 'host' AND a.alias_value = 'host:' || h.id::text
       AND a.memory_space_id = s.id
      LEFT JOIN bpm_memory_space_entitlements e
        ON e.host_id = h.id AND e.memory_space_id = s.id
       AND e.scope = btrim(h.memory_scope) AND e.namespace = 'private'
       AND e.status = 'active' AND e.default_capture
      WHERE s.id IS NULL OR a.id IS NULL OR e.id IS NULL
         OR nullif(btrim(h.memory_scope), '') IS NULL
    ) OR EXISTS (
      SELECT 1 FROM bpm_memory_space_entitlements e
      JOIN bpm_memory_spaces s ON s.id = e.memory_space_id
      WHERE e.status = 'active'
        AND (s.status <> 'active' OR nullif(btrim(e.scope), '') IS NULL
          OR nullif(btrim(e.namespace), '') IS NULL)
    ) OR EXISTS (
      SELECT 1 FROM bpm_memory_space_entitlements e
      WHERE e.status = 'active' AND e.default_capture
      GROUP BY e.host_id, e.namespace HAVING count(*) <> 1
    ) OR EXISTS (
      SELECT 1 FROM bpm_memory_space_legacy_aliases a
      JOIN skill_hosts h ON a.alias_type = 'host' AND a.alias_value = 'host:' || h.id::text
      WHERE a.memory_space_id <> md5('backplane-memory-space:host:' || h.id::text)::uuid
    )
    """
  end

  def root_inventory_sql do
    Enum.map(@roots, fn table ->
      """
      SELECT EXISTS (
        SELECT 1 FROM #{table} root
        WHERE (root.memory_space_id IS NULL
           OR nullif(btrim(root.scope), '') IS NULL
           OR nullif(btrim(root.namespace), '') IS NULL
           OR NOT EXISTS (
             SELECT 1 FROM bpm_memory_space_entitlements e
             JOIN bpm_memory_spaces s ON s.id=e.memory_space_id AND s.status='active'
             JOIN bpm_memory_space_legacy_aliases a
               ON a.memory_space_id=s.id AND a.alias_type='host'
              AND a.alias_value='host:' || root.host_id::text
             WHERE e.memory_space_id=root.memory_space_id
               AND e.host_id::text=root.host_id::text AND e.status='active'
               AND e.scope=root.scope AND e.namespace=root.namespace
           ))
          AND NOT EXISTS (#{approved_waiver_sql(table, "root")})
      )
      """
    end)
  end

  def child_inventory_sql do
    Enum.map(@children, fn {child, owner, key} ->
      {joins, valid} = child_links(child, owner, key)

      """
      SELECT EXISTS (
        SELECT 1 FROM #{child} child
        #{joins}
        WHERE (#{valid}) IS NOT TRUE
          AND NOT EXISTS (#{approved_waiver_sql(child, "child")})
      )
      """
    end)
  end

  defp child_links(child, owner, key) do
    owner_join = "LEFT JOIN #{owner} owner ON owner.id=child.#{key}"
    owner_valid = partition_match("owner", "owner")

    case child do
      "bpm_memory_evidence" ->
        joins = """
        #{owner_join}
        LEFT JOIN bpm_events source_event ON source_event.id=child.source_event_id
        LEFT JOIN bpm_observations source_observation ON source_observation.id=child.source_observation_id
        LEFT JOIN memory_summaries source_summary ON source_summary.id=child.source_summary_id
        LEFT JOIN bpm_memory_remember_requests source_request ON source_request.id=child.source_request_id
        LEFT JOIN bpm_memories request_owner ON request_owner.id=source_request.memory_id
        LEFT JOIN memory_crystals source_crystal ON source_crystal.id=child.source_crystal_id
        LEFT JOIN bpm_projected_sessions source_session
          ON source_session.host_id=child.host_id AND source_session.session_id=child.source_session_id
        """

        valid = """
        #{owner_valid} AND child.host_id IS NOT DISTINCT FROM owner.host_id
        AND (child.source_event_id IS NULL OR #{partition_match("owner", "source_event")})
        AND (child.source_observation_id IS NULL OR #{partition_match("owner", "source_observation")})
        AND (child.source_summary_id IS NULL OR #{partition_match("owner", "source_summary")})
        AND (child.source_request_id IS NULL OR #{partition_match("owner", "request_owner")})
        AND (child.source_crystal_id IS NULL OR #{partition_match("owner", "source_crystal")})
        AND (child.source_session_id IS NULL OR #{partition_match("owner", "source_session")})
        """

        {joins, valid}

      "bpm_memory_relations" ->
        with_related(owner_join, owner_valid, "bpm_memories", "target_memory_id")

      "bpm_memory_relation_evidence" ->
        joins = """
        LEFT JOIN bpm_memory_relations relation ON relation.id=child.relation_id
        LEFT JOIN bpm_memories owner ON owner.id=relation.source_memory_id
        LEFT JOIN bpm_memories related ON related.id=relation.target_memory_id
        LEFT JOIN bpm_memory_evidence evidence ON evidence.id=child.evidence_id
        LEFT JOIN bpm_memories evidence_owner ON evidence_owner.id=evidence.memory_id
        """

        {joins,
         "#{partition_match("owner", "related")} AND #{partition_match("owner", "evidence_owner")}"}

      "memory_crystal_source_events" ->
        with_related(owner_join, owner_valid, "bpm_events", "event_id")

      "memory_crystal_source_summaries" ->
        with_related(owner_join, owner_valid, "memory_summaries", "summary_id")

      "memory_crystal_source_actions" ->
        with_related(owner_join, owner_valid, "memory_actions", "action_id")

      "memory_crystal_lessons" ->
        with_related(owner_join, owner_valid, "bpm_memories", "lesson_memory_id")

      "memory_summary_source_events" ->
        {joins, valid} = with_related(owner_join, owner_valid, "bpm_events", "event_id")
        {joins, "#{valid} AND child.host_id IS NOT DISTINCT FROM owner.host_id"}

      "memory_action_edges" ->
        with_related(owner_join, owner_valid, "memory_actions", "target_id")

      "memory_recall_candidates" ->
        joins = """
        #{owner_join}
        LEFT JOIN bpm_memories source_memory ON child.candidate_kind IN ('memory','lesson') AND source_memory.id=child.candidate_id
        LEFT JOIN bpm_events source_event ON child.candidate_kind='event' AND source_event.id=child.candidate_id
        LEFT JOIN bpm_observations source_observation ON child.candidate_kind='observation' AND source_observation.id=child.candidate_id
        LEFT JOIN memory_summaries source_summary ON child.candidate_kind='summary' AND source_summary.id=child.candidate_id
        LEFT JOIN bpm_memory_remember_requests source_request ON child.candidate_kind='request' AND source_request.id=child.candidate_id
        LEFT JOIN bpm_memories request_owner ON request_owner.id=source_request.memory_id
        LEFT JOIN memory_crystals source_crystal ON child.candidate_kind='crystal' AND source_crystal.id=child.candidate_id
        """

        valid = """
        #{owner_valid} AND CASE child.candidate_kind
          WHEN 'memory' THEN #{partition_match("owner", "source_memory")}
          WHEN 'lesson' THEN #{partition_match("owner", "source_memory")}
          WHEN 'event' THEN #{partition_match("owner", "source_event")}
          WHEN 'observation' THEN #{partition_match("owner", "source_observation")}
          WHEN 'summary' THEN #{partition_match("owner", "source_summary")}
          WHEN 'request' THEN #{partition_match("owner", "request_owner")}
          WHEN 'crystal' THEN #{partition_match("owner", "source_crystal")}
          ELSE false END
        """

        {joins, valid}

      _ ->
        {owner_join, owner_valid}
    end
  end

  defp with_related(owner_join, _owner_valid, table, key) do
    {"#{owner_join} LEFT JOIN #{table} related ON related.id=child.#{key}",
     partition_match("owner", "related")}
  end

  defp partition_match(left, right) do
    """
    (nullif(btrim(to_jsonb(#{left})->>'memory_space_id'),'') IS NOT NULL
     AND nullif(btrim(to_jsonb(#{left})->>'scope'),'') IS NOT NULL
     AND nullif(btrim(to_jsonb(#{left})->>'namespace'),'') IS NOT NULL
     AND to_jsonb(#{left})->>'memory_space_id'=to_jsonb(#{right})->>'memory_space_id'
     AND to_jsonb(#{left})->>'scope'=to_jsonb(#{right})->>'scope'
     AND to_jsonb(#{left})->>'namespace'=to_jsonb(#{right})->>'namespace')
    """
  end

  defp approved_waiver_sql(table, row_alias) do
    """
    SELECT 1 FROM bpm_memory_space_backfill_issues issue
    WHERE issue.source_table='#{table}'
      AND issue.source_id=bpm_memory_backfill_source_id('#{table}',to_jsonb(#{row_alias}))
      AND issue.disposition='approved_waiver' AND issue.resolved_at IS NOT NULL
    """
  end

  def audit_inventory_sql do
    """
    SELECT EXISTS (
      SELECT 1 FROM memory_audit_log audit
      WHERE audit.operation IN (#{audit_operations_sql()})
        AND NOT (
          nullif(btrim(audit.metadata->>'memory_space_id'),'') IS NOT NULL
          AND nullif(btrim(audit.metadata->>'scope'),'') IS NOT NULL
          AND nullif(btrim(audit.metadata->>'namespace'),'') IS NOT NULL
        )
        AND 1 <> (
          SELECT count(*) FROM (
            SELECT DISTINCT m.memory_space_id,m.scope,m.namespace
            FROM bpm_memories m
            WHERE m.memory_space_id IS NOT NULL
              AND nullif(btrim(m.scope),'') IS NOT NULL
              AND nullif(btrim(m.namespace),'') IS NOT NULL
              AND CASE jsonb_typeof(audit.target_ids)
                WHEN 'array' THEN audit.target_ids @> jsonb_build_array(m.id::text)
                WHEN 'object' THEN EXISTS (
                  SELECT 1 FROM jsonb_each_text(audit.target_ids) AS t(k,v)
                  WHERE t.v=m.id::text)
                ELSE false END
          ) owners
        )
        AND NOT EXISTS (
          SELECT 1 FROM bpm_memory_space_backfill_issues issue
          WHERE issue.source_table='memory_audit_log' AND issue.source_id=audit.id::text
            AND issue.disposition='approved_waiver' AND issue.resolved_at IS NOT NULL
        )
    )
    """
  end

  # Same operation set used by the canonical-space backfill inventory.
  defp audit_operations_sql do
    ~w(
      activity.repair coordination.action.create coordination.action.status
      coordination.heal coordination.lease.acquire coordination.lease.cleanup
      coordination.signal.read coordination.signal.send crystal.crystallize forget
      governance_delete hard_delete lesson.candidate lesson.save lesson.strengthen
      lesson.transition memory.activity.purge memory.activity.summary memory.apply
      memory.archive memory.config.set memory.export memory.gate.set
      memory.import.completed memory.import.failed memory.import.started
      memory.recall_trace.purge memory.repair memory.replay.import_dispatched
      memory.replay.load memory.replay.sessions memory_relation.candidate
      memory_relation.policy memory_relation.resolve projection.rebuild
      projection.repair remember session.abandoned session.lifecycle_transition
      session.summary_enqueued
    )
    |> Enum.map_join(", ", &("'" <> &1 <> "'"))
  end

  def job_inventory_sql do
    """
    SELECT EXISTS (
      SELECT 1 FROM oban_jobs job
      WHERE (job.worker LIKE 'Elixir.Backplane.Memory.%'
          OR job.worker LIKE 'Backplane.Memory.%')
        AND job.state IN ('available','scheduled','retryable','executing')
        AND (CASE CASE WHEN job.worker LIKE 'Elixir.%' THEN job.worker
                          ELSE 'Elixir.' || job.worker END
          WHEN 'Elixir.Backplane.Memory.Workers.ProceduralWorker' THEN true
          WHEN 'Elixir.Backplane.Memory.Workers.EvictionWorker' THEN true
          WHEN 'Elixir.Backplane.Memory.Workers.FallbackSweepWorker' THEN true
          WHEN 'Elixir.Backplane.Memory.Workers.ActivityRetentionWorker' THEN true
          WHEN 'Elixir.Backplane.Memory.Workers.LeaseCleanupWorker' THEN true
          WHEN 'Elixir.Backplane.Memory.Workers.RecallTracePurgeWorker' THEN true
          WHEN 'Elixir.Backplane.Memory.Workers.LessonDecaySweepWorker' THEN true
          WHEN 'Elixir.Backplane.Memory.Workers.EmbedWorker' THEN EXISTS (
            SELECT 1 FROM bpm_memories owner
            WHERE owner.id::text=job.args->>'id'
              AND #{partition_match("owner", "owner")}
          )
          WHEN 'Elixir.Backplane.Memory.Workers.AccessWritebackWorker' THEN
            jsonb_typeof(job.args->'memory_ids')='array'
            AND NOT EXISTS (
              SELECT 1 FROM jsonb_array_elements_text(job.args->'memory_ids') target(id)
              LEFT JOIN bpm_memories owner ON owner.id::text=target.id
              WHERE owner.id IS NULL OR NOT #{partition_match("owner", "owner")}
            )
          WHEN 'Elixir.Backplane.Memory.Workers.ProjectionRepairWorker' THEN EXISTS (
            SELECT 1 FROM bpm_events owner WHERE owner.id::text=job.args->>'event_id'
              AND #{partition_match("owner", "owner")}
          )
          WHEN 'Elixir.Backplane.Memory.Workers.LessonCandidateWorker' THEN EXISTS (
            SELECT 1 FROM bpm_events owner WHERE owner.id::text=job.args->>'event_id'
              AND #{partition_match("owner", "owner")}
          )
          WHEN 'Elixir.Backplane.Memory.Workers.EpisodicWorker' THEN EXISTS (
            SELECT 1 FROM memory_summaries owner WHERE owner.id::text=job.args->>'summary_id'
              AND #{partition_match("owner", "owner")}
          )
          WHEN 'Elixir.Backplane.Memory.Workers.RelationClassifierWorker' THEN EXISTS (
            SELECT 1 FROM bpm_memories owner WHERE owner.id::text=job.args->>'memory_id'
              AND #{partition_match("owner", "job.args->'partition'")}
          )
          ELSE nullif(btrim(job.args->>'memory_space_id'),'') IS NOT NULL
            AND nullif(btrim(job.args->>'scope'),'') IS NOT NULL
            AND nullif(btrim(job.args->>'namespace'),'') IS NOT NULL
        END) IS NOT TRUE
        AND NOT EXISTS (
          SELECT 1 FROM bpm_memory_space_backfill_issues issue
          WHERE issue.source_table='oban_jobs' AND issue.source_id=job.id::text
            AND issue.disposition='approved_waiver' AND issue.resolved_at IS NOT NULL
        )
    )
    """
  end

  def initial_snapshots_sql do
    """
    SELECT EXISTS (
      SELECT 1 FROM bpm_memory_space_entitlements e
      JOIN bpm_memory_spaces space ON space.id=e.memory_space_id
      WHERE e.status='active' AND space.status='active'
        AND NOT EXISTS (
          SELECT 1 FROM bpm_memory_snapshots s
          JOIN bpm_memory_partition_revisions r
            ON r.memory_space_id=s.memory_space_id AND r.scope=s.scope
           AND r.namespace=s.namespace
          WHERE s.memory_space_id=e.memory_space_id AND s.scope=e.scope
            AND s.namespace=e.namespace AND s.status='ready'
            AND s.expires_at>now() AND s.revision=r.current_revision
            AND s.chunk_count>0 AND s.integrity_hash IS NOT NULL
            AND (SELECT count(*) FROM bpm_memory_snapshot_chunks c
                 WHERE c.snapshot_id=s.id)=s.chunk_count
            AND (SELECT coalesce(sum(c.item_count),0) FROM bpm_memory_snapshot_chunks c
                 WHERE c.snapshot_id=s.id)=s.item_count
        )
    )
    """
  end

  # Stream one row at a time so the cutover check does not retain snapshot payloads.
  # The lateral selection deliberately validates the newest current ready snapshot:
  # a corrupt replacement cannot be hidden by an older valid snapshot.
  defp initial_snapshot_integrity? do
    sql = """
    WITH partitions AS (
      SELECT DISTINCT e.memory_space_id,e.scope,e.namespace
      FROM bpm_memory_space_entitlements e
      JOIN bpm_memory_spaces space ON space.id=e.memory_space_id
      WHERE e.status='active' AND space.status='active'
    )
    SELECT p.memory_space_id::text,p.scope,p.namespace,s.id::text,
           s.chunk_count,s.item_count,s.integrity_hash,
           c.chunk_index,c.item_count,c.encoded_bytes,c.chunk_hash,c.payload
    FROM partitions p
    LEFT JOIN LATERAL (
      SELECT candidate.* FROM bpm_memory_snapshots candidate
      JOIN bpm_memory_partition_revisions r
        ON r.memory_space_id=candidate.memory_space_id
       AND r.scope=candidate.scope AND r.namespace=candidate.namespace
      WHERE candidate.memory_space_id=p.memory_space_id
        AND candidate.scope=p.scope AND candidate.namespace=p.namespace
        AND candidate.status='ready' AND candidate.expires_at>now()
        AND candidate.revision=r.current_revision
      ORDER BY candidate.inserted_at DESC,candidate.id DESC LIMIT 1
    ) s ON true
    LEFT JOIN bpm_memory_snapshot_chunks c ON c.snapshot_id=s.id
    ORDER BY p.memory_space_id,p.scope,p.namespace,c.chunk_index
    """

    case repo().transaction(fn ->
           Ecto.Adapters.SQL.stream(repo(), sql, [], max_rows: 1)
           |> Enum.reduce_while(nil, fn %{rows: rows}, state ->
             Enum.reduce_while(rows, {:cont, state}, fn row, {_, acc} ->
               case check_snapshot_row(row, acc) do
                 :invalid -> {:halt, {:halt, :invalid}}
                 next -> {:cont, {:cont, next}}
               end
             end)
             |> case do
               {:halt, reason} -> {:halt, reason}
               {:cont, next} -> {:cont, next}
             end
           end)
           |> snapshot_complete?()
         end) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp check_snapshot_row([space, scope, namespace, id, chunks, items, integrity | chunk], state) do
    key = {space, scope, namespace}

    cond do
      is_nil(id) or not is_integer(chunks) or chunks < 1 or not is_integer(items) or
        items < 0 or not is_binary(integrity) ->
        :invalid

      state == nil or state.key != key ->
        if snapshot_complete?(state) do
          check_chunk(chunk, %{
            key: key,
            id: id,
            chunks: chunks,
            items: items,
            integrity: integrity,
            index: 0,
            count: 0,
            hash: :crypto.hash_init(:sha256)
          })
        else
          :invalid
        end

      state.id == id ->
        check_chunk(chunk, state)

      true ->
        :invalid
    end
  end

  defp check_chunk([index, count, bytes, hash, payload], state) do
    items = is_map(payload) && Map.get(payload, "items")

    if index == state.index and is_integer(count) and count >= 0 and is_list(items) and
         count == length(items) and is_integer(bytes) and
         bytes == byte_size(Jason.encode!(payload)) and
         is_binary(hash) and hash == SnapshotBuilder.hash(payload) do
      %{
        state
        | index: state.index + 1,
          count: state.count + count,
          hash: :crypto.hash_update(state.hash, hash)
      }
    else
      :invalid
    end
  end

  defp snapshot_complete?(nil), do: true
  defp snapshot_complete?(:invalid), do: false

  defp snapshot_complete?(state) do
    state.index == state.chunks and state.count == state.items and
      state.integrity == "sha256:" <> Base.encode16(:crypto.hash_final(state.hash), case: :lower)
  end

  def issue_dispositions_sql do
    """
    SELECT EXISTS (
      SELECT 1 FROM bpm_memory_space_backfill_issues
      WHERE disposition NOT IN ('resolved','approved_waiver')
         OR resolved_at IS NULL
    )
    """
  end
end
