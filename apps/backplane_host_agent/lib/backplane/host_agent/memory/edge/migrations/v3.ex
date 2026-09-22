defmodule Backplane.HostAgent.Memory.Edge.Migrations.V3 do
  @moduledoc false

  def version, do: 3

  def up do
    [
      "ALTER TABLE edge_partitions ADD COLUMN snapshot_received_items INTEGER NOT NULL DEFAULT 0",
      """
      DELETE FROM edge_memories
      WHERE EXISTS (
        SELECT 1 FROM edge_partitions p
        WHERE p.snapshot_id IS NOT NULL
          AND p.memory_space_id=edge_memories.memory_space_id
          AND p.scope=edge_memories.scope AND p.namespace=edge_memories.namespace
          AND p.snapshot_id=edge_memories.generation
      )
      """,
      "DELETE FROM edge_snapshot_chunks WHERE snapshot_id IN (SELECT snapshot_id FROM edge_partitions WHERE snapshot_id IS NOT NULL)",
      """
      UPDATE edge_partitions
      SET snapshot_id=NULL, snapshot_revision=NULL, next_chunk_index=NULL,
          chunk_count=NULL, integrity_hash=NULL, snapshot_received_items=0,
          last_batch_id=NULL, last_delivery_hash=NULL, sync_status='snapshot_required'
      WHERE snapshot_id IS NOT NULL
      """
    ]
  end
end
