defmodule Backplane.Repo.Migrations.CreateLlmUsageLogs do
  use Ecto.Migration

  def change do
    create table(:llm_usage_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :provider_id, references(:llm_providers, type: :binary_id, on_delete: :nilify_all)
      add :model, :text
      add :status, :integer
      add :latency_ms, :integer
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :stream, :boolean, default: false
      add :client_ip, :text
      add :error_reason, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")
    end

    create index(:llm_usage_logs, [:provider_id, :inserted_at])
    create index(:llm_usage_logs, [:model, :inserted_at])
    create index(:llm_usage_logs, [:inserted_at])
  end
end
