defmodule Backplane.Repo.Migrations.CreateProjectedMemoryObservations do
  use Ecto.Migration

  def up do
    create table(:bpm_projected_observations, primary_key: false) do
      add(:event_id, :binary_id, primary_key: true)
      add(:subject_id, :text, null: false)
      add(:host_id, :text, null: false)
      add(:session_id, :text, null: false)
      add(:project, :text)
      add(:agent_id, :text)
      add(:source_sequence, :bigint)
      add(:event_type, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:tool_name, :text)
      add(:content, :text)
      add(:message, :text)
      add(:importance, :integer, null: false, default: 0)
      add(:is_error, :boolean, null: false, default: false)
      add(:file_paths, {:array, :text}, null: false, default: [])
      add(:commit_hash, :text)
      add(:processing_version, :text, null: false)
      add(:input_revision, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      index(:bpm_projected_observations, [:subject_id, :source_sequence, :event_id],
        name: :bpm_projected_observations_subject_sequence_idx
      )
    )

    create(
      index(:bpm_projected_observations, [:host_id, :session_id, :occurred_at, :event_id],
        name: :bpm_projected_observations_host_session_time_idx
      )
    )

    create(index(:bpm_projected_observations, [:occurred_at, :event_id]))
    create(index(:bpm_projected_observations, [:event_type, :occurred_at]))
    create(index(:bpm_projected_observations, [:project, :occurred_at]))
    create(index(:bpm_projected_observations, [:tool_name, :occurred_at]))
    create(index(:bpm_projected_observations, [:is_error, :occurred_at]))
    create(index(:bpm_projected_observations, [:importance, :occurred_at]))

    create(
      index(:bpm_projected_observations, [:file_paths],
        using: :gin,
        name: :bpm_projected_observations_file_paths_gin
      )
    )
  end

  def down do
    drop(table(:bpm_projected_observations))
  end
end
