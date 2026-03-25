defmodule Backplane.Transport.CORSTest do
  use ExUnit.Case, async: false

  alias Backplane.Transport.CORS

  setup do
    Application.delete_env(:backplane, CORS)
    on_exit(fn -> Application.delete_env(:backplane, CORS) end)
  end

  describe "OPTIONS preflight" do
    test "returns 204 with CORS headers" do
      conn =
        Plug.Test.conn(:options, "/mcp")
        |> Plug.Conn.put_req_header("origin", "http://localhost:3000")
        |> CORS.call([])

      assert conn.status == 204
      assert conn.halted
      assert get_header(conn, "access-control-allow-origin") == "*"
      assert get_header(conn, "access-control-allow-methods") =~ "POST"
      assert get_header(conn, "access-control-allow-headers") =~ "Authorization"
    end
  end

  describe "regular requests" do
    test "adds CORS headers to response" do
      conn =
        Plug.Test.conn(:post, "/mcp")
        |> CORS.call([])
        |> Plug.Conn.send_resp(200, "ok")

      assert get_header(conn, "access-control-allow-origin") == "*"
    end

    test "restricts to configured origins" do
      Application.put_env(:backplane, CORS, allowed_origins: ["http://example.com"])

      conn =
        Plug.Test.conn(:post, "/mcp")
        |> Plug.Conn.put_req_header("origin", "http://evil.com")
        |> CORS.call([])
        |> Plug.Conn.send_resp(200, "ok")

      assert get_header(conn, "access-control-allow-origin") == nil
    end

    test "allows matching configured origin" do
      Application.put_env(:backplane, CORS, allowed_origins: ["http://example.com"])

      conn =
        Plug.Test.conn(:post, "/mcp")
        |> Plug.Conn.put_req_header("origin", "http://example.com")
        |> CORS.call([])
        |> Plug.Conn.send_resp(200, "ok")

      assert get_header(conn, "access-control-allow-origin") == "http://example.com"
    end
  end

  defp get_header(conn, key) do
    case Plug.Conn.get_resp_header(conn, key) do
      [value] -> value
      [] -> nil
    end
  end
end
