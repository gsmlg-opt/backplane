defmodule Backplane.Repo.Migrations.AddEmbeddings do
  use Ecto.Migration

  # Read dimensions from embeddings config, default to 1536 (OpenAI compatible).
  # Ollama models with smaller dimensions (e.g. 768) fit within 1536.
  @default_dimensions 1536

  def up do
    if pgvector_available?() do
      dims = embedding_dimensions()

      execute("CREATE EXTENSION IF NOT EXISTS vector")

      alter table(:doc_chunks) do
        add(:embedding, :vector, size: dims)
      end

      alter table(:skills) do
        add(:embedding, :vector, size: dims)
      end

      execute("""
      CREATE INDEX idx_doc_chunks_embedding
      ON doc_chunks USING ivfflat (embedding vector_cosine_ops)
      WITH (lists = 100)
      """)

      execute("""
      CREATE INDEX idx_skills_embedding
      ON skills USING ivfflat (embedding vector_cosine_ops)
      WITH (lists = 50)
      """)
    else
      # pgvector not installed — skip. Embedding columns will be added
      # when pgvector is available and this migration is re-run.
      :ok
    end
  end

  def down do
    if column_exists?("doc_chunks", "embedding") do
      execute("DROP INDEX IF EXISTS idx_skills_embedding")
      execute("DROP INDEX IF EXISTS idx_doc_chunks_embedding")

      alter table(:skills) do
        remove(:embedding)
      end

      alter table(:doc_chunks) do
        remove(:embedding)
      end
    end
  end

  defp embedding_dimensions do
    case Application.get_env(:backplane, :embeddings) do
      %{dimensions: dims} when is_integer(dims) and dims > 0 -> dims
      _ -> @default_dimensions
    end
  end

  defp pgvector_available? do
    query = "SELECT 1 FROM pg_available_extensions WHERE name = 'vector'"

    case repo().query(query) do
      {:ok, %{num_rows: n}} when n > 0 -> true
      _ -> false
    end
  end

  defp column_exists?(table, column) do
    query = """
    SELECT 1 FROM information_schema.columns
    WHERE table_name = '#{table}' AND column_name = '#{column}'
    """

    case repo().query(query) do
      {:ok, %{num_rows: n}} when n > 0 -> true
      _ -> false
    end
  end
end
