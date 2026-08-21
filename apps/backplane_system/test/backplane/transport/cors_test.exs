defmodule Backplane.Transport.CORSTest do
  use ExUnit.Case, async: false

  alias Backplane.Transport.CORS

  setup do
    Application.delete_env(:backplane, CORS)
    on_exit(fn -> Application.delete_env(:backplane, CORS) end)
  end

  describe "init/1" do
    test "passes options through" do
      assert CORS.init(foo: :bar) == [foo: :bar]
    end
  end

  describe "OPTIONS preflight" do
    test "returns 204 with CORS headers" do
      conn =
        Plug.Test.conn(:options, "/mcp")
        |> Plug.Conn.put_req_header("origin", "http://localhost:3000")
        |> CORS.call(CORS.init([]))

      assert conn.status == 204
      assert conn.halted
      assert get_header(conn, "access-control-allow-origin") == "*"
      assert get_header(conn, "access-control-allow-methods") =~ "POST"
      assert get_header(conn, "access-control-allow-headers") =~ "Authorization"
    end

    test "allows modern MCP base headers and only safe requested parameter headers" do
      conn =
        Plug.Test.conn(:options, "/mcp")
        |> Plug.Conn.put_req_header("origin", "http://localhost:3000")
        |> Plug.Conn.put_req_header(
          "access-control-request-headers",
          "MCP-Protocol-Version, Mcp-Method, Mcp-Name, Idempotency-Key, " <>
            "Mcp-Param-Region, mcp-param-trace-id, Mcp-Param-user_id, " <>
            "Mcp-Param-region.v2, X-Unsafe"
        )
        |> CORS.call([])

      allowed = get_header(conn, "access-control-allow-headers")

      for base <- [
            "Content-Type",
            "Authorization",
            "Accept",
            "Mcp-Session-Id",
            "MCP-Protocol-Version",
            "Mcp-Method",
            "Mcp-Name",
            "Idempotency-Key"
          ] do
        assert header_member?(allowed, base)
      end

      assert header_member?(allowed, "Mcp-Param-Region")
      assert header_member?(allowed, "mcp-param-trace-id")
      assert header_member?(allowed, "Mcp-Param-user_id")
      assert header_member?(allowed, "Mcp-Param-region.v2")
      refute header_member?(allowed, "X-Unsafe")
    end

    test "rejects malformed parameter header names and deduplicates safe names case-insensitively" do
      requested =
        "Mcp-Param-Region, mcp-param-region, MCP-PARAM-TRACE, " <>
          "Mcp-Param-, Mcp-Param-bad:name, Mcp-Param-bad name, X-Unsafe"

      conn =
        Plug.Test.conn(:options, "/mcp")
        |> Plug.Conn.put_req_header("access-control-request-headers", requested)

      conn = %{
        conn
        | req_headers: [
            {"access-control-request-headers", "Mcp-Param-Good\r\nX-Injected"},
            {"access-control-request-headers", "Mcp-Param-null\0byte"}
            | conn.req_headers
          ]
      }

      conn = CORS.call(conn, [])
      allowed = get_header(conn, "access-control-allow-headers")
      downcased = Enum.map(header_members(allowed), &String.downcase/1)

      assert Enum.count(downcased, &(&1 == "mcp-param-region")) == 1
      assert Enum.count(downcased, &(&1 == "mcp-param-trace")) == 1
      refute "mcp-param-" in downcased
      refute Enum.any?(downcased, &String.contains?(&1, " "))
      refute Enum.any?(downcased, &String.contains?(&1, ":"))
      refute Enum.any?(downcased, &String.contains?(&1, "\r"))
      refute Enum.any?(downcased, &String.contains?(&1, "\0"))
      refute header_member?(allowed, "X-Unsafe")
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

  defp header_member?(value, expected) do
    Enum.any?(header_members(value), &(String.downcase(&1) == String.downcase(expected)))
  end

  defp header_members(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end
end
