defmodule Backplane.Transport.McpPlugTest do
  use Backplane.ConnCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Auth.Resources
  alias Backplane.Transport.{McpPlug, RateLimiter, Session}

  test "returns 404 for unknown routes" do
    conn =
      conn(:get, "/nonexistent")
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "Not found"
  end

  test "DELETE / returns 200 for session termination" do
    conn =
      conn(:delete, "/")
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 200
  end

  test "explicit modern DELETE returns 405 before deleting a legacy session" do
    session_id = "modern-delete-keeps-legacy"
    Session.create(session_id, "2025-11-25", %{}, %{})
    on_exit(fn -> Session.delete(session_id) end)

    conn =
      conn(:delete, "/")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-session-id", session_id)
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 405
    assert Session.get(session_id)
  end

  test "explicit modern GET returns 405 without opening the legacy SSE stream" do
    task =
      Task.async(fn ->
        conn(:get, "/")
        |> put_req_header("mcp-protocol-version", "2026-07-28")
        |> McpPlug.call(McpPlug.init([]))
      end)

    conn =
      case Task.yield(task, 200) || Task.shutdown(task, :brutal_kill) do
        {:ok, conn} -> conn
        nil -> flunk("explicit modern GET opened the legacy SSE stream")
      end

    assert conn.status == 405
    assert conn.state == :sent
  end

  test "HEAD / returns immediately without opening SSE stream" do
    task =
      Task.async(fn ->
        conn(:head, "/")
        |> put_req_header("accept", "text/event-stream")
        |> McpPlug.call(McpPlug.init([]))
      end)

    conn =
      case Task.yield(task, 200) || Task.shutdown(task, :brutal_kill) do
        {:ok, conn} -> conn
        nil -> flunk("HEAD / should return immediately instead of opening an SSE stream")
      end

    assert conn.status == 204
    assert conn.state == :sent

    refute Enum.any?(
             get_resp_header(conn, "content-type"),
             &String.contains?(&1, "text/event-stream")
           )
  end

  test "HEAD / returns no content before auth is enforced" do
    original_auth_token = Application.get_env(:backplane, :auth_token)
    Application.put_env(:backplane, :auth_token, "required-token")

    on_exit(fn -> restore_env(:auth_token, original_auth_token) end)

    conn =
      conn(:head, "/")
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 204
  end

  @tag timeout: 5_000
  test "GET / returns 200 with SSE content type" do
    task =
      Task.async(fn ->
        conn(:get, "/")
        |> McpPlug.call(McpPlug.init([]))
      end)

    # SSE endpoint enters an infinite loop, so we just check it started
    # Give it a moment to set up then check the task is running
    Process.sleep(100)
    assert Process.alive?(task.pid)

    # Kill the task since SSE loops forever
    Task.shutdown(task, :brutal_kill)
  end

  test "POST / with malformed JSON returns 400" do
    conn =
      conn(:post, "/", "not valid json{")
      |> put_req_header("content-type", "application/json")
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 400
  end

  test "POST / with oversized body returns 413" do
    large_body = String.duplicate("x", 2_000_000)

    conn =
      conn(:post, "/", large_body)
      |> put_req_header("content-type", "application/json")
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 413
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "too large"
  end

  test "explicit modern auth failures retain the modern protocol version" do
    oauth_client_fixture!(resources: [:mcp], scopes: ["public::echo"])

    conn =
      conn(:post, "/", "{}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"
    assert get_resp_header(conn, "x-mcp-protocol-version") == ["2026-07-28"]
  end

  test "modern and malformed protocol markers retain the modern version on rate limiting" do
    previous_rate_limit = Application.get_env(:backplane, RateLimiter)

    Application.put_env(:backplane, RateLimiter,
      max_requests: 0,
      window_ms: 60_000,
      trust_x_forwarded_for: false
    )

    on_exit(fn -> restore_env(RateLimiter, previous_rate_limit) end)

    header_sets = [
      [{"mcp-protocol-version", "2026-07-28"}],
      [
        {"MCP-Protocol-Version", "2026-07-28"},
        {"mcp-protocol-version", "2099-01-01"}
      ],
      [{:mcp_protocol_version, "2026-07-28"}]
    ]

    for raw_headers <- header_sets do
      conn = conn(:post, "/", "{}")
      conn = %{conn | req_headers: raw_headers ++ conn.req_headers}
      conn = McpPlug.call(conn, McpPlug.init([]))

      assert conn.status == 429
      assert Jason.decode!(conn.resp_body) == %{"error" => "Too many requests"}
      assert get_resp_header(conn, "x-mcp-protocol-version") == ["2026-07-28"]
    end
  end

  test "POST / with valid JSON-RPC returns 200" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 200
  end

  describe "protected resource authentication" do
    test "OAuth activation challenges the canonical MCP resource" do
      oauth_client_fixture!(resources: [:mcp], scopes: ["public::echo"])

      conn = endpoint_mcp_request("/mcp")

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Bearer resource_metadata="#{Resources.metadata_uri(:mcp)}")
             ]
    end

    test "query-bearing MCP challenges omit resource metadata" do
      oauth_client_fixture!(resources: [:mcp], scopes: ["public::echo"])

      conn = endpoint_mcp_request("/mcp?x=1")

      assert conn.status == 401
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      refute challenge =~ "resource_metadata"
    end

    test "PAT-only protection preserves the compatibility response" do
      Backplane.Fixtures.insert_client(token: "pat-only")

      conn = endpoint_mcp_request("/mcp")

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
      assert get_resp_header(conn, "www-authenticate") == []
    end

    test "accepts an MCP resource token and assigns its normalized identity" do
      token = resource_token!(:mcp, ["public::echo"], [:mcp])

      conn = endpoint_mcp_request("/mcp", token.value)

      assert conn.status == 200
      assert conn.assigns.resource_auth.kind == :oauth
      assert conn.assigns.resource_auth.resource == :mcp
      assert conn.assigns.tool_scopes == ["public::echo"]
    end

    test "rejects a v1-audience token without opaque fallback" do
      token = resource_token!(:v1, ["llm::invoke"], [:mcp, :v1])

      conn = endpoint_mcp_request("/mcp", token.value)

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"

      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(error="invalid_token")
      assert challenge =~ Resources.metadata_uri(:mcp)
    end
  end

  defp endpoint_mcp_request(path, token \\ nil) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    conn =
      conn(:post, path, body)
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    Backplane.Api.Endpoint.call(conn, Backplane.Api.Endpoint.init([]))
  end

  defp resource_token!(resource, scopes, resources) do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: resources, scopes: scopes)
    resource_access_token_fixture!(user, client, scopes, resource)
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)
end
