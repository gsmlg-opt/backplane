defmodule Backplane.Repo.Migrations.MemoryRecordsSearchSubjectKeys do
  use Ecto.Migration

  # Rebuilds `memory_records.search_tsv` so subjects contribute only their keys
  # (`service:billing` → `billing`), not their type prefix; otherwise a query word
  # like "service" matches every `service:*` record.
  def up do
    p = quoted_prefix()

    execute("""
    CREATE FUNCTION #{p}.memory_records_subject_text(text[]) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$ SELECT coalesce(string_agg(substr(k, strpos(k, ':') + 1), ' '), '') FROM unnest($1) AS k $$
    """)

    execute("ALTER TABLE #{p}.memory_records DROP COLUMN search_tsv")

    execute("""
    ALTER TABLE #{p}.memory_records ADD COLUMN search_tsv tsvector
    GENERATED ALWAYS AS (
      to_tsvector('simple',
        coalesce(title, '') || ' ' || content || ' ' || #{p}.memory_records_subject_text(subject_keys))
    ) STORED
    """)

    create(index(:memory_records, [:search_tsv], using: :gin))
  end

  def down do
    p = quoted_prefix()

    execute("ALTER TABLE #{p}.memory_records DROP COLUMN search_tsv")

    execute("""
    ALTER TABLE #{p}.memory_records ADD COLUMN search_tsv tsvector
    GENERATED ALWAYS AS (
      to_tsvector('simple',
        coalesce(title, '') || ' ' || content || ' ' || coalesce(#{p}.memory_records_immutable_join(subject_keys), ''))
    ) STORED
    """)

    create(index(:memory_records, [:search_tsv], using: :gin))
    execute("DROP FUNCTION #{p}.memory_records_subject_text(text[])")
  end

  defp quoted_prefix, do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}")
end
