defmodule Backplane.Transport.RouterTest do
  use Backplane.ConnCase, async: false

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

  test "POST /mcp with oversized body returns 413" do
    large_body = String.duplicate("x", 2_000_000)

    conn =
      Plug.Test.conn(:post, "/mcp", large_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn.status == 413
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "too large"
  end

  test "GET /metrics returns 200 with JSON metrics" do
    conn =
      Plug.Test.conn(:get, "/metrics")
      |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_map(body)
  end

  describe "webhook endpoints" do
    test "POST /webhook/github accepts valid payload without secret" do
      body = Jason.encode!(%{"action" => "push", "ref" => "refs/heads/main"})

      conn =
        Plug.Test.conn(:post, "/webhook/github", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "accepted"
    end

    test "POST /webhook/gitlab accepts valid payload without token" do
      body = Jason.encode!(%{"event_type" => "push", "ref" => "refs/heads/main"})

      conn =
        Plug.Test.conn(:post, "/webhook/gitlab", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "accepted"
    end

    test "POST /webhook/github rejects with invalid signature when secret configured" do
      Application.put_env(:backplane, :github_webhook_secret, "test-secret")
      on_exit(fn -> Application.delete_env(:backplane, :github_webhook_secret) end)

      body = Jason.encode!(%{"action" => "push"})

      conn =
        Plug.Test.conn(:post, "/webhook/github", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=invalid")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      assert conn.status == 401
    end

    test "POST /webhook/gitlab rejects with wrong token when token configured" do
      Application.put_env(:backplane, :gitlab_webhook_token, "correct-token")
      on_exit(fn -> Application.delete_env(:backplane, :gitlab_webhook_token) end)

      body = Jason.encode!(%{"event_type" => "push"})

      conn =
        Plug.Test.conn(:post, "/webhook/gitlab", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-gitlab-token", "wrong-token")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      assert conn.status == 401
    end
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
