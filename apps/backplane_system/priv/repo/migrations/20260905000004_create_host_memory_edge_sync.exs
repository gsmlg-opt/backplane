defmodule Backplane.Repo.Migrations.CreateHostMemoryEdgeSync do
  use Ecto.Migration

  def up do
    p = quote_name(prefix() || "public")

    execute("""
    CREATE TABLE #{p}.bpm_memory_partition_revisions (
      memory_space_id uuid NOT NULL REFERENCES #{p}.bpm_memory_spaces(id),
      scope text NOT NULL CHECK (length(btrim(scope)) > 0),
      namespace text NOT NULL CHECK (length(btrim(namespace)) > 0),
      current_revision bigint NOT NULL DEFAULT 0 CHECK (current_revision >= 0),
      first_available_revision bigint NOT NULL DEFAULT 1 CHECK (first_available_revision > 0 AND first_available_revision <= current_revision + 1),
      updated_at timestamp(6) without time zone NOT NULL DEFAULT timezone('UTC', now()),
      PRIMARY KEY (memory_space_id, scope, namespace)
    )
    """)

    execute("""
    CREATE TABLE #{p}.bpm_memory_changes (
      memory_space_id uuid NOT NULL, scope text NOT NULL, namespace text NOT NULL,
      revision bigint NOT NULL CHECK (revision > 0),
      op text NOT NULL CHECK (op IN ('upsert', 'delete')),
      memory_id uuid NOT NULL, payload jsonb NOT NULL,
      payload_bytes integer NOT NULL CHECK (payload_bytes > 0),
      created_at timestamp(6) without time zone NOT NULL DEFAULT timezone('UTC', now()),
      PRIMARY KEY (memory_space_id, scope, namespace, revision),
      FOREIGN KEY (memory_space_id, scope, namespace) REFERENCES #{p}.bpm_memory_partition_revisions,
      CHECK (payload_bytes = octet_length(payload::text))
    )
    """)

    execute("""
    CREATE TABLE #{p}.bpm_memory_snapshots (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      memory_space_id uuid NOT NULL, scope text NOT NULL, namespace text NOT NULL,
      revision bigint NOT NULL CHECK (revision >= 0),
      item_count integer NOT NULL DEFAULT 0 CHECK (item_count >= 0),
      chunk_count integer NOT NULL DEFAULT 0 CHECK (chunk_count >= 0),
      integrity_hash text,
      status text NOT NULL DEFAULT 'building' CHECK (status IN ('building', 'ready', 'expired')),
      expires_at timestamp(6) without time zone NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL DEFAULT timezone('UTC', now()),
      FOREIGN KEY (memory_space_id, scope, namespace) REFERENCES #{p}.bpm_memory_partition_revisions,
      UNIQUE (id, memory_space_id, scope, namespace),
      CHECK (status <> 'ready' OR (integrity_hash IS NOT NULL AND chunk_count > 0))
    )
    """)

    execute("""
    CREATE TABLE #{p}.bpm_memory_snapshot_chunks (
      snapshot_id uuid NOT NULL REFERENCES #{p}.bpm_memory_snapshots(id) ON DELETE CASCADE,
      chunk_index integer NOT NULL CHECK (chunk_index >= 0),
      item_count integer NOT NULL CHECK (item_count >= 0),
      encoded_bytes integer NOT NULL CHECK (encoded_bytes > 0),
      chunk_hash text NOT NULL, payload jsonb NOT NULL,
      PRIMARY KEY (snapshot_id, chunk_index)
    )
    """)

    execute("""
    CREATE TABLE #{p}.bpm_host_memory_cursors (
      host_id uuid NOT NULL,
      memory_space_id uuid NOT NULL, scope text NOT NULL, namespace text NOT NULL,
      applied_revision bigint NOT NULL DEFAULT 0 CHECK (applied_revision >= 0),
      active_snapshot_id uuid, snapshot_next_chunk_index integer CHECK (snapshot_next_chunk_index >= 0),
      last_acknowledged_batch_id uuid,
      acknowledged_at timestamp(6) without time zone,
      PRIMARY KEY (host_id, memory_space_id, scope, namespace),
      FOREIGN KEY (memory_space_id, scope, namespace) REFERENCES #{p}.bpm_memory_partition_revisions,
      FOREIGN KEY (active_snapshot_id, memory_space_id, scope, namespace) REFERENCES #{p}.bpm_memory_snapshots(id, memory_space_id, scope, namespace),
      CHECK ((active_snapshot_id IS NULL) = (snapshot_next_chunk_index IS NULL))
    )
    """)

    execute("""
    CREATE TABLE #{p}.bpm_host_memory_deliveries (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      host_id uuid NOT NULL,
      memory_space_id uuid NOT NULL, scope text NOT NULL, namespace text NOT NULL,
      kind text NOT NULL CHECK (kind IN ('delta', 'snapshot_chunk')),
      snapshot_id uuid, chunk_index integer,
      from_revision bigint, to_revision bigint NOT NULL CHECK (to_revision >= 0),
      payload jsonb NOT NULL, encoded_bytes integer NOT NULL CHECK (encoded_bytes > 0),
      chunk_hash text, integrity_hash text,
      status text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued', 'progress', 'acknowledged', 'expired')),
      issued_at timestamp(6) without time zone NOT NULL DEFAULT timezone('UTC', now()),
      acknowledged_at timestamp(6) without time zone,
      FOREIGN KEY (host_id, memory_space_id, scope, namespace) REFERENCES #{p}.bpm_host_memory_cursors,
      FOREIGN KEY (snapshot_id, memory_space_id, scope, namespace) REFERENCES #{p}.bpm_memory_snapshots(id, memory_space_id, scope, namespace),
      FOREIGN KEY (snapshot_id, chunk_index) REFERENCES #{p}.bpm_memory_snapshot_chunks,
      CHECK ((kind = 'delta' AND snapshot_id IS NULL AND chunk_index IS NULL AND from_revision IS NOT NULL AND from_revision > 0 AND from_revision <= to_revision)
        OR (kind = 'snapshot_chunk' AND snapshot_id IS NOT NULL AND chunk_index IS NOT NULL AND chunk_index >= 0 AND from_revision IS NULL AND chunk_hash IS NOT NULL AND integrity_hash IS NOT NULL))
    )
    """)

    execute(
      "CREATE UNIQUE INDEX bpm_host_memory_deliveries_one_issued ON #{p}.bpm_host_memory_deliveries (host_id, memory_space_id, scope, namespace) WHERE status = 'issued'"
    )

    execute("""
    CREATE TABLE #{p}.bpm_host_memory_compat_receipts (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(), host_id uuid NOT NULL,
      kind text NOT NULL CHECK (kind IN ('facts', 'wipe')),
      receipt_key text NOT NULL CHECK (length(receipt_key) > 0),
      scope text NOT NULL CHECK (length(btrim(scope)) > 0),
      payload_hash text NOT NULL CHECK (length(payload_hash) > 0),
      issued_at timestamp(6) without time zone NOT NULL DEFAULT timezone('UTC', now()),
      acknowledged_at timestamp(6) without time zone,
      UNIQUE (host_id, kind, receipt_key)
    )
    """)

    execute("""
    INSERT INTO #{p}.bpm_memory_partition_revisions (memory_space_id, scope, namespace)
    SELECT memory_space_id, scope, namespace FROM #{p}.bpm_memories
    WHERE memory_space_id IS NOT NULL AND length(btrim(scope)) > 0 AND length(btrim(namespace)) > 0
    UNION
    SELECT memory_space_id, scope, namespace FROM #{p}.bpm_memory_space_entitlements
    ON CONFLICT DO NOTHING
    """)
  end

  def down do
    p = quote_name(prefix() || "public")

    for table <-
          ~w(bpm_host_memory_compat_receipts bpm_host_memory_deliveries bpm_host_memory_cursors bpm_memory_snapshot_chunks bpm_memory_snapshots bpm_memory_changes bpm_memory_partition_revisions) do
      execute("DROP TABLE #{p}.#{table}")
    end
  end

  defp quote_name(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
