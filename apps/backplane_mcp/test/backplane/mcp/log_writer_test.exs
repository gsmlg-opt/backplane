defmodule Backplane.MCP.LogWriterTest do
  use Backplane.MCP.ObservabilityCase, async: false

  import Ecto.Query

  alias Backplane.MCP.{LogWriter, ProxyRequest}
  alias Backplane.Observability.Buffer
  alias Backplane.Repo

  @moduletag observability_v2: true

  test "persists sanitized rows with event_id conflict handling" do
    row = %{
      event_id: "evt-mcp-dup-001",
      operation: "jsonrpc",
      outcome: "success",
      rpc_method: "ping",
      http_status: 200,
      metadata: %{}
    }

    assert :ok = Buffer.try_enqueue(:mcp_proxy_root, row)
    assert :ok = Buffer.try_enqueue(:mcp_proxy_root, row)
    flush_logs!()

    assert [%ProxyRequest{} = log] =
             Repo.all(from(r in ProxyRequest, where: r.event_id == ^row.event_id))

    assert log.rpc_method == "ping"
    refute Map.has_key?(log, :raw_body)
  end

  test "health reflects buffer and insert totals" do
    assert :ok = Buffer.try_enqueue(:mcp_proxy_root, sample_row("evt-mcp-health-001"))
    flush_logs!()

    health = LogWriter.health()
    assert health.status == :ok
    assert health.inserted_total >= 1
    assert is_map(health.buffer)
  end

  test "writer database failure does not crash the process" do
    assert :ok =
             Buffer.try_enqueue(:mcp_proxy_root, %{
               operation: "jsonrpc",
               outcome: "success",
               rpc_method: "ping",
               http_status: 200
             })

    flush_logs!()
    health = LogWriter.health()
    assert health.status == :ok
    assert health.failed_total >= 1
  end

  defp sample_row(event_id) do
    %{
      event_id: event_id,
      operation: "jsonrpc",
      outcome: "success",
      rpc_method: "initialize",
      http_status: 200,
      metadata: %{}
    }
  end
end
