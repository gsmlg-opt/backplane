defmodule Backplane.Repo.Migrations.CreateEndpoints do
  use Ecto.Migration

  def change do
    create table(:endpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :enabled, :boolean, null: false, default: true
      add :mcp_enabled, :boolean, null: false, default: false
      add :llm_enabled, :boolean, null: false, default: false
      add :mcp_prefixes, {:array, :text}, null: false, default: []
      add :models, {:array, :text}, null: false, default: []
      add :restrict_clients, :boolean, null: false, default: false
      add :oauth_client_ids, {:array, :text}, null: false, default: []
      add :client_ids, {:array, :uuid}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:endpoints, [:name])
  end
end
