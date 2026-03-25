defmodule Backplane.Transport.RouterTest do
  use Backplane.ConnCase, async: true

  test "GET /health returns 200 with status" do
    conn =
      Plug.Test.conn(:get, "/health")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_map(body)
  end

  test "returns 404 for unknown routes" do
    conn =
      Plug.Test.conn(:get, "/nonexistent")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "Not found"
  end

  test "DELETE /mcp returns 200 for session termination" do
    conn =
      Plug.Test.conn(:delete, "/mcp")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn.status == 200
  end

  test "GET /mcp returns 200 with SSE content type" do
    conn =
      Plug.Test.conn(:get, "/mcp")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn.status == 200
    assert {"content-type", "text/event-stream; charset=utf-8"} in conn.resp_headers
  end

  test "POST /mcp with malformed JSON returns 400" do
    conn =
      Plug.Test.conn(:post, "/mcp", "not valid json{")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn.status == 400
  end

  test "POST /mcp with valid JSON-RPC returns 200" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    conn =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn.status == 200
  end
end
