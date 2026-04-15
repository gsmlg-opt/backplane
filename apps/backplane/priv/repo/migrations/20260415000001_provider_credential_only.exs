defmodule Backplane.Repo.Migrations.ProviderCredentialOnly do
  use Ecto.Migration

  def up do
    alter table(:llm_providers) do
      remove :api_key_encrypted
    end
  end

  def down do
    alter table(:llm_providers) do
      add :api_key_encrypted, :bytea
    end
  end
end
