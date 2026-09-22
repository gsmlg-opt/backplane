defmodule Backplane.Repo.Migrations.CoalesceProjectionRepairs do
  use Ecto.Migration

  @worker "Backplane.Memory.Workers.ProjectionRepairWorker"

  def up do
    create table(:bpm_projection_repair_frontiers, primary_key: false) do
      add :host_id, :text, primary_key: true
      add :session_id, :text, primary_key: true
      add :requested_generation, :bigint, null: false, default: 0
      add :requested_revision, :text
      add :inflight_generation, :bigint, null: false, default: 0
      add :inflight_revision, :text
      add :completed_generation, :bigint, null: false, default: 0
      add :completed_revision, :text
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:bpm_projection_repair_frontiers, :bpm_projection_repair_generation_order,
             check:
               "requested_generation >= inflight_generation AND inflight_generation >= completed_generation"
           )

    create constraint(:bpm_projection_repair_frontiers, :bpm_projection_repair_revision_presence,
             check: """
             (requested_generation = 0) = (requested_revision IS NULL) AND
             (inflight_generation = 0) = (inflight_revision IS NULL) AND
             (completed_generation = 0) = (completed_revision IS NULL)
             """
           )

    execute(deduplicate_legacy_jobs_sql())
  end

  def down do
    drop table(:bpm_projection_repair_frontiers)
  end

  defp deduplicate_legacy_jobs_sql do
    events = quote_name(:bpm_events)
    jobs = quote_name(:oban_jobs)

    """
    WITH eligible AS (
      SELECT job.id,
             event.host_id,
             event.session_id,
             row_number() OVER (
               PARTITION BY event.host_id, event.session_id
               ORDER BY job.id
             ) AS position
      FROM #{jobs} AS job
      JOIN #{events} AS event
        ON event.id::text = job.args ->> 'event_id'
      WHERE job.worker = '#{@worker}'
        AND job.state IN ('available', 'scheduled', 'retryable', 'suspended')
        AND jsonb_typeof(job.args) = 'object'
        AND job.args ? 'event_id'
        AND event.schema_version IS NOT NULL
        AND event.host_id IS NOT NULL
        AND btrim(event.host_id) <> ''
        AND event.session_id IS NOT NULL
        AND btrim(event.session_id) <> ''
    ), frontiers AS (
      INSERT INTO #{quote_name(:bpm_projection_repair_frontiers)}
        (host_id, session_id, requested_generation, inflight_generation,
         completed_generation, inserted_at, updated_at)
      SELECT DISTINCT host_id, session_id, 0, 0, 0, now(), now()
      FROM eligible
      ON CONFLICT (host_id, session_id) DO NOTHING
    ), converted AS (
      UPDATE #{jobs} AS job
      SET args = job.args || jsonb_build_object(
        'host_id', eligible.host_id,
        'session_id', eligible.session_id
      )
      FROM eligible
      WHERE job.id = eligible.id
        AND eligible.position = 1
      RETURNING job.id
    )
    DELETE FROM #{jobs} AS job
    USING eligible
    WHERE job.id = eligible.id
      AND eligible.position > 1
    """
  end

  defp quote_name(name) do
    case prefix() do
      nil -> ~s("#{name}")
      prefix -> ~s("#{prefix}"."#{name}")
    end
  end
end
