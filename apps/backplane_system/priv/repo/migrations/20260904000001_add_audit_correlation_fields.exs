defmodule Backplane.Repo.Migrations.AddAuditCorrelationFields do
  use Ecto.Migration

  def change do
    alter table(:tool_call_log) do
      add :event_id, :text
      add :request_id, :text
      add :trace_id, :text
      add :mcp_request_id, :text
    end

    create unique_index(:tool_call_log, [:event_id])

    alter table(:skill_load_log) do
      add :event_id, :text
      add :request_id, :text
      add :trace_id, :text
      add :mcp_request_id, :text
    end

    create unique_index(:skill_load_log, [:event_id])
  end
end
