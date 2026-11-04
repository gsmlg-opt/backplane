defmodule Backplane.Repo.Migrations.CreateLlmResponseRoutes do
  use Ecto.Migration

  def change do
    alter table(:llm_provider_apis) do
      add :responses_lifecycle, :boolean, null: false, default: false
      add :responses_route_ttl_seconds, :integer, null: false, default: 86_400
    end

    create constraint(:llm_provider_apis, :responses_route_ttl_seconds_range,
             check: "responses_route_ttl_seconds BETWEEN 60 AND 2592000"
           )

    create table(:llm_response_routes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_hash, :text, null: false
      add :response_id, :text
      # Keep tombstones when providers, APIs or credentials are removed. Lookup
      # then fails closed rather than reassigning an old upstream response.
      add :provider_id, :binary_id, null: false
      add :provider_api_id, :binary_id, null: false
      add :api_target, :text, null: false
      add :credential_id, :binary_id, null: false
      add :credential_name, :text, null: false
      add :context_hash, :text, null: false
      add :status, :text, null: false, default: "submitting"
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_response_routes, [:owner_hash, :response_id])
    create unique_index(:llm_response_routes, [:provider_api_id, :response_id])
    create index(:llm_response_routes, [:expires_at])
  end
end
