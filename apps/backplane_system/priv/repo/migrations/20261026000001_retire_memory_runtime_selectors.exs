defmodule Backplane.Repo.Migrations.RetireMemoryRuntimeSelectors do
  use Ecto.Migration

  def up do
    schema = prefix() || "public"
    jobs = ~s("#{schema}".styx_jobs)
    sessions = ~s("#{schema}".bpm_projected_sessions)
    summaries = ~s("#{schema}".memory_summaries)

    # A running old worker must finish before upgrading its persisted identity.
    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM #{jobs} WHERE state = 'executing' AND
          (worker LIKE 'BackplaneMemory.Workers.%' OR
           (worker IN ('Backplane.Memory.Workers.SummaryWorker',
                       'Backplane.Memory.Workers.EpisodicWorker') AND
            args ? 'session_id' AND NOT args ? 'input_revision' AND NOT args ? 'summary_id'))
      ) THEN
        RAISE EXCEPTION 'Stop Memory workers before retiring legacy jobs';
      END IF;
    END $$;
    """)

    execute("""
    UPDATE #{jobs}
    SET meta = COALESCE(meta, '{}'::jsonb) ||
          jsonb_build_object('memory_retirement', jsonb_build_object('original_worker', worker)),
        worker = replace(worker, 'BackplaneMemory.Workers.', 'Backplane.Memory.Workers.')
    WHERE state IN ('available', 'scheduled', 'retryable', 'suspended')
      AND worker IN (
        'BackplaneMemory.Workers.AccessWritebackWorker', 'BackplaneMemory.Workers.EmbedWorker',
        'BackplaneMemory.Workers.EpisodicWorker', 'BackplaneMemory.Workers.EvictionWorker',
        'BackplaneMemory.Workers.FallbackSweepWorker', 'BackplaneMemory.Workers.GraphExtractWorker',
        'BackplaneMemory.Workers.LeaseCleanupWorker', 'BackplaneMemory.Workers.ProceduralWorker',
        'BackplaneMemory.Workers.ProfileBuildWorker', 'BackplaneMemory.Workers.SummaryWorker'
      );
    """)

    # Session-only jobs carry no authority. Convert only an unambiguous canonical owner.
    execute("""
    WITH unique_sessions AS (
      SELECT session_id FROM #{sessions} GROUP BY session_id HAVING count(*) = 1
    )
    UPDATE #{jobs} j
    SET args = j.args || jsonb_build_object(
          'host_id', s.host_id, 'memory_space_id', s.memory_space_id,
          'client_id', s.client_id, 'source_client_id', s.source_client_id,
          'scope', s.scope, 'namespace', s.namespace,
          'processing_version', 'summary-v1', 'input_revision', s.input_revision)
    FROM #{sessions} s JOIN unique_sessions u USING (session_id)
    WHERE j.state IN ('available', 'scheduled', 'retryable', 'suspended')
      AND j.worker = 'Backplane.Memory.Workers.SummaryWorker'
      AND j.args = jsonb_build_object('session_id', s.session_id)
      AND s.memory_space_id IS NOT NULL AND s.host_id IS NOT NULL AND s.host_id <> ''
      AND s.client_id IS NOT NULL AND s.client_id <> ''
      AND s.scope IS NOT NULL AND s.namespace IS NOT NULL AND s.input_revision IS NOT NULL;
    """)

    execute("""
    WITH unique_summaries AS (
      SELECT session_id FROM #{summaries}
      WHERE processing_version = 'summary-v1' AND superseded_at IS NULL
        AND memory_space_id IS NOT NULL AND host_id IS NOT NULL AND host_id <> ''
        AND scope IS NOT NULL AND namespace IS NOT NULL
      GROUP BY session_id HAVING count(*) = 1
    )
    UPDATE #{jobs} j SET args = jsonb_build_object('summary_id', s.id)
    FROM #{summaries} s JOIN unique_summaries u USING (session_id)
    WHERE j.state IN ('available', 'scheduled', 'retryable', 'suspended')
      AND j.worker = 'Backplane.Memory.Workers.EpisodicWorker'
      AND j.args = jsonb_build_object('session_id', s.session_id)
      AND s.processing_version = 'summary-v1' AND s.superseded_at IS NULL;
    """)

    execute("""
    UPDATE #{jobs}
    SET state = 'cancelled', cancelled_at = now(),
        meta = COALESCE(meta, '{}'::jsonb) ||
          jsonb_build_object('memory_retirement',
            COALESCE(meta->'memory_retirement', '{}'::jsonb) ||
              jsonb_build_object('reason', 'unresolvable_canonical_authority'))
    WHERE state IN ('available', 'scheduled', 'retryable', 'suspended') AND
      (worker LIKE 'BackplaneMemory.Workers.%' OR
       (worker IN ('Backplane.Memory.Workers.SummaryWorker',
                   'Backplane.Memory.Workers.EpisodicWorker') AND
        args ? 'session_id' AND NOT args ? 'input_revision' AND NOT args ? 'summary_id'));
    """)

    execute("""
    DELETE FROM "#{schema}".system_settings
    WHERE key IN ('memory.events.enabled', 'memory.events.dual_write',
                  'memory.recall_v2.enabled', 'memory.host_sync_v1.enabled');
    """)
  end

  def down do
    raise Ecto.MigrationError, "Memory retirement cannot restore the removed runtime"
  end
end
