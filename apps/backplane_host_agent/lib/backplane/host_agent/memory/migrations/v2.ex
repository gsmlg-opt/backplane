defmodule Backplane.HostAgent.Memory.Migrations.V2 do
  @moduledoc false

  def version, do: 2

  def up do
    [
      "DROP INDEX IF EXISTS memory_outbox_state_seq_idx",
      "DROP INDEX IF EXISTS memory_outbox_memory_id_idx",
      "ALTER TABLE tombstones RENAME TO tombstones_v1",
      """
      CREATE TABLE tombstones (
        content_hash TEXT NOT NULL,
        scope TEXT NOT NULL,
        wiped_at TEXT NOT NULL,
        directive_id TEXT NOT NULL,
        PRIMARY KEY (scope, content_hash)
      )
      """,
      """
      INSERT INTO tombstones(content_hash, scope, wiped_at, directive_id)
      SELECT content_hash, scope, wiped_at, directive_id FROM tombstones_v1
      """,
      "DROP TABLE tombstones_v1",
      "CREATE TABLE memory_outbox_sequence_v2 (seq INTEGER NOT NULL)",
      """
      INSERT INTO memory_outbox_sequence_v2(seq)
      SELECT seq FROM sqlite_sequence WHERE name = 'memory_outbox'
      """,
      "ALTER TABLE memory_outbox RENAME TO memory_outbox_v1",
      """
      CREATE TABLE memory_outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        op TEXT NOT NULL CHECK (op IN ('remember', 'forget')),
        memory_id TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending'
          CHECK (state IN ('pending', 'inflight', 'retry_wait', 'done', 'dead_letter')),
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at TEXT,
        last_error TEXT,
        completed_at TEXT,
        dead_lettered_at TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      """
      INSERT INTO memory_outbox(
        seq, op, memory_id, state, attempts, next_attempt_at, last_error,
        completed_at, dead_lettered_at, inserted_at, updated_at
      )
      SELECT
        seq,
        op,
        memory_id,
        CASE state
          WHEN 'failed' THEN 'dead_letter'
          ELSE state
        END,
        attempts,
        NULL,
        last_error,
        CASE WHEN state = 'done' THEN updated_at ELSE NULL END,
        CASE WHEN state = 'failed' THEN updated_at ELSE NULL END,
        inserted_at,
        updated_at
      FROM memory_outbox_v1
      """,
      "DROP TABLE memory_outbox_v1",
      "DELETE FROM sqlite_sequence WHERE name IN ('memory_outbox', 'memory_outbox_v1')",
      """
      INSERT INTO sqlite_sequence(name, seq)
      SELECT
        'memory_outbox',
        MAX(
          COALESCE((SELECT seq FROM memory_outbox_sequence_v2), 0),
          COALESCE((SELECT MAX(seq) FROM memory_outbox), 0)
        )
      """,
      "DROP TABLE memory_outbox_sequence_v2",
      "CREATE INDEX memory_outbox_due_seq_idx ON memory_outbox(state, next_attempt_at, seq)",
      "CREATE INDEX memory_outbox_retention_idx ON memory_outbox(state, completed_at, dead_lettered_at, seq)",
      "CREATE INDEX memory_outbox_memory_id_idx ON memory_outbox(memory_id)"
    ]
  end
end
