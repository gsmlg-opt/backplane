defmodule Backplane.Repo.Migrations.CreateMemoryRecords do
  use Ecto.Migration

  def up do
    create table(:memory_records, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :kind, :text, null: false
      add :title, :text
      add :content, :text, null: false
      add :subjects, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :subject_keys, {:array, :text}, null: false, default: []
      add :property, :text
      add :tags, {:array, :text}, default: []
      add :confidence, :float
      add :status, :text, null: false, default: "active"
      add :superseded_by, references(:memory_records, type: :binary_id, on_delete: :nilify_all)
      add :forgotten_reason, :text
      add :forgotten_at, :utc_datetime_usec
      add :writer, :text, null: false
      add :host_id, :text
      add :agent_id, :text
      add :integration, :text
      add :session_id, :text
      add :client_id, :text
      add :source_event_ids, {:array, :binary_id}, default: []
      add :request_key, :text
      add :observed_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:memory_records, :memory_records_kind_check,
             check: "kind IN ('fact','procedure','worklog','note')"
           )

    create constraint(:memory_records, :memory_records_status_check,
             check: "status IN ('active','superseded','forgotten')"
           )

    create constraint(:memory_records, :memory_records_writer_check,
             check: "writer IN ('agent','memory_agent','user','host_collector')"
           )

    # array_to_string is only STABLE; generated columns need an IMMUTABLE wrapper.
    p = quoted_prefix()

    execute """
    CREATE FUNCTION #{quoted_prefix()}.memory_records_immutable_join(text[]) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$ SELECT array_to_string($1, ' ') $$
    """

    execute """
    ALTER TABLE #{p}.memory_records ADD COLUMN search_tsv tsvector
    GENERATED ALWAYS AS (
      to_tsvector('simple',
        coalesce(title, '') || ' ' || content || ' ' || coalesce(#{p}.memory_records_immutable_join(subject_keys), ''))
    ) STORED
    """

    create index(:memory_records, [:search_tsv], using: :gin)
    create index(:memory_records, [:subject_keys], using: :gin)
    create index(:memory_records, [:status, "observed_at DESC"])
    create index(:memory_records, [:kind, :status])
    create index(:memory_records, [:host_id])
    create index(:memory_records, [:agent_id])
    create unique_index(:memory_records, [:request_key], where: "request_key IS NOT NULL")
  end

  def down do
    drop table(:memory_records)
    execute "DROP FUNCTION #{quoted_prefix()}.memory_records_immutable_join(text[])"
  end

  defp quoted_prefix, do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}")
end
