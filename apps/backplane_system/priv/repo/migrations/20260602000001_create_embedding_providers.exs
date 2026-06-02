defmodule Backplane.Repo.Migrations.CreateEmbeddingProviders do
  use Ecto.Migration

  def change do
    create table(:embedding_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :credential, :text, null: false
      add :base_url, :text, null: false
      add :default_headers, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:embedding_providers, [:name],
             where: "deleted_at IS NULL",
             name: :embedding_providers_name_index
           )

    create index(:embedding_providers, [:enabled])

    create table(:embedding_models, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :provider_id,
          references(:embedding_providers, type: :binary_id, on_delete: :delete_all),
          null: false

      add :model, :text, null: false
      add :display_name, :text
      add :enabled, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:embedding_models, [:provider_id, :model])
    create index(:embedding_models, [:enabled])
  end
end
