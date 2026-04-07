defmodule Backplane.Repo.Migrations.CreateLlmUsageLogs do
  use Ecto.Migration

  def change do
    create table(:llm_usage_logs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :provider_id, references(:llm_providers, type: :uuid, on_delete: :nothing), null: false
      add :model, :text, null: false
      add :status, :integer
      add :latency_ms, :integer
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :stream, :boolean, default: false
      add :client_ip, :text
      add :error_reason, :text

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    execute(
      "CREATE INDEX llm_usage_logs_provider_id_inserted_at_index ON llm_usage_logs (provider_id, inserted_at DESC)",
      "DROP INDEX llm_usage_logs_provider_id_inserted_at_index"
    )

    execute(
      "CREATE INDEX llm_usage_logs_model_inserted_at_index ON llm_usage_logs (model, inserted_at DESC)",
      "DROP INDEX llm_usage_logs_model_inserted_at_index"
    )

    create index(:llm_usage_logs, [:inserted_at])
  end
end
