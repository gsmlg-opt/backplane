defmodule Backplane.Repo.Migrations.CreateMemoryLeases do
  use Ecto.Migration

  def change do
    create table(:memory_leases, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:action_id, :binary_id, null: false)
      add(:holder_agent_id, :text, null: false)
      add(:acquired_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:renewed_at, :utc_datetime_usec)
    end

    create(index(:memory_leases, [:action_id]))
    create(index(:memory_leases, [:expires_at]))
    create(unique_index(:memory_leases, [:action_id], name: :memory_leases_action_id_uniq))
  end
end
