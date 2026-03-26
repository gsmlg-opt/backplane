defmodule Backplane.Repo.Migrations.AddTagsToSkillsSearchVector do
  use Ecto.Migration

  def up do
    # Create an immutable helper to convert text[] to text for use in
    # generated columns. PostgreSQL's built-in array_to_string and casts
    # are STABLE, not IMMUTABLE, so we need this wrapper.
    execute("""
    CREATE OR REPLACE FUNCTION immutable_array_to_text(arr text[])
    RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$ SELECT array_to_string(arr, ' ') $$
    """)

    # Drop the existing generated column and recreate with tags included.
    # Weight scheme: A=name+tags, B=description, C=content
    execute("DROP INDEX IF EXISTS idx_skills_search")
    execute("ALTER TABLE skills DROP COLUMN search_vector")

    execute("""
    ALTER TABLE skills ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('english', name), 'A') ||
      setweight(to_tsvector('english', coalesce(immutable_array_to_text(tags), '')), 'A') ||
      setweight(to_tsvector('english', description), 'B') ||
      setweight(to_tsvector('english', content), 'C')
    ) STORED
    """)

    create index(:skills, [:search_vector], using: :gin, name: :idx_skills_search)
  end

  def down do
    execute("DROP INDEX IF EXISTS idx_skills_search")
    execute("ALTER TABLE skills DROP COLUMN search_vector")

    execute("""
    ALTER TABLE skills ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('english', name), 'A') ||
      setweight(to_tsvector('english', description), 'A') ||
      setweight(to_tsvector('english', content), 'B')
    ) STORED
    """)

    create index(:skills, [:search_vector], using: :gin, name: :idx_skills_search)

    execute("DROP FUNCTION IF EXISTS immutable_array_to_text(text[])")
  end
end
