defmodule Backplane.Repo.Migrations.CreateMemoryImportBatches do
  use Ecto.Migration

  def change do
    create table(:memory_import_batches, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:host_id, references(:skill_hosts, type: :binary_id, on_delete: :restrict), null: false)
      add(:integration, :text, null: false)
      add(:source_format, :text, null: false)
      add(:source_path_fingerprint, :text, null: false)
      add(:status, :text, null: false)
      add(:discovered_count, :bigint, null: false, default: 0)
      add(:imported_count, :bigint, null: false, default: 0)
      add(:duplicate_count, :bigint, null: false, default: 0)
      add(:rejected_count, :bigint, null: false, default: 0)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:completed_at, :utc_datetime_usec)
      add(:error, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:memory_import_batches, [:host_id, :started_at]))
    create(index(:memory_import_batches, [:source_path_fingerprint]))

    create(
      constraint(:memory_import_batches, :memory_import_batches_status_check,
        check: "status IN ('started', 'completed', 'failed')"
      )
    )

    create(
      constraint(:memory_import_batches, :memory_import_batches_counts_check,
        check:
          "discovered_count >= 0 AND imported_count >= 0 AND duplicate_count >= 0 AND rejected_count >= 0"
      )
    )
  end
end
