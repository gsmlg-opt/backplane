defmodule Backplane.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add :id, :text, primary_key: true
      add :name, :text, null: false
      add :description, :text, default: ""
      add :tags, {:array, :text}, default: []
      add :content, :text, null: false
      add :content_hash, :text
      add :enabled, :boolean, default: true

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "ALTER TABLE #{qualified("skills")} ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(name, '') || ' ' || coalesce(description, '') || ' ' || coalesce(content, ''))) STORED",
      "ALTER TABLE #{qualified("skills")} DROP COLUMN search_vector"
    )

    create index(:skills, [:tags], using: :gin)
    create index(:skills, [:search_vector], using: :gin)
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end
end
