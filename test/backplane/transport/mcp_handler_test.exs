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
  end

  describe "ping" do
    test "returns empty result" do
      resp = mcp_request("ping")

      assert resp["result"] == %{}
    end
  end

  describe "invalid request" do
    test "returns -32600 for missing jsonrpc field" do
      resp = raw_mcp_request(%{"method" => "initialize", "id" => 1})

      assert resp["error"]["code"] == -32600
    end

    test "returns -32601 for unknown method" do
      resp = mcp_request("nonexistent/method")

      assert resp["error"]["code"] == -32601
      assert resp["error"]["message"] =~ "Method not found"
    end
  end
end
