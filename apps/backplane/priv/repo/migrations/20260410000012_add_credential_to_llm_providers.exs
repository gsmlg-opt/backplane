defmodule Backplane.Repo.Migrations.AddCredentialToLlmProviders do
  use Ecto.Migration

  def change do
    alter table(:llm_providers) do
      add :credential, :text
    end
  end
end
