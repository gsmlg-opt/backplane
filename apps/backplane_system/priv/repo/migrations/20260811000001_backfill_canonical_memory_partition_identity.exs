defmodule Backplane.Repo.Migrations.BackfillCanonicalMemoryPartitionIdentity do
  use Ecto.Migration

  @host_partition_prefix "host:"
  @host_memory_request_prefix "host-memory.v1:"

  def up do
    events = qualified_table("bpm_events")
    streams = qualified_table("bpm_streams")
    memories = qualified_table("bpm_memories")
    requests = qualified_table("bpm_memory_remember_requests")
    hosts = qualified_table("skill_hosts")

    execute("ALTER TABLE #{events} DISABLE TRIGGER bpm_events_captured_immutable")

    execute("""
    UPDATE #{events} AS event
    SET client_id = '#{@host_partition_prefix}' || host.id::text
    FROM #{hosts} AS host
    WHERE event.schema_version IS NOT NULL
      AND event.ingest_auth_token_id IS NOT NULL
      AND event.host_id = host.id::text
      AND event.client_id IS DISTINCT FROM '#{@host_partition_prefix}' || host.id::text
    """)

    execute("ALTER TABLE #{events} ENABLE TRIGGER bpm_events_captured_immutable")

    execute("""
    UPDATE #{streams} AS stream
    SET client_id = '#{@host_partition_prefix}' || host.id::text
    FROM #{hosts} AS host
    WHERE stream.host_id = host.id::text
      AND stream.client_id IS DISTINCT FROM '#{@host_partition_prefix}' || host.id::text
      AND EXISTS (
        SELECT 1
        FROM #{events} AS event
        WHERE event.stream_id = stream.stream_id
          AND event.host_id = host.id::text
          AND event.schema_version IS NOT NULL
          AND event.ingest_auth_token_id IS NOT NULL
      )
    """)

    execute("""
    WITH trusted_memory_partitions AS (
      SELECT
        request.memory_id,
        min(host.id::text) AS host_id
      FROM #{requests} AS request
      JOIN #{hosts} AS host
        ON request.idempotency_scope = '#{@host_memory_request_prefix}' || host.id::text
      GROUP BY request.memory_id
      HAVING count(DISTINCT host.id) = 1
    )
    UPDATE #{memories} AS memory
    SET
      client_id = '#{@host_partition_prefix}' || trusted.host_id,
      namespace = 'private'
    FROM trusted_memory_partitions AS trusted
    WHERE memory.id = trusted.memory_id
      AND (
        memory.client_id IS DISTINCT FROM '#{@host_partition_prefix}' || trusted.host_id
        OR memory.namespace IS DISTINCT FROM 'private'
      )
    """)
  end

  # The legacy token/client values are not recoverable from canonical host identity.
  def down do
    raise Ecto.MigrationError,
      message:
        "irreversible migration: legacy token/client partition identities cannot be recovered"
  end

  defp qualified_table(table) do
    case prefix() do
      nil -> table
      prefix -> ~s|"#{String.replace(prefix, "\"", "\"\"")}".#{table}|
    end
  end
end
