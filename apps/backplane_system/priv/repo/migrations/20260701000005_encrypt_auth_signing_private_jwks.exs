defmodule Backplane.Repo.Migrations.EncryptAuthSigningPrivateJwks do
  use Ecto.Migration

  def up do
    alter table(:auth_signing_keys) do
      add :encrypted_private_jwk, :binary
    end

    flush()

    for [id, private_jwk] <- repo().query!("SELECT id, private_jwk FROM auth_signing_keys").rows do
      encrypted =
        private_jwk
        |> Jason.encode!()
        |> Backplane.Settings.Encryption.encrypt()

      repo().query!(
        "UPDATE auth_signing_keys SET encrypted_private_jwk = $1 WHERE id = $2",
        [encrypted, id]
      )
    end

    alter table(:auth_signing_keys) do
      modify :encrypted_private_jwk, :binary, null: false
      remove :private_jwk
    end
  end

  def down do
    alter table(:auth_signing_keys) do
      add :private_jwk, :map
    end

    flush()

    for [id, encrypted] <-
          repo().query!("SELECT id, encrypted_private_jwk FROM auth_signing_keys").rows do
      {:ok, raw_jwk} = Backplane.Settings.Encryption.decrypt(encrypted)
      private_jwk = Jason.decode!(raw_jwk)

      repo().query!(
        "UPDATE auth_signing_keys SET private_jwk = $1 WHERE id = $2",
        [private_jwk, id]
      )
    end

    alter table(:auth_signing_keys) do
      modify :private_jwk, :map, null: false
      remove :encrypted_private_jwk
    end
  end
end
