defmodule Backplane.Repo.Migrations.IndexMemoryEvictionBatches do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:bpm_memories, [:inserted_at, :id],
        name: :bpm_memories_eviction_scan_idx,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:bpm_memories, [:inserted_at, :id],
        name: :bpm_memories_eviction_scan_idx,
        concurrently: true
      )
    )
  end
end
