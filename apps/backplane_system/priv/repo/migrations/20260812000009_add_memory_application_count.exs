defmodule Backplane.Repo.Migrations.AddMemoryApplicationCount do
  use Ecto.Migration

  def up do
    alter table(:bpm_memories) do
      add(:application_count, :integer, null: false, default: 0)
    end

    create(
      constraint(:bpm_memories, :bpm_memories_application_count_nonnegative,
        check: "application_count >= 0"
      )
    )
  end

  def down do
    drop_if_exists(constraint(:bpm_memories, :bpm_memories_application_count_nonnegative))

    alter table(:bpm_memories) do
      remove(:application_count)
    end
  end
end
