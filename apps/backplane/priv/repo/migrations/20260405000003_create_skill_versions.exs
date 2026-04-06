defmodule Backplane.Repo.Migrations.CreateSkillVersions do
  use Ecto.Migration

  def change do
    create table(:skill_versions) do
      add(:skill_id, references(:skills, type: :string, on_delete: :delete_all), null: false)
      add(:version, :integer, null: false)
      add(:content_hash, :text, null: false)
      add(:content, :text, null: false)
      add(:metadata, :map, default: %{})
      add(:author, :text)
      add(:change_summary, :text)

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(unique_index(:skill_versions, [:skill_id, :version]))
    create(index(:skill_versions, [:skill_id]))
  end
end
