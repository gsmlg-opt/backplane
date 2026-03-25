defmodule Backplane.Transport.McpHandlerTest do
  use Backplane.ConnCase, async: true

  describe "initialize" do
    test "returns protocolVersion and serverInfo" do
      resp = mcp_request("initialize")

      assert resp["result"]["protocolVersion"]
      assert resp["result"]["serverInfo"]["name"] == "backplane"
      assert resp["result"]["serverInfo"]["version"]
    end

    test "returns tools capability with listChanged" do
      resp = mcp_request("initialize")

      assert resp["result"]["capabilities"]["tools"]["listChanged"] == true
    end

    test "returns Mcp-Session-Id header" do
      conn = mcp_request_conn("initialize")

      session_ids =
        conn.resp_headers
        |> Enum.filter(fn {k, _v} -> k == "mcp-session-id" end)
        |> Enum.map(fn {_k, v} -> v end)

      assert length(session_ids) == 1
      [session_id] = session_ids
      assert is_binary(session_id)
      assert String.length(session_id) > 10
    end
  end

  describe "tools/list" do
    test "returns tools array including native skill tools" do
      resp = mcp_request("tools/list")

      tools = resp["result"]["tools"]
      assert is_list(tools)
      names = Enum.map(tools, & &1["name"])
      assert "skill::search" in names
      assert "skill::list" in names
    end
  end

  describe "tools/call" do
    test "returns error for unknown tool name" do
      resp = mcp_request("tools/call", %{"name" => "nonexistent::tool", "arguments" => %{}})

      assert resp["result"]["isError"] == true
      assert hd(resp["result"]["content"])["text"] =~ "Unknown tool"
    end

    test "returns -32602 for missing tool name" do
      resp = mcp_request("tools/call", %{"arguments" => %{}})

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "name"
    end

    test "returns -32602 for nil params" do
      resp = mcp_request("tools/call")

      assert resp["error"]["code"] == -32_602
    end

    test "returns -32602 for missing required arguments" do
      resp = mcp_request("tools/call", %{"name" => "docs::query-docs", "arguments" => %{}})

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "Missing required arguments"
      assert resp["error"]["message"] =~ "project_id"
    end

    test "returns -32602 for wrong argument type" do
      resp =
        mcp_request("tools/call", %{
          "name" => "docs::query-docs",
          "arguments" => %{"project_id" => 123, "query" => "test"}
        })

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "project_id"
      assert resp["error"]["message"] =~ "string"
    end
  end

  describe "ping" do
    test "returns empty result" do
      resp = mcp_request("ping")

      assert resp["result"] == %{}
    end
  end

  describe "notifications" do
    test "returns 202 for notifications (no id)" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      conn =
        Plug.Test.conn(:post, "/mcp", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      assert conn.status == 202
    end
  end

  describe "successful tool call" do
    test "calls skill::list and returns results" do
      resp = mcp_request("tools/call", %{"name" => "skill::list", "arguments" => %{}})

      refute resp["result"]["isError"]
      content = hd(resp["result"]["content"])
      assert content["type"] == "text"
    end
  end

  describe "invalid request" do
    test "returns -32600 for missing jsonrpc field" do
      resp = raw_mcp_request(%{"method" => "initialize", "id" => 1})

      assert resp["error"]["code"] == -32_600
    end

    test "returns -32601 for unknown method" do
      resp = mcp_request("nonexistent/method")

      assert resp["error"]["code"] == -32_601
      assert resp["error"]["message"] =~ "Method not found"
    end
  end
end
