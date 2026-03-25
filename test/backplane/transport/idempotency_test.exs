defmodule Backplane.Transport.IdempotencyTest do
  use Backplane.ConnCase, async: false

  test "request without idempotency key processes normally" do
    resp = mcp_request("ping")
    assert resp["result"] == %{}
  end

  test "first request with idempotency key processes and caches" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    conn =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("idempotency-key", "test-key-1")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert resp["result"] == %{}
  end

  test "repeated request with same key returns cached response" do
    key = "test-key-repeat-#{System.unique_integer([:positive])}"
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1})

    # First request
    conn1 =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("idempotency-key", key)
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn1.status == 200
    first_body = conn1.resp_body

    # Second request with same key — should return cached
    conn2 =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("idempotency-key", key)
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn2.status == 200
    assert conn2.resp_body == first_body
    assert conn2.halted
  end

  test "different keys produce independent responses" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    conn1 =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header(
        "idempotency-key",
        "key-a-#{System.unique_integer([:positive])}"
      )
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    conn2 =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header(
        "idempotency-key",
        "key-b-#{System.unique_integer([:positive])}"
      )
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    # Both should process independently (not cached)
    assert conn1.status == 200
    assert conn2.status == 200
    refute conn1.halted
    refute conn2.halted
  end

  test "empty idempotency key header is ignored" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    conn =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("idempotency-key", "")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn.status == 200
    refute conn.halted
  end

  test "cached response preserves status code and content type" do
    key = "test-key-status-#{System.unique_integer([:positive])}"
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    # First request
    conn1 =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("idempotency-key", key)
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    # Second request with same key
    conn2 =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("idempotency-key", key)
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn2.status == conn1.status

    ct =
      conn2.resp_headers
      |> Enum.find(fn {k, _} -> k == "content-type" end)
      |> elem(1)

    assert ct =~ "application/json"
  end
end
