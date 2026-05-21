defmodule Backplane.Repo.Migrations.ExtendSkillsForArchives do
  use Ecto.Migration

  def change do
    alter table(:skills) do
      add :slug, :text
      add :version, :text
      add :license, :text
      add :homepage, :text
      add :author, :text
      add :meta, :map, null: false, default: %{}
      add :archive_ref, :text
      add :size_bytes, :bigint
      add :file_count, :integer
      add :source_kind, :text
      add :source_uri, :text
      add :source_rev, :text
    end

    execute("""
    UPDATE skills
    SET slug =
      trim(both '-' from regexp_replace(lower(coalesce(nullif(name, ''), id)), '[^a-z0-9]+', '-', 'g'))
      || '-' || substr(md5(id), 1, 8)
    WHERE slug IS NULL
    """)

    create unique_index(:skills, [:slug])

    execute(
      "ALTER TABLE skills ALTER COLUMN slug SET NOT NULL",
      "ALTER TABLE skills ALTER COLUMN slug DROP NOT NULL"
    )
  end
end
