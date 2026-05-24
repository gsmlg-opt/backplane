defmodule Backplane.Repo.Migrations.CreateCredentials do
  use Ecto.Migration

  def change do
    create table(:credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :kind, :text, null: false
      add :encrypted_value, :bytea, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:credentials, [:name])
    create index(:credentials, [:kind])
  end
end
