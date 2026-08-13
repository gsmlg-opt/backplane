defmodule Backplane.Repo.Migrations.AddCaptureSourceSequenceIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS #{qualified("bpm_events_host_session_source_sequence_idx")}"
    )

    create(
      index(:bpm_events, [:host_id, :session_id, :source_sequence],
        name: :bpm_events_host_session_source_sequence_idx,
        concurrently: true
      )
    )
  end

  def down do
    drop(
      index(:bpm_events, [:host_id, :session_id, :source_sequence],
        name: :bpm_events_host_session_source_sequence_idx,
        concurrently: true
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
