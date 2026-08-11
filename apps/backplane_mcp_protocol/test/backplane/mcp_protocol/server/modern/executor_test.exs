defmodule Backplane.McpProtocol.Server.Modern.ExecutorTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Server.Modern.Executor
  alias Backplane.McpProtocol.Server.Registry

  @version "2026-07-28"

  setup do
    task_supervisor = start_supervised!({Task.Supervisor, []})

    session_supervisor =
      start_supervised!(
        {DynamicSupervisor, name: Registry.session_supervisor_name(ModernStubServer), strategy: :one_for_one}
      )

    transport_context = %{
      type: :stdio,
      task_supervisor: task_supervisor,
      assigns: %{test_pid: self()}
    }

    %{
      task_supervisor: task_supervisor,
      session_supervisor: session_supervisor,
      transport_context: transport_context
    }
  end

  test "discovery is deterministic, modern-only, and bypasses application callbacks", context do
    request = request("server/discover", %{}, id: "discover-1")

    assert {:response, response} =
             Executor.execute(ModernStubServer, request, context.transport_context)

    assert response["id"] == "discover-1"
    assert response["jsonrpc"] == "2.0"

    assert %{
             "resultType" => "complete",
             "supportedVersions" => [@version],
             "ttlMs" => 0,
             "cacheScope" => "private",
             "capabilities" => capabilities,
             "instructions" => "Use the test tools deterministically.",
             "_meta" => %{
               "io.modelcontextprotocol/serverInfo" => %{
                 "name" => "modern-stub",
                 "version" => "1.0.0"
               }
             }
           } = response["result"]

    assert Map.has_key?(capabilities, "completions")
    refute Map.has_key?(capabilities, "completion")
    refute Map.has_key?(capabilities, "tasks")
    refute_receive {:modern_init_request, _}
    refute_receive {:modern_handle_request, _, _}
  end

  test "sanitizes malformed discovery metadata without losing the request id", context do
    for {params, id} <- [{[], "params-list"}, {"invalid", "params-scalar"}, {%{"_meta" => []}, "meta-list"}] do
      request = %{"jsonrpc" => "2.0", "id" => id, "method" => "server/discover", "params" => params}

      assert {:response, %{"id" => ^id, "error" => %{"code" => -32_602}}} =
               Executor.execute(ModernStubServer, request, context.transport_context)
    end

    refute_receive {:modern_init_request, _}
    refute_receive {:modern_handle_request, _, _}
  end

  test "normal requests initialize once, use fresh frames, and return deterministic lists", context do
    list_request = request("tools/list", %{}, id: 10)

    assert {:response, first} =
             Executor.execute(ModernStubServer, list_request, context.transport_context)

    assert {:response, second} =
             Executor.execute(ModernStubServer, %{list_request | "id" => 11}, context.transport_context)

    assert Enum.map(first["result"]["tools"], & &1.name) == ["alpha", "middle", "route", "zeta"]
    assert Enum.map(second["result"]["tools"], & &1.name) == ["alpha", "middle", "route", "zeta"]
    assert first["result"]["resultType"] == "complete"
    assert first["result"]["ttlMs"] == 0
    assert first["result"]["cacheScope"] == "private"

    assert_receive {:modern_init_request, _}
    assert_receive {:modern_handle_request, "tools/list", 1}
    assert_receive {:modern_init_request, _}
    assert_receive {:modern_handle_request, "tools/list", 1}
  end

  test "returned frames are discarded between calls and legacy init is never invoked", context do
    call = fn id ->
      request(
        "tools/call",
        %{"name" => "route", "arguments" => %{"region" => "west"}},
        id: id
      )
    end

    assert {:response, first} = Executor.execute(ModernStubServer, call.(1), context.transport_context)
    assert {:response, second} = Executor.execute(ModernStubServer, call.(2), context.transport_context)

    first_content = first["result"]["structuredContent"]
    second_content = second["result"]["structuredContent"]
    assert first_content["initCount"] == 1
    assert second_content["initCount"] == 1
    refute first_content["requestNonce"] == second_content["requestNonce"]
  end

  test "reinstalls authoritative context after request initialization", context do
    request = request("tools/list", %{"_testInit" => "tamper-context"})
    transport_context = Map.put(context.transport_context, :auth, %{sub: "trusted"})

    assert {:response, %{"result" => _}} =
             Executor.execute(ModernStubServer, request, transport_context)

    assert_receive {:modern_callback_context, callback_context}
    assert callback_context.auth == %{sub: "trusted"}
    assert callback_context.era == :modern
    assert callback_context.execution_mode == :stateless
  end

  test "validates request-local tool parameter headers after init_request", context do
    request =
      request("tools/call", %{"name" => "route", "arguments" => %{"region" => "west"}})

    http_context =
      Map.merge(context.transport_context, %{
        type: :http,
        req_headers: [
          {"MCP-Protocol-Version", @version},
          {"Mcp-Method", "tools/call"},
          {"Mcp-Name", "route"},
          {"Mcp-Param-Region", "west"}
        ]
      })

    assert {:response, %{"result" => _}} =
             Executor.execute(ModernStubServer, request, http_context)

    bad_context =
      put_in(
        http_context,
        [:req_headers],
        List.keyreplace(http_context.req_headers, "Mcp-Param-Region", 0, {
          "Mcp-Param-Region",
          "east"
        })
      )

    assert {:response, %{"error" => %{"code" => -32_020}}} =
             Executor.execute(ModernStubServer, request, bad_context)

    assert_receive {:modern_init_request, _}
    assert_receive {:modern_handle_request, "tools/call", 1}
    assert_receive {:modern_init_request, _}
    refute_receive {:modern_handle_request, "tools/call", _}
  end

  test "returns header mismatch before unsupported version for disagreeing HTTP markers", context do
    request =
      "tools/list"
      |> request()
      |> put_in(
        ["params", "_meta", "io.modelcontextprotocol/protocolVersion"],
        "2099-01-01"
      )

    http_context =
      Map.merge(context.transport_context, %{
        type: :http,
        req_headers: [
          {"MCP-Protocol-Version", @version},
          {"Mcp-Method", "tools/list"}
        ]
      })

    assert {:response, %{"error" => %{"code" => -32_020}}} =
             Executor.execute(ModernStubServer, request, http_context)

    refute_receive {:modern_init_request, _}
  end

  test "returns header mismatch before a legacy-only server's unsupported version", context do
    request = request("tools/list", %{}, id: "legacy-only-mismatch")

    http_context =
      Map.merge(context.transport_context, %{
        type: :http,
        req_headers: [
          {"MCP-Protocol-Version", "2099-01-01"},
          {"Mcp-Method", "tools/list"}
        ]
      })

    assert {:response,
            %{
              "id" => "legacy-only-mismatch",
              "error" => %{"code" => -32_020}
            }} =
             Executor.execute(ModernLegacyOnlyServer, request, http_context)

    refute_receive {:modern_init_request, _}
  end

  test "capability-gates core methods and server-specific modern versions", context do
    for {method, params} <- [
          {"tools/list", %{}},
          {"prompts/list", %{}},
          {"resources/list", %{}},
          {"completion/complete", %{"ref" => "ref", "argument" => %{}}}
        ] do
      assert {:response, %{"error" => %{"code" => -32_601}}} =
               Executor.execute(
                 ModernNoToolsServer,
                 request(method, params),
                 context.transport_context
               )
    end

    assert {:response, %{"result" => %{"completion" => %{"values" => [%{"value" => "alpha"}]}}}} =
             Executor.execute(
               ModernStubServer,
               request("completion/complete", %{"ref" => "ref", "argument" => %{}}),
               context.transport_context
             )

    assert_receive {:modern_init_request, _}
    assert_receive {:modern_handle_request, "completion/complete", 1}

    assert {:response,
            %{
              "error" => %{
                "code" => -32_022,
                "data" => %{"requested" => @version, "supported" => []}
              }
            }} =
             Executor.execute(
               ModernLegacyOnlyServer,
               request("tools/list"),
               context.transport_context
             )

    refute_receive {:modern_init_request, _}
  end

  test "contains metadata callback failures and timeouts", context do
    request = request("tools/list", %{}, id: "metadata-failure")

    assert {:response, raised_response} =
             Executor.execute(ModernRaisingMetadataServer, request, context.transport_context)

    assert raised_response["id"] == "metadata-failure"
    assert raised_response["error"]["code"] == -32_603
    refute inspect(raised_response) =~ "private metadata"

    assert {:response, timeout_response} =
             Executor.execute(
               ModernSlowMetadataServer,
               %{request | "id" => "metadata-timeout"},
               context.transport_context,
               timeout: 10
             )

    assert timeout_response["id"] == "metadata-timeout"
    assert timeout_response["error"]["code"] == -32_603
  end

  test "preserves explicit init errors and sanitizes every callback failure class", context do
    error_request = request("tools/list", %{"_testInit" => "error"}, id: "init-error")

    assert {:response, %{"id" => "init-error", "error" => %{"code" => -32_602}}} =
             Executor.execute(ModernStubServer, error_request, context.transport_context)

    failure_requests =
      for {field, mode} <- [
            {"_testInit", "raise"},
            {"_testInit", "throw"},
            {"_testInit", "exit"},
            {"_testInit", "invalid"},
            {"_testCallback", "raise"},
            {"_testCallback", "throw"},
            {"_testCallback", "exit"},
            {"_testCallback", "invalid"},
            {"_testCallback", "noreply"}
          ] do
        request("tools/list", %{field => mode}, id: "#{field}:#{mode}")
      end

    for failure_request <- failure_requests do
      assert {:response, response} =
               Executor.execute(ModernStubServer, failure_request, context.transport_context)

      assert response["id"] == failure_request["id"]
      assert response["error"]["code"] == -32_603
      refute inspect(response) =~ "private"
      refute inspect(response) =~ "stack"
    end
  end

  test "times out isolated callbacks without leaking details", context do
    request = request("tools/list", %{"_testInit" => "timeout"}, id: "slow")

    assert {:response, response} =
             Executor.execute(ModernStubServer, request, context.transport_context, timeout: 10)

    assert response["id"] == "slow"
    assert response["error"]["code"] == -32_603
  end

  test "offers an explicit test-only inline path without weakening the production default", context do
    no_supervisor_context = Map.delete(context.transport_context, :task_supervisor)

    assert {:response, %{"error" => %{"code" => -32_603}}} =
             Executor.execute(ModernStubServer, request("tools/list"), no_supervisor_context)

    assert {:response, %{"result" => %{"resultType" => "complete"}}} =
             Executor.execute(
               ModernStubServer,
               request("tools/list"),
               no_supervisor_context,
               isolation: :inline
             )
  end

  test "never creates a legacy session process", context do
    before_counts = DynamicSupervisor.count_children(context.session_supervisor)

    for id <- 1..3 do
      assert {:response, %{"result" => _}} =
               Executor.execute(
                 ModernStubServer,
                 request("tools/list", %{}, id: id),
                 context.transport_context
               )
    end

    after_counts = DynamicSupervisor.count_children(context.session_supervisor)
    assert before_counts.active == 0
    assert after_counts.active == 0
    assert after_counts.specs == before_counts.specs
  end

  defp request(method, params \\ %{}, opts \\ []) do
    capabilities = Keyword.get(opts, :client_capabilities, %{})

    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => capabilities,
      "io.modelcontextprotocol/clientInfo" => %{"name" => "test-client", "version" => "1.0"}
    }

    %{
      "jsonrpc" => "2.0",
      "id" => Keyword.get(opts, :id, 1),
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end
end
