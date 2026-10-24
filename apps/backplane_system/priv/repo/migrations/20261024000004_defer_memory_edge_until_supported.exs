defmodule Backplane.Repo.Migrations.DeferMemoryEdgeUntilSupported do
  use Ecto.Migration

  def up do
    p = quote_name(prefix() || "public")

    # Remember starts with effective_support=false until its evidence is attached.
    # Such a row has never been published: projection must not emit a tombstone
    # when the final payload is unsupported, oversized, or otherwise ineligible.
    # Keep the conservative old-row eligibility for previously supported copies,
    # including copies whose changes were compacted or entitlement was revoked.
    execute("""
    DO $migration$
    DECLARE definition text;
    BEGIN
      SELECT pg_get_functiondef('#{p}.bpm_capture_memory_edge_change()'::regprocedure)
        INTO definition;
      IF strpos(definition, 'AND OLD.lifecycle_state IN') = 0 THEN
        RAISE EXCEPTION 'unexpected memory edge capture old eligibility';
      END IF;
      EXECUTE replace(definition, 'AND OLD.lifecycle_state IN',
        'AND OLD.effective_support AND OLD.lifecycle_state IN');
    END $migration$
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message: "forward-only: edge publication must wait for complete support"
  end

  defp quote_name(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
