defmodule Backplane.Repo.Migrations.PartitionMemoryDerivedModels do
  use Ecto.Migration
  require Logger

  @tables ~w(memory_profiles memory_graph_nodes memory_graph_edges memory_slots memory_actions memory_leases memory_signals)a

  def up do
    execute("ALTER TABLE #{table_name(:memory_profiles)} DROP CONSTRAINT memory_profiles_pkey")

    alter table(:memory_profiles, prefix: prefix()) do
      add(:id, :binary_id, null: false, default: fragment("gen_random_uuid()"))
    end

    execute("ALTER TABLE #{table_name(:memory_profiles)} ADD PRIMARY KEY (id)")

    execute("ALTER TABLE #{table_name(:memory_slots)} DROP CONSTRAINT memory_slots_pkey")

    alter table(:memory_slots, prefix: prefix()) do
      add(:id, :binary_id, null: false, default: fragment("gen_random_uuid()"))
    end

    execute("ALTER TABLE #{table_name(:memory_slots)} ADD PRIMARY KEY (id)")

    Enum.each(@tables, fn table_name ->
      alter table(table_name, prefix: prefix()) do
        add(:host_id, :text)
        add(:client_id, :text)
        add(:scope, :text)
        add(:namespace, :text)
      end

      create(index(table_name, [:host_id, :client_id, :scope, :namespace], prefix: prefix()))
    end)

    create(
      unique_index(
        :memory_profiles,
        [:host_id, :client_id, :scope, :namespace, :project],
        name: :memory_profiles_partition_project_uniq,
        prefix: prefix()
      )
    )

    create(
      unique_index(
        :memory_slots,
        [:host_id, :client_id, :scope, :namespace, :name],
        name: :memory_slots_partition_name_uniq,
        prefix: prefix()
      )
    )

    # A legacy profile is recoverable only when every durable memory in the
    # project has one identical, complete partition identity.
    execute("""
    WITH trusted AS (
      SELECT memory.metadata->>'project' AS project,
             min(memory.host_id) AS host_id,
             min(memory.client_id) AS client_id,
             min(memory.scope) AS scope,
             min(memory.namespace) AS namespace
      FROM #{table_name(:bpm_memories)} AS memory
      WHERE memory.host_id IS NOT NULL
        AND memory.client_id IS NOT NULL
        AND memory.scope IS NOT NULL
        AND memory.namespace IS NOT NULL
        AND jsonb_typeof(memory.metadata->'project') = 'string'
      GROUP BY memory.metadata->>'project'
      HAVING count(DISTINCT (memory.host_id, memory.client_id, memory.scope, memory.namespace)) = 1
    )
    UPDATE #{table_name(:memory_profiles)} AS profile
    SET host_id = trusted.host_id,
        client_id = trusted.client_id,
        scope = trusted.scope,
        namespace = trusted.namespace
    FROM trusted
    WHERE profile.project = trusted.project
      AND profile.host_id IS NULL
      AND profile.client_id IS NULL
      AND profile.scope IS NULL
      AND profile.namespace IS NULL
    """)

    # Actions with source memories can be recovered only when all sources agree.
    execute("""
    WITH trusted AS (
      SELECT action.id,
             min(memory.host_id) AS host_id,
             min(memory.client_id) AS client_id,
             min(memory.scope) AS scope,
             min(memory.namespace) AS namespace
      FROM #{table_name(:memory_actions)} AS action
      JOIN LATERAL unnest(action.source_memory_ids) AS source(memory_id) ON true
      JOIN #{table_name(:bpm_memories)} AS memory ON memory.id = source.memory_id
      WHERE memory.host_id IS NOT NULL
        AND memory.client_id IS NOT NULL
        AND memory.scope IS NOT NULL
        AND memory.namespace IS NOT NULL
      GROUP BY action.id
      HAVING count(*) = cardinality(action.source_memory_ids)
         AND count(DISTINCT (memory.host_id, memory.client_id, memory.scope, memory.namespace)) = 1
    )
    UPDATE #{table_name(:memory_actions)} AS action
    SET host_id = trusted.host_id,
        client_id = trusted.client_id,
        scope = trusted.scope,
        namespace = trusted.namespace
    FROM trusted
    WHERE action.id = trusted.id
    """)

    execute("""
    UPDATE #{table_name(:memory_leases)} AS lease
    SET host_id = action.host_id,
        client_id = action.client_id,
        scope = action.scope,
        namespace = action.namespace
    FROM #{table_name(:memory_actions)} AS action
    WHERE lease.action_id = action.id
      AND action.host_id IS NOT NULL
      AND action.client_id IS NOT NULL
      AND action.scope IS NOT NULL
      AND action.namespace IS NOT NULL
    """)

    # Legacy graph nodes/edges, slots, and signals carry no durable ownership
    # evidence. They intentionally remain NULL so exact-partition reads deny them.
    flush()
    report_partition_outcome()
  end

  def down do
    # Rollback policy: hard stop. Restoring the project/name primary keys could
    # collapse distinct partitioned rows, while NULL-denied legacy ownership
    # cannot be reconstructed. Operators must restore a pre-migration backup.
    raise Ecto.MigrationError,
      message:
        "irreversible migration: ambiguous legacy partition identities are intentionally not reconstructed"
  end

  defp report_partition_outcome do
    Enum.each(@tables, fn table ->
      [[partitioned, denied]] =
        repo().query!("""
        SELECT
          count(*) FILTER (
            WHERE host_id IS NOT NULL
              AND client_id IS NOT NULL
              AND scope IS NOT NULL
              AND namespace IS NOT NULL
          ),
          count(*) FILTER (
            WHERE host_id IS NULL
               OR client_id IS NULL
               OR scope IS NULL
               OR namespace IS NULL
          )
        FROM #{table_name(table)}
        """).rows

      Logger.warning(
        "memory partition migration table=#{table} partitioned=#{partitioned} denied=#{denied}"
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
