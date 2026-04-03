defmodule Backplane.Transport.AuthPlugTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

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

    test "always passes /webhook/github without auth" do
      conn =
        conn(:post, "/webhook/github", "")
        |> AuthPlug.call([])

      refute conn.halted
    end

    test "always passes /webhook/gitlab without auth" do
      conn =
        conn(:post, "/webhook/gitlab", "")
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
end
