defmodule Backplane.Repo.Migrations.CreateLlmModelAliases do
  use Ecto.Migration

  def change do
    create table(:llm_model_aliases, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :alias, :text, null: false
      add :model, :text, null: false
      add :provider_id, references(:llm_providers, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_model_aliases, [:alias])
    create index(:llm_model_aliases, [:provider_id])
  end
end
