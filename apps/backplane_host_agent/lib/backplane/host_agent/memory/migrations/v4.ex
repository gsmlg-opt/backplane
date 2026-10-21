defmodule Backplane.HostAgent.Memory.Migrations.V4 do
  @moduledoc false

  def version, do: 4

  def up do
    [
      """
      CREATE TABLE memories_v4 (
        id TEXT PRIMARY KEY, content TEXT NOT NULL, content_hash TEXT NOT NULL,
        memory_type TEXT NOT NULL DEFAULT 'episodic'
          CHECK (memory_type IN ('working', 'episodic', 'semantic', 'procedural')),
        scope TEXT NOT NULL, agent_id TEXT NOT NULL, session_id TEXT,
        tags TEXT NOT NULL DEFAULT '[]', metadata TEXT NOT NULL DEFAULT '{}',
        confidence REAL NOT NULL DEFAULT 1.0,
        sync_state TEXT NOT NULL DEFAULT 'pending' CHECK (sync_state IN ('pending', 'synced', 'failed')),
        remote_id TEXT, synced_at TEXT, deleted_at TEXT,
        inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        remote_revision INTEGER CHECK (remote_revision IS NULL OR remote_revision > 0)
      )
      """,
      "INSERT INTO memories_v4 SELECT * FROM memories",
      "DROP TABLE memories",
      "ALTER TABLE memories_v4 RENAME TO memories",
      "CREATE UNIQUE INDEX memories_content_scope_live_uniq ON memories(content_hash, scope, memory_type, agent_id) WHERE deleted_at IS NULL",
      "CREATE INDEX memories_scope_inserted_idx ON memories(scope, inserted_at)",
      "CREATE INDEX memories_sync_state_idx ON memories(sync_state)",
      "CREATE INDEX memories_deleted_idx ON memories(deleted_at)",
      "ALTER TABLE memories ADD COLUMN facets TEXT NOT NULL DEFAULT '[]'",
      "ALTER TABLE memories ADD COLUMN memory_space_id TEXT",
      "ALTER TABLE memories ADD COLUMN namespace TEXT",
      "ALTER TABLE memory_outbox ADD COLUMN payload TEXT",
      "ALTER TABLE memory_outbox ADD COLUMN ack_partition TEXT",
      "ALTER TABLE memory_outbox ADD COLUMN ack_canonical_id TEXT",
      "ALTER TABLE memory_outbox ADD COLUMN ack_revision INTEGER CHECK (ack_revision IS NULL OR ack_revision > 0)",
      """
      CREATE TABLE memory_request_keys (
        agent_id TEXT NOT NULL, scope TEXT NOT NULL, idempotency_key TEXT NOT NULL,
        request_hash TEXT NOT NULL, memory_id TEXT NOT NULL,
        PRIMARY KEY (agent_id, scope, idempotency_key)
      )
      """,
      """
      CREATE TABLE canonical_memory_receipts (
        canonical_id TEXT NOT NULL, memory_space_id TEXT NOT NULL, scope TEXT NOT NULL,
        namespace TEXT NOT NULL, agent_id TEXT NOT NULL, received_at TEXT NOT NULL,
        PRIMARY KEY (canonical_id, memory_space_id, scope, namespace, agent_id)
      )
      """
    ]
  end
end
