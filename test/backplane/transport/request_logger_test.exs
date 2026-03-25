defmodule Backplane.Transport.RequestLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Backplane.Transport.RequestLogger

  setup do
    prev_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: prev_level) end)
  end

  describe "call/2" do
    test "logs request with method and path" do
      log =
        capture_log(fn ->
          Plug.Test.conn(:get, "/health")
          |> RequestLogger.call([])
          |> Plug.Conn.send_resp(200, "ok")
        end)

      assert log =~ "GET /health"
      assert log =~ "200"
    end

    test "logs MCP requests with JSON-RPC method" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1})

      log =
        capture_log(fn ->
          Plug.Test.conn(:post, "/mcp", body)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Parsers.call(
            Plug.Parsers.init(parsers: [:json], json_decoder: Jason, pass: ["application/json"])
          )
          |> RequestLogger.call([])
          |> Plug.Conn.send_resp(200, "{}")
        end)

      assert log =~ "MCP tools/list"
    end

    test "logs duration in milliseconds" do
      log =
        capture_log(fn ->
          Plug.Test.conn(:get, "/health")
          |> RequestLogger.call([])
          |> Plug.Conn.send_resp(200, "ok")
        end)

      assert log =~ ~r/\d+\.\d+ms/
    end

    test "logs errors at error level for 5xx status" do
      log =
        capture_log(fn ->
          Plug.Test.conn(:get, "/broken")
          |> RequestLogger.call([])
          |> Plug.Conn.send_resp(500, "error")
        end)

      assert log =~ "GET /broken"
      assert log =~ "500"
    end
  end
end
