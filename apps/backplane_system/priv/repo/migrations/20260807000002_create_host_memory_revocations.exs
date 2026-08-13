defmodule Backplane.Repo.Migrations.CreateHostMemoryRevocations do
  use Ecto.Migration

  def up do
    create table(:bpm_host_memory_revocations, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:host_id, :text, null: false)
      add(:local_id, :text, null: false)

      add(:memory_id, references(:bpm_memories, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(
        :source_request_id,
        references(:bpm_memory_remember_requests, type: :binary_id, on_delete: :restrict)
      )

      add(:scope, :text, null: false)
      add(:content_hash, :binary, null: false)
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create unique_index(:bpm_host_memory_revocations, [:host_id, :local_id])

    create unique_index(:bpm_host_memory_revocations, [:source_request_id],
             where: "source_request_id IS NOT NULL"
           )

    create constraint(:bpm_host_memory_revocations, :bpm_host_memory_revocations_nonempty,
             check:
               "btrim(host_id) <> '' AND btrim(local_id) <> '' AND btrim(scope) <> '' AND octet_length(content_hash) = 32"
           )

    execute("""
    CREATE TRIGGER bpm_host_memory_revocations_immutable_row
    BEFORE UPDATE OR DELETE ON #{qualified("bpm_host_memory_revocations")}
    FOR EACH ROW EXECUTE FUNCTION #{qualified("bpm_reject_memory_provenance_mutation")}()
    """)

    execute("""
    CREATE TRIGGER bpm_host_memory_revocations_immutable_truncate
    BEFORE TRUNCATE ON #{qualified("bpm_host_memory_revocations")}
    FOR EACH STATEMENT EXECUTE FUNCTION #{qualified("bpm_reject_memory_provenance_mutation")}()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS bpm_host_memory_revocations_immutable_truncate ON #{qualified("bpm_host_memory_revocations")}"
    )

    execute(
      "DROP TRIGGER IF EXISTS bpm_host_memory_revocations_immutable_row ON #{qualified("bpm_host_memory_revocations")}"
    )

    drop table(:bpm_host_memory_revocations)
  end

  defp qualified(name) do
    [prefix(), name]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(".", fn identifier ->
      ~s("#{identifier |> to_string() |> String.replace("\"", "\"\"")}")
    end)
  end
end
