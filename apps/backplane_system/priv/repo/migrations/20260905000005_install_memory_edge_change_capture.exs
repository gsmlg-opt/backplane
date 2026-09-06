defmodule Backplane.Repo.Migrations.InstallMemoryEdgeChangeCapture do
  use Ecto.Migration

  def up do
    p = quote_name(prefix() || "public")

    # Shared by capture and the revision-pinned canonical snapshot reader.
    # JSONB text bytes conservatively bound compact JSON wire encoding.
    execute("""
    CREATE FUNCTION #{p}.bpm_memory_edge_payload(m #{p}.bpm_memories)
    RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
      SELECT jsonb_build_object(
        'canonical_id', m.id, 'memory_type', m.memory_type,
        'content', m.content, 'content_hash', encode(m.content_hash, 'hex'),
        'confidence', m.confidence, 'lifecycle_state', m.lifecycle_state,
        'tags', m.tags, 'metadata', m.metadata, 'expires_at', m.expires_at)
    $$
    """)

    # A 256 KiB default leaves room in a 512 KiB frame for protocol envelopes.
    # Read the durable setting inside the canonical transaction, not an ETS cache.
    execute("""
    CREATE FUNCTION #{p}.bpm_memory_edge_max_item_bytes()
    RETURNS integer LANGUAGE sql STABLE AS $$
      SELECT COALESCE((SELECT CASE
        WHEN jsonb_typeof(value->'v') = 'number' AND (value->>'v') ~ '^[0-9]{1,6}$'
        THEN greatest(1, least(262144, (value->>'v')::integer))
        ELSE 262144 END
        FROM #{p}.system_settings WHERE key = 'memory.host_sync_max_item_bytes'), 262144)
    $$
    """)

    execute("""
    CREATE FUNCTION #{p}.bpm_memory_edge_eligible(m #{p}.bpm_memories)
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

    execute("""
    CREATE FUNCTION #{p}.bpm_capture_memory_edge_change()
    RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      old_payload jsonb; new_payload jsonb;
      old_eligible boolean := false; new_eligible boolean := false;
      moved boolean := false; part record; rev bigint; body jsonb; hint text;
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        old_payload := #{p}.bpm_memory_edge_payload(OLD);
        -- History can be compacted and settings/entitlements can change after a
        -- snapshot. Conservatively tombstone any formerly mirrorable shape;
        -- never infer absence on a host from absence in retained change rows.
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

      -- Both initialization (unique-index locks) and row locks use the same
      -- lexical order, including moves to partitions not seen before.
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

      -- Emit the old delete first even when lexical lock order was the reverse.
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
        -- PostgreSQL delivers NOTIFY only if the containing transaction commits.
        hint := jsonb_build_object('memory_space_id', part.memory_space_id, 'scope', part.scope,
          'namespace', part.namespace, 'current_revision', rev)::text;
        -- Valid partition identifiers can exceed NOTIFY's payload ceiling.
        -- Polling reads durable revisions, so an oversized hint is dispensable.
        IF octet_length(hint) < 8000 THEN
          PERFORM pg_notify('bpm_memory_edge_available', hint);
        END IF;
      END LOOP;
      RETURN NULL;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER bpm_memory_edge_change_capture
    AFTER INSERT OR UPDATE OR DELETE ON #{p}.bpm_memories
    FOR EACH ROW EXECUTE FUNCTION #{p}.bpm_capture_memory_edge_change()
    """)

    execute("""
    CREATE FUNCTION #{p}.bpm_reject_memory_change_update()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'memory change rows are immutable';
    END
    $$
    """)

    execute("""
    CREATE TRIGGER bpm_memory_changes_immutable BEFORE UPDATE ON #{p}.bpm_memory_changes
    FOR EACH ROW EXECUTE FUNCTION #{p}.bpm_reject_memory_change_update()
    """)
  end

  def down do
    p = quote_name(prefix() || "public")
    execute("DROP TRIGGER bpm_memory_changes_immutable ON #{p}.bpm_memory_changes")
    execute("DROP FUNCTION #{p}.bpm_reject_memory_change_update()")
    execute("DROP TRIGGER bpm_memory_edge_change_capture ON #{p}.bpm_memories")
    execute("DROP FUNCTION #{p}.bpm_capture_memory_edge_change()")
    execute("DROP FUNCTION #{p}.bpm_memory_edge_eligible(#{p}.bpm_memories)")
    execute("DROP FUNCTION #{p}.bpm_memory_edge_max_item_bytes()")
    execute("DROP FUNCTION #{p}.bpm_memory_edge_payload(#{p}.bpm_memories)")
  end

  defp quote_name(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
