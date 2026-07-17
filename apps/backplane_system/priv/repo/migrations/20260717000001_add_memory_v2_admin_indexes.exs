defmodule Backplane.Repo.Migrations.AddMemoryV2AdminIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS bpm_streams_last_event_stream_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS bpm_events_occurred_id_idx")

    execute("""
    CREATE INDEX CONCURRENTLY bpm_streams_last_event_stream_idx
    ON bpm_streams (last_event_at DESC NULLS LAST, stream_id DESC)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY bpm_events_occurred_id_idx
    ON bpm_events (occurred_at DESC, id DESC)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS bpm_events_occurred_id_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS bpm_streams_last_event_stream_idx")
  end
end
