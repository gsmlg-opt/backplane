defmodule Backplane.MCP.AccessEventTest do
  use Backplane.MCP.ObservabilityCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.MCP.AccessEvent
  alias Backplane.Observability.Context

  @moduletag observability_v2: true

  test "log writer persists telemetry events" do
    :ok =
      :telemetry.execute(
        [:backplane, :mcp_proxy, :request, :stop],
        %{duration_ms: 3},
        %{
          event_id: "evt-direct-telemetry",
          attributes: %{operation: "jsonrpc", outcome: "success", rpc_method: "ping"},
          context: %{request_id: "req-direct", trace_id: String.duplicate("d", 32)}
        }
      )

    flush_logs!()

    import Ecto.Query

    assert %ProxyRequest{} =
             Backplane.Repo.one(
               from(r in ProxyRequest, where: r.event_id == "evt-direct-telemetry")
             )
  end

  test "finalize emits a durable MCP root access record" do
    context = Context.root(request_id: "req-mcp-access", trace_id: String.duplicate("c", 32))

    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1})

    conn =
      conn(:post, "/mcp", body)
      |> put_req_header("content-type", "application/json")
      |> Context.put(context)
      |> Backplane.Transport.McpObservability.call([])
      |> send_resp(200, ~s({"jsonrpc":"2.0","id":1,"result":{"tools":[]}}))

    flush_logs!()

    import Ecto.Query

    log =
      Backplane.Repo.one(
        from(r in ProxyRequest,
          where: r.request_id == "req-mcp-access",
          order_by: [desc: r.inserted_at],
          limit: 1
        )
      )

    assert log.outcome == "success"
    assert log.operation == "jsonrpc"
    assert log.request_id == "req-mcp-access"
    assert log.metadata == %{}
    refute log_stores_body?(log)
  end

  test "sse_open operation does not persist when marked runtime-only" do
    conn =
      conn(:head, "/mcp")
      |> send_resp(204, "")

    access = AccessEvent.start(conn)
    assert access.runtime_only? == true

    :ok = AccessEvent.finalize(access, conn, :success, status: 204)
    flush_logs!()

    assert latest_log() == nil
  end

  defp log_stores_body?(log) do
    Map.has_key?(log, :raw_body) or
      (is_map(log.metadata) and
         Enum.any?(log.metadata, fn {_k, v} -> is_binary(v) and String.contains?(v, "jsonrpc") end))
  end
end
