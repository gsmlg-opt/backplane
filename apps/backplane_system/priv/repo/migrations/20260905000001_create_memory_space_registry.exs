defmodule Backplane.Repo.Migrations.CreateMemorySpaceRegistry do
  use Ecto.Migration

  def up do
    create table(:bpm_memory_spaces, primary_key: false, prefix: prefix()) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:kind, :text, null: false)
      add(:status, :text, null: false, default: "active")
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:bpm_memory_spaces, :bpm_memory_spaces_kind_check,
        prefix: prefix(),
        check: "kind IN ('private', 'shared')"
      )
    )

    create(
      constraint(:bpm_memory_spaces, :bpm_memory_spaces_status_check,
        prefix: prefix(),
        check: "status IN ('active', 'disabled')"
      )
    )

    create table(:bpm_memory_space_entitlements, primary_key: false, prefix: prefix()) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :memory_space_id,
        references(:bpm_memory_spaces,
          type: :binary_id,
          on_delete: :restrict,
          prefix: prefix()
        ),
        null: false
      )

      add(:host_id, :binary_id, null: false)

      add(:scope, :text, null: false)
      add(:namespace, :text, null: false, default: "private")
      add(:default_capture, :boolean, null: false, default: false)
      add(:status, :text, null: false, default: "active")
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :bpm_memory_space_entitlements,
        [:memory_space_id, :host_id, :scope, :namespace],
        name: :bpm_memory_space_entitlements_partition_index,
        prefix: prefix()
      )
    )

    create(
      index(:bpm_memory_space_entitlements, [:host_id, :status],
        name: :bpm_memory_space_entitlements_host_status_index,
        prefix: prefix()
      )
    )

    create(
      unique_index(:bpm_memory_space_entitlements, [:host_id, :namespace],
        name: :bpm_memory_space_entitlements_active_default_index,
        where: "status = 'active' AND default_capture = true",
        prefix: prefix()
      )
    )

    create(
      constraint(:bpm_memory_space_entitlements, :bpm_memory_space_entitlements_scope_check,
        prefix: prefix(),
        check: "length(btrim(scope)) > 0"
      )
    )

    create(
      constraint(
        :bpm_memory_space_entitlements,
        :bpm_memory_space_entitlements_namespace_check,
        prefix: prefix(),
        check: "length(btrim(namespace)) > 0"
      )
    )

    create(
      constraint(:bpm_memory_space_entitlements, :bpm_memory_space_entitlements_status_check,
        prefix: prefix(),
        check: "status IN ('active', 'revoked')"
      )
    )

    create table(:bpm_memory_space_legacy_aliases, primary_key: false, prefix: prefix()) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:alias_type, :text, null: false)
      add(:alias_value, :text, null: false)

      add(
        :memory_space_id,
        references(:bpm_memory_spaces,
          type: :binary_id,
          on_delete: :restrict,
          prefix: prefix()
        ),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:bpm_memory_space_legacy_aliases, [:alias_type, :alias_value],
        name: :bpm_memory_space_legacy_aliases_identity_index,
        prefix: prefix()
      )
    )

    create(
      index(:bpm_memory_space_legacy_aliases, [:memory_space_id],
        name: :bpm_memory_space_legacy_aliases_space_index,
        prefix: prefix()
      )
    )

    create(
      constraint(:bpm_memory_space_legacy_aliases, :bpm_memory_space_legacy_aliases_type_check,
        prefix: prefix(),
        check: "length(btrim(alias_type)) > 0"
      )
    )

    create(
      constraint(:bpm_memory_space_legacy_aliases, :bpm_memory_space_legacy_aliases_value_check,
        prefix: prefix(),
        check: "length(btrim(alias_value)) > 0"
      )
    )

    create table(:bpm_memory_space_backfill_issues, primary_key: false, prefix: prefix()) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:source_table, :text, null: false)
      add(:source_id, :text, null: false)
      add(:reason, :text, null: false)
      add(:disposition, :text, null: false, default: "pending")
      add(:details, :map, null: false, default: %{})
      add(:resolved_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:bpm_memory_space_backfill_issues, [:source_table, :source_id],
        name: :bpm_memory_space_backfill_issues_source_index,
        prefix: prefix()
      )
    )

    create(
      constraint(
        :bpm_memory_space_backfill_issues,
        :bpm_memory_space_backfill_issues_disposition_check,
        prefix: prefix(),
        check: "disposition IN ('pending', 'resolved', 'approved_waiver')"
      )
    )

    execute(legacy_host_lock_sql(prefix()))
    execute(space_backfill_sql(prefix()))
    execute(alias_backfill_sql(prefix()))
    execute(entitlement_backfill_sql(prefix()))
  end

  @doc false
  def provision_existing_hosts(repo, migration_prefix) do
    {:ok, :ok} =
      repo.transaction(fn ->
        repo.query!(legacy_host_lock_sql(migration_prefix))
        repo.query!(space_backfill_sql(migration_prefix))
        repo.query!(alias_backfill_sql(migration_prefix))
        repo.query!(entitlement_backfill_sql(migration_prefix))
        :ok
      end)

    :ok
  end

  @doc false
  def legacy_host_lock_sql(migration_prefix) do
    "LOCK TABLE #{qualified(migration_prefix, "skill_hosts")} IN SHARE ROW EXCLUSIVE MODE"
  end

  defp space_backfill_sql(migration_prefix) do
    """
    INSERT INTO #{qualified(migration_prefix, "bpm_memory_spaces")}
      (id, kind, status, inserted_at, updated_at)
    SELECT md5('backplane-memory-space:host:' || host.id::text)::uuid,
           'private', 'active', now(), now()
    FROM #{qualified(migration_prefix, "skill_hosts")} AS host
    ON CONFLICT (id) DO NOTHING
    """
  end

  defp alias_backfill_sql(migration_prefix) do
    """
    INSERT INTO #{qualified(migration_prefix, "bpm_memory_space_legacy_aliases")}
      (alias_type, alias_value, memory_space_id, inserted_at, updated_at)
    SELECT 'host', 'host:' || host.id::text,
           md5('backplane-memory-space:host:' || host.id::text)::uuid,
           now(), now()
    FROM #{qualified(migration_prefix, "skill_hosts")} AS host
    ON CONFLICT (alias_type, alias_value) DO NOTHING
    """
  end

  defp entitlement_backfill_sql(migration_prefix) do
    """
    INSERT INTO #{qualified(migration_prefix, "bpm_memory_space_entitlements")}
      (memory_space_id, host_id, scope, namespace, default_capture, status,
       inserted_at, updated_at)
    SELECT md5('backplane-memory-space:host:' || host.id::text)::uuid,
           host.id, btrim(host.memory_scope), 'private', true, 'active', now(), now()
    FROM #{qualified(migration_prefix, "skill_hosts")} AS host
    ON CONFLICT (memory_space_id, host_id, scope, namespace) DO NOTHING
    """
  end

  defp qualified(migration_prefix, table_name) do
    [migration_prefix || "public", table_name]
    |> Enum.map_join(".", &quote_name/1)
  end

  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
end
