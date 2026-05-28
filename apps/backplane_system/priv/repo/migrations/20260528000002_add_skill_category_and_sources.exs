defmodule Backplane.Repo.Migrations.AddSkillCategoryAndSources do
  use Ecto.Migration

  def change do
    # Add category column to skills
    alter table(:skills) do
      add :category, :text
    end

    create index(:skills, [:category])

    # Create upstream skill sources table
    create table(:skill_sources, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :source_type, :text, null: false, default: "github"
      add :url, :text, null: false
      add :branch, :text, default: "main"
      add :path_prefix, :text, default: "skills/"
      add :enabled, :boolean, default: true
      add :last_synced_at, :utc_datetime_usec
      add :last_sync_status, :text
      add :last_sync_error, :text
      add :sync_metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:skill_sources, [:url, :branch])
  end
end
