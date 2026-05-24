defmodule Backplane.Repo.Migrations.CreateBpmMemories do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vector")

    create table(:bpm_memories, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:content, :text, null: false)
      add(:memory_type, :text, null: false, default: "semantic")
      add(:scope, :text, null: false, default: "global")
      add(:agent_id, :text, null: false)
      add(:host_id, :text, null: false)
      add(:client_id, :text)
      add(:session_id, :text)
      add(:tags, {:array, :text}, null: false, default: [])
      add(:metadata, :map, null: false, default: %{})
      add(:embedding_model, :text, default: "Qwen/Qwen3-Embedding-4B")
      add(:content_hash, :binary, null: false)
      add(:confidence, :float, null: false, default: 1.0)
      add(:access_count, :integer, null: false, default: 0)
      add(:accessed_at, :utc_datetime_usec)
      add(:superseded_by, :binary_id)
      add(:expires_at, :utc_datetime_usec)
      add(:deleted_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    # halfvec(2560) — added via raw SQL; pgvector >= 0.7 required
    execute(
      "ALTER TABLE bpm_memories ADD COLUMN embedding halfvec(2560)",
      "ALTER TABLE bpm_memories DROP COLUMN IF EXISTS embedding"
    )

    # generated tsvector for FTS (Postgres 12+)
    execute(
      """
      ALTER TABLE bpm_memories
        ADD COLUMN search_tsv tsvector
        GENERATED ALWAYS AS (to_tsvector('english', coalesce(content, ''))) STORED
      """,
      "ALTER TABLE bpm_memories DROP COLUMN IF EXISTS search_tsv"
    )

    create(
      constraint(:bpm_memories, :bpm_memories_memory_type_check,
        check: "memory_type IN ('working', 'episodic', 'semantic', 'procedural')"
      )
    )

    # HNSW index for halfvec cosine similarity
    execute(
      "CREATE INDEX bpm_memories_embedding_hnsw_idx ON bpm_memories USING hnsw (embedding halfvec_cosine_ops) WHERE embedding IS NOT NULL",
      "DROP INDEX IF EXISTS bpm_memories_embedding_hnsw_idx"
    )

    create(
      index(:bpm_memories, [:search_tsv], using: :gin, name: :bpm_memories_search_tsv_gin_idx)
    )

    create(index(:bpm_memories, [:tags], using: :gin, name: :bpm_memories_tags_gin_idx))
    create(index(:bpm_memories, [:scope, :memory_type]))
    create(index(:bpm_memories, [:session_id]))
    create(index(:bpm_memories, [:content_hash]))
    create(index(:bpm_memories, [:agent_id]))
    create(index(:bpm_memories, [:client_id]))
    create(index(:bpm_memories, [:deleted_at]))
  end

  def down do
    drop_if_exists(table(:bpm_memories))
  end
end
