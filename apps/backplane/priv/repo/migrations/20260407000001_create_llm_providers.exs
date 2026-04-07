defmodule Backplane.Repo.Migrations.CreateLlmProviders do
  use Ecto.Migration

  def change do
    create table(:llm_providers, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :api_type, :text, null: false
      add :api_url, :text, null: false
      add :api_key_encrypted, :bytea, null: false
      add :models, {:array, :text}, null: false
      add :default_headers, :map, default: %{}
      add :rpm_limit, :integer
      add :enabled, :boolean, default: true, null: false
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_providers, [:name], where: "deleted_at IS NULL", name: :llm_providers_name_active_index)
    create index(:llm_providers, [:api_type, :enabled])

    execute(
      "CREATE INDEX llm_providers_models_gin ON llm_providers USING GIN (models)",
      "DROP INDEX llm_providers_models_gin"
    )
  end
end
