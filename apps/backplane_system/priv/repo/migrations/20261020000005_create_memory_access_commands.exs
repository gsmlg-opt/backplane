defmodule Backplane.Repo.Migrations.CreateMemoryAccessCommands do
  use Ecto.Migration

  def up do
    create table(:bpm_memory_access_commands, primary_key: false, prefix: prefix()) do
      add(:id, :binary_id, primary_key: true)
      add(:host_id, :binary_id, null: false)
      add(:access_id, :binary_id, null: false)
      add(:command_id, :binary_id, null: false)
      add(:memory_space_id, :binary_id, null: false)
      add(:scope, :text, null: false)
      add(:namespace, :text, null: false)
      add(:authority_version, :bigint, null: false)
      add(:operation, :text, null: false)
      add(:payload_digest, :binary, null: false)
      add(:status, :text, null: false)
      add(:canonical_id, :binary_id)
      add(:revision, :bigint)
      add(:error_code, :string, size: 64)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bpm_memory_access_commands, [:host_id, :access_id, :command_id],
             prefix: prefix()
           )

    create constraint(:bpm_memory_access_commands, :bpm_memory_access_commands_shape,
             prefix: prefix(),
             check:
               "authority_version > 0 AND octet_length(payload_digest) = 32 AND operation IN ('remember','forget') AND length(btrim(scope)) > 0 AND length(btrim(namespace)) > 0 AND ((status = 'committed' AND canonical_id IS NOT NULL AND error_code IS NULL AND (revision IS NULL OR revision > 0)) OR (status = 'rejected' AND canonical_id IS NULL AND revision IS NULL AND error_code IS NOT NULL))"
           )

    execute(
      "CREATE TRIGGER bpm_memory_access_commands_immutable BEFORE UPDATE OR DELETE ON #{qualified("bpm_memory_access_commands")} FOR EACH ROW EXECUTE FUNCTION #{qualified("bpm_reject_memory_provenance_mutation")}()"
    )

    execute(
      "CREATE TRIGGER bpm_memory_access_commands_immutable_truncate BEFORE TRUNCATE ON #{qualified("bpm_memory_access_commands")} FOR EACH STATEMENT EXECUTE FUNCTION #{qualified("bpm_reject_memory_provenance_mutation")}()"
    )
  end

  defp qualified(name), do: ~s|"#{prefix() || "public"}"."#{name}"|
end
