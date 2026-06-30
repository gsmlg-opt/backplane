defmodule Backplane.Repo.Migrations.CreateAuthSigningKeys do
  use Ecto.Migration

  def change do
    create table(:auth_signing_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :kid, :text, null: false
      add :private_jwk, :map, null: false
      add :public_jwk, :map, null: false
      add :active, :boolean, default: true, null: false
      add :retired_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:auth_signing_keys, [:kid])
    create index(:auth_signing_keys, [:active])
  end
end
