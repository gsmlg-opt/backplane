defmodule Backplane.Repo.Migrations.CreateClients do
  use Ecto.Migration

  def change do
    create table(:clients, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :token_hash, :text, null: false
      add :scopes, {:array, :text}, default: []
      add :active, :boolean, default: true
      add :last_seen_at, :utc_datetime_usec
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:clients, [:name])
  end
end
