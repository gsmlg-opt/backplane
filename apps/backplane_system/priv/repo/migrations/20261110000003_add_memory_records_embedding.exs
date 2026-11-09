defmodule Backplane.Repo.Migrations.AddMemoryRecordsEmbedding do
  use Ecto.Migration

  # No ANN index: pgvector HNSW/IVFFlat cap `vector` at 2000 dimensions and
  # single-user volume makes an exact scan acceptable.
  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"
    execute "ALTER TABLE #{quoted_prefix()}.memory_records ADD COLUMN embedding vector(2560)"
  end

  def down do
    execute "ALTER TABLE #{quoted_prefix()}.memory_records DROP COLUMN embedding"
  end

  defp quoted_prefix, do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}")
end
