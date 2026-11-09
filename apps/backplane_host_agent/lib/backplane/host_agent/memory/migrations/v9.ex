defmodule Backplane.HostAgent.Memory.Migrations.V9 do
  @moduledoc """
  Keeps record provenance (host, client, source event ids) on local records and
  clears the pull cursor so the next sync re-pulls this host's records to fill it.
  """
  def version, do: 9

  def up do
    [
      "ALTER TABLE local_records ADD COLUMN host_id TEXT",
      "ALTER TABLE local_records ADD COLUMN client_id TEXT",
      "ALTER TABLE local_records ADD COLUMN source_event_ids TEXT NOT NULL DEFAULT '[]'",
      "DELETE FROM memory_sync_state WHERE key = 'pull_cursor'"
    ]
  end
end
