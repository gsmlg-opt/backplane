defmodule Backplane.Repo.Migrations.IndexClientCredentials do
  use Ecto.Migration

  def up do
    alter table(:clients) do
      add(:token_digest, :binary)
      remove(:token_hash)
    end

    create(unique_index(:clients, [:token_digest]))

    create(
      constraint(:clients, :clients_token_digest_length,
        check: "token_digest IS NULL OR octet_length(token_digest) = 32"
      )
    )
  end

  def down do
    raise "Client credential invalidation is irreversible; use a digest-compatible release"
  end
end
