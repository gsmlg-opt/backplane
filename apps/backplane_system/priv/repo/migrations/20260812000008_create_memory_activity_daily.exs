defmodule Backplane.Repo.Migrations.CreateMemoryActivityDaily do
  use Ecto.Migration

  @batch_size 500
  @repair_marker "20260812000008_activity_projection_repair"

  def up do
    create table(:memory_activity_subject_contributions, primary_key: false) do
      add(:subject_id, :text, primary_key: true)
      add(:date, :date, primary_key: true)
      add(:project, :text, primary_key: true)
      add(:agent_id, :text, primary_key: true)
      add(:host_id, :text, primary_key: true)
      add(:client_id, :text, primary_key: true)
      add(:scope, :text, primary_key: true)
      add(:namespace, :text, primary_key: true)
      add(:event_type, :text, primary_key: true)
      add(:event_count, :bigint, null: false, default: 0)
      add(:session_count, :bigint, null: false, default: 0)
      add(:memory_count, :bigint, null: false, default: 0)
      add(:lesson_count, :bigint, null: false, default: 0)
      add(:crystal_count, :bigint, null: false, default: 0)
      add(:recall_count, :bigint, null: false, default: 0)
      add(:action_count, :bigint, null: false, default: 0)
      add(:error_count, :bigint, null: false, default: 0)
      add(:processing_version, :text, null: false)
      add(:input_revision, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      index(
        :memory_activity_subject_contributions,
        [:client_id, :scope, :namespace, :date, :project, :agent_id, :host_id, :event_type],
        name: :memory_activity_contributions_aggregate_idx
      )
    )

    create table(:memory_activity_daily, primary_key: false) do
      add(:date, :date, primary_key: true)
      add(:project, :text, primary_key: true)
      add(:agent_id, :text, primary_key: true)
      add(:host_id, :text, primary_key: true)
      add(:client_id, :text, primary_key: true)
      add(:scope, :text, primary_key: true)
      add(:namespace, :text, primary_key: true)
      add(:event_type, :text, primary_key: true)
      add(:event_count, :bigint, null: false, default: 0)
      add(:session_count, :bigint, null: false, default: 0)
      add(:memory_count, :bigint, null: false, default: 0)
      add(:lesson_count, :bigint, null: false, default: 0)
      add(:crystal_count, :bigint, null: false, default: 0)
      add(:recall_count, :bigint, null: false, default: 0)
      add(:action_count, :bigint, null: false, default: 0)
      add(:error_count, :bigint, null: false, default: 0)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      index(
        :memory_activity_daily,
        [:client_id, :scope, :namespace, :date, :project, :agent_id, :host_id, :event_type],
        name: :memory_activity_daily_partition_date_idx
      )
    )

    create(
      constraint(
        :memory_activity_subject_contributions,
        :memory_activity_contribution_counts_check,
        check: non_negative_counters()
      )
    )

    create(
      constraint(:memory_activity_daily, :memory_activity_daily_counts_check,
        check: non_negative_counters()
      )
    )

    flush()
    backfill_contributions(nil)
    rebuild_daily()
    queue_repairs(nil)
  end

  def down do
    drop(table(:memory_activity_daily))
    drop(table(:memory_activity_subject_contributions))
  end

  defp backfill_contributions(cursor) do
    %{rows: rows} = repo().query!(backfill_sql(), [cursor, @batch_size])

    case List.last(rows) do
      [next_cursor] -> backfill_contributions(next_cursor)
      nil -> :ok
    end
  end

  defp backfill_sql do
    snapshots = qualified_table("bpm_projection_snapshots")
    states = qualified_table("bpm_projection_states")
    sessions = qualified_table("bpm_projected_sessions")
    contributions = qualified_table("memory_activity_subject_contributions")

    """
    WITH candidates AS (
      SELECT snapshot.subject_id,
             snapshot.input_revision,
             state.processing_version,
             snapshot.read_model,
             session.client_id,
             session.scope,
             session.namespace,
             snapshot.inserted_at,
             snapshot.updated_at
      FROM #{snapshots} AS snapshot
      JOIN #{states} AS state
        ON state.projector = snapshot.projector
       AND state.subject_type = snapshot.subject_type
       AND state.subject_id = snapshot.subject_id
       AND state.input_revision = snapshot.input_revision
       AND state.output_revision = snapshot.output_revision
      JOIN #{sessions} AS session ON session.subject_id = snapshot.subject_id
      WHERE snapshot.projector = 'activity'
        AND snapshot.subject_type = 'captured_session'
        AND state.status IN ('complete', 'pending')
        AND session.client_id IS NOT NULL
        AND session.scope IS NOT NULL
        AND session.namespace IS NOT NULL
        AND ($1::text IS NULL OR snapshot.subject_id > $1)
      ORDER BY snapshot.subject_id
      LIMIT $2
    ), expanded AS (
      SELECT candidate.subject_id,
             (row->>'date')::date AS date,
             COALESCE(row->>'project', '') AS project,
             COALESCE(row->>'agent_id', '') AS agent_id,
             COALESCE(row->>'host_id', '') AS host_id,
             candidate.client_id,
             candidate.scope,
             candidate.namespace,
             COALESCE(row->>'event_type', '') AS event_type,
             COALESCE((row->>'event_count')::bigint, 0) AS event_count,
             COALESCE((row->>'session_count')::bigint, 0) AS session_count,
             COALESCE(
               (row->>'memory_count')::bigint,
               CASE WHEN row->>'event_type' LIKE 'memory.%'
                          AND row->>'event_type' <> 'memory.recalled'
                    THEN COALESCE((row->>'event_count')::bigint, 0) ELSE 0 END
             ) AS memory_count,
             COALESCE(
               (row->>'lesson_count')::bigint,
               CASE WHEN row->>'event_type' LIKE 'lesson.%'
                    THEN COALESCE((row->>'event_count')::bigint, 0) ELSE 0 END
             ) AS lesson_count,
             COALESCE(
               (row->>'crystal_count')::bigint,
               CASE WHEN row->>'event_type' LIKE 'crystal.%'
                    THEN COALESCE((row->>'event_count')::bigint, 0) ELSE 0 END
             ) AS crystal_count,
             COALESCE(
               (row->>'recall_count')::bigint,
               CASE WHEN row->>'event_type' = 'memory.recalled'
                    THEN COALESCE((row->>'event_count')::bigint, 0) ELSE 0 END
             ) AS recall_count,
             COALESCE(
               (row->>'action_count')::bigint,
               CASE WHEN row->>'event_type' LIKE 'action.%'
                          OR row->>'event_type' LIKE 'task.%'
                    THEN COALESCE((row->>'event_count')::bigint, 0) ELSE 0 END
             ) AS action_count,
             COALESCE((row->>'error_count')::bigint, 0) AS error_count,
             candidate.processing_version,
             candidate.input_revision,
             candidate.inserted_at,
             candidate.updated_at
      FROM candidates AS candidate
      CROSS JOIN LATERAL jsonb_array_elements(
        CASE
          WHEN jsonb_typeof(candidate.read_model->'activity') = 'array'
            THEN candidate.read_model->'activity'
          ELSE '[]'::jsonb
        END
      ) AS row
      WHERE row ? 'date'
        AND NULLIF(row->>'host_id', '') IS NOT NULL
        AND NULLIF(row->>'event_type', '') IS NOT NULL
    ), consolidated AS (
      SELECT subject_id, date, project, agent_id, host_id, client_id, scope, namespace,
             event_type, sum(event_count) AS event_count,
             sum(session_count) AS session_count, sum(memory_count) AS memory_count,
             sum(lesson_count) AS lesson_count, sum(crystal_count) AS crystal_count,
             sum(recall_count) AS recall_count, sum(action_count) AS action_count,
             sum(error_count) AS error_count, processing_version, input_revision,
             min(inserted_at) AS inserted_at, max(updated_at) AS updated_at
      FROM expanded
      GROUP BY subject_id, date, project, agent_id, host_id, client_id, scope, namespace,
               event_type, processing_version, input_revision
    ), upserted AS (
      INSERT INTO #{contributions}
        (subject_id, date, project, agent_id, host_id, client_id, scope, namespace,
         event_type, event_count, session_count, memory_count, lesson_count,
         crystal_count, recall_count, action_count, error_count, processing_version,
         input_revision, inserted_at, updated_at)
      SELECT subject_id, date, project, agent_id, host_id, client_id, scope, namespace,
             event_type, event_count, session_count, memory_count, lesson_count,
             crystal_count, recall_count, action_count, error_count, processing_version,
             input_revision, inserted_at, updated_at
      FROM consolidated
      ON CONFLICT (subject_id, date, project, agent_id, host_id, client_id, scope,
                   namespace, event_type)
      DO UPDATE SET
        event_count = EXCLUDED.event_count,
        session_count = EXCLUDED.session_count,
        memory_count = EXCLUDED.memory_count,
        lesson_count = EXCLUDED.lesson_count,
        crystal_count = EXCLUDED.crystal_count,
        recall_count = EXCLUDED.recall_count,
        action_count = EXCLUDED.action_count,
        error_count = EXCLUDED.error_count,
        processing_version = EXCLUDED.processing_version,
        input_revision = EXCLUDED.input_revision,
        updated_at = EXCLUDED.updated_at
      RETURNING subject_id
    )
    SELECT subject_id FROM candidates ORDER BY subject_id
    """
  end

  defp rebuild_daily do
    contributions = qualified_table("memory_activity_subject_contributions")
    daily = qualified_table("memory_activity_daily")

    repo().query!("""
    INSERT INTO #{daily}
      (date, project, agent_id, host_id, client_id, scope, namespace, event_type,
       event_count, session_count, memory_count, lesson_count, crystal_count,
       recall_count, action_count, error_count, inserted_at, updated_at)
    SELECT date, project, agent_id, host_id, client_id, scope, namespace, event_type,
           sum(event_count), sum(session_count), sum(memory_count), sum(lesson_count),
           sum(crystal_count), sum(recall_count), sum(action_count), sum(error_count),
           now(), now()
    FROM #{contributions}
    GROUP BY date, project, agent_id, host_id, client_id, scope, namespace, event_type
    """)
  end

  defp queue_repairs(cursor) do
    %{rows: rows} =
      repo().query!(repair_sql(), [cursor_host(cursor), cursor_session(cursor), @batch_size])

    case List.last(rows) do
      [host_id, session_id] -> queue_repairs({host_id, session_id})
      nil -> :ok
    end
  end

  defp repair_sql do
    events = qualified_table("bpm_events")
    sessions = qualified_table("bpm_projected_sessions")
    snapshots = qualified_table("bpm_projection_snapshots")
    states = qualified_table("bpm_projection_states")
    jobs = qualified_table("oban_jobs")

    """
    WITH subject_page AS (
      SELECT event.host_id, event.session_id,
             max(event.source_sequence) AS source_sequence_max
      FROM #{events} AS event
      WHERE event.schema_version IS NOT NULL
        AND event.host_id IS NOT NULL
        AND event.session_id IS NOT NULL
        AND ($1::text IS NULL OR event.host_id > $1
             OR (event.host_id = $1 AND event.session_id > $2))
      GROUP BY event.host_id, event.session_id
      ORDER BY event.host_id, event.session_id
      LIMIT $3
    ), latest AS (
      SELECT page.*,
             latest_event.id AS event_id,
             latest_event.occurred_at AS last_event_at
      FROM subject_page AS page
      JOIN LATERAL (
        SELECT event.id, event.occurred_at
        FROM #{events} AS event
        WHERE event.schema_version IS NOT NULL
          AND event.host_id = page.host_id
          AND event.session_id = page.session_id
        ORDER BY event.source_sequence DESC NULLS LAST,
                 event.occurred_at DESC,
                 event.event_type DESC,
                 event.id DESC
        LIMIT 1
      ) AS latest_event ON true
    ), repair_candidates AS (
      SELECT latest.event_id
      FROM latest
      LEFT JOIN #{sessions} AS session
        ON session.host_id = latest.host_id AND session.session_id = latest.session_id
      LEFT JOIN #{snapshots} AS snapshot
        ON snapshot.projector = 'activity'
       AND snapshot.subject_type = 'captured_session'
       AND snapshot.subject_id = session.subject_id
      LEFT JOIN #{states} AS state
        ON state.projector = 'activity'
       AND state.subject_type = 'captured_session'
       AND state.subject_id = session.subject_id
      WHERE session.subject_id IS NULL
         OR snapshot.subject_id IS NULL
         OR state.subject_id IS NULL
         OR state.status NOT IN ('complete', 'pending')
         OR state.input_revision IS DISTINCT FROM snapshot.input_revision
         OR state.output_revision IS DISTINCT FROM snapshot.output_revision
         OR session.input_revision IS DISTINCT FROM state.input_revision
         OR session.source_sequence_max IS DISTINCT FROM latest.source_sequence_max
         OR session.last_event_at IS DISTINCT FROM latest.last_event_at
    ), inserted AS (
      INSERT INTO #{jobs} (queue, worker, args, max_attempts, meta)
      SELECT 'memory',
             'Backplane.Memory.Workers.ProjectionRepairWorker',
             jsonb_build_object('event_id', candidate.event_id::text),
             5,
             jsonb_build_object('backplane_migration', '#{@repair_marker}')
      FROM repair_candidates AS candidate
      WHERE NOT EXISTS (
        SELECT 1 FROM #{jobs} AS job
        WHERE job.queue = 'memory'
          AND job.worker = 'Backplane.Memory.Workers.ProjectionRepairWorker'
          AND job.args = jsonb_build_object('event_id', candidate.event_id::text)
          AND job.meta @> jsonb_build_object('backplane_migration', '#{@repair_marker}')
      )
      RETURNING id
    )
    SELECT host_id, session_id FROM subject_page ORDER BY host_id, session_id
    """
  end

  defp cursor_host(nil), do: nil
  defp cursor_host({host_id, _session_id}), do: host_id
  defp cursor_session(nil), do: nil
  defp cursor_session({_host_id, session_id}), do: session_id

  defp non_negative_counters do
    "event_count >= 0 AND session_count >= 0 AND memory_count >= 0 AND " <>
      "lesson_count >= 0 AND crystal_count >= 0 AND recall_count >= 0 AND " <>
      "action_count >= 0 AND error_count >= 0"
  end

  defp qualified_table(name) do
    case prefix() do
      nil -> ~s|"#{name}"|
      prefix -> ~s|"#{String.replace(prefix, "\"", "\"\"")}"."#{name}"|
    end
  end
end
