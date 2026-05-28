defmodule Backplane.Repo.Migrations.AddSelectedSkillsAndTagsToSkillSources do
  use Ecto.Migration

  def change do
    alter table(:skill_sources) do
      add :selected_skills, {:array, :text}, null: false, default: []
      add :sync_tags, {:array, :text}, null: false, default: []
    end
  end
end
