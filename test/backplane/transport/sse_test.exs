defmodule Backplane.Transport.SSETest do
  use Backplane.ConnCase

  alias Backplane.Transport.SSE

  describe "streaming_requested?/1" do
    test "returns true when Accept header contains text/event-stream" do
      conn =
        Plug.Test.conn(:post, "/mcp")
        |> Plug.Conn.put_req_header("accept", "text/event-stream")

      assert SSE.streaming_requested?(conn)
    end

    test "returns true when Accept header contains mixed types with text/event-stream" do
      conn =
        Plug.Test.conn(:post, "/mcp")
        |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")

      assert SSE.streaming_requested?(conn)
    end

    test "returns false when Accept header is application/json" do
      conn =
        Plug.Test.conn(:post, "/mcp")
        |> Plug.Conn.put_req_header("accept", "application/json")

      refute SSE.streaming_requested?(conn)
    end

    test "returns false when no Accept header is set" do
      conn = Plug.Test.conn(:post, "/mcp")

      refute SSE.streaming_requested?(conn)
    end
  end

  describe "SSE tool call integration" do
    test "returns SSE stream when Accept: text/event-stream is set" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => 1,
          "params" => %{"name" => "skill::list", "arguments" => %{}}
        })

      conn =
        Plug.Test.conn(:post, "/mcp", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("accept", "text/event-stream")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      assert conn.status == 200
      assert {"content-type", "text/event-stream; charset=utf-8"} in conn.resp_headers
      assert {"cache-control", "no-cache"} in conn.resp_headers

      # Parse the SSE response body
      body = IO.iodata_to_binary(conn.resp_body)
      assert body =~ "event: message"
      assert body =~ "data: "

      # Extract the JSON data from SSE
      [data_line] =
        body
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))

      json = String.trim_leading(data_line, "data: ")
      parsed = Jason.decode!(json)

      assert parsed["jsonrpc"] == "2.0"
      assert parsed["id"] == 1
      assert is_map(parsed["result"])
    end

    test "returns regular JSON when Accept header is not SSE" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => 1,
          "params" => %{"name" => "skill::list", "arguments" => %{}}
        })

      conn =
        Plug.Test.conn(:post, "/mcp", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      assert conn.status == 200
      assert {"content-type", "application/json; charset=utf-8"} in conn.resp_headers

      parsed = Jason.decode!(conn.resp_body)
      assert parsed["jsonrpc"] == "2.0"
      assert parsed["id"] == 1
    end
  end
end
