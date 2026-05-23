defmodule Backplane.Repo.Migrations.AddBpmMemoriesDedupIndex do
  use Ecto.Migration

  def up do
    execute(
      "CREATE UNIQUE INDEX bpm_memories_dedup_uniq ON bpm_memories (content_hash, scope) WHERE deleted_at IS NULL",
      "DROP INDEX IF EXISTS bpm_memories_dedup_uniq"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS bpm_memories_dedup_uniq")
  end
end
