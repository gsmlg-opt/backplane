defmodule Backplane.Repo.Migrations.IndexMemoryRecordsHostUpdated do
  use Ecto.Migration

  def change do
    create index(:memory_records, [:host_id, :updated_at, :id])
  end
end
