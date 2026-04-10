defmodule Backplane.Repo.Migrations.CreateLlmProviders do
  use Ecto.Migration

  def change do
    create table(:llm_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :api_type, :text, null: false
      add :api_url, :text, null: false
      add :api_key_encrypted, :bytea
      add :models, {:array, :text}, default: []
      add :default_headers, :map, default: %{}
      add :rpm_limit, :integer
      add :enabled, :boolean, default: true
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_providers, [:name], where: "deleted_at IS NULL")
    create index(:llm_providers, [:api_type, :enabled])
    create index(:llm_providers, [:models], using: :gin)
  end
end
