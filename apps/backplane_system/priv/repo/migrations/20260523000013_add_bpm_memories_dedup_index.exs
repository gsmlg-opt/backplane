defmodule Backplane.Repo.Migrations.AddBpmMemoriesDedupIndex do
  use Ecto.Migration

  def up do
    execute(
      "CREATE UNIQUE INDEX bpm_memories_dedup_uniq ON #{qualified("bpm_memories")} (content_hash, scope) WHERE deleted_at IS NULL",
      "DROP INDEX IF EXISTS #{qualified("bpm_memories_dedup_uniq")}"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS #{qualified("bpm_memories_dedup_uniq")}")
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end
end
