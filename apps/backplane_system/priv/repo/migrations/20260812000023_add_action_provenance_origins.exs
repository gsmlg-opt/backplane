defmodule Backplane.Repo.Migrations.AddActionProvenanceOrigins do
  use Ecto.Migration

  def change do
    alter table(:memory_actions, prefix: prefix()) do
      add(:source_session_ids, {:array, :text}, null: false, default: [])
      add(:source_lesson_ids, {:array, :binary_id}, null: false, default: [])
      add(:source_crystal_ids, {:array, :binary_id}, null: false, default: [])
    end
  end
end
