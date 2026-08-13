defmodule Backplane.Repo.Migrations.CreateMemoryEvidenceAndRememberRequests do
  use Ecto.Migration

  def up do
    create table(:bpm_memory_remember_requests, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:idempotency_scope, :text, null: false)
      add(:idempotency_key, :text, null: false)
      add(:request_hash, :binary, null: false)

      add(:memory_id, references(:bpm_memories, type: :binary_id, on_delete: :restrict),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:bpm_memory_remember_requests, [:idempotency_scope, :idempotency_key],
        name: :bpm_memory_remember_requests_scope_key_uniq
      )
    )

    create(
      constraint(:bpm_memory_remember_requests, :bpm_memory_remember_requests_scope_nonempty,
        check: "btrim(idempotency_scope) <> ''"
      )
    )

    create(
      constraint(:bpm_memory_remember_requests, :bpm_memory_remember_requests_key_nonempty,
        check: "btrim(idempotency_key) <> ''"
      )
    )

    create(
      constraint(:bpm_memory_remember_requests, :bpm_memory_remember_requests_hash_length,
        check: "octet_length(request_hash) = 32"
      )
    )

    create table(:bpm_memory_evidence, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:memory_id, references(:bpm_memories, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:source_event_id, references(:bpm_events, type: :binary_id, on_delete: :restrict))

      add(
        :source_observation_id,
        references(:bpm_observations, type: :binary_id, on_delete: :restrict)
      )

      add(
        :source_summary_id,
        references(:memory_summaries, type: :binary_id, on_delete: :restrict)
      )

      add(
        :source_request_id,
        references(:bpm_memory_remember_requests, type: :binary_id, on_delete: :restrict)
      )

      add(:source_session_id, :text)
      add(:session_id, :text)
      add(:agent_id, :text)
      add(:host_id, :text)
      add(:evidence_kind, :text, null: false)
      add(:support_score, :float, null: false)
      add(:excerpt, :text)
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      constraint(:bpm_memory_evidence, :bpm_memory_evidence_kind_check,
        check: "evidence_kind IN ('supports', 'contradicts', 'derives', 'confirms', 'applies')"
      )
    )

    create(
      constraint(:bpm_memory_evidence, :bpm_memory_evidence_score_check,
        check: "support_score >= 0.0 AND support_score <= 1.0"
      )
    )

    create(
      constraint(:bpm_memory_evidence, :bpm_memory_evidence_source_check,
        check: """
        num_nonnulls(source_event_id, source_observation_id, source_summary_id, source_request_id)
          + CASE WHEN source_session_id IS NULL THEN 0 ELSE 1 END = 1
        AND (source_session_id IS NULL
          OR (btrim(source_session_id) <> '' AND host_id IS NOT NULL AND btrim(host_id) <> ''))
        """
      )
    )

    create(
      unique_index(:bpm_memory_evidence, [:source_event_id, :memory_id],
        where: "source_event_id IS NOT NULL",
        name: :bpm_memory_evidence_event_source_uniq
      )
    )

    create(
      unique_index(:bpm_memory_evidence, [:source_observation_id, :memory_id],
        where: "source_observation_id IS NOT NULL",
        name: :bpm_memory_evidence_observation_source_uniq
      )
    )

    create(
      unique_index(:bpm_memory_evidence, [:source_summary_id, :memory_id],
        where: "source_summary_id IS NOT NULL",
        name: :bpm_memory_evidence_summary_source_uniq
      )
    )

    create(
      unique_index(:bpm_memory_evidence, [:source_request_id, :memory_id],
        where: "source_request_id IS NOT NULL",
        name: :bpm_memory_evidence_request_source_uniq
      )
    )

    create(
      unique_index(
        :bpm_memory_evidence,
        [:host_id, :source_session_id, :memory_id],
        where: "source_session_id IS NOT NULL",
        name: :bpm_memory_evidence_session_source_uniq
      )
    )

    create(
      index(:bpm_memory_evidence, [:memory_id, :created_at, :id],
        name: :bpm_memory_evidence_memory_created_id_idx
      )
    )

    execute("""
    CREATE FUNCTION #{qualified("bpm_reject_memory_provenance_mutation")}()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'memory provenance rows are immutable'
        USING ERRCODE = '55000';
    END;
    $$
    """)

    for table <- ["bpm_memory_remember_requests", "bpm_memory_evidence"] do
      execute("""
      CREATE TRIGGER #{table}_immutable_row
      BEFORE UPDATE OR DELETE ON #{qualified(table)}
      FOR EACH ROW EXECUTE FUNCTION #{qualified("bpm_reject_memory_provenance_mutation")}()
      """)

      execute("""
      CREATE TRIGGER #{table}_immutable_truncate
      BEFORE TRUNCATE ON #{qualified(table)}
      FOR EACH STATEMENT EXECUTE FUNCTION #{qualified("bpm_reject_memory_provenance_mutation")}()
      """)
    end
  end

  def down do
    for table <- ["bpm_memory_evidence", "bpm_memory_remember_requests"] do
      execute("DROP TRIGGER IF EXISTS #{table}_immutable_truncate ON #{qualified(table)}")
      execute("DROP TRIGGER IF EXISTS #{table}_immutable_row ON #{qualified(table)}")
    end

    execute("DROP FUNCTION IF EXISTS #{qualified("bpm_reject_memory_provenance_mutation")}()")
    drop(table(:bpm_memory_evidence))
    drop(table(:bpm_memory_remember_requests))
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end
end
