defmodule Backplane.Transport.McpHandlerTest do
  use Backplane.ConnCase, async: false

  import Backplane.Auth.Fixtures
  import Backplane.SkillArchiveCase
  import Ecto.Query
  import ExUnit.CaptureLog

  alias Backplane.Auth.Resources
  alias Backplane.Audit.SkillLoadLog
  alias BackplaneMcp.Fixtures
  alias Backplane.Repo
  alias Backplane.Skills
  alias Backplane.Skills.Hosts
  alias Backplane.Skills.Skill
  alias Backplane.Memory.Memories.Memory, as: MemorySchema
  alias Backplane.Transport.McpPlug

  @moduletag :tmp_dir
  @blob_setting "skills.blob.local_root"
  @service_setting "services.skill.enabled"
  @legacy_versions ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

  setup %{tmp_dir: tmp_dir} do
    previous_blob_root = Backplane.Settings.get(@blob_setting)
    previous_service_setting = :ets.lookup(:backplane_settings, @service_setting)
    :ets.insert(:backplane_settings, {@blob_setting, Path.join(tmp_dir, "blobs")})
    :ets.insert(:backplane_settings, {@service_setting, true})
    Backplane.Skills.Registry.refresh()

    alias Backplane.Registry.{Tool, ToolRegistry}

    previous_tool_rows = :ets.tab2list(:backplane_tools)
    :ets.delete_all_objects(:backplane_tools)

    for module <- [Backplane.Tools.Hub, Backplane.Tools.Admin],
        tool_def <- module.tools() do
      tool = %Tool{
        name: tool_def.name,
        description: tool_def.description,
        input_schema: tool_def.input_schema,
        origin: :native,
        module: tool_def.module,
        handler: tool_def.handler
      }

      ToolRegistry.register_native(tool)
    end

    ToolRegistry.register_managed("skill", Backplane.Services.Skills.tools())

    ToolRegistry.register_native(%Tool{
      name: "public::echo",
      description: "Visible test tool",
      input_schema: %{"type" => "object", "properties" => %{}},
      origin: :native,
      module: __MODULE__.PublicTool,
      handler: nil
    })

    on_exit(fn ->
      :ets.insert(:backplane_settings, {@blob_setting, previous_blob_root})
      :ets.delete(:backplane_settings, @service_setting)

      if previous_service_setting != [] do
        :ets.insert(:backplane_settings, previous_service_setting)
      end

      :ets.delete_all_objects(:backplane_tools)

      if previous_tool_rows != [] do
        :ets.insert(:backplane_tools, previous_tool_rows)
      end
    end)

    :ok
  end

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

    test "falls back from a protocol version not implemented by the hub transport" do
      resp =
        mcp_request("initialize", %{
          "protocolVersion" => Backplane.McpProtocol.Protocol.latest_version()
        })

      assert resp["result"]["protocolVersion"] == Backplane.protocol_version()
    end

    test "falls back to the legacy endpoint default for 2026-07-28" do
      resp = mcp_request("initialize", %{"protocolVersion" => "2026-07-28"})
      assert resp["result"]["protocolVersion"] == "2025-11-25"
    end

    for version <- @legacy_versions do
      test "accepts legacy protocolVersion #{version}" do
        resp = mcp_request("initialize", %{"protocolVersion" => unquote(version)})
        assert resp["result"]["protocolVersion"] == unquote(version)
      end
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
    test "returns public and skill tools while hiding hub and admin tools" do
      resp = mcp_request("tools/list")

      tools = resp["result"]["tools"]
      assert is_list(tools)
      names = Enum.map(tools, & &1["name"])
      assert "public::echo" in names
      assert "skill::search" in names
      refute "hub::status" in names
      refute "admin::clients" in names
    end

    test "registers Skills tools with a managed origin" do
      assert %{origin: {:managed, "skill"}} =
               Backplane.Registry.ToolRegistry.lookup("skill::search")
    end

    test "removes Skills tools when the managed service is disabled" do
      assert :ok = Backplane.Services.Skills.set_enabled(false)

      names = mcp_request("tools/list")["result"]["tools"] |> Enum.map(& &1["name"])

      refute Enum.any?(names, &String.starts_with?(&1, "skill::"))
      assert :not_found = Backplane.Registry.ToolRegistry.resolve("skill::list")
    end

    test "exposes v1 archive skill tools and hides legacy mutation tools" do
      resp = mcp_request("tools/list")

      names = resp["result"]["tools"] |> Enum.map(& &1["name"])
      assert "skill::load" in names
      assert "skill::download" in names
      assert "skill::publish" in names
      refute "skill::create" in names
      refute "skill::update" in names
      refute "skill::versions" in names
    end

    test "normalizes stale path-like upstream prefixes in API response" do
      alias Backplane.Registry.Tool

      stale_tool = %Tool{
        name: "/github::search",
        description: "Search repositories",
        input_schema: %{},
        origin: {:upstream, "/github"},
        upstream_pid: self(),
        original_name: "search"
      }

      normalized_tool = %Tool{
        name: "github::search",
        description: "Search repositories",
        input_schema: %{},
        origin: {:upstream, "github"},
        upstream_pid: self(),
        original_name: "search"
      }

      :ets.insert(:backplane_tools, [
        {stale_tool.name, stale_tool},
        {normalized_tool.name, normalized_tool}
      ])

      on_exit(fn ->
        :ets.delete(:backplane_tools, stale_tool.name)
        :ets.delete(:backplane_tools, normalized_tool.name)
      end)

      resp = mcp_request("tools/list")
      names = Enum.map(resp["result"]["tools"], & &1["name"])

      refute "/github::search" in names
      assert "github::search" in names
      assert Enum.count(names, &(&1 == "github::search")) == 1
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
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("if-none-match", etag)
        |> McpPlug.call(McpPlug.init([]))

      assert conn2.status == 304
    end

    test "returns full response when ETag does not match" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1})

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("if-none-match", "\"stale-etag\"")
        |> McpPlug.call(McpPlug.init([]))

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
      resp = mcp_request("tools/call", %{"name" => "skill::search", "arguments" => %{}})

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "Missing required arguments"
      assert resp["error"]["message"] =~ "query"
    end

    test "returns -32602 when skill::load omits required slug" do
      resp = mcp_request("tools/call", %{"name" => "skill::load", "arguments" => %{}})

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "Missing required arguments"
      assert resp["error"]["message"] =~ "slug"
    end

    test "returns -32602 for wrong argument type" do
      resp =
        mcp_request("tools/call", %{
          "name" => "skill::search",
          "arguments" => %{"query" => 123}
        })

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "query"
      assert resp["error"]["message"] =~ "must be string"
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
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

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
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

      assert conn.status == 202
    end

    test "returns 202 for unknown notification method" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "custom/notification"})

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

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

    test "logs successful skill::load with authenticated client metadata", %{tmp_dir: tmp_dir} do
      ingest_archive!(tmp_dir, "audit-load-skill", name: "Audit Load Skill")
      {client, token} = Fixtures.insert_client(name: "audit-client", scopes: ["skill::*"])

      resp =
        mcp_request(
          "tools/call",
          %{"name" => "skill::load", "arguments" => %{"slug" => "audit-load-skill"}},
          auth_token: token
        )

      refute resp["result"]["isError"]

      assert %{"slug" => "audit-load-skill"} =
               Jason.decode!(hd(resp["result"]["content"])["text"])

      assert eventually(fn ->
               Repo.get_by(SkillLoadLog,
                 skill_name: "Audit Load Skill",
                 client_id: client.id,
                 client_name: "audit-client"
               )
             end)
    end

    test "logs successful skill::load without authenticated client metadata", %{tmp_dir: tmp_dir} do
      ingest_archive!(tmp_dir, "open-audit-load-skill", name: "Open Audit Load Skill")

      resp =
        mcp_request(
          "tools/call",
          %{"name" => "skill::load", "arguments" => %{"slug" => "open-audit-load-skill"}}
        )

      refute resp["result"]["isError"]

      assert %{"slug" => "open-audit-load-skill"} =
               Jason.decode!(hd(resp["result"]["content"])["text"])

      assert eventually(fn ->
               Repo.get_by(SkillLoadLog, skill_name: "Open Audit Load Skill")
             end)
    end

    test "logs successful batch skill::load with authenticated client metadata", %{
      tmp_dir: tmp_dir
    } do
      ingest_archive!(tmp_dir, "batch-audit-load-skill", name: "Batch Audit Load Skill")
      {client, token} = Fixtures.insert_client(name: "batch-audit-client", scopes: ["skill::*"])

      responses =
        raw_mcp_request(
          [
            %{
              "jsonrpc" => "2.0",
              "method" => "tools/call",
              "id" => 1,
              "params" => %{
                "name" => "skill::load",
                "arguments" => %{"slug" => "batch-audit-load-skill"}
              }
            }
          ],
          auth_token: token
        )

      assert [%{"result" => result}] = responses
      refute result["isError"]

      assert %{"slug" => "batch-audit-load-skill"} =
               Jason.decode!(hd(result["content"])["text"])

      assert eventually(fn ->
               Repo.get_by(SkillLoadLog,
                 skill_name: "Batch Audit Load Skill",
                 client_id: client.id,
                 client_name: "batch-audit-client"
               )
             end)
    end
  end

  describe "resources/list" do
    test "returns resources array" do
      resp = mcp_request("resources/list")

      assert is_list(resp["result"]["resources"])
    end
  end

  describe "resources/templates/list" do
    test "lists only dynamic Memory templates authorized by the OAuth partition" do
      host = create_memory_host!("resource-templates", "scope:resource-templates")
      read_token = oauth_memory_token!(host, ["memory.read"])
      write_token = oauth_memory_token!(host, ["memory.write"])

      assert %{"result" => %{"resourceTemplates" => templates}} =
               mcp_request("resources/templates/list", nil, auth_token: read_token.value)

      assert Enum.map(templates, & &1["uriTemplate"]) |> Enum.sort() == [
               "memory://recall/{id}/trace",
               "memory://session/{id}/handoff"
             ]

      assert %{"result" => %{"resourceTemplates" => []}} =
               mcp_request("resources/templates/list", nil, auth_token: write_token.value)
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
      assert resp["error"]["message"] =~ "Resource not found"
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
      assert resp["error"]["message"] =~ "Resource not found"
    end

    test "returns error for backplane URI with no chunk_id" do
      resp = mcp_request("resources/read", %{"uri" => "backplane://docs/onlyproject"})
      assert resp["error"]
    end
  end

  describe "prompts/list" do
    test "returns prompts array" do
      resp = mcp_request("prompts/list")

      assert is_list(resp["result"]["prompts"])
    end

    test "lists inserted skills as prompts with empty arguments" do
      Fixtures.insert_skill(
        id: "prompt/list-skill",
        slug: "prompt-list-skill",
        name: "prompt-list-skill",
        description: "A listed prompt skill",
        content: "# Prompt List Skill\nFollow these instructions.",
        source_kind: "db"
      )

      Backplane.Skills.Registry.refresh()

      resp = mcp_request("prompts/list")

      # Current Skill records do not have a tools field, so prompt arguments are empty.
      assert %{
               "name" => "prompt-list-skill",
               "description" => "A listed prompt skill",
               "arguments" => []
             } in resp["result"]["prompts"]
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
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

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
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert is_list(responses)
      assert length(responses) == 2
      assert Enum.all?(responses, fn r -> r["jsonrpc"] == "2.0" end)
      assert Enum.map(responses, & &1["id"]) == [1, 2]
    end

    test "returns error for empty batch" do
      conn =
        conn(:post, "/", Jason.encode!([]))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32_600
    end

    test "handles mixed requests and notifications" do
      batch = [
        %{"jsonrpc" => "2.0", "method" => "ping", "id" => 1},
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      ]

      conn =
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

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
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

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
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

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
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

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
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

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
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

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
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert length(responses) == 2

      valid = Enum.find(responses, &(&1["id"] == 1))
      assert valid["result"] == %{}

      invalid = Enum.find(responses, &(&1["id"] == nil))
      assert invalid["error"]["code"] == -32_600
    end
  end

  describe "completion/complete" do
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
          "ref" => %{"type" => "ref/tool", "name" => "hub::inspect"},
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
      Fixtures.insert_skill(
        id: "comp-skill-test",
        slug: "comp-skill-test",
        name: "comp-test",
        description: "test",
        content: "# test",
        source_kind: "db"
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

  describe "prompts/get with inserted skill" do
    test "returns prompt messages for a skill that exists" do
      content = "# Test Skill\nFollow these instructions."
      hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      %Skill{}
      |> Skill.changeset(%{
        id: "prompt/test-skill",
        slug: "prompt-test-skill",
        name: "test-prompt-skill",
        description: "A skill for prompt testing",
        tags: ["test"],
        content: content,
        content_hash: hash,
        source_kind: "db",
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
    defmodule RaisingSecretTool do
      def call(%{"secret" => secret}), do: raise("tool failed with #{secret}")
    end

    setup do
      {_client, token} =
        Fixtures.insert_client(
          name: "logging-admin",
          scopes: ["memory.admin", "test::*"]
        )

      %{token: token}
    end

    test "accepts valid log level for an administrator without changing global Logger", %{
      token: token
    } do
      original_level = Logger.level()

      for level <- ~w(debug info notice warning error critical alert emergency) do
        resp = mcp_request("logging/setLevel", %{"level" => level}, auth_token: token)
        assert resp["result"] == %{}, "Expected empty result for level #{level}"
        assert Logger.level() == original_level
      end
    end

    test "an accepted debug preference cannot expose request payloads or SQL parameters", %{
      token: token
    } do
      secret = "mcp-log-secret-#{System.unique_integer([:positive])}"

      :ok =
        Backplane.Registry.ToolRegistry.register_native(%Backplane.Registry.Tool{
          name: "test::raising-secret",
          description: "Raises a secret-bearing exception",
          input_schema: %{
            "type" => "object",
            "properties" => %{"secret" => %{"type" => "string"}},
            "required" => ["secret"]
          },
          origin: :native,
          module: RaisingSecretTool
        })

      on_exit(fn ->
        Backplane.Registry.ToolRegistry.deregister_native("test::raising-secret")
      end)

      log =
        capture_log(fn ->
          response =
            mcp_request(
              "logging/setLevel",
              %{"level" => "debug", "untrusted_payload" => secret},
              auth_token: token
            )

          assert response["result"] == %{}
          assert {:ok, _result} = Repo.query("SELECT $1::text", [secret])

          response =
            mcp_request(
              "tools/call",
              %{"name" => "test::raising-secret", "arguments" => %{"secret" => secret}},
              auth_token: token
            )

          assert response["result"]["isError"]
        end)

      refute log =~ secret
    end

    test "rejects invalid log level", %{token: token} do
      resp = mcp_request("logging/setLevel", %{"level" => "invalid"}, auth_token: token)
      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "level"
    end

    test "rejects missing level param", %{token: token} do
      resp = mcp_request("logging/setLevel", %{}, auth_token: token)
      assert resp["error"]["code"] == -32_602
    end

    test "rejects a non-administrative caller and leaves global Logger unchanged" do
      {_client, token} = Fixtures.insert_client(name: "logging-reader", scopes: ["memory.read"])
      original_level = Logger.level()
      response = mcp_request("logging/setLevel", %{"level" => "debug"}, auth_token: token)
      assert response["error"]["code"] == -32_001
      assert Logger.level() == original_level
    end

    test "logging capability advertised in initialize", %{token: token} do
      resp = mcp_request("initialize", nil, auth_token: token)
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
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

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
    test "returns resources without a cursor when no resources are registered" do
      resp = mcp_request("resources/list")
      result = resp["result"]
      assert result["resources"] == []
      refute Map.has_key?(result, "nextCursor")
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
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

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
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

      [resp] = Jason.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32_602
    end

    test "batch resources/read with missing resources returns errors" do
      batch = [
        %{
          "jsonrpc" => "2.0",
          "method" => "resources/read",
          "id" => 1,
          "params" => %{"uri" => "backplane://docs/fake/1"}
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
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

      responses = Jason.decode!(conn.resp_body)
      assert length(responses) == 3

      missing = Enum.find(responses, &(&1["id"] == 1))
      assert missing["error"]["code"] == -32_602

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
        slug: "batch-prompt-skill",
        name: "batch-prompt-skill",
        description: "Batch test skill",
        tags: ["test"],
        content: content,
        content_hash: hash,
        source_kind: "db",
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
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

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
      {_client, token} =
        Fixtures.insert_client(name: "batch-logging-admin", scopes: ["memory.admin"])

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
        conn(:post, "/", Jason.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> McpPlug.call(McpPlug.init([]))

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
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

      assert conn.status == 202
    end

    test "notifications/cancelled returns 202" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/cancelled"
        })

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

      assert conn.status == 202
    end

    test "unknown notification returns 202" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/unknown"
        })

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> McpPlug.call(McpPlug.init([]))

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

    test "returns error when skill search limit is below schema minimum" do
      resp =
        mcp_request("tools/call", %{
          "name" => "skill::search",
          "arguments" => %{"query" => "skill", "limit" => 0}
        })

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "limit"
      assert resp["error"]["message"] =~ ">= 1"
    end

    test "returns error when skill list limit exceeds schema maximum" do
      resp =
        mcp_request("tools/call", %{
          "name" => "skill::list",
          "arguments" => %{"limit" => 101}
        })

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "limit"
      assert resp["error"]["message"] =~ "<= 100"
    end
  end

  describe "format_result" do
    test "tools/call returns string result directly" do
      # Call a tool that returns a plain string result
      resp =
        mcp_request("tools/call", %{
          "name" => "skill::load",
          "arguments" => %{"slug" => "nonexistent"}
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
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> McpPlug.call(McpPlug.init([]))

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

      def start_link(response), do: GenServer.start_link(__MODULE__, {response, self()})

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_call(
            {:tools_call, name, arguments, timeout},
            _from,
            {response, owner} = state
          ) do
        send(owner, {:mock_upstream_call, name, arguments, timeout})
        {:reply, response, state}
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

      assert_receive {:mock_upstream_call, "echo", %{}, 5_000}
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

      assert_receive {:mock_upstream_call, "fail", %{}, 5_000}
      assert resp["result"]["isError"] == true
      assert hd(resp["result"]["content"])["text"] =~ "upstream failed"
    end
  end

  describe "scoped tools/list" do
    test "returns all tools for scope [\"*\"]" do
      {_client, token} = BackplaneMcp.Fixtures.insert_client(name: "all-access", scopes: ["*"])
      resp = mcp_request("tools/list", nil, auth_token: token)

      tools = resp["result"]["tools"]
      assert is_list(tools)
      assert length(tools) > 0
    end

    test "returns only docs:: tools for scope [\"docs::*\"]" do
      {_client, token} =
        BackplaneMcp.Fixtures.insert_client(name: "docs-only", scopes: ["docs::*"])

      resp = mcp_request("tools/list", nil, auth_token: token)

      tools = resp["result"]["tools"]
      assert is_list(tools)

      Enum.each(tools, fn tool ->
        assert String.starts_with?(tool["name"], "docs::")
      end)
    end

    test "returns single tool for exact scope" do
      {_client, token} =
        BackplaneMcp.Fixtures.insert_client(name: "single-tool", scopes: ["public::echo"])

      resp = mcp_request("tools/list", nil, auth_token: token)

      tools = resp["result"]["tools"]
      assert length(tools) == 1
      assert hd(tools)["name"] == "public::echo"
    end

    test "returns empty list for scope with no matches" do
      {_client, token} =
        BackplaneMcp.Fixtures.insert_client(name: "no-match", scopes: ["nonexistent::*"])

      resp = mcp_request("tools/list", nil, auth_token: token)

      assert resp["result"]["tools"] == []
    end

    test "OAuth exact scope returns only the named tool" do
      token = oauth_token!(["public::echo"])
      resp = mcp_request("tools/list", nil, auth_token: token.value)

      assert Enum.map(resp["result"]["tools"], & &1["name"]) == ["public::echo"]
    end

    test "OAuth namespace wildcard returns only matching tools" do
      token = oauth_token!(["public::*"])
      resp = mcp_request("tools/list", nil, auth_token: token.value)

      names = Enum.map(resp["result"]["tools"], & &1["name"])
      assert names == ["public::echo"]
      assert Enum.all?(names, &String.starts_with?(&1, "public::"))
    end
  end

  describe "scoped tools/call" do
    test "PAT JSON and batch managed remember calls receive the same trusted metadata context" do
      host = create_memory_host!("pat-dispatch", "scope:pat")
      register_memory_remember_tool!()

      {_client, token} =
        BackplaneMcp.Fixtures.insert_client(
          name: "memory-pat-dispatch",
          scopes: ["memory::remember"],
          metadata: %{"memory_partition_id" => "host:#{host.id}"}
        )

      args = %{"content" => "pat json", "agent_id" => "agent", "scope" => "scope:pat"}

      json =
        mcp_request(
          "tools/call",
          %{"name" => "memory::remember", "arguments" => args},
          auth_token: token
        )

      refute json["result"]["isError"]

      batch = [
        %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => 2,
          "params" => %{
            "name" => "memory::remember",
            "arguments" => %{args | "content" => "pat batch"}
          }
        }
      ]

      conn = direct_mcp_conn(batch, token)
      assert [%{"result" => result}] = Jason.decode!(conn.resp_body)
      refute result["isError"]

      assert [first, second] =
               MemorySchema
               |> order_by([memory], asc: memory.content)
               |> Repo.all()

      assert {first.content, second.content} == {"pat batch", "pat json"}

      for memory <- [first, second] do
        assert memory.host_id == host.id
        assert memory.client_id == "host:#{host.id}"
        assert memory.namespace == "private"
        assert memory.scope == "scope:pat"
      end
    end

    test "OAuth managed remember resolves server metadata and rejects spoofed ownership" do
      host = create_memory_host!("oauth-dispatch", "scope:oauth")
      register_memory_remember_tool!()
      token = oauth_memory_token!(host, ["memory::remember"])

      accepted =
        mcp_request(
          "tools/call",
          %{
            "name" => "memory::remember",
            "arguments" => %{
              "content" => "oauth memory",
              "agent_id" => "agent",
              "scope" => "scope:oauth"
            }
          },
          auth_token: token.value
        )

      refute accepted["result"]["isError"]
      assert %MemorySchema{host_id: host_id, client_id: partition} = Repo.one!(MemorySchema)
      assert host_id == host.id
      assert partition == "host:#{host.id}"

      rejected =
        mcp_request(
          "tools/call",
          %{
            "name" => "memory::remember",
            "arguments" => %{
              "content" => "spoof",
              "agent_id" => "agent",
              "host_id" => Ecto.UUID.generate(),
              "client_id" => "host:attacker"
            }
          },
          auth_token: token.value
        )

      assert rejected["error"]["code"] == -32_602
      assert rejected["error"]["message"] =~ "Unexpected arguments"
      assert Repo.aggregate(MemorySchema, :count) == 1
    end

    test "SSE managed remember receives the same verified PAT context" do
      host = create_memory_host!("sse-dispatch", "scope:sse")
      register_memory_remember_tool!()

      {_client, token} =
        BackplaneMcp.Fixtures.insert_client(
          name: "memory-sse-dispatch",
          scopes: ["memory::remember"],
          metadata: %{"memory_partition_id" => "host:#{host.id}"}
        )

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => 1,
          "params" => %{
            "name" => "memory::remember",
            "arguments" => %{
              "content" => "sse memory",
              "agent_id" => "agent",
              "scope" => "scope:sse"
            }
          }
        })

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("authorization", "Bearer #{token}")
        |> McpPlug.call(McpPlug.init([]))

      assert conn.status == 200
      assert %MemorySchema{host_id: host_id, client_id: partition} = Repo.one!(MemorySchema)
      assert host_id == host.id
      assert partition == "host:#{host.id}"
    end

    test "PAT and OAuth credentials share one live host partition across JSON batch SSE and prompts" do
      host = create_memory_host!("credential-rotation", "scope:credential-rotation")
      register_memory_surface!()

      {_client, pat} =
        BackplaneMcp.Fixtures.insert_client(
          name: "memory-credential-rotation-pat",
          scopes: ["memory::*"],
          metadata: %{"memory_partition_id" => "host:#{host.id}"}
        )

      oauth = oauth_memory_token!(host, ["memory::*"])
      args = %{"agent_id" => "agent", "scope" => host.memory_scope}

      json =
        mcp_request(
          "tools/call",
          %{
            "name" => "memory::remember",
            "arguments" => Map.put(args, "content", "credential rotation json")
          },
          auth_token: pat
        )

      refute json["result"]["isError"]

      batch = [
        %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => 2,
          "params" => %{
            "name" => "memory::remember",
            "arguments" => Map.put(args, "content", "credential rotation batch")
          }
        }
      ]

      assert [%{"result" => batch_result}] =
               batch |> direct_mcp_conn(oauth.value) |> then(&Jason.decode!(&1.resp_body))

      refute batch_result["isError"]

      sse =
        sse_mcp_conn(
          %{
            "name" => "memory::remember",
            "arguments" => Map.put(args, "content", "credential rotation sse")
          },
          pat
        )

      assert sse.status == 200

      for token <- [pat, oauth.value] do
        prompt =
          mcp_request(
            "prompts/get",
            %{
              "name" => "recall_context",
              "arguments" => %{"query" => "credential rotation"}
            },
            auth_token: token
          )

        assert prompt["result"]["messages"] != []
      end

      memories = Repo.all(MemorySchema)
      assert length(memories) == 3

      assert Enum.all?(memories, fn memory ->
               memory.host_id == host.id and memory.client_id == "host:#{host.id}" and
                 memory.namespace == "private" and memory.scope == host.memory_scope
             end)
    end

    test "deleted metadata host fails closed over JSON batch SSE and managed prompts" do
      host = create_memory_host!("deleted-metadata", "scope:deleted-metadata")
      register_memory_surface!()

      {_client, pat} =
        BackplaneMcp.Fixtures.insert_client(
          name: "memory-deleted-host-pat",
          scopes: ["memory::*"],
          metadata: %{"memory_partition_id" => "host:#{host.id}"}
        )

      oauth = oauth_memory_token!(host, ["memory::*"])
      assert {:ok, _deleted} = Hosts.delete_agent(host)

      params = %{
        "name" => "memory::remember",
        "arguments" => %{
          "content" => "must not persist",
          "agent_id" => "agent",
          "scope" => host.memory_scope
        }
      }

      json = mcp_request("tools/call", params, auth_token: pat)
      assert json["result"]["isError"] == true

      batch = [%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 2, "params" => params}]

      assert [%{"result" => %{"isError" => true}}] =
               batch |> direct_mcp_conn(oauth.value) |> then(&Jason.decode!(&1.resp_body))

      sse = sse_mcp_conn(params, pat)
      assert sse.status == 200
      assert sse.resp_body =~ ~s|"isError":true|
      assert Repo.aggregate(MemorySchema, :count) == 0

      for token <- [pat, oauth.value] do
        hidden =
          mcp_request(
            "prompts/get",
            %{"name" => "recall_context", "arguments" => %{"query" => "anything"}},
            auth_token: token
          )

        absent = mcp_request("prompts/get", %{"name" => "does-not-exist"}, auth_token: token)
        assert hidden["error"] == absent["error"]
      end
    end

    test "allows call for in-scope tool" do
      {_client, token} =
        BackplaneMcp.Fixtures.insert_client(name: "skill-access", scopes: ["skill::*"])

      resp =
        mcp_request(
          "tools/call",
          %{"name" => "skill::list", "arguments" => %{}},
          auth_token: token
        )

      # Should succeed (not an access denied error)
      refute resp["error"]
    end

    test "returns -32001 error for out-of-scope tool" do
      {_client, token} =
        BackplaneMcp.Fixtures.insert_client(name: "docs-restricted", scopes: ["docs::*"])

      resp =
        mcp_request(
          "tools/call",
          %{"name" => "skill::search", "arguments" => %{"query" => "test"}},
          auth_token: token
        )

      assert resp["error"]["code"] == -32_001
      assert resp["error"]["message"] =~ "not in scope"
    end

    test "error message includes tool name" do
      {_client, token} =
        BackplaneMcp.Fixtures.insert_client(name: "limited-client", scopes: ["docs::*"])

      resp =
        mcp_request(
          "tools/call",
          %{"name" => "git::repo-tree", "arguments" => %{}},
          auth_token: token
        )

      assert resp["error"]["message"] =~ "git::repo-tree"
    end

    test "allows an exact in-scope OAuth tool call" do
      token = oauth_token!(["skill::list"])

      resp =
        mcp_request(
          "tools/call",
          %{"name" => "skill::list", "arguments" => %{}},
          auth_token: token.value
        )

      refute resp["error"]
    end

    test "single OAuth tool denial keeps JSON-RPC body and adds a 403 challenge" do
      token = oauth_token!(["public::echo"])

      conn =
        endpoint_mcp_conn(
          %{
            "jsonrpc" => "2.0",
            "method" => "tools/call",
            "id" => 1,
            "params" => %{"name" => "skill::search", "arguments" => %{"query" => "test"}}
          },
          token.value
        )

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_001

      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(error="insufficient_scope")
      assert challenge =~ ~s(scope="skill::search")
      assert challenge =~ Resources.metadata_uri(:mcp)
    end

    test "single PAT tool denial remains HTTP 200 without an OAuth challenge" do
      {_client, token} =
        BackplaneMcp.Fixtures.insert_client(name: "pat-denial", scopes: ["public::echo"])

      conn =
        mcp_request_conn(
          "tools/call",
          %{"name" => "skill::search", "arguments" => %{"query" => "test"}},
          auth_token: token
        )

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_001
      assert get_resp_header(conn, "www-authenticate") == []
    end

    test "OAuth batch denials remain HTTP 200 without a batch-wide challenge" do
      token = oauth_token!(["public::echo"])

      conn =
        direct_mcp_conn(
          [
            %{
              "jsonrpc" => "2.0",
              "method" => "tools/call",
              "id" => 1,
              "params" => %{
                "name" => "skill::search",
                "arguments" => %{"query" => "test"}
              }
            },
            %{"jsonrpc" => "2.0", "method" => "ping", "id" => 2}
          ],
          token.value
        )

      assert conn.status == 200
      [denial, ping] = Jason.decode!(conn.resp_body)
      assert denial["error"]["code"] == -32_001
      assert ping["result"] == %{}
      assert get_resp_header(conn, "www-authenticate") == []
    end
  end

  defp oauth_token!(scopes) do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:mcp], scopes: scopes)
    resource_access_token_fixture!(user, client, scopes, :mcp)
  end

  defp oauth_memory_token!(host, scopes) do
    user = auth_user_fixture!()

    client =
      oauth_client_fixture!(
        resources: [:mcp],
        scopes: scopes,
        metadata: %{"memory_partition_id" => "host:#{host.id}"}
      )

    resource_access_token_fixture!(user, client, scopes, :mcp)
  end

  defp create_memory_host!(suffix, memory_scope) do
    {:ok, host, _auth_token, _plaintext} =
      Hosts.create_agent_with_token(%{
        "name" => "mcp-memory-#{suffix}-#{System.unique_integer([:positive])}",
        "memory_scope" => memory_scope
      })

    host
  end

  defp register_memory_remember_tool! do
    remember = Enum.find(Backplane.Memory.Service.tools(), &(&1.name == "memory::remember"))
    Backplane.Registry.ToolRegistry.register_managed("memory", [remember])
  end

  defp register_memory_surface! do
    register_memory_remember_tool!()

    Backplane.Registry.PromptRegistry.register_managed(
      "memory",
      Backplane.Memory.Service.prompts(),
      Backplane.Memory.Service
    )
  end

  defp sse_mcp_conn(params, token) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 1,
        "params" => params
      })

    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "text/event-stream")
    |> put_req_header("authorization", "Bearer #{token}")
    |> McpPlug.call(McpPlug.init([]))
  end

  defp endpoint_mcp_conn(body, token) do
    conn =
      conn(:post, "/mcp", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    Backplane.Api.Endpoint.call(conn, Backplane.Api.Endpoint.init([]))
  end

  defp direct_mcp_conn(body, token) do
    conn(:post, "/", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> McpPlug.call(McpPlug.init([]))
  end

  defp ingest_archive!(tmp_dir, slug, attrs) do
    archive =
      create_archive!(
        tmp_dir,
        [
          {"#{slug}/SKILL.md", skill_content(attrs)},
          {"#{slug}/meta.json", Jason.encode!(%{"slug" => slug})}
        ],
        name: "#{slug}.tar.gz"
      )

    assert {:ok, _skill} = Skills.ingest_archive(archive, [])
    archive
  end

  defp skill_content(attrs) do
    name = Keyword.get(attrs, :name, "Example Skill")

    """
    ---
    name: #{name}
    description: #{Keyword.get(attrs, :description, "Example skill")}
    tags: [archive, test]
    version: "1.2.3"
    ---

    # #{name}

    Use this skill in MCP handler tests.
    """
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(25)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  describe "management tools filtering" do
    test "tools/list does not return admin::* or hub::* tools" do
      resp = mcp_request("tools/list")
      tools = resp["result"]["tools"]
      names = Enum.map(tools, & &1["name"])

      refute Enum.any?(names, &String.starts_with?(&1, "admin::"))
      refute Enum.any?(names, &String.starts_with?(&1, "hub::"))
    end
  end
end
