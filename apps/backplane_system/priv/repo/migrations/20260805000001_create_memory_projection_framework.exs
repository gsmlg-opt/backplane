defmodule Backplane.Repo.Migrations.CreateMemoryProjectionFramework do
  use Ecto.Migration

  @statuses ~w(pending running complete skipped failed dead_letter)

  def up do
    create table(:bpm_projection_states, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:projector, :text, null: false)
      add(:subject_type, :text, null: false)
      add(:subject_id, :text, null: false)
      add(:input_revision, :text)
      add(:output_revision, :text)
      add(:status, :text, null: false, default: "pending")
      add(:attempt_count, :integer, null: false, default: 0)
      add(:last_error, :text)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:bpm_projection_states, [:projector, :subject_type, :subject_id],
        name: :bpm_projection_states_subject_uniq
      )
    )

    create(index(:bpm_projection_states, [:status, :updated_at]))

    create(
      constraint(:bpm_projection_states, :bpm_projection_states_status_check,
        check: "status IN (#{quoted_statuses()})"
      )
    )

    create(
      constraint(:bpm_projection_states, :bpm_projection_states_attempt_count_check,
        check: "attempt_count >= 0"
      )
    )

    create table(:bpm_projection_snapshots, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:projector, :text, null: false)
      add(:subject_type, :text, null: false)
      add(:subject_id, :text, null: false)
      add(:input_revision, :text, null: false)
      add(:output_revision, :text, null: false)
      add(:read_model, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:bpm_projection_snapshots, [:projector, :subject_type, :subject_id],
        name: :bpm_projection_snapshots_subject_uniq
      )
    )

    execute("""
    CREATE FUNCTION #{qualified("bpm_reject_captured_event_mutation")}()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.schema_version IS NOT NULL THEN
        RAISE EXCEPTION 'captured memory events are immutable'
          USING ERRCODE = '55000';
      END IF;

      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER bpm_events_captured_immutable
    BEFORE UPDATE OR DELETE ON #{qualified("bpm_events")}
    FOR EACH ROW
    EXECUTE FUNCTION #{qualified("bpm_reject_captured_event_mutation")}()
    """)

    execute("""
    CREATE FUNCTION #{qualified("bpm_reject_captured_event_truncate")}()
    RETURNS trigger AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("bpm_events")} WHERE schema_version IS NOT NULL) THEN
        RAISE EXCEPTION 'captured memory events are immutable'
          USING ERRCODE = '55000';
      END IF;

      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER bpm_events_captured_truncate_immutable
    BEFORE TRUNCATE ON #{qualified("bpm_events")}
    FOR EACH STATEMENT
    EXECUTE FUNCTION #{qualified("bpm_reject_captured_event_truncate")}()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS bpm_events_captured_truncate_immutable ON #{qualified("bpm_events")}"
    )

    execute("DROP FUNCTION IF EXISTS #{qualified("bpm_reject_captured_event_truncate")}()")
    execute("DROP TRIGGER IF EXISTS bpm_events_captured_immutable ON #{qualified("bpm_events")}")
    execute("DROP FUNCTION IF EXISTS #{qualified("bpm_reject_captured_event_mutation")}()")
    drop(table(:bpm_projection_snapshots))
    drop(table(:bpm_projection_states))
  end

  defp quoted_statuses do
    Enum.map_join(@statuses, ", ", &"'#{&1}'")
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end
end
