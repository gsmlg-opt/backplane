defmodule Backplane.Repo.Migrations.ApplyCurrentContextToMemoryEdges do
  use Ecto.Migration

  def up do
    # NULL preserves the fact that old immutable receipts lack per-request
    # provenance. It does not turn a known legacy Hermes mirror into proof of
    # independent support for a newly mapped source.
    alter table(:bpm_memory_remember_requests) do
      add(:independent_support, :boolean)
    end

    flush()
    p = quote_name(prefix() || "public")

    execute("""
    CREATE FUNCTION #{p}.bpm_memory_independent_support(m #{p}.bpm_memories)
    RETURNS boolean LANGUAGE sql STABLE AS $$
      SELECT (
        NOT EXISTS (SELECT 1 FROM #{p}.bpm_memory_remember_requests r WHERE r.memory_id=m.id)
        AND COALESCE(m.metadata->>'source','') NOT IN
          ('hermes.memory_write.add','hermes.memory_write.update','hermes.sync_turn')
      ) OR EXISTS (
        SELECT 1 FROM #{p}.bpm_memory_remember_requests r WHERE r.memory_id=m.id AND r.origin='direct'
          AND COALESCE(r.independent_support, COALESCE(m.metadata->>'source','') NOT IN
            ('hermes.memory_write.add','hermes.memory_write.update','hermes.sync_turn'))
      ) OR EXISTS (
        SELECT 1 FROM #{p}.bpm_memory_remember_requests r WHERE r.memory_id=m.id AND r.origin='derived'
          AND EXISTS (SELECT 1 FROM #{p}.bpm_memory_request_evidence g WHERE g.request_id=r.id)
          AND NOT EXISTS (SELECT 1 FROM #{p}.bpm_memory_request_evidence g
            JOIN #{p}.bpm_memory_evidence ev ON ev.id=g.evidence_id
            WHERE g.request_id=r.id AND ev.source_mutation_id IS NOT NULL)
      )
    $$
    """)

    execute("""
    CREATE FUNCTION #{p}.bpm_memory_current_supported(m #{p}.bpm_memories)
    RETURNS boolean LANGUAGE sql STABLE AS $$
      SELECT
        #{p}.bpm_memory_independent_support(m)
        OR EXISTS (SELECT 1 FROM #{p}.bpm_memory_source_entries e WHERE e.memory_id=m.id AND e.active AND NOT e.suppressed)
        OR EXISTS (
          SELECT 1 FROM #{p}.bpm_memory_remember_requests r WHERE r.memory_id=m.id AND r.origin='derived'
            AND EXISTS (SELECT 1 FROM #{p}.bpm_memory_request_evidence g WHERE g.request_id=r.id)
            AND NOT EXISTS (
              SELECT 1 FROM #{p}.bpm_memory_request_evidence g JOIN #{p}.bpm_memory_evidence ev ON ev.id=g.evidence_id
              WHERE g.request_id=r.id AND ev.source_mutation_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM #{p}.bpm_memory_source_entries e JOIN #{p}.bpm_memories root ON root.id=e.memory_id
                WHERE e.mutation_id=ev.source_mutation_id AND e.active AND NOT e.suppressed
                  AND root.deleted_at IS NULL AND root.lifecycle_state NOT IN ('superseded','archived','tombstoned')
                  AND (root.expires_at IS NULL OR root.expires_at>timezone('UTC',clock_timestamp()))
              )
            )
        )
    $$
    """)

    execute("""
    CREATE FUNCTION #{p}.bpm_memory_source_valid_until(m #{p}.bpm_memories)
    RETURNS timestamp LANGUAGE sql STABLE AS $$
      SELECT CASE WHEN #{p}.bpm_memory_independent_support(m)
        THEN NULL ELSE (
          SELECT min(root.expires_at) FROM #{p}.bpm_memory_remember_requests r
          JOIN #{p}.bpm_memory_request_evidence g ON g.request_id=r.id
          JOIN #{p}.bpm_memory_evidence ev ON ev.id=g.evidence_id
          JOIN #{p}.bpm_memory_source_entries e ON e.mutation_id=ev.source_mutation_id
          JOIN #{p}.bpm_memories root ON root.id=e.memory_id
          WHERE r.memory_id=m.id AND e.active AND NOT e.suppressed
        ) END
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{p}.bpm_memory_edge_payload(m #{p}.bpm_memories)
    RETURNS jsonb LANGUAGE sql STABLE AS $$
      SELECT jsonb_build_object(
        'canonical_id',m.id,'memory_type',m.memory_type,'content',m.content,
        'content_hash',encode(m.content_hash,'hex'),'confidence',m.confidence,
        'lifecycle_state',m.lifecycle_state,'tags',m.tags,
        'metadata',jsonb_set(COALESCE(m.metadata,'{}'::jsonb),'{current_context}',context,true),
        'expires_at',m.expires_at,
        'edge_priority',(CASE WHEN m.memory_type='procedural' THEN 2.0 ELSE 0.0 END)
          + least(1.0,greatest(0.0,coalesce(m.confidence,0.0))),
        'updated_at',m.updated_at) || context
      FROM (SELECT COALESCE(m.metadata->'current_context','{}'::jsonb) || jsonb_build_object(
        'policy_version','current_context.v1',
        'trust',COALESCE(m.metadata->'current_context'->>'trust','candidate_inference'),
        'source_refs',COALESCE(m.metadata->'current_context'->'source_refs','[]'::jsonb),
        'support_complete',COALESCE((m.metadata->'current_context'->>'support_complete')::boolean,false),
        'independent_support',#{p}.bpm_memory_independent_support(m),
        'effective_support',m.effective_support AND #{p}.bpm_memory_current_supported(m),
        'valid_until',#{p}.bpm_memory_source_valid_until(m)) AS context) projected
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{p}.bpm_memory_edge_eligible(m #{p}.bpm_memories)
    RETURNS boolean LANGUAGE sql STABLE AS $$
      SELECT COALESCE(
        (m.memory_type IN ('semantic','procedural') OR #{p}.bpm_memory_edge_host_origin(m))
        AND m.lifecycle_state IN ('active','disputed') AND m.deleted_at IS NULL
        AND m.effective_support AND #{p}.bpm_memory_current_supported(m)
        AND (m.expires_at IS NULL OR m.expires_at>timezone('UTC',clock_timestamp()))
        AND EXISTS (
          SELECT 1 FROM #{p}.bpm_memory_space_entitlements e
          JOIN #{p}.bpm_memory_spaces s ON s.id=e.memory_space_id
          WHERE e.memory_space_id=m.memory_space_id AND e.scope=m.scope
            AND e.namespace=m.namespace AND e.status='active' AND s.status='active'
        )
        AND octet_length(#{p}.bpm_memory_edge_payload(m)::text)<=#{p}.bpm_memory_edge_max_item_bytes(),false)
    $$
    """)

    # Preserve the existing lock/revision protocol, including host episodic exits.
    execute("""
    DO $migration$
    DECLARE definition text;
    BEGIN
      SELECT pg_get_functiondef('#{p}.bpm_capture_memory_edge_change()'::regprocedure) INTO definition;
      IF strpos(definition,'OLD.expires_at, OLD.deleted_at)')=0
        OR strpos(definition,'NEW.expires_at, NEW.deleted_at)')=0 THEN
        RAISE EXCEPTION 'unexpected memory edge capture bookkeeping guard';
      END IF;
      definition:=replace(definition,'OLD.expires_at, OLD.deleted_at)',
        'OLD.expires_at, OLD.deleted_at, OLD.effective_support)');
      definition:=replace(definition,'NEW.expires_at, NEW.deleted_at)',
        'NEW.expires_at, NEW.deleted_at, NEW.effective_support)');
      EXECUTE definition;
    END $migration$
    """)

    execute("""
    CREATE FUNCTION #{p}.bpm_refresh_memory_source_dependents()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF (OLD.deleted_at,OLD.lifecycle_state,OLD.expires_at)
        IS NOT DISTINCT FROM (NEW.deleted_at,NEW.lifecycle_state,NEW.expires_at) THEN RETURN NEW; END IF;
      WITH locked AS MATERIALIZED (
        SELECT DISTINCT dependent.id FROM #{p}.bpm_memories dependent
        JOIN #{p}.bpm_memory_remember_requests r ON r.memory_id=dependent.id
        JOIN #{p}.bpm_memory_request_evidence g ON g.request_id=r.id
        JOIN #{p}.bpm_memory_evidence ev ON ev.id=g.evidence_id
        JOIN #{p}.bpm_memory_source_mutations mu ON mu.id=ev.source_mutation_id
        WHERE mu.memory_id=NEW.id AND dependent.id<>NEW.id
      ), prepared AS (
        SELECT m.id,#{p}.bpm_memory_current_supported(m) AS supported,
          jsonb_set(COALESCE(m.metadata->'current_context','{}'::jsonb),'{valid_until}',
            COALESCE(to_jsonb(#{p}.bpm_memory_source_valid_until(m)),'null'::jsonb),true) AS context
        FROM #{p}.bpm_memories m JOIN locked l ON l.id=m.id ORDER BY m.id FOR UPDATE OF m
      )
      UPDATE #{p}.bpm_memories m SET effective_support=p.supported,
        metadata=jsonb_set(COALESCE(m.metadata,'{}'::jsonb),'{current_context}',p.context,true),
        updated_at=timezone('UTC',clock_timestamp())
      FROM prepared p WHERE m.id=p.id AND (m.effective_support IS DISTINCT FROM p.supported
        OR m.metadata->'current_context' IS DISTINCT FROM p.context);
      RETURN NEW;
    END $$
    """)

    execute("""
    CREATE TRIGGER bpm_memory_source_dependents
    AFTER UPDATE OF deleted_at,lifecycle_state,expires_at ON #{p}.bpm_memories
    FOR EACH ROW EXECUTE FUNCTION #{p}.bpm_refresh_memory_source_dependents()
    """)

    # Previously issued snapshots lack suppression metadata; reconnect through a
    # fresh canonical snapshot rather than treating those payloads as current.
    execute("UPDATE #{p}.bpm_host_memory_deliveries SET status='expired' WHERE status='issued'")

    execute("""
    UPDATE #{p}.bpm_host_memory_cursors SET acknowledged_at=NULL,
      active_snapshot_id=NULL,snapshot_next_chunk_index=NULL
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message: "forward-only: readers must retain source withdrawal and current-context policy"
  end

  defp quote_name(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
