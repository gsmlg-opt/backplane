defmodule Backplane.Repo.Migrations.CreateMemoryProfiles do
  use Ecto.Migration

  def change do
    create table(:memory_profiles, primary_key: false) do
      add(:project, :text, primary_key: true)
      add(:top_concepts, :map, null: false, default: %{})
      add(:top_files, :map, null: false, default: %{})
      add(:patterns, :map, null: false, default: %{})
      add(:session_count, :integer, null: false, default: 0)
      add(:total_observations, :integer, null: false, default: 0)
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end
  end
end
