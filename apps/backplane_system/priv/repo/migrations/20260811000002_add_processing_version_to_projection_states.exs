defmodule Backplane.Repo.Migrations.AddProcessingVersionToProjectionStates do
  use Ecto.Migration

  @legacy_version "legacy-v0"

  def up do
    alter table(:bpm_projection_states) do
      add(:processing_version, :text, null: false, default: @legacy_version)
    end

    alter table(:bpm_projection_states) do
      modify(:processing_version, :text, null: false, default: nil)
    end
  end

  def down do
    alter table(:bpm_projection_states) do
      remove(:processing_version)
    end
  end
end
