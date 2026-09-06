defmodule Backplane.Repo.Migrations.AddMemorySpaceIdentity do
  use Ecto.Migration

  @roots ~w(
    bpm_events
    bpm_streams
    bpm_memories
    bpm_observations
    memory_sessions
    bpm_projected_observations
    bpm_projected_sessions
    memory_summaries
    memory_crystals
    memory_profiles
    memory_graph_nodes
    memory_graph_edges
    memory_activity_daily
    memory_activity_subject_contributions
    memory_replay_events
    memory_recall_runs
    memory_actions
    memory_leases
    memory_signals
    memory_slots
    memory_import_batches
    bpm_projection_states
    bpm_projection_snapshots
    bpm_host_memory_revocations
  )

  @missing_host ~w(
    bpm_observations
    memory_sessions
    bpm_projection_states
    bpm_projection_snapshots
  )

  @missing_scope ~w(
    bpm_streams
    bpm_observations
    memory_sessions
    memory_summaries
    memory_import_batches
    bpm_projection_states
    bpm_projection_snapshots
  )

  @missing_namespace @missing_scope ++ ["bpm_host_memory_revocations"]

  def up do
    Enum.each(@roots, &add_owner_columns/1)
    Enum.each(@missing_host, &add_text_column(&1, :host_id))
    Enum.each(@roots, &add_text_column(&1, :source_client_id))
    Enum.each(@missing_scope, &add_text_column(&1, :scope))
    Enum.each(@missing_namespace, &add_text_column(&1, :namespace))

    install_activity_canonical_keys()
    install_canonical_unique_indexes()
    execute(derivation_function_sql())

    Enum.each(@roots, fn table_name ->
      execute(create_trigger_sql(table_name))
      execute(add_check_sql(table_name, "memory_space_id", "memory_space_id IS NOT NULL"))

      execute(
        add_check_sql(table_name, "scope", "scope IS NOT NULL AND length(btrim(scope)) > 0")
      )

      execute(
        add_check_sql(
          table_name,
          "namespace",
          "namespace IS NOT NULL AND length(btrim(namespace)) > 0"
        )
      )
    end)
  end

  def down do
    Enum.each(@roots, fn table_name ->
      execute(drop_trigger_sql(table_name))
      execute(drop_check_sql(table_name, "namespace"))
      execute(drop_check_sql(table_name, "scope"))
      execute(drop_check_sql(table_name, "memory_space_id"))
    end)

    execute("DROP FUNCTION IF EXISTS #{qualified("bpm_derive_memory_space_identity")}()")

    restore_legacy_unique_indexes()
    restore_activity_legacy_keys()
    Enum.each(Enum.reverse(@missing_namespace), &remove_column(&1, :namespace))
    Enum.each(Enum.reverse(@missing_scope), &remove_column(&1, :scope))
    Enum.each(Enum.reverse(@roots), &remove_column(&1, :source_client_id))
    Enum.each(Enum.reverse(@missing_host), &remove_column(&1, :host_id))
    Enum.each(Enum.reverse(@roots), &remove_column(&1, :memory_space_id))
  end

  defp add_owner_columns(table_name) do
    alter table(table_name, prefix: prefix()) do
      add(
        :memory_space_id,
        references(:bpm_memory_spaces,
          type: :binary_id,
          on_delete: :restrict,
          prefix: prefix()
        )
      )
    end
  end

  defp install_activity_canonical_keys do
    execute(
      activity_key_sql(
        "memory_activity_daily",
        ~w(date project agent_id host_id client_id scope namespace event_type)
      )
    )

    execute(
      activity_key_sql(
        "memory_activity_subject_contributions",
        ~w(subject_id date project agent_id host_id client_id scope namespace event_type)
      )
    )
  end

  defp activity_key_sql(table_name, legacy_columns) do
    table = qualified(table_name)
    schema_name = escape_literal(prefix() || "public")
    key_columns = Enum.map_join(["memory_space_id" | legacy_columns], ", ", &quote_name/1)
    index_name = quote_name(table_name <> "_canonical_key_idx")
    primary_key = quote_name(table_name <> "_pkey")

    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{schema_name}' AND table_name = '#{escape_literal(table_name)}'
          AND column_name = 'date'
      ) THEN
        ALTER TABLE #{table} DROP CONSTRAINT IF EXISTS #{primary_key};
        CREATE UNIQUE INDEX IF NOT EXISTS #{index_name} ON #{table} (#{key_columns});
      END IF;
    END;
    $$
    """
  end

  defp restore_activity_legacy_keys do
    execute(
      restore_activity_key_sql(
        "memory_activity_daily",
        ~w(date project agent_id host_id client_id scope namespace event_type)
      )
    )

    execute(
      restore_activity_key_sql(
        "memory_activity_subject_contributions",
        ~w(subject_id date project agent_id host_id client_id scope namespace event_type)
      )
    )
  end

  defp install_canonical_unique_indexes do
    execute(
      rekey_unique_index_sql(
        "memory_profiles",
        "memory_profiles_partition_project_uniq",
        ~w(memory_space_id host_id client_id scope namespace project),
        "project"
      )
    )

    execute(
      rekey_unique_index_sql(
        "memory_slots",
        "memory_slots_partition_name_uniq",
        ~w(memory_space_id host_id client_id scope namespace name),
        "name"
      )
    )
  end

  defp restore_legacy_unique_indexes do
    execute(
      rekey_unique_index_sql(
        "memory_profiles",
        "memory_profiles_partition_project_uniq",
        ~w(host_id client_id scope namespace project),
        "project"
      )
    )

    execute(
      rekey_unique_index_sql(
        "memory_slots",
        "memory_slots_partition_name_uniq",
        ~w(host_id client_id scope namespace name),
        "name"
      )
    )
  end

  defp rekey_unique_index_sql(table_name, index_name, columns, marker_column) do
    schema_name = escape_literal(prefix() || "public")
    index = qualified(index_name)
    table = qualified(table_name)
    key_columns = Enum.map_join(columns, ", ", &quote_name/1)

    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{schema_name}' AND table_name = '#{escape_literal(table_name)}'
          AND column_name = '#{escape_literal(marker_column)}'
      ) THEN
        DROP INDEX IF EXISTS #{index};
        CREATE UNIQUE INDEX #{quote_name(index_name)} ON #{table} (#{key_columns});
      END IF;
    END;
    $$
    """
  end

  defp restore_activity_key_sql(table_name, legacy_columns) do
    table = qualified(table_name)
    schema_name = escape_literal(prefix() || "public")
    key_columns = Enum.map_join(legacy_columns, ", ", &quote_name/1)
    primary_key = quote_name(table_name <> "_pkey")

    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{schema_name}' AND table_name = '#{escape_literal(table_name)}'
          AND column_name = 'date'
      ) THEN
        DROP INDEX IF EXISTS #{qualified(table_name <> "_canonical_key_idx")};
        ALTER TABLE #{table} ADD CONSTRAINT #{primary_key} PRIMARY KEY (#{key_columns});
      END IF;
    END;
    $$
    """
  end

  defp add_text_column(table_name, column_name) do
    alter table(table_name, prefix: prefix()) do
      add(column_name, :text)
    end
  end

  defp remove_column(table_name, column_name) do
    alter table(table_name, prefix: prefix()) do
      remove(column_name)
    end
  end

  defp derivation_function_sql do
    function = qualified("bpm_derive_memory_space_identity")
    aliases = qualified("bpm_memory_space_legacy_aliases")
    spaces = qualified("bpm_memory_spaces")
    entitlements = qualified("bpm_memory_space_entitlements")

    """
    CREATE OR REPLACE FUNCTION #{function}()
    RETURNS trigger AS $$
    DECLARE
      candidate_count integer;
      candidate_space_id uuid;
      candidate_scope text;
      candidate_namespace text;
    BEGIN
      IF NEW.memory_space_id IS NULL AND NEW.host_id IS NOT NULL THEN
        SELECT count(*), min(matches.memory_space_id::text)::uuid,
               min(matches.scope), min(matches.namespace)
        INTO candidate_count, candidate_space_id, candidate_scope, candidate_namespace
        FROM (
          SELECT DISTINCT alias_row.memory_space_id, entitlement.scope, entitlement.namespace
          FROM #{aliases} AS alias_row
          JOIN #{spaces} AS space
            ON space.id = alias_row.memory_space_id AND space.status = 'active'
          JOIN #{entitlements} AS entitlement
            ON entitlement.memory_space_id = alias_row.memory_space_id
           AND entitlement.host_id::text = NEW.host_id::text
           AND entitlement.status = 'active'
          WHERE alias_row.alias_type = 'host'
            AND alias_row.alias_value = 'host:' || NEW.host_id::text
            AND (NEW.scope IS NULL OR entitlement.scope = NEW.scope)
            AND (NEW.namespace IS NULL OR entitlement.namespace = NEW.namespace)
        ) AS matches;

        IF candidate_count = 1 THEN
          NEW.memory_space_id := candidate_space_id;
          NEW.scope := coalesce(NEW.scope, candidate_scope);
          NEW.namespace := coalesce(NEW.namespace, candidate_namespace);
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """
  end

  defp create_trigger_sql(table_name) do
    """
    CREATE TRIGGER #{quote_name(table_name <> "_derive_memory_space_identity")}
    BEFORE INSERT OR UPDATE ON #{qualified(table_name)}
    FOR EACH ROW
    EXECUTE FUNCTION #{qualified("bpm_derive_memory_space_identity")}()
    """
  end

  defp drop_trigger_sql(table_name) do
    "DROP TRIGGER IF EXISTS #{quote_name(table_name <> "_derive_memory_space_identity")} ON #{qualified(table_name)}"
  end

  defp add_check_sql(table_name, suffix, expression) do
    constraint_name = table_name <> "_canonical_" <> suffix

    "ALTER TABLE #{qualified(table_name)} ADD CONSTRAINT #{quote_name(constraint_name)} CHECK (#{expression}) NOT VALID"
  end

  defp drop_check_sql(table_name, suffix) do
    constraint_name = table_name <> "_canonical_" <> suffix

    "ALTER TABLE #{qualified(table_name)} DROP CONSTRAINT IF EXISTS #{quote_name(constraint_name)}"
  end

  defp qualified(name) do
    [prefix() || "public", name]
    |> Enum.map_join(".", &quote_name/1)
  end

  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
  defp escape_literal(value), do: String.replace(value, "'", "''")
end
