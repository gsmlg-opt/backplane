defmodule Backplane.Repo.Migrations.CreateSecrethubPublications do
  use Ecto.Migration

  # Where each credential was published in SecretHub. Holds no secret values or
  # value digests; used to remove paths that are no longer desired.
  def change do
    create table(:secrethub_publications, primary_key: false) do
      add :credential_name, :string, primary_key: true
      add :path, :string, null: false
      add :version, :integer
      add :synced_at, :utc_datetime_usec
      add :last_attempt_at, :utc_datetime_usec, null: false
      add :last_error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:secrethub_publications, [:path])
  end
end
