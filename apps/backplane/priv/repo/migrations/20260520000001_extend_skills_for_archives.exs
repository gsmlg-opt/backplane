defmodule Backplane.Repo.Migrations.ExtendSkillsForArchives do
  use Ecto.Migration

  def up do
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

    flush()

    execute("""
    UPDATE skills
    SET slug =
      trim(both '-' from regexp_replace(lower(coalesce(nullif(name, ''), id)), '[^a-z0-9]+', '-', 'g'))
      || '-' || substr(md5(id), 1, 8)
    WHERE slug IS NULL
    """)

    alter table(:skills) do
      modify :slug, :text, null: false
    end

    create unique_index(:skills, [:slug])
  end

  def down do
    drop index(:skills, [:slug])

    alter table(:skills) do
      remove :source_rev
      remove :source_uri
      remove :source_kind
      remove :file_count
      remove :size_bytes
      remove :archive_ref
      remove :meta
      remove :author
      remove :homepage
      remove :license
      remove :version
      remove :slug
    end
  end
end
