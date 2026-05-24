defmodule Backplane.Repo.Migrations.CreateMemoryAuditLog do
  use Ecto.Migration

  def change do
    create table(:memory_audit_log, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:operation, :text, null: false)
      add(:actor, :text)
      add(:target_ids, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:memory_audit_log, [:operation]))
    create(index(:memory_audit_log, [:created_at]))
  end
end
