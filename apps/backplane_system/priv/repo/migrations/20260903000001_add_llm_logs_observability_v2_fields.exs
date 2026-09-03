defmodule Backplane.Repo.Migrations.AddLlmLogsObservabilityV2Fields do
  use Ecto.Migration

  def change do
    alter table(:llm_logs) do
      add :event_id, :text
      add :trace_id, :text
      add :operation, :text
      add :http_method, :text
      add :path, :text
      add :outcome, :text
      add :error_kind, :text
      add :error_code, :text
      add :upstream_duration_ms, :integer
      add :ttft_ms, :integer
      add :stream_duration_ms, :integer
      add :stream_chunks, :integer
      add :cached_tokens, :integer
      add :reasoning_tokens, :integer
      add :finish_reason, :text
      add :provider_request_id, :text
      add :attempt_count, :integer, null: false, default: 1
    end

    create unique_index(:llm_logs, [:event_id])
    create index(:llm_logs, [:trace_id, :inserted_at], where: "trace_id IS NOT NULL")
    create index(:llm_logs, [:request_id, :inserted_at], where: "request_id IS NOT NULL")
    create index(:llm_logs, [:outcome, :inserted_at], where: "outcome IS NOT NULL")
  end
end
