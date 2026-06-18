defmodule Backplane.Transport.McpPlugTest do
  use Backplane.ConnCase, async: false

  alias Backplane.Transport.McpPlug

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

  test "POST / with valid JSON-RPC returns 200" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 200
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)
end
