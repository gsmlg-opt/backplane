defmodule Backplane.Repo.Migrations.CreateMcpToolCalls do
  use Ecto.Migration

  def change do
    create table(:mcp_tool_calls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_id, :text, null: false
      add :mcp_request_id, :text
      add :trace_id, :text
      add :span_id, :text
      add :parent_span_id, :text

      add :tool_name, :text, null: false
      add :tool_namespace, :text
      add :original_tool_name, :text
      add :execution_kind, :text

      add :upstream_name, :text
      add :upstream_prefix, :text
      add :upstream_transport, :text
      add :upstream_protocol_version, :text

      add :arguments_hash, :text
      add :cache_status, :text
      add :timeout_ms, :integer
      add :attempt_count, :integer
      add :duration_ms, :integer

      add :outcome, :text, null: false
      add :error_kind, :text
      add :error_code, :text
      add :error_message, :text

      add :metadata, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:mcp_tool_calls, [:event_id])
    create index(:mcp_tool_calls, [:mcp_request_id], where: "mcp_request_id IS NOT NULL")
    create index(:mcp_tool_calls, [:trace_id, :inserted_at], where: "trace_id IS NOT NULL")
    create index(:mcp_tool_calls, [:tool_name, :inserted_at])
    create index(:mcp_tool_calls, [:upstream_name, :inserted_at], where: "upstream_name IS NOT NULL")
    create index(:mcp_tool_calls, [:outcome, :inserted_at])
  end
end
