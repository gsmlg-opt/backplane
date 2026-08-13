defmodule Backplane.Repo.Migrations.CompleteMemoryProfileProjection do
  use Ecto.Migration

  def change do
    alter table(:memory_profiles, prefix: prefix()) do
      add(:active_lessons, :map, null: false, default: %{})
      add(:recent_crystals, :map, null: false, default: %{})
      add(:recent_summaries, :map, null: false, default: %{})
      add(:source_records, :map, null: false, default: %{})
      add(:summary, :text, null: false, default: "")
    end
  end
end
