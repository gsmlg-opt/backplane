defmodule Backplane.Repo.Migrations.CreateLlmOpenaiServices do
  use Ecto.Migration

  def change do
    create table(:llm_openai_services, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :provider_id, references(:llm_providers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :enabled, :boolean, null: false, default: false
      add :models, {:array, :string}, null: false, default: []
      add :default_model, :string
      add :request_timeout_ms, :integer, null: false, default: 120_000
      add :max_request_bytes, :integer, null: false, default: 50_000_000
      add :max_response_bytes, :integer, null: false, default: 100_000_000
      add :max_session_ms, :integer, null: false, default: 3_600_000
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_openai_services, [:provider_id, :kind])

    create constraint(:llm_openai_services, :llm_openai_services_kind_check,
             check: "kind IN ('decisions', 'images', 'speech', 'transcription', 'realtime')"
           )
  end
end
