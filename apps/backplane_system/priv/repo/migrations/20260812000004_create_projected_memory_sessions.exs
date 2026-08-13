defmodule Backplane.Repo.Migrations.CreateProjectedMemorySessions do
  use Ecto.Migration

  @backfill_batch_size 500

  def up do
    create table(:bpm_projected_sessions, primary_key: false) do
      add(:subject_id, :text, primary_key: true)
      add(:host_id, :text, null: false)
      add(:session_id, :text, null: false)
      add(:project, :text)
      add(:agent_id, :text)
      add(:integration, :text)
      add(:status, :text, null: false)
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:last_event_at, :utc_datetime_usec, null: false)
      add(:source_sequence_max, :bigint)
      add(:gap_count, :integer, null: false, default: 0)
      add(:processing_version, :text, null: false)
      add(:input_revision, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:bpm_projected_sessions, [:host_id, :session_id],
        name: :bpm_projected_sessions_host_session_uniq
      )
    )

    create(
      index(:bpm_projected_sessions, [:last_event_at, :subject_id],
        name: :bpm_projected_sessions_fallback_candidates_idx,
        where: "status IN ('active', 'stopped', 'completed', 'abandoned')"
      )
    )

    flush()
    backfill_batches(nil)
  end

  def down do
    drop(table(:bpm_projected_sessions))
  end

  # Keyset batches bound each statement's source scan and write set. The source
  # projection/event rows are only read; migration rollback remains atomic.
  defp backfill_batches(cursor) do
    %{rows: rows} = repo().query!(backfill_sql(), [cursor, @backfill_batch_size])

    case List.last(rows) do
      [next_cursor] -> backfill_batches(next_cursor)
      nil -> :ok
    end
  end

  defp backfill_sql do
    snapshots = qualified_table("bpm_projection_snapshots")
    states = qualified_table("bpm_projection_states")
    events = qualified_table("bpm_events")
    sessions = qualified_table("bpm_projected_sessions")
    jobs = qualified_table("oban_jobs")

    """
    WITH candidates AS (
      SELECT snapshot.subject_id,
             snapshot.input_revision,
             snapshot.output_revision,
             snapshot.read_model,
             snapshot.inserted_at,
             snapshot.updated_at,
             state.processing_version
      FROM #{snapshots} AS snapshot
      JOIN #{states} AS state
        ON state.projector = 'session'
       AND state.subject_type = 'captured_session'
       AND state.subject_id = snapshot.subject_id
       AND state.input_revision = snapshot.input_revision
       AND state.output_revision = snapshot.output_revision
      WHERE snapshot.projector = 'session'
        AND snapshot.subject_type = 'captured_session'
        AND snapshot.input_revision IS NOT NULL
        AND snapshot.output_revision IS NOT NULL
        AND ($1::text IS NULL OR snapshot.subject_id > $1)
      ORDER BY snapshot.subject_id
      LIMIT $2
    ), derived AS (
      SELECT candidate.subject_id,
             first_event.host_id,
             first_event.session_id,
             COALESCE(project_value.project, NULLIF(candidate.read_model->>'project', '')) AS project,
             COALESCE(agent_value.agent_id, NULLIF(candidate.read_model->>'agent_id', '')) AS agent_id,
             first_event.integration,
             CASE last_lifecycle.event_type
               WHEN 'agent.session.abandoned' THEN 'abandoned'
               WHEN 'agent.session.ended' THEN 'completed'
               WHEN 'session.ended' THEN 'completed'
               WHEN 'agent.session.stopped' THEN 'stopped'
               ELSE 'active'
             END AS status,
             COALESCE(first_started.occurred_at, first_event.occurred_at) AS started_at,
             terminal_event.occurred_at AS ended_at,
             last_event.occurred_at AS last_event_at,
             sequence_stats.source_sequence_max,
             sequence_stats.gap_count,
             COALESCE(NULLIF(candidate.processing_version, ''), 'session-v1') AS processing_version,
             candidate.input_revision,
             candidate.inserted_at,
             candidate.updated_at
      FROM candidates AS candidate
      JOIN LATERAL (
        SELECT event.host_id, event.session_id, event.occurred_at, event.integration
        FROM #{events} AS event
        WHERE event.schema_version IS NOT NULL
          AND event.host_id = candidate.read_model->>'host_id'
          AND event.session_id = candidate.read_model->>'session_id'
          AND event.id::text IN (
            SELECT source_id
            FROM jsonb_array_elements_text(
              CASE
                WHEN jsonb_typeof(candidate.read_model->'source_event_ids') = 'array'
                  THEN candidate.read_model->'source_event_ids'
                ELSE '[]'::jsonb
              END
            ) AS source_ids(source_id)
          )
        ORDER BY event.source_sequence ASC NULLS FIRST, event.event_type ASC, event.id ASC
        LIMIT 1
      ) AS first_event ON true
      JOIN LATERAL (
        SELECT event.occurred_at
        FROM #{events} AS event
        WHERE event.schema_version IS NOT NULL
          AND event.host_id = first_event.host_id
          AND event.session_id = first_event.session_id
          AND event.id::text IN (
            SELECT source_id
            FROM jsonb_array_elements_text(candidate.read_model->'source_event_ids')
              AS source_ids(source_id)
          )
        ORDER BY event.source_sequence DESC NULLS LAST, event.event_type DESC, event.id DESC
        LIMIT 1
      ) AS last_event ON true
      LEFT JOIN LATERAL (
        SELECT event.occurred_at
        FROM #{events} AS event
        WHERE event.schema_version IS NOT NULL
          AND event.host_id = first_event.host_id
          AND event.session_id = first_event.session_id
          AND event.event_type IN ('agent.session.started', 'session.started')
          AND event.id::text IN (
            SELECT source_id
            FROM jsonb_array_elements_text(candidate.read_model->'source_event_ids')
              AS source_ids(source_id)
          )
        ORDER BY event.source_sequence ASC NULLS FIRST, event.event_type ASC, event.id ASC
        LIMIT 1
      ) AS first_started ON true
      LEFT JOIN LATERAL (
        SELECT event.event_type
        FROM #{events} AS event
        WHERE event.schema_version IS NOT NULL
          AND event.host_id = first_event.host_id
          AND event.session_id = first_event.session_id
          AND event.event_type IN (
            'agent.session.abandoned', 'agent.session.ended', 'session.ended',
            'agent.session.stopped', 'agent.session.started', 'session.started'
          )
          AND event.id::text IN (
            SELECT source_id
            FROM jsonb_array_elements_text(candidate.read_model->'source_event_ids')
              AS source_ids(source_id)
          )
        ORDER BY event.source_sequence DESC NULLS LAST, event.event_type DESC, event.id DESC
        LIMIT 1
      ) AS last_lifecycle ON true
      LEFT JOIN LATERAL (
        SELECT event.occurred_at
        FROM #{events} AS event
        WHERE event.schema_version IS NOT NULL
          AND event.host_id = first_event.host_id
          AND event.session_id = first_event.session_id
          AND event.event_type IN (
            'agent.session.abandoned', 'agent.session.ended', 'session.ended',
            'agent.session.stopped'
          )
          AND event.id::text IN (
            SELECT source_id
            FROM jsonb_array_elements_text(candidate.read_model->'source_event_ids')
              AS source_ids(source_id)
          )
        ORDER BY event.source_sequence DESC NULLS LAST, event.event_type DESC, event.id DESC
        LIMIT 1
      ) AS terminal_event ON true
      LEFT JOIN LATERAL (
        SELECT event.project
        FROM #{events} AS event
        WHERE event.schema_version IS NOT NULL
          AND event.host_id = first_event.host_id
          AND event.session_id = first_event.session_id
          AND NULLIF(event.project, '') IS NOT NULL
          AND event.id::text IN (
            SELECT source_id
            FROM jsonb_array_elements_text(candidate.read_model->'source_event_ids')
              AS source_ids(source_id)
          )
        ORDER BY event.source_sequence ASC NULLS FIRST, event.event_type ASC, event.id ASC
        LIMIT 1
      ) AS project_value ON true
      LEFT JOIN LATERAL (
        SELECT event.agent_id
        FROM #{events} AS event
        WHERE event.schema_version IS NOT NULL
          AND event.host_id = first_event.host_id
          AND event.session_id = first_event.session_id
          AND NULLIF(event.agent_id, '') IS NOT NULL
          AND event.id::text IN (
            SELECT source_id
            FROM jsonb_array_elements_text(candidate.read_model->'source_event_ids')
              AS source_ids(source_id)
          )
        ORDER BY event.source_sequence ASC NULLS FIRST, event.event_type ASC, event.id ASC
        LIMIT 1
      ) AS agent_value ON true
      JOIN LATERAL (
        SELECT max(ordered.source_sequence) AS source_sequence_max,
               count(*) FILTER (
                 WHERE ordered.source_sequence > ordered.previous_sequence + 1
               )::integer AS gap_count
        FROM (
          SELECT sequences.source_sequence,
                 lag(sequences.source_sequence, 1, 0) OVER (
                   ORDER BY sequences.source_sequence
                 ) AS previous_sequence
          FROM (
            SELECT DISTINCT event.source_sequence
            FROM #{events} AS event
            WHERE event.schema_version IS NOT NULL
              AND event.host_id = first_event.host_id
              AND event.session_id = first_event.session_id
              AND event.source_sequence > 0
              AND event.id::text IN (
                SELECT source_id
                FROM jsonb_array_elements_text(candidate.read_model->'source_event_ids')
                  AS source_ids(source_id)
              )
          ) AS sequences
        ) AS ordered
      ) AS sequence_stats ON true
    ), upserted AS (
      INSERT INTO #{sessions}
        (subject_id, host_id, session_id, project, agent_id, integration, status,
         started_at, ended_at, last_event_at, source_sequence_max, gap_count,
         processing_version, input_revision, inserted_at, updated_at)
      SELECT subject_id, host_id, session_id, project, agent_id, integration, status,
             started_at, ended_at, last_event_at, source_sequence_max, gap_count,
             processing_version, input_revision, inserted_at, updated_at
      FROM derived
      ON CONFLICT (subject_id) DO UPDATE SET
        host_id = EXCLUDED.host_id,
        session_id = EXCLUDED.session_id,
        project = EXCLUDED.project,
        agent_id = EXCLUDED.agent_id,
        integration = EXCLUDED.integration,
        status = EXCLUDED.status,
        started_at = EXCLUDED.started_at,
        ended_at = EXCLUDED.ended_at,
        last_event_at = EXCLUDED.last_event_at,
        source_sequence_max = EXCLUDED.source_sequence_max,
        gap_count = EXCLUDED.gap_count,
        processing_version = EXCLUDED.processing_version,
        input_revision = EXCLUDED.input_revision,
        updated_at = EXCLUDED.updated_at
      RETURNING subject_id
    ), repair_candidates AS (
      SELECT DISTINCT latest_event.id AS event_id
      FROM candidates AS candidate
      JOIN LATERAL (
        SELECT event.id
        FROM #{events} AS event
        WHERE event.schema_version IS NOT NULL
          AND event.host_id = candidate.read_model->>'host_id'
          AND event.session_id = candidate.read_model->>'session_id'
        ORDER BY event.source_sequence DESC NULLS LAST, event.event_type DESC, event.id DESC
        LIMIT 1
      ) AS latest_event ON true
    ), repair_jobs AS (
      INSERT INTO #{jobs} (queue, worker, args, max_attempts, meta)
      SELECT 'memory',
             'Backplane.Memory.Workers.ProjectionRepairWorker',
             jsonb_build_object('event_id', repair_candidate.event_id::text),
             5,
             jsonb_build_object(
               'backplane_migration',
               '20260812000004_projected_session_repair'
             )
      FROM repair_candidates AS repair_candidate
      WHERE NOT EXISTS (
        SELECT 1
        FROM #{jobs} AS existing_job
        WHERE existing_job.worker = 'Backplane.Memory.Workers.ProjectionRepairWorker'
          AND existing_job.queue = 'memory'
          AND existing_job.args = jsonb_build_object(
            'event_id', repair_candidate.event_id::text
          )
          AND existing_job.meta @> jsonb_build_object(
            'backplane_migration',
            '20260812000004_projected_session_repair'
          )
      )
      RETURNING id
    )
    SELECT subject_id FROM candidates ORDER BY subject_id
    """
  end

  defp qualified_table(table) do
    case prefix() do
      nil -> ~s|"#{table}"|
      prefix -> ~s|"#{String.replace(prefix, "\"", "\"\"")}"."#{table}"|
    end
  end
end
