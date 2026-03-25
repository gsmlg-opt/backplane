defmodule Backplane.Transport.AuthPlugTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  setup context do
    if context[:auth_token] do
      Application.put_env(:backplane, :auth_token, context[:auth_token])
      on_exit(fn -> Application.delete_env(:backplane, :auth_token) end)
    else
      Application.delete_env(:backplane, :auth_token)
    end

    :ok
  end

  describe "no auth configured" do
    test "passes all requests through" do
      conn =
        conn(:post, "/mcp", "")
        |> Backplane.Transport.AuthPlug.call([])

      refute conn.halted
    end

    test "does not check authorization header" do
      conn =
        conn(:post, "/mcp", "")
        |> Backplane.Transport.AuthPlug.call([])

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
        |> Backplane.Transport.AuthPlug.call([])

      refute conn.halted
    end

    test "rejects request with missing authorization header (401)" do
      conn =
        conn(:post, "/mcp", "")
        |> Backplane.Transport.AuthPlug.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "rejects request with wrong token (401)" do
      conn =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Bearer wrong-token")
        |> Backplane.Transport.AuthPlug.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "rejects request with malformed authorization header (401)" do
      conn =
        conn(:post, "/mcp", "")
        |> put_req_header("authorization", "Basic dGVzdDp0ZXN0")
        |> Backplane.Transport.AuthPlug.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "always passes /health without auth" do
      conn =
        conn(:get, "/health", "")
        |> Backplane.Transport.AuthPlug.call([])

      refute conn.halted
    end
  end
end
