defmodule Backplane.Repo.Migrations.ExtendSourceCommandReceipts do
  use Ecto.Migration

  def up do
    alter table(:bpm_memory_access_commands), do: add(:result, :map, null: false, default: %{})
    drop constraint(:bpm_memory_access_commands, :bpm_memory_access_commands_shape)

    create constraint(:bpm_memory_access_commands, :bpm_memory_access_commands_shape,
             check:
               "authority_version > 0 AND octet_length(payload_digest) = 32 AND operation IN ('remember','forget','source_mutate','source_reconcile') AND length(btrim(scope)) > 0 AND length(btrim(namespace)) > 0 AND ((status='committed' AND error_code IS NULL AND (revision IS NULL OR revision>0) AND (canonical_id IS NOT NULL OR operation IN ('source_mutate','source_reconcile'))) OR (status='rejected' AND canonical_id IS NULL AND revision IS NULL AND error_code IS NOT NULL))"
           )
  end

  def down, do: raise(Ecto.MigrationError, message: "forward-only source command receipts")
end
