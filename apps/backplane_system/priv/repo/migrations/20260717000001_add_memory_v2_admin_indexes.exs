defmodule Backplane.Repo.Migrations.AddMemoryV2AdminIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{qualified("bpm_streams_last_event_stream_idx")}")
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{qualified("bpm_events_occurred_id_idx")}")

    execute("""
    CREATE INDEX CONCURRENTLY #{quoted("bpm_streams_last_event_stream_idx")}
    ON #{qualified("bpm_streams")} (last_event_at DESC NULLS LAST, stream_id DESC)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY #{quoted("bpm_events_occurred_id_idx")}
    ON #{qualified("bpm_events")} (occurred_at DESC, id DESC)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{qualified("bpm_events_occurred_id_idx")}")
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{qualified("bpm_streams_last_event_stream_idx")}")
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end

  defp quoted(identifier),
    do: ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
end
