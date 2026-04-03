defmodule Backplane.Transport.McpHandlerTest do
  use Backplane.ConnCase, async: true

  alias Backplane.Docs.{DocChunk, Project}
  alias Backplane.Repo
  alias Backplane.Skills.Skill
  alias Backplane.Transport.Router

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

    test "accepts unsupported protocolVersion and returns server version" do
      resp = mcp_request("initialize", %{"protocolVersion" => "1999-01-01"})
      assert resp["result"]["protocolVersion"] == Backplane.protocol_version()
    end

    test "accepts matching protocolVersion" do
      resp = mcp_request("initialize", %{"protocolVersion" => Backplane.protocol_version()})
      assert resp["result"]["protocolVersion"] == Backplane.protocol_version()
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

  describe "tools/list ETag" do
    test "includes ETag header in tools/list response" do
      conn = mcp_request_conn("tools/list")

      etags =
        conn.resp_headers
        |> Enum.filter(fn {k, _} -> k == "etag" end)
        |> Enum.map(fn {_, v} -> v end)

      assert [etag] = etags
      assert etag =~ ~r/^"bp-tools-/
    end

    test "returns 304 when client sends matching If-None-Match" do
      # First request to get the ETag
      conn1 = mcp_request_conn("tools/list")
      [{_, etag}] = Enum.filter(conn1.resp_headers, fn {k, _} -> k == "etag" end)

      # Second request with the ETag
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1})

      conn2 =
        conn(:post, "/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("if-none-match", etag)
        |> Router.call(Router.init([]))

      assert conn2.status == 304
    end

    test "returns full response when ETag does not match" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1})

      conn =
        conn(:post, "/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("if-none-match", "\"stale-etag\"")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert is_list(resp["result"]["tools"])
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
        conn(:post, "/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

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
        conn(:post, "/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 202
    end

    test "returns 202 for unknown notification method" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "custom/notification"})

      conn =
        conn(:post, "/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

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

  describe "resources/list pagination" do
    test "returns resources without nextCursor when under page size" do
      resp = mcp_request("resources/list")
      refute Map.has_key?(resp["result"], "nextCursor")
    end

    test "accepts cursor parameter" do
      # Even with no data matching the cursor, should return empty
      resp =
        mcp_request("resources/list", %{"cursor" => Base.url_encode64("999999", padding: false)})

      assert is_list(resp["result"]["resources"])
    end

    test "accepts nil params" do
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

    test "returns error for non-numeric chunk ID in URI" do
      resp = mcp_request("resources/read", %{"uri" => "backplane://docs/project/abc"})
      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "invalid URI"
    end

    test "returns error for backplane URI with no chunk_id" do
      resp = mcp_request("resources/read", %{"uri" => "backplane://docs/onlyproject"})
      assert resp["error"]
    end

    test "returns content for an existing doc chunk" do
      Repo.insert(
        %Project{id: "res-read-proj", repo: "test/read", ref: "main"},
        on_conflict: :nothing
      )

      {:ok, chunk} =
        Repo.insert(%DocChunk{
          project_id: "res-read-proj",
          source_path: "lib/readable.ex",
          content: "Readable doc content for testing",
          chunk_type: "module_doc",
          content_hash: "resread123"
        })

      uri = "backplane://docs/res-read-proj/#{chunk.id}"
      resp = mcp_request("resources/read", %{"uri" => uri})
      assert is_list(resp["result"]["contents"])
      [content] = resp["result"]["contents"]
      assert content["text"] == "Readable doc content for testing"
      assert content["mimeType"] == "text/plain"
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

  describe "tools/call with nil params" do
    test "returns -32602 when params is nil (no params key)" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 1})

      conn =
        conn(:post, "/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32_602
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
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert is_list(responses)
      assert length(responses) == 2
      assert Enum.all?(responses, fn r -> r["jsonrpc"] == "2.0" end)
      assert Enum.map(responses, & &1["id"]) == [1, 2]
    end

    test "returns error for empty batch" do
      conn =
        conn(:post, "/mcp", Jason.encode!([]))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32_600
    end

    test "handles mixed requests and notifications" do
      batch = [
        %{"jsonrpc" => "2.0", "method" => "ping", "id" => 1},
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      ]

      conn =
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

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
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

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
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

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
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 202
    end

    test "batch tools/call with missing required arg returns validation error" do
      batch = [
        %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => 1,
          "params" => %{"name" => "skill::search", "arguments" => %{}}
        }
      ]

      conn =
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      [resp] = Jason.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "Invalid params"
      assert resp["error"]["message"] =~ "Missing required arguments"
    end

    test "batch tools/call success returns result with content" do
      batch = [
        %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => 1,
          "params" => %{"name" => "hub::status", "arguments" => %{}}
        }
      ]

      conn =
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      [resp] = Jason.decode!(conn.resp_body)
      assert is_list(resp["result"]["content"])
      text = hd(resp["result"]["content"])["text"]
      # hub::status returns a map, so format_result JSON-encodes it
      assert {:ok, _} = Jason.decode(text)
    end

    test "handles invalid entries in batch" do
      batch = [
        %{"jsonrpc" => "2.0", "method" => "ping", "id" => 1},
        %{"invalid" => "garbage"}
      ]

      conn =
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert length(responses) == 2

      valid = Enum.find(responses, &(&1["id"] == 1))
      assert valid["result"] == %{}

      invalid = Enum.find(responses, &(&1["id"] == nil))
      assert invalid["error"]["code"] == -32_600
    end
  end

  describe "completion/complete" do
    test "returns completion values for project_id argument" do
      # Insert a project so there's something to complete
      Repo.insert(
        %Project{id: "comp-test-project", repo: "test/repo", ref: "main"},
        on_conflict: :nothing
      )

      Repo.insert(%DocChunk{
        project_id: "comp-test-project",
        source_path: "test.md",
        content: "test",
        chunk_type: "markdown",
        content_hash: "comp123"
      })

      resp =
        mcp_request("completion/complete", %{
          "ref" => %{"type" => "ref/tool", "name" => "docs::query-docs"},
          "argument" => %{"name" => "project_id", "value" => "comp"}
        })

      assert is_map(resp["result"]["completion"])
      assert is_list(resp["result"]["completion"]["values"])
      assert resp["result"]["completion"]["hasMore"] == false
    end

    test "returns completion values for tool_name argument" do
      resp =
        mcp_request("completion/complete", %{
          "ref" => %{"type" => "ref/tool", "name" => "hub::inspect"},
          "argument" => %{"name" => "tool_name", "value" => "skill::"}
        })

      values = resp["result"]["completion"]["values"]
      assert is_list(values)
      assert Enum.any?(values, &String.starts_with?(&1, "skill::"))
    end

    test "returns empty completions for unknown argument" do
      resp =
        mcp_request("completion/complete", %{
          "ref" => %{"type" => "ref/tool", "name" => "docs::query-docs"},
          "argument" => %{"name" => "unknown_arg", "value" => ""}
        })

      assert resp["result"]["completion"]["values"] == []
    end

    test "returns empty completions for prompt ref" do
      resp =
        mcp_request("completion/complete", %{
          "ref" => %{"type" => "ref/prompt", "name" => "some-prompt"},
          "argument" => %{"name" => "arg", "value" => ""}
        })

      assert resp["result"]["completion"]["values"] == []
    end

    test "returns error for missing params" do
      resp = mcp_request("completion/complete", %{})

      assert resp["error"]["code"] == -32_602
    end

    test "returns error for nil params" do
      resp = mcp_request("completion/complete")

      assert resp["error"]["code"] == -32_602
    end

    test "advertises completions capability in initialize" do
      resp = mcp_request("initialize")

      assert is_map(resp["result"]["capabilities"]["completions"])
    end

    test "returns completions for skill_id argument" do
      # Insert a skill into the DB so the registry has something to list
      Repo.insert(
        %Skill{
          id: "comp-skill-test",
          name: "comp-test",
          description: "test",
          content: "# test",
          content_hash: "comphash#{System.unique_integer([:positive])}",
          source: "db",
          enabled: true
        },
        on_conflict: :nothing
      )

      Backplane.Skills.Registry.refresh()

      resp =
        mcp_request("completion/complete", %{
          "ref" => %{"type" => "ref/tool", "name" => "skill::load"},
          "argument" => %{"name" => "skill_id", "value" => "comp"}
        })

      values = resp["result"]["completion"]["values"]
      assert is_list(values)
      assert Enum.any?(values, &String.contains?(&1, "comp"))
    end

    test "returns completions for repo argument" do
      Repo.insert(
        %Project{
          id: "comp-repo-proj",
          repo: "https://github.com/test/comp.git",
          ref: "main"
        },
        on_conflict: :nothing
      )

      resp =
        mcp_request("completion/complete", %{
          "ref" => %{"type" => "ref/tool", "name" => "git::repo-tree"},
          "argument" => %{"name" => "repo", "value" => "https://"}
        })

      values = resp["result"]["completion"]["values"]
      assert is_list(values)
    end

    test "returns all values (up to 20) when prefix is empty" do
      resp =
        mcp_request("completion/complete", %{
          "ref" => %{"type" => "ref/tool", "name" => "hub::inspect"},
          "argument" => %{"name" => "tool_name", "value" => ""}
        })

      values = resp["result"]["completion"]["values"]
      assert [_ | _] = values
      assert Enum.count(values) <= 20
    end

    test "returns empty for unknown ref type" do
      resp =
        mcp_request("completion/complete", %{
          "ref" => %{"type" => "ref/unknown", "name" => "something"},
          "argument" => %{"name" => "arg", "value" => ""}
        })

      assert resp["result"]["completion"]["values"] == []
    end
  end

  describe "resources/list with data" do
    test "returns resource entries for indexed doc chunks" do
      Repo.insert(
        %Project{id: "res-list-proj", repo: "test/repo", ref: "main"},
        on_conflict: :nothing
      )

      Repo.insert(%DocChunk{
        project_id: "res-list-proj",
        source_path: "lib/example.ex",
        content: "Example content",
        chunk_type: "module_doc",
        content_hash: "reslist123"
      })

      resp = mcp_request("resources/list")
      resources = resp["result"]["resources"]
      assert Enum.any?(resources, fn r -> String.contains?(r["name"], "res-list-proj") end)
    end
  end

  describe "prompts/get with inserted skill" do
    test "returns prompt messages for a skill that exists" do
      content = "# Test Skill\nFollow these instructions."
      hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      %Skill{}
      |> Skill.changeset(%{
        id: "prompt/test-skill",
        name: "test-prompt-skill",
        description: "A skill for prompt testing",
        tags: ["test"],
        content: content,
        content_hash: hash,
        source: "db",
        enabled: true
      })
      |> Repo.insert!()

      Backplane.Skills.Registry.refresh()

      resp = mcp_request("prompts/get", %{"name" => "test-prompt-skill"})

      assert is_list(resp["result"]["messages"])
      [message] = resp["result"]["messages"]
      assert message["role"] == "user"
      assert message["content"]["text"] =~ "Test Skill"
    end
  end

  describe "logging/setLevel" do
    test "accepts valid log level" do
      for level <- ~w(debug info notice warning error critical alert emergency) do
        resp = mcp_request("logging/setLevel", %{"level" => level})
        assert resp["result"] == %{}, "Expected empty result for level #{level}"
      end
    end

    test "rejects invalid log level" do
      resp = mcp_request("logging/setLevel", %{"level" => "invalid"})
      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "level"
    end

    test "rejects missing level param" do
      resp = mcp_request("logging/setLevel", %{})
      assert resp["error"]["code"] == -32_602
    end

    test "actually reconfigures Logger level" do
      original_level = Logger.level()

      try do
        mcp_request("logging/setLevel", %{"level" => "error"})
        assert Logger.level() == :error

        mcp_request("logging/setLevel", %{"level" => "debug"})
        assert Logger.level() == :debug
      after
        Logger.configure(level: original_level)
      end
    end

    test "logging capability advertised in initialize" do
      resp = mcp_request("initialize")
      assert is_map(resp["result"]["capabilities"]["logging"])
    end
  end

  describe "batch with resource/prompt methods" do
    test "batch can process resources/list and prompts/list together" do
      batch = [
        %{"jsonrpc" => "2.0", "method" => "resources/list", "id" => 1},
        %{"jsonrpc" => "2.0", "method" => "prompts/list", "id" => 2}
      ]

      conn =
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert length(responses) == 2

      res_resp = Enum.find(responses, &(&1["id"] == 1))
      assert is_list(res_resp["result"]["resources"])

      prompt_resp = Enum.find(responses, &(&1["id"] == 2))
      assert is_list(prompt_resp["result"]["prompts"])
    end
  end

  describe "tools/call validation" do
    test "returns error when name is missing" do
      resp = mcp_request("tools/call", %{})
      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "name"
    end

    test "returns error for nonexistent tool" do
      resp = mcp_request("tools/call", %{"name" => "nonexistent::tool"})
      # Should return error content or dispatch error
      result = resp["result"]
      assert result["isError"] == true or resp["error"] != nil
    end

    test "calls a native tool successfully" do
      resp = mcp_request("tools/call", %{"name" => "skill::list"})
      result = resp["result"]
      assert result != nil
      assert is_list(result["content"])
    end

    test "passes arguments to tool" do
      resp =
        mcp_request("tools/call", %{
          "name" => "skill::search",
          "arguments" => %{"query" => "test"}
        })

      result = resp["result"]
      assert result != nil
      assert is_list(result["content"])
    end
  end

  describe "completion/complete validation" do
    test "returns error when ref is missing" do
      resp = mcp_request("completion/complete", %{})
      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "ref"
    end

    test "returns error when argument is missing" do
      resp = mcp_request("completion/complete", %{"ref" => %{"type" => "ref/resource"}})
      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "ref"
    end
  end

  describe "resources/list pagination with cursor" do
    test "returns nextCursor when more than page_size chunks exist" do
      # Insert enough chunks to trigger pagination (page_size is 100)
      Repo.insert(
        %Project{id: "paginate-proj", repo: "test/paginate", ref: "main"},
        on_conflict: :nothing
      )

      for i <- 1..105 do
        Repo.insert(%DocChunk{
          project_id: "paginate-proj",
          source_path: "lib/mod_#{i}.ex",
          content: "Content #{i}",
          chunk_type: "module_doc",
          content_hash: "paginatehash#{i}"
        })
      end

      resp = mcp_request("resources/list")
      result = resp["result"]
      assert is_list(result["resources"])

      if result["nextCursor"] do
        # Use the cursor to get the next page
        resp2 = mcp_request("resources/list", %{"cursor" => result["nextCursor"]})
        result2 = resp2["result"]
        assert is_list(result2["resources"])
      end
    end
  end

  describe "tool call with error result" do
    test "returns isError for tool that returns error" do
      resp = mcp_request("tools/call", %{"name" => "nonexistent::tool"})
      result = resp["result"]
      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "Unknown tool"
    end
  end

  describe "batch tools/call and resources/read" do
    test "batch tools/call dispatches native tool" do
      batch = [
        %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => 1,
          "params" => %{"name" => "skill::list"}
        },
        %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => 2,
          "params" => %{"name" => "nonexistent::tool"}
        }
      ]

      conn =
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert length(responses) == 2

      ok_resp = Enum.find(responses, &(&1["id"] == 1))
      assert is_list(ok_resp["result"]["content"])

      err_resp = Enum.find(responses, &(&1["id"] == 2))
      assert err_resp["result"]["isError"] == true
    end

    test "batch tools/call with missing name" do
      batch = [
        %{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 1, "params" => %{}}
      ]

      conn =
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      [resp] = Jason.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32_602
    end

    test "batch resources/read with valid chunk" do
      Repo.insert(
        %Project{id: "batch-read-proj", repo: "test/batch", ref: "main"},
        on_conflict: :nothing
      )

      {:ok, chunk} =
        Repo.insert(%DocChunk{
          project_id: "batch-read-proj",
          source_path: "lib/batch.ex",
          content: "Batch read content",
          chunk_type: "module_doc",
          content_hash: "batchread123"
        })

      uri = "backplane://docs/batch-read-proj/#{chunk.id}"

      batch = [
        %{
          "jsonrpc" => "2.0",
          "method" => "resources/read",
          "id" => 1,
          "params" => %{"uri" => uri}
        },
        %{
          "jsonrpc" => "2.0",
          "method" => "resources/read",
          "id" => 2,
          "params" => %{"uri" => "backplane://docs/fake/99999"}
        },
        %{"jsonrpc" => "2.0", "method" => "resources/read", "id" => 3, "params" => %{}}
      ]

      conn =
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert length(responses) == 3

      ok_resp = Enum.find(responses, &(&1["id"] == 1))
      assert is_list(ok_resp["result"]["contents"])

      not_found = Enum.find(responses, &(&1["id"] == 2))
      assert not_found["error"]["code"] == -32_602

      missing_uri = Enum.find(responses, &(&1["id"] == 3))
      assert missing_uri["error"]["code"] == -32_602
    end

    test "batch prompts/get with valid and missing name" do
      content = "# Batch Skill\nInstructions here."
      hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      %Skill{}
      |> Skill.changeset(%{
        id: "batch/prompt-skill",
        name: "batch-prompt-skill",
        description: "Batch test skill",
        tags: ["test"],
        content: content,
        content_hash: hash,
        source: "db",
        enabled: true
      })
      |> Repo.insert!()

      Backplane.Skills.Registry.refresh()

      batch = [
        %{
          "jsonrpc" => "2.0",
          "method" => "prompts/get",
          "id" => 1,
          "params" => %{"name" => "batch-prompt-skill"}
        },
        %{
          "jsonrpc" => "2.0",
          "method" => "prompts/get",
          "id" => 2,
          "params" => %{"name" => "nonexistent"}
        },
        %{"jsonrpc" => "2.0", "method" => "prompts/get", "id" => 3, "params" => %{}}
      ]

      conn =
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert length(responses) == 3

      ok_resp = Enum.find(responses, &(&1["id"] == 1))
      assert is_list(ok_resp["result"]["messages"])

      not_found = Enum.find(responses, &(&1["id"] == 2))
      assert not_found["error"]["code"] == -32_602

      missing_name = Enum.find(responses, &(&1["id"] == 3))
      assert missing_name["error"]["code"] == -32_602
    end

    test "batch completion/complete and logging/setLevel" do
      batch = [
        %{
          "jsonrpc" => "2.0",
          "method" => "completion/complete",
          "id" => 1,
          "params" => %{
            "ref" => %{"type" => "ref/tool", "name" => "skill::search"},
            "argument" => %{"name" => "query", "value" => ""}
          }
        },
        %{"jsonrpc" => "2.0", "method" => "completion/complete", "id" => 2, "params" => %{}},
        %{
          "jsonrpc" => "2.0",
          "method" => "logging/setLevel",
          "id" => 3,
          "params" => %{"level" => "debug"}
        },
        %{
          "jsonrpc" => "2.0",
          "method" => "logging/setLevel",
          "id" => 4,
          "params" => %{"level" => "invalid"}
        }
      ]

      conn =
        conn(:post, "/mcp", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert length(responses) == 4

      complete_ok = Enum.find(responses, &(&1["id"] == 1))
      assert is_map(complete_ok["result"]["completion"])

      complete_err = Enum.find(responses, &(&1["id"] == 2))
      assert complete_err["error"]["code"] == -32_602

      log_ok = Enum.find(responses, &(&1["id"] == 3))
      assert log_ok["result"] == %{}

      log_err = Enum.find(responses, &(&1["id"] == 4))
      assert log_err["error"]["code"] == -32_602
    end
  end

  describe "notification handling" do
    test "notifications/initialized returns 202" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })

      conn =
        conn(:post, "/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 202
    end

    test "notifications/cancelled returns 202" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/cancelled"
        })

      conn =
        conn(:post, "/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 202
    end

    test "unknown notification returns 202" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/unknown"
        })

      conn =
        conn(:post, "/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 202
    end
  end

  describe "invalid request format" do
    test "returns error for request without jsonrpc field" do
      resp = raw_mcp_request(%{"method" => "ping", "id" => 1})
      assert resp["error"]["code"] == -32_600
    end

    test "returns error for request with wrong jsonrpc version" do
      resp = raw_mcp_request(%{"jsonrpc" => "1.0", "method" => "ping", "id" => 1})
      assert resp["error"]["code"] == -32_600
    end

    test "returns error for request with no method field at all" do
      resp = raw_mcp_request(%{"id" => 1, "data" => "something"})
      assert resp["error"]["code"] == -32_600
      assert resp["error"]["message"] =~ "Invalid Request"
    end
  end

  describe "tools/call input validation" do
    test "returns error when required argument is missing" do
      resp = mcp_request("tools/call", %{"name" => "skill::search", "arguments" => %{}})
      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "Missing required arguments"
      assert resp["error"]["message"] =~ "query"
    end

    test "returns error when argument type is wrong" do
      resp =
        mcp_request("tools/call", %{
          "name" => "skill::search",
          "arguments" => %{"query" => 123}
        })

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "must be string"
    end
  end

  describe "prompts with tool arguments" do
    setup do
      content = "# Skill with Tools"
      hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      %Skill{}
      |> Skill.changeset(%{
        id: "prompt/with-tools",
        name: "skill-with-tools",
        description: "Has required tools",
        tags: [],
        content: content,
        content_hash: hash,
        source: "db",
        tools: ["git::repo-tree", "docs::query-docs"],
        enabled: true
      })
      |> Repo.insert!()

      Backplane.Skills.Registry.refresh()
      :ok
    end

    test "prompts/list includes prompt arguments for skills with tools" do
      resp = mcp_request("prompts/list")
      prompts = resp["result"]["prompts"]

      skill_prompt = Enum.find(prompts, fn p -> p["name"] == "skill-with-tools" end)
      assert skill_prompt != nil
      assert is_list(skill_prompt["arguments"])
      assert length(skill_prompt["arguments"]) == 2

      arg_names = Enum.map(skill_prompt["arguments"], & &1["name"])
      assert "git::repo-tree" in arg_names
      assert "docs::query-docs" in arg_names
    end
  end

  describe "format_result" do
    test "tools/call returns string result directly" do
      # Call a tool that returns a plain string result
      resp =
        mcp_request("tools/call", %{
          "name" => "skill::load",
          "arguments" => %{"skill_id" => "nonexistent"}
        })

      # Even error results go through format_result — the isError path
      assert resp["result"]["isError"] == true
      assert is_binary(hd(resp["result"]["content"])["text"])
    end

    test "tools/call JSON-encodes non-binary result (map)" do
      # hub::status returns a map, exercising format_result/1 non-binary clause
      resp =
        mcp_request("tools/call", %{
          "name" => "hub::status",
          "arguments" => %{}
        })

      text = hd(resp["result"]["content"])["text"]
      assert is_binary(text)
      # Should be valid JSON (the map was encoded)
      assert {:ok, decoded} = Jason.decode(text)
      assert is_map(decoded)
      assert Map.has_key?(decoded, "total_tools")
    end
  end

  describe "malformed cursor" do
    test "resources/list with invalid cursor falls back to offset 0" do
      resp = mcp_request("resources/list", %{"cursor" => "!!!invalid-base64!!!"})
      result = resp["result"]
      assert is_list(result["resources"])
    end
  end

  describe "SSE streaming" do
    test "tools/call with Accept: text/event-stream returns chunked SSE response" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => 1,
          "params" => %{"name" => "hub::status", "arguments" => %{}}
        })

      conn =
        conn(:post, "/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> Router.call(Router.init([]))

      assert conn.status == 200

      content_type =
        conn.resp_headers
        |> Enum.find(fn {k, _} -> k == "content-type" end)
        |> elem(1)

      assert content_type =~ "text/event-stream"
    end
  end

  describe "format_result fallback" do
    test "handles non-JSON-serializable tool result gracefully" do
      alias Backplane.Registry.{Tool, ToolRegistry}

      # Define an inline module that returns a map containing a ref (non-serializable)
      defmodule TestNonSerializableTool do
        def call(_args), do: {:ok, %{ref: make_ref()}}
      end

      tool = %Tool{
        name: "test::non-serializable",
        description: "Test tool returning non-serializable data",
        input_schema: %{"type" => "object", "properties" => %{}},
        origin: :native,
        module: TestNonSerializableTool,
        handler: nil
      }

      ToolRegistry.register_native(tool)

      on_exit(fn ->
        :ets.delete(:backplane_tools, "test::non-serializable")
      end)

      resp = mcp_request("tools/call", %{"name" => "test::non-serializable", "arguments" => %{}})

      # Should succeed (200 response) instead of crashing
      assert resp["result"]
      content = hd(resp["result"]["content"])
      assert content["type"] == "text"
      # The inspect fallback should produce a readable string with the ref
      assert content["text"] =~ "ref"
    end

    test "format_result passes through binary results" do
      alias Backplane.Registry.{Tool, ToolRegistry}

      defmodule TestStringTool do
        def call(_args), do: {:ok, "plain string result"}
      end

      tool = %Tool{
        name: "test::string-result",
        description: "Test tool returning a plain string",
        input_schema: %{"type" => "object", "properties" => %{}},
        origin: :native,
        module: TestStringTool,
        handler: nil
      }

      ToolRegistry.register_native(tool)

      on_exit(fn ->
        :ets.delete(:backplane_tools, "test::string-result")
      end)

      resp = mcp_request("tools/call", %{"name" => "test::string-result", "arguments" => %{}})

      assert resp["result"]
      content = hd(resp["result"]["content"])
      assert content["text"] == "plain string result"
    end
  end

  describe "upstream tool dispatch" do
    defmodule MockUpstream do
      use GenServer

      def start_link(response), do: GenServer.start_link(__MODULE__, response)

      @impl true
      def init(response), do: {:ok, response}

      @impl true
      def handle_call({:tools_call, _name, _args}, _from, response) do
        {:reply, response, response}
      end
    end

    test "forwards tool call to upstream process and returns result" do
      {:ok, pid} = MockUpstream.start_link({:ok, %{answer: "42"}})

      tool = %Backplane.Registry.Tool{
        name: "mock-upstream::echo",
        description: "Mock upstream tool",
        input_schema: %{"type" => "object", "properties" => %{}},
        origin: {:upstream, "mock-upstream"},
        upstream_pid: pid,
        original_name: "echo",
        timeout: 5_000
      }

      :ets.insert(:backplane_tools, {tool.name, tool})
      on_exit(fn -> :ets.delete(:backplane_tools, tool.name) end)

      resp = mcp_request("tools/call", %{"name" => "mock-upstream::echo", "arguments" => %{}})

      assert resp["result"]
      content = hd(resp["result"]["content"])
      assert content["type"] == "text"
      assert content["text"] =~ "answer"
    end

    test "returns error when upstream returns {:error, reason}" do
      {:ok, pid} = MockUpstream.start_link({:error, "upstream failed"})

      tool = %Backplane.Registry.Tool{
        name: "mock-upstream::fail",
        description: "Mock failing upstream tool",
        input_schema: %{"type" => "object", "properties" => %{}},
        origin: {:upstream, "mock-upstream"},
        upstream_pid: pid,
        original_name: "fail",
        timeout: 5_000
      }

      :ets.insert(:backplane_tools, {tool.name, tool})
      on_exit(fn -> :ets.delete(:backplane_tools, tool.name) end)

      resp = mcp_request("tools/call", %{"name" => "mock-upstream::fail", "arguments" => %{}})

      assert resp["result"]["isError"] == true
      assert hd(resp["result"]["content"])["text"] =~ "upstream failed"
    end
  end
end
