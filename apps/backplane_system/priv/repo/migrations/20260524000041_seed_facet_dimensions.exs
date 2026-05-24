defmodule Backplane.Repo.Migrations.SeedFacetDimensions do
  use Ecto.Migration

  def up do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    dimensions = [
      {"language", "Programming language (e.g. elixir, python, typescript)"},
      {"framework", "Framework or library (e.g. phoenix, react, django)"},
      {"project", "Project or repository name"},
      {"environment", "Runtime environment (e.g. dev, staging, production)"},
      {"team", "Team or squad identifier"},
      {"type", "Memory classification (e.g. bug, decision, pattern, learning)"}
    ]

    Enum.each(dimensions, fn {name, desc} ->
      execute("""
      INSERT INTO memory_facet_dimensions (name, description, created_at)
      VALUES ('#{name}', '#{desc}', '#{now}')
      ON CONFLICT (name) DO NOTHING
      """)
    end)
  end

  def down do
    execute(
      "DELETE FROM memory_facet_dimensions WHERE name IN ('language','framework','project','environment','team','type')"
    )
  end
end
