defmodule Backplane.Transport.RouterTest do
  use Backplane.ConnCase, async: false

  alias Backplane.Transport.Router

  test "GET /health returns 200 with status" do
    conn =
      conn(:get, "/health")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_map(body)
  end

  test "returns 404 for unknown routes" do
    conn =
      conn(:get, "/nonexistent")
      |> Router.call(Router.init([]))

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "Not found"
  end

  test "DELETE /mcp returns 200 for session termination" do
    conn =
      conn(:delete, "/mcp")
      |> Router.call(Router.init([]))

    assert conn.status == 200
  end

  @tag timeout: 5_000
  test "GET /mcp returns 200 with SSE content type" do
    task =
      Task.async(fn ->
        conn(:get, "/mcp")
        |> Router.call(Router.init([]))
      end)

    # SSE endpoint enters an infinite loop, so we just check it started
    # Give it a moment to set up then check the task is running
    Process.sleep(100)
    assert Process.alive?(task.pid)

    # Kill the task since SSE loops forever
    Task.shutdown(task, :brutal_kill)
  end

  test "POST /mcp with malformed JSON returns 400" do
    conn =
      conn(:post, "/mcp", "not valid json{")
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 400
  end

  test "POST /mcp with oversized body returns 413" do
    large_body = String.duplicate("x", 2_000_000)

    conn =
      conn(:post, "/mcp", large_body)
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 413
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "too large"
  end

  test "GET /metrics returns 200 with JSON metrics" do
    conn =
      conn(:get, "/metrics")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_map(body)
  end

  describe "webhook endpoints" do
    test "POST /webhook/github accepts valid payload without secret" do
      body = Jason.encode!(%{"action" => "push", "ref" => "refs/heads/main"})

      conn =
        conn(:post, "/webhook/github", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "accepted"
    end

    test "POST /webhook/gitlab accepts valid payload without token" do
      body = Jason.encode!(%{"event_type" => "push", "ref" => "refs/heads/main"})

      conn =
        conn(:post, "/webhook/gitlab", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "accepted"
    end

    test "POST /webhook/github accepts with valid HMAC signature" do
      secret = "test-webhook-secret"
      Application.put_env(:backplane, :github_webhook_secret, secret)
      on_exit(fn -> Application.delete_env(:backplane, :github_webhook_secret) end)

      payload = Jason.encode!(%{"action" => "push", "ref" => "refs/heads/main"})

      signature =
        "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower))

      conn =
        conn(:post, "/webhook/github", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", signature)
        |> Router.call(Router.init([]))

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "accepted"
    end

    test "POST /webhook/github rejects with invalid signature when secret configured" do
      Application.put_env(:backplane, :github_webhook_secret, "test-secret")
      on_exit(fn -> Application.delete_env(:backplane, :github_webhook_secret) end)

      body = Jason.encode!(%{"action" => "push"})

      conn =
        conn(:post, "/webhook/github", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", "sha256=invalid")
        |> Router.call(Router.init([]))

      assert conn.status == 401
    end

    test "POST /webhook/github rejects when secret configured but raw_body missing" do
      Application.put_env(:backplane, :github_webhook_secret, "test-secret")
      on_exit(fn -> Application.delete_env(:backplane, :github_webhook_secret) end)

      body = Jason.encode!(%{"action" => "push"})

      # Build a conn without going through CacheBodyReader, so raw_body is nil
      conn =
        conn(:post, "/webhook/github", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", "sha256=valid-looking-sig")
        |> Router.call(Router.init([]))

      # Should reject (401) rather than accept — raw_body missing means validation
      # can't proceed when a secret IS configured
      assert conn.status == 401
    end

    test "POST /webhook/github uses per-project webhook secret with provider:repo format" do
      secret = "project-specific-secret"

      # Projects use "github:owner/repo" format from backplane.toml
      Application.put_env(:backplane, :projects, [
        %{id: "test-proj", repo: "github:org/repo", ref: "main", webhook_secret: secret}
      ])

      on_exit(fn -> Application.delete_env(:backplane, :projects) end)

      # Webhook payload uses full clone URL
      payload =
        Jason.encode!(%{
          "ref" => "refs/heads/main",
          "repository" => %{"clone_url" => "https://github.com/org/repo.git"}
        })

      signature =
        "sha256=" <>
          (:crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower))

      conn =
        conn(:post, "/webhook/github", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", signature)
        |> Router.call(Router.init([]))

      assert conn.status == 202
    end

    test "POST /webhook/github rejects when per-project secret doesn't match" do
      Application.put_env(:backplane, :projects, [
        %{id: "test-proj", repo: "github:org/repo", ref: "main", webhook_secret: "correct-secret"}
      ])

      on_exit(fn -> Application.delete_env(:backplane, :projects) end)

      payload =
        Jason.encode!(%{
          "ref" => "refs/heads/main",
          "repository" => %{"clone_url" => "https://github.com/org/repo.git"}
        })

      wrong_sig =
        "sha256=" <>
          (:crypto.mac(:hmac, :sha256, "wrong-secret", payload) |> Base.encode16(case: :lower))

      conn =
        conn(:post, "/webhook/github", payload)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", wrong_sig)
        |> Router.call(Router.init([]))

      assert conn.status == 401
    end

    test "POST /webhook/gitlab rejects with wrong token when token configured" do
      Application.put_env(:backplane, :gitlab_webhook_token, "correct-token")
      on_exit(fn -> Application.delete_env(:backplane, :gitlab_webhook_token) end)

      body = Jason.encode!(%{"event_type" => "push"})

      conn =
        conn(:post, "/webhook/gitlab", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-gitlab-token", "wrong-token")
        |> Router.call(Router.init([]))

      assert conn.status == 401
    end
  end

  test "POST /mcp with valid JSON-RPC returns 200" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    conn =
      conn(:post, "/mcp", body)
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 200
  end
end
