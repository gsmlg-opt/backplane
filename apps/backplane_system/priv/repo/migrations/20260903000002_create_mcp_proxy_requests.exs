defmodule Backplane.Repo.Migrations.CreateMcpProxyRequests do
  use Ecto.Migration

  def change do
    create table(:mcp_proxy_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_id, :text, null: false
      add :request_id, :text
      add :trace_id, :text

      add :operation, :text, null: false
      add :rpc_id, :text
      add :rpc_method, :text
      add :protocol_version, :text
      add :era, :text
      add :transport, :text
      add :session_id, :text

      add :client_id, :binary_id
      add :client_name, :text
      add :client_version, :text
      add :auth_kind, :text
      add :remote_ip, :text

      add :http_method, :text
      add :path, :text
      add :http_status, :integer
      add :jsonrpc_error_code, :integer

      add :request_bytes, :integer
      add :response_bytes, :integer
      add :duration_ms, :integer

      add :outcome, :text, null: false
      add :idempotency_status, :text
      add :error_kind, :text
      add :error_code, :text
      add :error_message, :text

      add :metadata, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:mcp_proxy_requests, [:event_id])
    create index(:mcp_proxy_requests, [:trace_id, :inserted_at], where: "trace_id IS NOT NULL")
    create index(:mcp_proxy_requests, [:request_id, :inserted_at], where: "request_id IS NOT NULL")
    create index(:mcp_proxy_requests, [:outcome, :inserted_at], where: "outcome IS NOT NULL")
    create index(:mcp_proxy_requests, [:client_id, :inserted_at], where: "client_id IS NOT NULL")
    create index(:mcp_proxy_requests, [:operation, :inserted_at])
    create index(:mcp_proxy_requests, [:rpc_method, :inserted_at], where: "rpc_method IS NOT NULL")
  end
end
