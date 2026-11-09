defmodule Backplane.HostAgent.Memory.Migrations.V8 do
  @moduledoc """
  Replaces the legacy host memory schema (V1-V7) with local records, a
  remember/forget outbox and a small sync-state table. Legacy data is dropped.
  """
  def version, do: 8

  @legacy_tables ~w(
    memories memories_v4 facts memory_outbox memory_outbox_v1 memory_outbox_v6
    memory_outbox_sequence_v2 memory_outbox_sequence_v6 tombstones tombstones_v1 slots
    canonical_memory_receipts memory_access_global memory_access_state memory_request_keys
  )

  def up do
    Enum.map(@legacy_tables, &"DROP TABLE IF EXISTS #{&1}") ++
      [
        """
        CREATE TABLE local_records (
          local_id TEXT PRIMARY KEY,
          remote_id TEXT UNIQUE,
          request_key TEXT UNIQUE,
          kind TEXT NOT NULL,
          title TEXT,
          content TEXT NOT NULL,
          subjects TEXT NOT NULL DEFAULT '[]',
          property TEXT,
          tags TEXT NOT NULL DEFAULT '[]',
          status TEXT NOT NULL DEFAULT 'active',
          superseded_by TEXT,
          forgotten_reason TEXT,
          writer TEXT NOT NULL,
          agent_id TEXT,
          integration TEXT,
          session_id TEXT,
          observed_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          sync_state TEXT NOT NULL CHECK (sync_state IN ('pending', 'synced', 'failed'))
        )
        """,
        "CREATE INDEX local_records_status_observed_idx ON local_records(status, observed_at)",
        "CREATE INDEX local_records_kind_status_idx ON local_records(kind, status)",
        """
        CREATE TABLE memory_outbox (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          op TEXT NOT NULL CHECK (op IN ('remember', 'forget')),
          local_id TEXT NOT NULL,
          payload TEXT NOT NULL,
          state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'failed')),
          attempts INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          inserted_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
        """,
        "CREATE TABLE memory_sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
      ]
  end
end
