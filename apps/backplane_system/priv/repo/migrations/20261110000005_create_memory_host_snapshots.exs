defmodule Backplane.Repo.Migrations.CreateMemoryHostSnapshots do
  use Ecto.Migration

  def change do
    create table(:memory_host_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :host_id, :text, null: false
      add :collector, :text, null: false
      add :unit, :text, null: false
      add :collected_at, :utc_datetime_usec
      add :event_id, :binary_id
      add :slots, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memory_host_snapshots, [:host_id, :collector, :unit])
  end
end
