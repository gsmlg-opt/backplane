defmodule Backplane.Repo.Migrations.IncludeHostEpisodicEdgeMemories do
  use Ecto.Migration

  def up do
    p = quote_name(prefix() || "public")

    execute("""
    CREATE TABLE #{p}.bpm_host_memory_command_receipts (
      source_request_id uuid PRIMARY KEY REFERENCES #{p}.bpm_memory_remember_requests(id) ON DELETE RESTRICT,
      memory_id uuid NOT NULL REFERENCES #{p}.bpm_memories(id) ON DELETE RESTRICT,
      edge_revision bigint NOT NULL CHECK (edge_revision > 0),
      created_at timestamp(6) without time zone NOT NULL DEFAULT timezone('UTC', now())
    )
    """)

    execute("""
    CREATE TRIGGER bpm_host_memory_command_receipts_immutable_row
    BEFORE UPDATE OR DELETE ON #{p}.bpm_host_memory_command_receipts
    FOR EACH ROW EXECUTE FUNCTION #{p}.bpm_reject_memory_provenance_mutation()
    """)

    execute("""
    CREATE TRIGGER bpm_host_memory_command_receipts_immutable_truncate
    BEFORE TRUNCATE ON #{p}.bpm_host_memory_command_receipts
    FOR EACH STATEMENT EXECUTE FUNCTION #{p}.bpm_reject_memory_provenance_mutation()
    """)

    execute("""
    CREATE FUNCTION #{p}.bpm_memory_edge_host_origin(m #{p}.bpm_memories)
    RETURNS boolean LANGUAGE sql STABLE AS $$
      SELECT COALESCE(m.memory_type = 'episodic'
        AND m.host_id IS NOT NULL AND length(btrim(m.host_id)) > 0
        AND m.client_id = 'host:' || m.host_id
        AND (
          (jsonb_typeof(m.metadata->'host_memory') = 'object'
            AND length(btrim(m.metadata->'host_memory'->>'local_id')) > 0)
          OR EXISTS (
            SELECT 1 FROM #{p}.bpm_memory_remember_requests r
            WHERE r.memory_id = m.id
              AND r.idempotency_scope = 'host-memory.v1:' || m.host_id
              AND r.id::text = m.metadata->>'host_memory_command_revision'
          )
        ), false)
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{p}.bpm_memory_edge_eligible(m #{p}.bpm_memories)
    RETURNS boolean LANGUAGE sql STABLE AS $$
      SELECT COALESCE(
        (m.memory_type IN ('semantic', 'procedural') OR #{p}.bpm_memory_edge_host_origin(m))
        AND m.lifecycle_state IN ('active', 'disputed') AND m.deleted_at IS NULL
        AND EXISTS (
          SELECT 1 FROM #{p}.bpm_memory_space_entitlements e
          JOIN #{p}.bpm_memory_spaces s ON s.id = e.memory_space_id
          WHERE e.memory_space_id = m.memory_space_id AND e.scope = m.scope
            AND e.namespace = m.namespace AND e.status = 'active' AND s.status = 'active'
        )
        AND octet_length(#{p}.bpm_memory_edge_payload(m)::text) <= #{p}.bpm_memory_edge_max_item_bytes(),
        false)
    $$
    """)

    rewrite_old_eligibility(p, true)

    # A pre-upgrade host remember can have deduplicated onto a crystal memory.
    # Such a row has an immutable host request but no host_memory.local_id.
    # Choose the earliest request deterministically and only mark rows whose
    # exact projected payload remains edge eligible after adding the marker.
    # The canonical UPDATE trigger then assigns the first causal edge revision.
    # Block concurrent canonical writes before selected/prepared read metadata;
    # the migration transaction keeps the lock through the backfill UPDATE.
    execute("LOCK TABLE #{p}.bpm_memories IN SHARE ROW EXCLUSIVE MODE")

    execute("""
    WITH selected AS (
      SELECT DISTINCT ON (m.id) m.id AS memory_id, r.id AS request_id
      FROM #{p}.bpm_memories m
      JOIN #{p}.bpm_memory_remember_requests r ON r.memory_id = m.id
      WHERE m.memory_type = 'episodic'
        AND m.host_id IS NOT NULL AND length(btrim(m.host_id)) > 0
        AND m.client_id = 'host:' || m.host_id
        AND r.idempotency_scope = 'host-memory.v1:' || m.host_id
        AND NOT (m.metadata ? 'host_memory_command_revision')
        AND NOT COALESCE(jsonb_typeof(m.metadata->'host_memory') = 'object'
          AND length(btrim(m.metadata->'host_memory'->>'local_id')) > 0, false)
      ORDER BY m.id, r.inserted_at, r.id
    ), prepared AS (
      SELECT m.id, jsonb_set(m.metadata, '{host_memory_command_revision}',
        to_jsonb(s.request_id::text), true) AS metadata,
        timezone('UTC', clock_timestamp()) AS updated_at
      FROM #{p}.bpm_memories m JOIN selected s ON s.memory_id = m.id
    )
    UPDATE #{p}.bpm_memories m
    SET metadata = prepared.metadata, updated_at = prepared.updated_at
    FROM prepared
    WHERE m.id = prepared.id
      AND #{p}.bpm_memory_edge_eligible(jsonb_populate_record(m,
        jsonb_build_object('metadata', prepared.metadata, 'updated_at', prepared.updated_at)))
    """)

    # The canonical table, rather than retained changes, supplies historical
    # episodic rows to these already connected hosts at their next pull.
    execute("""
    UPDATE #{p}.bpm_host_memory_deliveries d SET status = 'expired'
    WHERE d.status = 'issued' AND EXISTS (
      SELECT 1 FROM #{p}.bpm_memories m
      WHERE m.memory_space_id = d.memory_space_id AND m.scope = d.scope
        AND m.namespace = d.namespace AND #{p}.bpm_memory_edge_eligible(m)
        AND #{p}.bpm_memory_edge_host_origin(m))
    """)

    execute("""
    UPDATE #{p}.bpm_host_memory_cursors c
    SET acknowledged_at = NULL, active_snapshot_id = NULL, snapshot_next_chunk_index = NULL
    WHERE EXISTS (
      SELECT 1 FROM #{p}.bpm_memories m
      WHERE m.memory_space_id = c.memory_space_id AND m.scope = c.scope
        AND m.namespace = c.namespace AND #{p}.bpm_memory_edge_eligible(m)
        AND #{p}.bpm_memory_edge_host_origin(m))
    """)
  end

  def down do
    p = quote_name(prefix() || "public")

    # A host can have activated an episodic snapshot even if the source row was
    # deleted since delivery. Force every cursor through a canonical snapshot
    # after rollback so no stale episodic item survives on the edge.
    execute(
      "UPDATE #{p}.bpm_host_memory_deliveries SET status = 'expired' WHERE status = 'issued'"
    )

    execute("""
    UPDATE #{p}.bpm_host_memory_cursors
    SET acknowledged_at = NULL, active_snapshot_id = NULL, snapshot_next_chunk_index = NULL
    """)

    rewrite_old_eligibility(p, false)

    execute("""
    CREATE OR REPLACE FUNCTION #{p}.bpm_memory_edge_eligible(m #{p}.bpm_memories)
    RETURNS boolean LANGUAGE sql STABLE AS $$
      SELECT COALESCE(
        m.memory_type IN ('semantic', 'procedural')
        AND m.lifecycle_state IN ('active', 'disputed') AND m.deleted_at IS NULL
        AND EXISTS (
          SELECT 1 FROM #{p}.bpm_memory_space_entitlements e
          JOIN #{p}.bpm_memory_spaces s ON s.id = e.memory_space_id
          WHERE e.memory_space_id = m.memory_space_id AND e.scope = m.scope
            AND e.namespace = m.namespace AND e.status = 'active' AND s.status = 'active'
        )
        AND octet_length(#{p}.bpm_memory_edge_payload(m)::text) <= #{p}.bpm_memory_edge_max_item_bytes(),
        false)
    $$
    """)

    execute("DROP FUNCTION #{p}.bpm_memory_edge_host_origin(#{p}.bpm_memories)")
    execute("DROP TABLE #{p}.bpm_host_memory_command_receipts")
  end

  defp rewrite_old_eligibility(p, include_host?) do
    original = "OLD.memory_type IN ('semantic', 'procedural')"

    replacement =
      "(OLD.memory_type IN ('semantic', 'procedural') OR #{p}.bpm_memory_edge_host_origin(OLD))"

    {from, to} = if include_host?, do: {original, replacement}, else: {replacement, original}

    execute("""
    DO $migration$
    DECLARE definition text;
    BEGIN
      SELECT pg_get_functiondef('#{p}.bpm_capture_memory_edge_change()'::regprocedure)
        INTO definition;
      IF strpos(definition, #{quote_literal(from)}) = 0 THEN
        RAISE EXCEPTION 'unexpected memory edge capture function during episodic migration';
      END IF;
      EXECUTE replace(definition, #{quote_literal(from)}, #{quote_literal(to)});
    END
    $migration$
    """)
  end

  defp quote_name(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
  defp quote_literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
