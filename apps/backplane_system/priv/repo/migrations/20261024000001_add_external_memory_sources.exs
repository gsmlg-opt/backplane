defmodule Backplane.Repo.Migrations.AddExternalMemorySources do
  use Ecto.Migration

  def up do
    create table(:bpm_memory_sources, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :memory_space_id,
        references(:bpm_memory_spaces, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:scope, :text, null: false)
      add(:namespace, :text, null: false)
      add(:host_id, :text, null: false)
      add(:integration, :text, null: false)
      add(:installation_id, :binary_id, null: false)
      add(:profile_id, :text, null: false)
      add(:target, :text, null: false)
      add(:revision_floor, :bigint, null: false, default: 0)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :bpm_memory_sources,
             [
               :memory_space_id,
               :scope,
               :namespace,
               :host_id,
               :integration,
               :installation_id,
               :profile_id,
               :target
             ],
             name: :bpm_memory_sources_identity_uniq
           )

    create table(:bpm_memory_source_mutations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:source_id, references(:bpm_memory_sources, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:entry_id, :binary_id, null: false)
      add(:revision, :bigint, null: false)
      add(:operation, :text, null: false)
      add(:payload_digest, :text, null: false)
      add(:provenance, :map, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:memory_id, references(:bpm_memories, type: :binary_id, on_delete: :restrict))
      add(:outcome, :text, null: false)
      add(:edge_revision, :bigint)
      timestamps(type: :utc_datetime_usec)
    end

    create index(:bpm_memory_source_mutations, [:source_id, :entry_id, :revision])

    create table(:bpm_memory_source_entries, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:source_id, references(:bpm_memory_sources, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:entry_id, :binary_id, null: false)
      add(:revision, :bigint, null: false)

      add(
        :mutation_id,
        references(:bpm_memory_source_mutations, type: :binary_id, on_delete: :restrict)
      )

      add(:memory_id, references(:bpm_memories, type: :binary_id, on_delete: :restrict))
      add(:active, :boolean, null: false, default: false)
      add(:suppressed, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bpm_memory_source_entries, [:source_id, :entry_id])
    create index(:bpm_memory_source_entries, [:memory_id], where: "active")

    create constraint(:bpm_memory_source_entries, :bpm_memory_source_entry_active_check,
             check:
               "NOT active OR (memory_id IS NOT NULL AND mutation_id IS NOT NULL AND NOT suppressed)"
           )

    create table(:bpm_memory_source_reconciliations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:source_id, references(:bpm_memory_sources, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:revision, :bigint, null: false)
      add(:page_count, :integer, null: false)
      add(:entry_count, :integer, null: false)
      add(:snapshot_hash, :text, null: false)
      add(:status, :text, null: false, default: "staging")
      add(:result, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create index(:bpm_memory_source_reconciliations, [:source_id, :status])

    create table(:bpm_memory_source_reconciliation_pages, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :reconciliation_id,
        references(:bpm_memory_source_reconciliations, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:page_index, :integer, null: false)
      add(:page_hash, :text, null: false)
      add(:entries, {:array, :map}, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bpm_memory_source_reconciliation_pages, [:reconciliation_id, :page_index])

    alter table(:bpm_memory_evidence) do
      add(
        :source_mutation_id,
        references(:bpm_memory_source_mutations, type: :binary_id, on_delete: :restrict)
      )
    end

    drop constraint(:bpm_memory_evidence, :bpm_memory_evidence_source_check)

    create constraint(:bpm_memory_evidence, :bpm_memory_evidence_source_check,
             check:
               "num_nonnulls(source_event_id, source_observation_id, source_summary_id, source_request_id, source_crystal_id, source_mutation_id, source_session_id) = 1 AND (source_session_id IS NULL OR (btrim(source_session_id) <> '' AND nullif(btrim(host_id), '') IS NOT NULL))"
           )

    create unique_index(:bpm_memory_evidence, [:source_mutation_id, :memory_id],
             where: "source_mutation_id IS NOT NULL",
             name: :bpm_memory_evidence_mutation_source_uniq
           )

    alter table(:bpm_memory_remember_requests) do
      add(:origin, :text, null: false, default: "direct")
    end

    create constraint(:bpm_memory_remember_requests, :bpm_memory_request_origin_check,
             check: "origin IN ('direct','external_source','derived')"
           )

    create table(:bpm_memory_request_evidence, primary_key: false) do
      add(
        :request_id,
        references(:bpm_memory_remember_requests, type: :binary_id, on_delete: :restrict),
        primary_key: true
      )

      add(:evidence_id, references(:bpm_memory_evidence, type: :binary_id, on_delete: :restrict),
        primary_key: true
      )
    end

    alter table(:bpm_memories) do
      add(:effective_support, :boolean, null: false, default: true)
    end

    flush()
    p = quote_name(prefix() || "public")

    execute("""
    CREATE FUNCTION #{p}.bpm_memory_mutation_evidence_partition() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.source_mutation_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM #{p}.bpm_memory_source_mutations mu
        JOIN #{p}.bpm_memory_sources s ON s.id=mu.source_id
        JOIN #{p}.bpm_memories m ON m.id=NEW.memory_id
        WHERE mu.id=NEW.source_mutation_id AND s.memory_space_id=m.memory_space_id
          AND s.host_id=m.host_id AND s.scope=m.scope AND s.namespace=m.namespace
          AND NEW.host_id=s.host_id
      ) THEN RAISE EXCEPTION 'source evidence partition mismatch' USING ERRCODE='23514', CONSTRAINT='bpm_memory_evidence_canonical_partition'; END IF;
      RETURN NEW;
    END $$
    """)

    execute(
      "CREATE TRIGGER bpm_memory_mutation_evidence_partition BEFORE INSERT ON #{p}.bpm_memory_evidence FOR EACH ROW EXECUTE FUNCTION #{p}.bpm_memory_mutation_evidence_partition()"
    )
  end

  def down do
    raise Ecto.MigrationError,
      message: "forward-only: source withdrawals and provenance cannot safely be discarded"
  end

  defp quote_name(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
