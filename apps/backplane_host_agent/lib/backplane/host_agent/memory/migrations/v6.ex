defmodule Backplane.HostAgent.Memory.Migrations.V6 do
  @moduledoc false
  def version, do: 6

  def up do
    [
      "CREATE TABLE memory_outbox_sequence_v6 (seq INTEGER NOT NULL)",
      "INSERT INTO memory_outbox_sequence_v6 SELECT seq FROM sqlite_sequence WHERE name='memory_outbox'",
      """
      CREATE TABLE memory_outbox_v6 (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        op TEXT NOT NULL CHECK (op IN ('remember','forget','source_mutate','source_reconcile')),
        memory_id TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending', 'inflight', 'retry_wait', 'done', 'dead_letter')),
        attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at TEXT, last_error TEXT,
        completed_at TEXT, dead_lettered_at TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        payload TEXT, ack_partition TEXT, ack_canonical_id TEXT,
        ack_revision INTEGER CHECK (ack_revision IS NULL OR ack_revision > 0),
        command_id TEXT, access_id TEXT, authority_version INTEGER, target_partition TEXT,
        payload_digest TEXT, request_key TEXT, request_agent_id TEXT, ack_result TEXT
      )
      """,
      "INSERT INTO memory_outbox_v6 SELECT *,NULL FROM memory_outbox",
      "DROP TABLE memory_outbox",
      "ALTER TABLE memory_outbox_v6 RENAME TO memory_outbox",
      "DELETE FROM sqlite_sequence WHERE name IN ('memory_outbox','memory_outbox_v6')",
      """
      INSERT INTO sqlite_sequence(name,seq) SELECT 'memory_outbox',
        MAX(COALESCE((SELECT seq FROM memory_outbox_sequence_v6),0),COALESCE((SELECT MAX(seq) FROM memory_outbox),0))
      """,
      "DROP TABLE memory_outbox_sequence_v6",
      "CREATE INDEX memory_outbox_due_seq_idx ON memory_outbox(state,next_attempt_at,seq)",
      "CREATE INDEX memory_outbox_retention_idx ON memory_outbox(state,completed_at,dead_lettered_at,seq)",
      "CREATE INDEX memory_outbox_memory_id_idx ON memory_outbox(memory_id)",
      "CREATE UNIQUE INDEX memory_shared_command_id ON memory_outbox(command_id) WHERE access_id IS NOT NULL",
      "CREATE UNIQUE INDEX memory_shared_request_key ON memory_outbox(request_agent_id,access_id,op,request_key) WHERE access_id IS NOT NULL AND request_key IS NOT NULL",
      """
      CREATE TRIGGER memory_shared_command_identity BEFORE UPDATE OF command_id,access_id,authority_version,target_partition,payload_digest,payload,op,request_key,request_agent_id ON memory_outbox
      WHEN OLD.access_id IS NOT NULL AND (
        NEW.command_id IS NOT OLD.command_id OR NEW.access_id IS NOT OLD.access_id OR
        NEW.authority_version IS NOT OLD.authority_version OR NEW.target_partition IS NOT OLD.target_partition OR
        NEW.payload_digest IS NOT OLD.payload_digest OR NEW.payload IS NOT OLD.payload OR NEW.op IS NOT OLD.op OR
        NEW.request_key IS NOT OLD.request_key OR NEW.request_agent_id IS NOT OLD.request_agent_id)
      BEGIN SELECT RAISE(ABORT,'immutable shared command identity'); END
      """
    ]
  end
end
