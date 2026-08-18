defmodule Backplane.McpProtocol.Server.Transport.StreamableHTTP.ModernRequestTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Backplane.McpProtocol.Server.Transport.StreamableHTTP.ModernRequest

  @version "2026-07-28"

  setup do
    %{task_supervisor: start_supervised!({Task.Supervisor, []})}
  end

  test "dispatches discovery without server session runtime configuration", context do
    request = modern_request("server/discover", "discover-direct")
    {conn, transport_context} = request_conn(request)

    conn =
      ModernRequest.call(conn, request, transport_context,
        server: ModernStubServer,
        task_supervisor: context.task_supervisor
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert get_resp_header(conn, "mcp-session-id") == []

    assert %{
             "id" => "discover-direct",
             "result" => %{
               "resultType" => "complete",
               "supportedVersions" => supported_versions
             }
           } = JSON.decode!(conn.resp_body)

    assert @version in supported_versions
  end

  test "rejects a non-map message as a modern invalid request", context do
    request = modern_request("tools/list", "invalid-direct")
    {conn, transport_context} = request_conn(request)

    conn =
      ModernRequest.call(conn, [request], transport_context,
        server: ModernStubServer,
        task_supervisor: context.task_supervisor
      )

    assert conn.status == 400

    assert %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"code" => -32_600}
           } = JSON.decode!(conn.resp_body)
  end

  test "rejects subscriptions when no subscription runtime is configured", context do
    request = modern_request("subscriptions/listen", "subscription-direct")
    {conn, transport_context} = request_conn(request)

    conn =
      ModernRequest.call(conn, request, transport_context,
        server: ModernStubServer,
        task_supervisor: context.task_supervisor,
        subscriptions: nil
      )

    assert conn.status == 404

    assert %{
             "id" => "subscription-direct",
             "error" => %{"code" => -32_601}
           } = JSON.decode!(conn.resp_body)
  end

  test "renders modern parse errors without dispatch configuration" do
    conn =
      :post
      |> conn("/", "not json")
      |> ModernRequest.parse_error()

    assert conn.status == 400

    assert %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"code" => -32_700}
           } = JSON.decode!(conn.resp_body)
  end

  test "preserves request-scoped SSE rendering", context do
    request = modern_request("server/discover", "discover-sse")
    {conn, transport_context} = request_conn(request, "text/event-stream, application/json")

    conn =
      ModernRequest.call(conn, request, transport_context,
        server: ModernStubServer,
        task_supervisor: context.task_supervisor
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream; charset=utf-8"]
    assert get_resp_header(conn, "mcp-session-id") == []

    body = response_body(conn)
    assert body =~ "event: message"
    assert body =~ ~s("id":"discover-sse")
    assert body =~ ~s("resultType":"complete")
  end

  defp request_conn(request, accept \\ "application/json, text/event-stream") do
    conn =
      :post
      |> conn("/", JSON.encode!(request))
      |> assign(:test_pid, self())
      |> put_req_header("accept", accept)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", @version)
      |> put_req_header("mcp-method", request["method"])

    transport_context = %{
      assigns: conn.assigns,
      type: :http,
      req_headers: conn.req_headers,
      query_params: %{},
      remote_ip: conn.remote_ip,
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port,
      request_path: conn.request_path,
      auth: nil
    }

    {conn, transport_context}
  end

  defp modern_request(method, id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end

  defp response_body(%Plug.Conn{resp_body: ""} = conn) do
    case conn.adapter do
      {Plug.Adapters.Test.Conn, %{chunks: chunks}} when is_binary(chunks) -> chunks
      _other -> ""
    end
  end

  defp response_body(%Plug.Conn{resp_body: body}) when is_binary(body), do: body
end
