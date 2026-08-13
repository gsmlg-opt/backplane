defmodule Backplane.Repo.Migrations.CreateMemoryReplayEvents do
  use Ecto.Migration

  def up do
    create table(:memory_replay_events, primary_key: false) do
      add(:subject_id, :text, primary_key: true)
      add(:input_revision, :text, primary_key: true)
      add(:position, :integer, primary_key: true)
      add(:event_id, references(:bpm_events, type: :uuid, on_delete: :restrict), null: false)
      add(:host_id, :text, null: false)
      add(:client_id, :text, null: false)
      add(:scope, :text, null: false)
      add(:namespace, :text, null: false)
      add(:session_id, :text, null: false)
      add(:source_sequence, :bigint)
      add(:kind, :text, null: false)
      add(:event_type, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:detail, :map, null: false, default: fragment("'{}'::jsonb"))
      add(:processing_version, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:memory_replay_events, [:subject_id, :input_revision, :event_id, :kind],
        name: :memory_replay_event_kind_unique_idx
      )
    )

    create(
      index(
        :memory_replay_events,
        [:host_id, :client_id, :scope, :namespace, :session_id, :input_revision, :position],
        name: :memory_replay_exact_partition_page_idx
      )
    )

    create(
      constraint(:memory_replay_events, :memory_replay_position_check, check: "position > 0")
    )

    execute("""
    CREATE FUNCTION #{qualified("memory_replay_immutable")}()
    RETURNS trigger AS $$ BEGIN
      RAISE EXCEPTION 'replay rows are immutable' USING ERRCODE = '23514', CONSTRAINT = 'memory_replay_immutable';
    END; $$ LANGUAGE plpgsql
    """)

    execute(
      "CREATE TRIGGER memory_replay_immutable_row BEFORE UPDATE OR DELETE ON #{qualified("memory_replay_events")} FOR EACH ROW EXECUTE FUNCTION #{qualified("memory_replay_immutable")}()"
    )

    execute(
      "CREATE TRIGGER memory_replay_immutable_truncate BEFORE TRUNCATE ON #{qualified("memory_replay_events")} FOR EACH STATEMENT EXECUTE FUNCTION #{qualified("memory_replay_immutable")}()"
    )
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS memory_replay_immutable_truncate ON #{qualified("memory_replay_events")}"
    )

    execute(
      "DROP TRIGGER IF EXISTS memory_replay_immutable_row ON #{qualified("memory_replay_events")}"
    )

    execute("DROP FUNCTION IF EXISTS #{qualified("memory_replay_immutable")}()")
    drop(table(:memory_replay_events))
  end

  defp qualified(name),
    do: [prefix(), name] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.map_join(".", &quote_name/1)

  defp quote_name(name), do: ~s("#{String.replace(to_string(name), "\"", "\"\"")}")
end
