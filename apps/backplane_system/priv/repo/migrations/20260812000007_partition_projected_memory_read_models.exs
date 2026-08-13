defmodule Backplane.Repo.Migrations.PartitionProjectedMemoryReadModels do
  use Ecto.Migration
  require Logger

  @projected_tables [:bpm_projected_observations, :bpm_projected_sessions]

  def up do
    Enum.each(@projected_tables, fn table_name ->
      alter table(table_name, prefix: prefix()) do
        add(:client_id, :text)
        add(:scope, :text)
        add(:namespace, :text)
      end

      create(index(table_name, [:host_id, :client_id, :scope, :namespace], prefix: prefix()))
    end)

    execute("""
    UPDATE #{table_name(:bpm_projected_observations)} AS observation
    SET client_id = event.client_id,
        scope = event.scope,
        namespace = event.namespace
    FROM #{table_name(:bpm_events)} AS event
    WHERE observation.event_id = event.id
      AND event.host_id = observation.host_id
      AND event.client_id IS NOT NULL
      AND event.scope IS NOT NULL
      AND event.namespace IS NOT NULL
    """)

    execute("""
    WITH trusted AS (
      SELECT session.subject_id,
             min(event.client_id) AS client_id,
             min(event.scope) AS scope,
             min(event.namespace) AS namespace
      FROM #{table_name(:bpm_projected_sessions)} AS session
      JOIN #{table_name(:bpm_events)} AS event
        ON event.host_id = session.host_id
       AND event.session_id = session.session_id
       AND event.schema_version IS NOT NULL
      GROUP BY session.subject_id
      HAVING count(*) = count(*) FILTER (
               WHERE event.client_id IS NOT NULL
                 AND event.scope IS NOT NULL
                 AND event.namespace IS NOT NULL
             )
         AND count(DISTINCT (event.client_id, event.scope, event.namespace)) = 1
    )
    UPDATE #{table_name(:bpm_projected_sessions)} AS session
    SET client_id = trusted.client_id,
        scope = trusted.scope,
        namespace = trusted.namespace
    FROM trusted
    WHERE session.subject_id = trusted.subject_id
    """)

    execute("""
    UPDATE #{table_name(:bpm_projection_snapshots)} AS snapshot
    SET read_model = snapshot.read_model || jsonb_build_object(
      'client_id', session.client_id,
      'scope', session.scope,
      'namespace', session.namespace
    )
    FROM #{table_name(:bpm_projected_sessions)} AS session
    WHERE snapshot.subject_type = 'captured_session'
      AND snapshot.projector IN ('session', 'observations')
      AND snapshot.subject_id = session.subject_id
      AND session.client_id IS NOT NULL
      AND session.scope IS NOT NULL
      AND session.namespace IS NOT NULL
    """)

    flush()
    report_partition_outcome()
  end

  def down do
    # Rollback policy: hard stop. Dropping these columns would make trusted and
    # denied projections indistinguishable. Operators must restore a
    # pre-migration backup instead of attempting an in-place downgrade.
    raise Ecto.MigrationError,
      message: "irreversible migration: ambiguous projected partition identities remain denied"
  end

  defp report_partition_outcome do
    Enum.each(@projected_tables, fn table ->
      [[partitioned, denied]] =
        repo().query!("""
        SELECT
          count(*) FILTER (
            WHERE client_id IS NOT NULL
              AND scope IS NOT NULL
              AND namespace IS NOT NULL
          ),
          count(*) FILTER (
            WHERE client_id IS NULL
               OR scope IS NULL
               OR namespace IS NULL
          )
        FROM #{table_name(table)}
        """).rows

      Logger.warning(
        "memory projection partition migration table=#{table} partitioned=#{partitioned} denied=#{denied}"
      )
    end)
  end

  defp table_name(name) do
    case prefix() do
      nil -> quote_identifier(name)
      migration_prefix -> "#{quote_identifier(migration_prefix)}.#{quote_identifier(name)}"
    end
  end

  defp quote_identifier(identifier) do
    escaped = identifier |> to_string() |> String.replace("\"", "\"\"")
    "\"#{escaped}\""
  end
end
