defmodule Backplane.Repo.Migrations.AddBpmMemoriesNamespace do
  use Ecto.Migration

  def change do
    alter table(:bpm_memories) do
      add(:namespace, :text, null: false, default: "private")
    end

    create(index(:bpm_memories, [:namespace]))
  end
end
