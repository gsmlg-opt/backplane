defmodule Backplane.Repo.Migrations.AddMemoryEdgePayloadPriority do
  use Ecto.Migration

  def up do
    p = quote_name(prefix() || "public")

    execute("""
    CREATE OR REPLACE FUNCTION #{p}.bpm_memory_edge_payload(m #{p}.bpm_memories)
    RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
      SELECT jsonb_build_object(
        'canonical_id', m.id, 'memory_type', m.memory_type,
        'content', m.content, 'content_hash', encode(m.content_hash, 'hex'),
        'confidence', m.confidence, 'lifecycle_state', m.lifecycle_state,
        'tags', m.tags, 'metadata', m.metadata, 'expires_at', m.expires_at,
        'edge_priority',
          (CASE WHEN m.memory_type = 'procedural' THEN 2.0 ELSE 0.0 END) +
          least(1.0, greatest(0.0, coalesce(m.confidence, 0.0))),
        'updated_at', m.updated_at)
    $$
    """)

    replace_capture_function(p)
  end

  def down do
    p = quote_name(prefix() || "public")

    execute("""
    CREATE OR REPLACE FUNCTION #{p}.bpm_memory_edge_payload(m #{p}.bpm_memories)
    RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
      SELECT jsonb_build_object(
        'canonical_id', m.id, 'memory_type', m.memory_type,
        'content', m.content, 'content_hash', encode(m.content_hash, 'hex'),
        'confidence', m.confidence, 'lifecycle_state', m.lifecycle_state,
        'tags', m.tags, 'metadata', m.metadata, 'expires_at', m.expires_at)
    $$
    """)

    restore_capture_function(p)
  end

  defp replace_capture_function(p), do: capture_function(p, bookkeeping_guard())
  defp restore_capture_function(p), do: capture_function(p, "")

  defp capture_function(p, guard) do
    execute("""
    CREATE OR REPLACE FUNCTION #{p}.bpm_capture_memory_edge_change()
    RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      old_payload jsonb; new_payload jsonb;
      old_eligible boolean := false; new_eligible boolean := false;
      moved boolean := false; part record; rev bigint; body jsonb; hint text;
    BEGIN
      #{guard}

      IF TG_OP <> 'INSERT' THEN
        old_payload := #{p}.bpm_memory_edge_payload(OLD);
        old_eligible := COALESCE(OLD.memory_type IN ('semantic', 'procedural')
          AND OLD.lifecycle_state IN ('active', 'disputed') AND OLD.deleted_at IS NULL
          AND OLD.memory_space_id IS NOT NULL AND length(btrim(OLD.scope)) > 0
          AND length(btrim(OLD.namespace)) > 0, false);
      END IF;
      IF TG_OP <> 'DELETE' THEN
        new_payload := #{p}.bpm_memory_edge_payload(NEW);
        new_eligible := #{p}.bpm_memory_edge_eligible(NEW);
        IF octet_length(new_payload::text) > #{p}.bpm_memory_edge_max_item_bytes() THEN
          PERFORM pg_notify('bpm_memory_edge_omitted', '{"reason":"payload_too_large"}');
        END IF;
      END IF;
      IF TG_OP = 'UPDATE' THEN
        moved := (OLD.memory_space_id, OLD.scope, OLD.namespace)
          IS DISTINCT FROM (NEW.memory_space_id, NEW.scope, NEW.namespace);
        IF NOT moved AND OLD.deleted_at IS NOT DISTINCT FROM NEW.deleted_at
          AND old_payload IS NOT DISTINCT FROM new_payload THEN
          RETURN NEW;
        END IF;
      END IF;
      IF NOT old_eligible AND NOT new_eligible THEN RETURN NULL; END IF;

      FOR part IN
        SELECT DISTINCT memory_space_id, scope COLLATE "C" AS scope, namespace COLLATE "C" AS namespace FROM (
          SELECT OLD.memory_space_id, OLD.scope, OLD.namespace WHERE old_eligible
          UNION ALL
          SELECT NEW.memory_space_id, NEW.scope, NEW.namespace WHERE new_eligible
        ) partitions
        ORDER BY memory_space_id, scope, namespace
      LOOP
        INSERT INTO #{p}.bpm_memory_partition_revisions (memory_space_id, scope, namespace)
          VALUES (part.memory_space_id, part.scope, part.namespace) ON CONFLICT DO NOTHING;
        PERFORM 1 FROM #{p}.bpm_memory_partition_revisions
          WHERE memory_space_id = part.memory_space_id AND scope = part.scope
            AND namespace = part.namespace FOR UPDATE;
      END LOOP;

      FOR part IN
        SELECT OLD.memory_space_id, OLD.scope, OLD.namespace, OLD.id AS memory_id, 'delete' AS op, 0 AS ordering
          WHERE old_eligible AND (NOT new_eligible OR moved)
        UNION ALL
        SELECT NEW.memory_space_id, NEW.scope, NEW.namespace, NEW.id, 'upsert', 1 WHERE new_eligible
        ORDER BY ordering
      LOOP
        UPDATE #{p}.bpm_memory_partition_revisions
          SET current_revision = current_revision + 1, updated_at = timezone('UTC', clock_timestamp())
          WHERE memory_space_id = part.memory_space_id AND scope = part.scope AND namespace = part.namespace
          RETURNING current_revision INTO rev;
        body := CASE WHEN part.op = 'delete'
          THEN jsonb_build_object('canonical_id', part.memory_id) ELSE new_payload END;
        INSERT INTO #{p}.bpm_memory_changes
          (memory_space_id, scope, namespace, revision, op, memory_id, payload, payload_bytes)
          VALUES (part.memory_space_id, part.scope, part.namespace, rev, part.op, part.memory_id, body, octet_length(body::text));
        hint := jsonb_build_object('memory_space_id', part.memory_space_id, 'scope', part.scope,
          'namespace', part.namespace, 'current_revision', rev)::text;
        IF octet_length(hint) < 8000 THEN
          PERFORM pg_notify('bpm_memory_edge_available', hint);
        END IF;
      END LOOP;
      RETURN NULL;
    END
    $$
    """)
  end

  defp bookkeeping_guard do
    """
    -- Canonical updated_at is mirrored, but bookkeeping/access-only writes do
    -- not allocate a revision. Semantic changes still carry their new time.
    IF TG_OP = 'UPDATE' AND
      (OLD.id, OLD.memory_space_id, OLD.scope, OLD.namespace, OLD.memory_type,
       OLD.content, OLD.content_hash, OLD.confidence, OLD.lifecycle_state,
       OLD.tags, OLD.metadata, OLD.expires_at, OLD.deleted_at)
      IS NOT DISTINCT FROM
      (NEW.id, NEW.memory_space_id, NEW.scope, NEW.namespace, NEW.memory_type,
       NEW.content, NEW.content_hash, NEW.confidence, NEW.lifecycle_state,
       NEW.tags, NEW.metadata, NEW.expires_at, NEW.deleted_at)
    THEN RETURN NEW;
    END IF;
    """
  end

  defp quote_name(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
