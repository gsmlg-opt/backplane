defmodule Backplane.Repo.Migrations.RetireMemoryV1AndV2Selectors do
  use Ecto.Migration

  def up do
    schema = prefix() || "public"

    execute("""
    DELETE FROM "#{schema}".system_settings
    WHERE key IN (
      'memory.host_sync_v1.enabled',
      'memory.host_sync_v2.enabled',
      'memory.recall_v2.enabled',
      'memory.session_summary_v2.enabled',
      'memory.fact_extraction_v2.enabled',
      'memory.procedure_extraction_v2.enabled'
    );
    """)
  end

  def down do
    :ok
  end
end
