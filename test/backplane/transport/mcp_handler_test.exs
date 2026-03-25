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
    test "returns 202 for notifications/initialized (no id)" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      conn =
        Plug.Test.conn(:post, "/mcp", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      assert conn.status == 202
    end

    test "returns 202 for notifications/cancelled" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/cancelled",
          "params" => %{"requestId" => 42, "reason" => "timeout"}
        })

      conn =
        Plug.Test.conn(:post, "/mcp", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      assert conn.status == 202
    end

    test "returns 202 for unknown notification method" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "custom/notification"})

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

  describe "resources/list" do
    test "returns resources array" do
      resp = mcp_request("resources/list")

      assert is_list(resp["result"]["resources"])
    end
  end

  describe "resources/read" do
    test "returns error for invalid URI" do
      resp = mcp_request("resources/read", %{"uri" => "invalid://uri"})

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "invalid URI"
    end

    test "returns error for missing uri param" do
      resp = mcp_request("resources/read", %{})

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "uri"
    end

    test "returns error for non-existent resource" do
      resp = mcp_request("resources/read", %{"uri" => "backplane://docs/fake/999999"})

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "not found"
    end
  end

  describe "prompts/list" do
    test "returns prompts array" do
      resp = mcp_request("prompts/list")

      assert is_list(resp["result"]["prompts"])
    end
  end

  describe "prompts/get" do
    test "returns error for non-existent prompt" do
      resp = mcp_request("prompts/get", %{"name" => "nonexistent"})

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "not found"
    end

    test "returns error for missing name param" do
      resp = mcp_request("prompts/get", %{})

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "name"
    end
  end

  describe "initialize capabilities" do
    test "advertises resources and prompts capabilities" do
      resp = mcp_request("initialize")

      capabilities = resp["result"]["capabilities"]
      assert is_map(capabilities["resources"])
      assert is_map(capabilities["prompts"])
      assert is_map(capabilities["tools"])
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

  describe "batch requests" do
    test "processes multiple requests and returns array" do
      batch = [
        %{"jsonrpc" => "2.0", "method" => "ping", "id" => 1},
        %{"jsonrpc" => "2.0", "method" => "ping", "id" => 2}
      ]

      conn =
        Plug.Test.conn(:post, "/mcp", Jason.encode!(batch))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert is_list(responses)
      assert length(responses) == 2
      assert Enum.all?(responses, fn r -> r["jsonrpc"] == "2.0" end)
      assert Enum.map(responses, & &1["id"]) == [1, 2]
    end

    test "returns error for empty batch" do
      conn =
        Plug.Test.conn(:post, "/mcp", Jason.encode!([]))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32_600
    end

    test "handles mixed requests and notifications" do
      batch = [
        %{"jsonrpc" => "2.0", "method" => "ping", "id" => 1},
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      ]

      conn =
        Plug.Test.conn(:post, "/mcp", Jason.encode!(batch))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      responses = Jason.decode!(conn.resp_body)
      # Only the request with id gets a response, notification is silent
      assert length(responses) == 1
      assert hd(responses)["id"] == 1
    end

    test "batch processes initialize and tools/list together" do
      batch = [
        %{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1},
        %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 2}
      ]

      conn =
        Plug.Test.conn(:post, "/mcp", Jason.encode!(batch))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert length(responses) == 2

      init_resp = Enum.find(responses, &(&1["id"] == 1))
      assert init_resp["result"]["protocolVersion"]
      assert init_resp["result"]["capabilities"]

      tools_resp = Enum.find(responses, &(&1["id"] == 2))
      assert is_list(tools_resp["result"]["tools"])
    end

    test "batch returns method not found for unknown methods" do
      batch = [
        %{"jsonrpc" => "2.0", "method" => "nonexistent", "id" => 1}
      ]

      conn =
        Plug.Test.conn(:post, "/mcp", Jason.encode!(batch))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert [resp] = responses
      assert resp["error"]["code"] == -32_601
    end

    test "batch with all notifications returns 202" do
      batch = [
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        %{"jsonrpc" => "2.0", "method" => "notifications/cancelled"}
      ]

      conn =
        Plug.Test.conn(:post, "/mcp", Jason.encode!(batch))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      assert conn.status == 202
    end

    test "handles invalid entries in batch" do
      batch = [
        %{"jsonrpc" => "2.0", "method" => "ping", "id" => 1},
        %{"invalid" => "garbage"}
      ]

      conn =
        Plug.Test.conn(:post, "/mcp", Jason.encode!(batch))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Transport.Router.call(Backplane.Transport.Router.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert length(responses) == 2

      valid = Enum.find(responses, &(&1["id"] == 1))
      assert valid["result"] == %{}

      invalid = Enum.find(responses, &(&1["id"] == nil))
      assert invalid["error"]["code"] == -32_600
    end
  end
end
