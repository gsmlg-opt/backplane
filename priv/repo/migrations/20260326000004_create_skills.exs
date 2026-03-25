defmodule Backplane.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add :id, :text, primary_key: true
      add :name, :text, null: false
      add :description, :text, null: false, default: ""
      add :tags, {:array, :text}, null: false, default: []
      add :tools, {:array, :text}, null: false, default: []
      add :model, :text
      add :version, :text, null: false, default: "1.0.0"
      add :content, :text, null: false
      add :content_hash, :text, null: false
      add :source, :text, null: false
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skills, [:source])
    create index(:skills, [:tags], using: :gin)

    execute(
      """
      ALTER TABLE skills ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (
        setweight(to_tsvector('english', name), 'A') ||
        setweight(to_tsvector('english', description), 'A') ||
        setweight(to_tsvector('english', content), 'B')
      ) STORED
      """,
      "ALTER TABLE skills DROP COLUMN search_vector"
    )

    create index(:skills, [:search_vector], using: :gin, name: :idx_skills_search)
  end
end
