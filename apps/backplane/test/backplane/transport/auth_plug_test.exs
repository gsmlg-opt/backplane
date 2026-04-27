defmodule Backplane.Transport.AuthPlugTest do
  use Backplane.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Backplane.Fixtures

  alias Backplane.Transport.AuthPlug

  setup context do
    if context[:auth_token] do
      Application.put_env(:backplane, :auth_token, context[:auth_token])
    else
      Application.delete_env(:backplane, :auth_token)
    end

    Application.delete_env(:backplane, :auth_tokens)

    on_exit(fn ->
      Application.delete_env(:backplane, :auth_token)
      Application.delete_env(:backplane, :auth_tokens)
    end)

    :ok
  end

  test "init/1 passes through opts unchanged" do
    assert AuthPlug.init([]) == []
    assert AuthPlug.init(foo: :bar) == [foo: :bar]
  end

  describe "no auth configured" do
    test "passes all requests through" do
      conn =
        conn(:post, "/mcp", "")
        |> AuthPlug.call([])

      refute conn.halted
    end

    test "does not check authorization header" do
      conn =
        conn(:post, "/mcp", "")
        |> AuthPlug.call([])

      refute conn.halted
    end
  end

  describe "auth configured" do
    setup do
      Application.put_env(:backplane, :auth_token, "test-secret")
      on_exit(fn -> Application.delete_env(:backplane, :auth_token) end)
      :ok
    end

    test "passes request with valid bearer token" do
      conn =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Bearer test-secret")
        |> AuthPlug.call([])

      refute conn.halted
    end

    test "rejects request with missing authorization header (401)" do
      conn =
        conn(:post, "/mcp", "")
        |> AuthPlug.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "rejects request with wrong token (401)" do
      conn =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Bearer wrong-token")
        |> AuthPlug.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "rejects request with malformed authorization header (401)" do
      conn =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Basic dGVzdDp0ZXN0")
        |> AuthPlug.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "accepts bearer token with case-insensitive scheme (RFC 6750)" do
      conn =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "bearer test-secret")
        |> AuthPlug.call([])

      refute conn.halted
    end

    test "accepts BEARER token in uppercase" do
      conn =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "BEARER test-secret")
        |> AuthPlug.call([])

      refute conn.halted
    end

    test "trims whitespace from bearer token" do
      conn =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Bearer  test-secret ")
        |> AuthPlug.call([])

      refute conn.halted
    end

    test "always passes /health without auth" do
      conn =
        conn(:get, "/health", "")
        |> AuthPlug.call([])

      refute conn.halted
    end

    test "always passes /metrics without auth" do
      conn =
        conn(:get, "/metrics", "")
        |> AuthPlug.call([])

      refute conn.halted
    end
  end

  describe "token rotation (auth_tokens list)" do
    setup do
      Application.put_env(:backplane, :auth_tokens, ["new-token", "old-token"])
      on_exit(fn -> Application.delete_env(:backplane, :auth_tokens) end)
      :ok
    end

    test "accepts the first (current) token" do
      conn =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Bearer new-token")
        |> AuthPlug.call([])

      refute conn.halted
    end

    test "accepts the second (previous) token" do
      conn =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Bearer old-token")
        |> AuthPlug.call([])

      refute conn.halted
    end

    test "rejects tokens not in the list" do
      conn =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Bearer invalid-token")
        |> AuthPlug.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "auth_tokens takes precedence over auth_token" do
      Application.put_env(:backplane, :auth_token, "single-token")

      conn =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Bearer single-token")
        |> AuthPlug.call([])

      # single-token is not in auth_tokens list, so should be rejected
      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "client mode" do
    test "resolves bearer token to client and sets assigns" do
      {_client, token} = insert_client(name: "test-client", scopes: ["docs::*", "git::*"])

      result =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Bearer #{token}")
        |> AuthPlug.call([])

      refute result.halted
      assert result.assigns[:client].name == "test-client"
      assert result.assigns[:tool_scopes] == ["docs::*", "git::*"]
    end

    test "falls through to legacy token on client miss" do
      # Insert a client so client mode is active
      insert_client(name: "existing-client")
      Application.put_env(:backplane, :auth_token, "legacy-secret")

      result =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Bearer legacy-secret")
        |> AuthPlug.call([])

      refute result.halted
      assert result.assigns[:tool_scopes] == ["*"]
      refute Map.has_key?(result.assigns, :client)
    end

    test "returns 401 when both client and legacy fail" do
      insert_client(name: "existing-client")

      result =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Bearer wrong-token")
        |> AuthPlug.call([])

      assert result.halted
      assert result.status == 401
    end

    test "sets tool_scopes from client record" do
      {_client, token} = insert_client(name: "scoped-client", scopes: ["skill::*"])

      result =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Bearer #{token}")
        |> AuthPlug.call([])

      refute result.halted
      assert result.assigns[:tool_scopes] == ["skill::*"]
    end
  end
end
