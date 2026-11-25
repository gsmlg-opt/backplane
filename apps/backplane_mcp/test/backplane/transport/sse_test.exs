defmodule Backplane.Transport.SSETest do
  use Backplane.ConnCase

  alias Backplane.Transport.{McpPlug, SSE}

  describe "streaming_requested?/1" do
    test "returns true when Accept header contains text/event-stream" do
      conn =
        conn(:post, "/")
        |> put_req_header("accept", "text/event-stream")

      assert SSE.streaming_requested?(conn)
    end

    test "returns true when Accept header contains mixed types with text/event-stream" do
      conn =
        conn(:post, "/")
        |> put_req_header("accept", "application/json, text/event-stream")

      assert SSE.streaming_requested?(conn)
    end

    test "returns false when Accept header is application/json" do
      conn =
        conn(:post, "/")
        |> put_req_header("accept", "application/json")

      refute SSE.streaming_requested?(conn)
    end

    test "returns false when no Accept header is set" do
      conn = conn(:post, "/")

      refute SSE.streaming_requested?(conn)
    end
  end

  describe "start_stream/1" do
    test "sets SSE headers and returns chunked conn" do
      conn =
        conn(:post, "/")
        |> SSE.start_stream()

      assert conn.status == 200
      assert conn.state == :chunked
      assert {"content-type", "text/event-stream; charset=utf-8"} in conn.resp_headers
      assert {"cache-control", "no-cache"} in conn.resp_headers
      assert get_resp_header(conn, "connection") == []
    end
  end

  describe "send_event/3" do
    test "sends SSE event with JSON-RPC result" do
      conn =
        conn(:post, "/")
        |> SSE.start_stream()
        |> SSE.send_event(42, %{tools: []})

      body = IO.iodata_to_binary(conn.resp_body)
      assert body =~ "event: message\n"

      [data_line] =
        body
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))

      parsed = Formata.JSON.decode!(String.trim_leading(data_line, "data: "))
      assert parsed["jsonrpc"] == "2.0"
      assert parsed["id"] == 42
      assert parsed["result"] == %{"tools" => []}
    end
  end

  describe "send_error_event/4" do
    test "sends SSE event with JSON-RPC error" do
      conn =
        conn(:post, "/")
        |> SSE.start_stream()
        |> SSE.send_error_event(7, -32_601, "Method not found")

      body = IO.iodata_to_binary(conn.resp_body)
      assert body =~ "event: message\n"

      [data_line] =
        body
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))

      parsed = Formata.JSON.decode!(String.trim_leading(data_line, "data: "))
      assert parsed["jsonrpc"] == "2.0"
      assert parsed["id"] == 7
      assert parsed["error"]["code"] == -32_601
      assert parsed["error"]["message"] == "Method not found"
    end
  end

  describe "SSE tool call integration" do
    setup do
      rows = :ets.tab2list(:backplane_tools)

      Backplane.Registry.ToolRegistry.register_managed("fixture", [
        %{
          name: "fixture::echo",
          description: "Echo",
          input_schema: %{"type" => "object"},
          handler: fn arguments -> {:ok, arguments} end
        }
      ])

      on_exit(fn ->
        :ets.delete_all_objects(:backplane_tools)
        :ets.insert(:backplane_tools, rows)
      end)
    end

    test "returns SSE stream when Accept: text/event-stream is set" do
      body =
        Formata.JSON.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => 1,
          "params" => %{"name" => "fixture::echo", "arguments" => %{}}
        })

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> McpPlug.call(McpPlug.init([]))

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
      parsed = Formata.JSON.decode!(json)

      assert parsed["jsonrpc"] == "2.0"
      assert parsed["id"] == 1
      assert is_map(parsed["result"])
    end

    test "returns SSE error event for unknown tool" do
      body =
        Formata.JSON.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => 1,
          "params" => %{"name" => "nonexistent::tool", "arguments" => %{}}
        })

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> McpPlug.call(McpPlug.init([]))

      assert conn.status == 200
      assert {"content-type", "text/event-stream; charset=utf-8"} in conn.resp_headers

      body_text = IO.iodata_to_binary(conn.resp_body)
      assert body_text =~ "event: message"

      [data_line] =
        body_text
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))

      parsed = Formata.JSON.decode!(String.trim_leading(data_line, "data: "))
      assert parsed["jsonrpc"] == "2.0"
      assert parsed["id"] == 1
      # Unknown tool returns isError in result, not a JSON-RPC error
      assert parsed["result"]["isError"] == true
    end

    test "returns regular JSON when Accept header is not SSE" do
      body =
        Formata.JSON.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => 1,
          "params" => %{"name" => "fixture::echo", "arguments" => %{}}
        })

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

      assert conn.status == 200
      assert {"content-type", "application/json; charset=utf-8"} in conn.resp_headers

      parsed = Formata.JSON.decode!(conn.resp_body)
      assert parsed["jsonrpc"] == "2.0"
      assert parsed["id"] == 1
    end
  end
end
