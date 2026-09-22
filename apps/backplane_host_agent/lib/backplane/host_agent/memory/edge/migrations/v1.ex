defmodule Backplane.HostAgent.Memory.Edge.Migrations.V1 do
  @moduledoc false
  def version, do: 1

  def up do
    [
      """
      CREATE TABLE edge_partitions (
        memory_space_id TEXT NOT NULL, scope TEXT NOT NULL, namespace TEXT NOT NULL,
        applied_revision INTEGER NOT NULL DEFAULT 0,
        active_generation TEXT NOT NULL DEFAULT '0',
        last_batch_id TEXT, last_sync_at TEXT,
        snapshot_id TEXT, snapshot_revision INTEGER, next_chunk_index INTEGER,
        chunk_count INTEGER, integrity_hash TEXT,
        PRIMARY KEY (memory_space_id, scope, namespace)
      )
      """,
      """
      CREATE TABLE edge_memories (
        memory_space_id TEXT NOT NULL, scope TEXT NOT NULL, namespace TEXT NOT NULL,
        generation TEXT NOT NULL, canonical_id TEXT NOT NULL,
        memory_type TEXT, content TEXT, content_hash TEXT, confidence REAL,
        lifecycle_state TEXT NOT NULL,
        tags TEXT, metadata TEXT, source_refs TEXT,
        server_revision INTEGER NOT NULL, edge_priority REAL, edge_expires_at TEXT,
        updated_at TEXT, last_accessed_at TEXT, byte_size INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (memory_space_id, scope, namespace, generation, canonical_id)
      )
      """,
      """
      CREATE TABLE edge_snapshot_chunks (
        snapshot_id TEXT NOT NULL, chunk_index INTEGER NOT NULL,
        chunk_hash TEXT NOT NULL, applied_at TEXT NOT NULL,
        PRIMARY KEY (snapshot_id, chunk_index)
      )
      """
    ]
  end
end
