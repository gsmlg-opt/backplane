defmodule Backplane.Repo.Migrations.AddCaptureSourceIdentityConstraint do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS #{qualified("bpm_events_capture_source_identity_uniq")}"
    )

    create(
      unique_index(
        :bpm_events,
        [:host_id, :session_id, :source_sequence, :event_type],
        name: :bpm_events_capture_source_identity_uniq,
        concurrently: true,
        where:
          "schema_version IS NOT NULL AND session_id IS NOT NULL AND source_sequence IS NOT NULL"
      )
    )
  end

  def down do
    drop(
      unique_index(
        :bpm_events,
        [:host_id, :session_id, :source_sequence, :event_type],
        name: :bpm_events_capture_source_identity_uniq,
        concurrently: true,
        where:
          "schema_version IS NOT NULL AND session_id IS NOT NULL AND source_sequence IS NOT NULL"
      )
    )
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end
end
