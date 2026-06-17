defmodule Backplane.HostAgent.Memory.Migrations.V1 do
  @moduledoc false

  def version, do: 1

  def up do
    [
      """
      CREATE TABLE IF NOT EXISTS memories (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        memory_type TEXT NOT NULL DEFAULT 'episodic'
          CHECK (memory_type = 'episodic'),
        scope TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        session_id TEXT,
        tags TEXT NOT NULL DEFAULT '[]',
        metadata TEXT NOT NULL DEFAULT '{}',
        confidence REAL NOT NULL DEFAULT 1.0,
        sync_state TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_state IN ('pending', 'synced', 'failed')),
        remote_id TEXT,
        synced_at TEXT,
        deleted_at TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      """
      CREATE UNIQUE INDEX IF NOT EXISTS memories_content_scope_live_uniq
        ON memories(content_hash, scope)
        WHERE deleted_at IS NULL
      """,
      "CREATE INDEX IF NOT EXISTS memories_scope_inserted_idx ON memories(scope, inserted_at)",
      "CREATE INDEX IF NOT EXISTS memories_sync_state_idx ON memories(sync_state)",
      "CREATE INDEX IF NOT EXISTS memories_deleted_idx ON memories(deleted_at)",
      """
      CREATE TABLE IF NOT EXISTS facts (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        scope TEXT NOT NULL,
        tags TEXT NOT NULL DEFAULT '[]',
        metadata TEXT NOT NULL DEFAULT '{}',
        updated_at TEXT NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS facts_scope_updated_idx ON facts(scope, updated_at)",
      """
      CREATE TABLE IF NOT EXISTS memory_outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        op TEXT NOT NULL CHECK (op IN ('remember', 'forget')),
        memory_id TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending'
          CHECK (state IN ('pending', 'inflight', 'done', 'failed')),
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS memory_outbox_state_seq_idx ON memory_outbox(state, seq)",
      "CREATE INDEX IF NOT EXISTS memory_outbox_memory_id_idx ON memory_outbox(memory_id)",
      """
      CREATE TABLE IF NOT EXISTS tombstones (
        content_hash TEXT PRIMARY KEY,
        scope TEXT NOT NULL,
        wiped_at TEXT NOT NULL,
        directive_id TEXT NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS slots (
        scope TEXT NOT NULL,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (scope, key)
      )
      """
    ]
  end
end
