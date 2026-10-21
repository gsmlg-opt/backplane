defmodule Backplane.HostAgent.Memory.Migrations.V5 do
  @moduledoc false
  def version, do: 5

  def up do
    [
      """
      CREATE TABLE memory_access_state (
        access_id TEXT PRIMARY KEY, partition TEXT NOT NULL,
        authority_version INTEGER NOT NULL CHECK(authority_version > 0),
        status TEXT NOT NULL CHECK(status IN ('active','fenced','needs_sync')),
        capabilities TEXT NOT NULL, lease_seconds INTEGER NOT NULL CHECK(lease_seconds BETWEEN 0 AND 300),
        fence_reason TEXT, updated_at TEXT NOT NULL
      )
      """,
      "CREATE TABLE memory_access_global (id INTEGER PRIMARY KEY CHECK(id=1), fenced INTEGER NOT NULL DEFAULT 0, reason TEXT, updated_at TEXT NOT NULL)",
      "INSERT INTO memory_access_global(id, fenced, updated_at) VALUES (1, 0, datetime('now'))",
      "ALTER TABLE memory_outbox ADD COLUMN command_id TEXT",
      "ALTER TABLE memory_outbox ADD COLUMN access_id TEXT",
      "ALTER TABLE memory_outbox ADD COLUMN authority_version INTEGER",
      "ALTER TABLE memory_outbox ADD COLUMN target_partition TEXT",
      "ALTER TABLE memory_outbox ADD COLUMN payload_digest TEXT",
      "ALTER TABLE memory_outbox ADD COLUMN request_key TEXT",
      "ALTER TABLE memory_outbox ADD COLUMN request_agent_id TEXT",
      "CREATE UNIQUE INDEX memory_shared_command_id ON memory_outbox(command_id) WHERE access_id IS NOT NULL",
      "CREATE UNIQUE INDEX memory_shared_request_key ON memory_outbox(request_agent_id, access_id, op, request_key) WHERE access_id IS NOT NULL AND request_key IS NOT NULL",
      """
      CREATE TRIGGER memory_shared_command_identity BEFORE UPDATE OF command_id,access_id,authority_version,target_partition,payload_digest,payload,op,request_key,request_agent_id ON memory_outbox
      WHEN OLD.access_id IS NOT NULL AND (
        NEW.command_id IS NOT OLD.command_id OR NEW.access_id IS NOT OLD.access_id OR
        NEW.authority_version IS NOT OLD.authority_version OR NEW.target_partition IS NOT OLD.target_partition OR
        NEW.payload_digest IS NOT OLD.payload_digest OR NEW.payload IS NOT OLD.payload OR NEW.op IS NOT OLD.op OR
        NEW.request_key IS NOT OLD.request_key OR NEW.request_agent_id IS NOT OLD.request_agent_id)
      BEGIN SELECT RAISE(ABORT, 'immutable shared command identity'); END
      """,
      "ALTER TABLE canonical_memory_receipts ADD COLUMN access_id TEXT",
      "ALTER TABLE canonical_memory_receipts ADD COLUMN authority_version INTEGER"
    ]
  end
end
