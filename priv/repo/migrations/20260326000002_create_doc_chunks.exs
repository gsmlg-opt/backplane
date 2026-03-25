defmodule Backplane.Repo.Migrations.CreateDocChunks do
  use Ecto.Migration

  def change do
    create table(:doc_chunks) do
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :source_path, :text, null: false
      add :module, :text
      add :function, :text
      add :chunk_type, :text, null: false
      add :content, :text, null: false
      add :content_hash, :text, null: false
      add :tokens, :integer

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:doc_chunks, [:project_id])
    create index(:doc_chunks, [:project_id, :content_hash])

    execute(
      """
      ALTER TABLE doc_chunks ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(module, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(function, '')), 'A') ||
        setweight(to_tsvector('english', content), 'B')
      ) STORED
      """,
      "ALTER TABLE doc_chunks DROP COLUMN search_vector"
    )

    create index(:doc_chunks, [:search_vector], using: :gin, name: :idx_doc_chunks_search)
  end
end
