defmodule Backplane.HostAgent.Memory.Migrations.V7 do
  @moduledoc "One-time retirement of unbound uploader rows without replaying ambiguous writes."
  def version, do: 7

  def up do
    [
      "ALTER TABLE memory_outbox ADD COLUMN migration_state TEXT",
      "ALTER TABLE memory_outbox ADD COLUMN migration_reason TEXT",
      """
      UPDATE memory_outbox
      SET migration_state=state,
          migration_reason=CASE
            WHEN state='done' THEN 'historical_acknowledged'
            WHEN attempts>0 OR state='inflight' THEN 'needs_verified_receipt_and_authority_mapping'
            ELSE 'needs_authority_mapping'
          END,
          state=CASE WHEN state='done' THEN state ELSE 'dead_letter' END
      WHERE access_id IS NULL
      """
    ]
  end
end
