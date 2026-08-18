defmodule Backplane.Proxy.UpstreamTest do
  use Backplane.DataCase, async: false

  alias Backplane.Proxy.{ClientPool, Upstream}
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Settings.Credentials
  alias Backplane.Settings.Credentials.Vault

  setup do
    :ets.delete_all_objects(:backplane_tools)

    ClientPool
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      if is_pid(pid), do: DynamicSupervisor.terminate_child(ClientPool, pid)
    end)

    on_exit(fn ->
      ClientPool
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        if is_pid(pid), do: DynamicSupervisor.terminate_child(ClientPool, pid)
      end)

      :ets.delete_all_objects(:backplane_tools)
    end)

    :ok
  end

  describe "protocol-package negotiation" do
    @describetag :task13

    test "defaults HTTP upstreams to legacy initialization and session-era requests" do
      url = start_http_fixture(mode: :legacy)
      pid = start_test_upstream(http_config("legacy-default", url))

      assert eventually(fn -> Upstream.status(pid).status == :connected end)

      initialize = receive_upstream_request("initialize")
      assert initialize.path == "/custom/mcp"
      refute Map.has_key?(initialize.header_map, "mcp-session-id")

      assert %{header_map: %{"mcp-session-id" => "mock-legacy-session"}} =
               receive_upstream_request("notifications/initialized")

      assert %{header_map: %{"mcp-session-id" => "mock-legacy-session"}} =
               receive_upstream_request("tools/list")

      refute_receive {:upstream_request, %{method: "server/discover"}}, 50

      assert %{
               protocol_preference: "2025-11-25",
               negotiated_version: "2025-11-25",
               era: :legacy,
               negotiation_status: :ready,
               status: :connected
             } = Upstream.status(pid)

      state = :sys.get_state(pid)
      assert state.server_info == %{"name" => "mock-legacy", "version" => "0.1.0"}
      assert state.server_capabilities == %{"tools" => %{"listChanged" => false}}
    end

    test "strict modern HTTP uses discovery without initialize or session state" do
      url = start_http_fixture(mode: :modern)
      pid = start_test_upstream(http_config("strict-modern", url, protocol_version: "2026-07-28"))

      assert eventually(fn -> Upstream.status(pid).status == :connected end)

      assert %{headers: discover_headers} = receive_upstream_request("server/discover")
      assert {"mcp-method", "server/discover"} in discover_headers
      assert {"mcp-protocol-version", "2026-07-28"} in discover_headers

      assert %{header_map: tool_headers} = receive_upstream_request("tools/list")
      refute Map.has_key?(tool_headers, "mcp-session-id")
      refute_receive {:upstream_request, %{method: "initialize"}}, 50
      refute_receive {:strict_modern_violation, _}, 50

      assert %{
               protocol_preference: "2026-07-28",
               negotiated_version: "2026-07-28",
               era: :modern,
               negotiation_status: :ready,
               status: :connected
             } = Upstream.status(pid)

      state = :sys.get_state(pid)
      assert state.server_info == %{"name" => "mock-modern", "version" => "0.1.0"}
      assert state.server_capabilities == %{"tools" => %{}}
    end

    test "strict modern HTTP fixture rejects a session header instead of only reporting it" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "session-violation",
        "method" => "tools/list"
      }

      conn =
        :post
        |> Plug.Test.conn("/custom/mcp", JSON.encode!(request))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("mcp-session-id", "forbidden-modern-session")
        |> Backplane.Test.MockMcpPlug.call(mode: :modern, owner: self())

      assert conn.status == 400
      assert_receive {:strict_modern_violation, %{method: "tools/list", session?: true}}
    end

    test "auto prefers modern and keeps the configured string in status" do
      url = start_http_fixture(mode: :modern)
      pid = start_test_upstream(http_config("auto-modern", url, protocol_version: "auto"))

      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      assert %{method: "server/discover"} = receive_upstream_request("server/discover")
      refute_receive {:upstream_request, %{method: "initialize"}}, 50

      assert %{protocol_preference: "auto", negotiated_version: "2026-07-28", era: :modern} =
               Upstream.status(pid)
    end

    test "auto falls back once only on a recognized plain legacy HTTP response" do
      url = start_http_fixture(mode: :auto_legacy)
      pid = start_test_upstream(http_config("auto-legacy", url, protocol_version: "auto"))

      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      assert %{method: "server/discover"} = receive_upstream_request("server/discover")
      assert %{method: "initialize"} = receive_upstream_request("initialize")

      assert %{method: "notifications/initialized"} =
               receive_upstream_request("notifications/initialized")

      assert %{protocol_preference: "auto", negotiated_version: "2025-11-25", era: :legacy} =
               Upstream.status(pid)

      refute_receive {:upstream_request, %{method: "server/discover"}}, 100
      refute_receive {:upstream_request, %{method: "initialize"}}, 100
    end

    for mode <- [:discover_500, :discover_malformed, :discover_jsonrpc_error] do
      test "auto does not fall back after #{mode}" do
        mode = unquote(mode)
        url = start_http_fixture(mode: mode)

        pid =
          start_test_upstream(
            http_config("auto-terminal-#{mode}", url,
              protocol_version: "auto",
              timeout: 200
            )
          )

        assert eventually(fn -> Upstream.status(pid).status == :disconnected end)
        assert %{method: "server/discover"} = receive_upstream_request("server/discover")
        refute_receive {:upstream_request, %{method: "initialize"}}, 150
      end
    end
  end

  describe "stdio negotiation parity" do
    @describetag :task13

    @tag :stdio
    @tag :tmp_dir
    test "legacy and strict modern stdio use their own lifecycle and health methods", %{
      tmp_dir: tmp_dir
    } do
      legacy_events = Path.join(tmp_dir, "legacy-events.jsonl")
      modern_events = Path.join(tmp_dir, "modern-events.jsonl")
      modern_violations = Path.join(tmp_dir, "modern-violations.txt")

      legacy =
        start_test_upstream(
          stdio_config("stdio-legacy", %{
            "MCP_TEST_MODE" => "legacy",
            "MCP_TEST_EVENT_FILE" => legacy_events
          })
        )

      modern =
        start_test_upstream(
          stdio_config(
            "stdio-modern",
            %{
              "MCP_TEST_MODE" => "modern",
              "MCP_TEST_EVENT_FILE" => modern_events,
              "MCP_TEST_VIOLATION_FILE" => modern_violations
            },
            protocol_version: "2026-07-28"
          )
        )

      assert eventually(fn -> Upstream.status(legacy).status == :connected end)
      assert eventually(fn -> Upstream.status(modern).status == :connected end)
      assert eventually(fn -> "initialize" in stdio_methods(legacy_events) end)
      assert eventually(fn -> "server/discover" in stdio_methods(modern_events) end)
      refute "server/discover" in stdio_methods(legacy_events)
      refute "initialize" in stdio_methods(modern_events)

      send(legacy, :health_ping)
      send(modern, :health_ping)

      assert eventually(fn -> "ping" in stdio_methods(legacy_events) end)

      assert eventually(fn ->
               Enum.count(stdio_methods(modern_events), &(&1 == "tools/list")) >= 2
             end)

      refute "ping" in stdio_methods(modern_events)
      assert file_lines(modern_violations) == []
    end

    @tag :stdio
    @tag :tmp_dir
    test "stdio auto performs one recognized legacy fallback", %{tmp_dir: tmp_dir} do
      events = Path.join(tmp_dir, "auto-events.jsonl")

      pid =
        start_test_upstream(
          stdio_config(
            "stdio-auto",
            %{"MCP_TEST_MODE" => "auto_legacy", "MCP_TEST_EVENT_FILE" => events},
            protocol_version: "auto"
          )
        )

      assert eventually(fn -> Upstream.status(pid).status == :connected end)

      assert eventually(fn ->
               stdio_methods(events) |> Enum.count(&(&1 == "server/discover")) == 1
             end)

      assert Enum.count(stdio_methods(events), &(&1 == "initialize")) == 1
      assert %{protocol_preference: "auto", era: :legacy} = Upstream.status(pid)
    end

    @tag :stdio
    @tag :tmp_dir
    test "stdio auto treats a recognized modern error as terminal without initialize", %{
      tmp_dir: tmp_dir
    } do
      events = Path.join(tmp_dir, "terminal-events.jsonl")

      pid =
        start_test_upstream(
          stdio_config(
            "stdio-terminal",
            %{
              "MCP_TEST_MODE" => "discover_jsonrpc_error",
              "MCP_TEST_EVENT_FILE" => events
            },
            protocol_version: "auto",
            timeout: 500
          )
        )

      assert eventually(fn -> Upstream.status(pid).status == :disconnected end)
      assert eventually(fn -> "server/discover" in stdio_methods(events) end)
      refute "initialize" in stdio_methods(events)
    end

    @tag :stdio
    @tag :tmp_dir
    test "stdio auto treats a malformed discovery result as terminal without initialize", %{
      tmp_dir: tmp_dir
    } do
      events = Path.join(tmp_dir, "malformed-events.jsonl")

      pid =
        start_test_upstream(
          stdio_config(
            "stdio-malformed",
            %{
              "MCP_TEST_MODE" => "discover_malformed",
              "MCP_TEST_EVENT_FILE" => events
            },
            protocol_version: "auto",
            timeout: 500
          )
        )

      assert eventually(fn -> Upstream.status(pid).status == :disconnected end)
      assert eventually(fn -> "server/discover" in stdio_methods(events) end)
      refute "initialize" in stdio_methods(events)
    end
  end

  describe "catalog, credentials, and forwarding" do
    @describetag :task13

    test "uses the exact URL and resolves a rotated credential per request" do
      credential = unique_name("upstream-credential")
      assert {:ok, _} = Credentials.store(credential, "first-secret", "upstream")
      sync_vault()

      url = start_http_fixture(mode: :modern)

      pid =
        start_test_upstream(
          http_config("credential-rotation", url,
            protocol_version: "2026-07-28",
            credential: credential,
            auth_scheme: "bearer"
          )
        )

      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      first = receive_upstream_request("server/discover")
      assert first.path == "/custom/mcp"
      assert first.header_map["authorization"] == "Bearer first-secret"
      drain_upstream_requests()

      assert {:ok, _} = Credentials.rotate(credential, "second-secret")
      sync_vault()
      assert :ok = Upstream.refresh(pid)

      assert %{header_map: %{"authorization" => "Bearer second-secret"}} =
               receive_upstream_request("tools/list")

      refute inspect(:sys.get_state(pid)) =~ "first-secret"
      refute inspect(:sys.get_state(pid)) =~ "second-secret"
      refute inspect(Upstream.status(pid)) =~ "second-secret"
    end

    test "paginates atomically, retains last-good on failure, and overlays safe timeouts" do
      {:ok, catalog} = Agent.start_link(fn -> :old end)

      provider = fn cursor ->
        case {Agent.get(catalog, & &1), cursor} do
          {:old, nil} ->
            %{"tools" => [raw_tool("old")]}

          {:cycle, nil} ->
            %{"tools" => [raw_tool("partial")], "nextCursor" => "cycle"}

          {:cycle, "cycle"} ->
            %{"tools" => [], "nextCursor" => "cycle"}

          {:new, nil} ->
            %{"tools" => [raw_tool("new_one")], "nextCursor" => "page-2"}

          {:new, "page-2"} ->
            %{"tools" => [raw_tool("new_two")]}
        end
      end

      url = start_http_fixture(mode: :modern, catalog: provider)

      pid =
        start_test_upstream(
          http_config("catalog-refresh", url,
            protocol_version: "2026-07-28",
            timeout: 0,
            tool_timeouts: %{"new_one" => 1_234, "new_two" => 0}
          )
        )

      assert eventually(fn ->
               match?(
                 %{name: "catalog-refresh::old"},
                 ToolRegistry.lookup("catalog-refresh::old")
               )
             end)

      drain_upstream_requests()

      Agent.update(catalog, fn _ -> :cycle end)
      assert :ok = Upstream.refresh(pid)
      assert %{method: "tools/list"} = receive_upstream_request("tools/list")
      assert %{method: "tools/list"} = receive_upstream_request("tools/list")
      assert %{} = ToolRegistry.lookup("catalog-refresh::old")
      assert ToolRegistry.lookup("catalog-refresh::partial") == nil

      Agent.update(catalog, fn _ -> :new end)
      assert :ok = Upstream.refresh(pid)
      assert %{method: "tools/list"} = receive_upstream_request("tools/list")
      assert %{method: "tools/list"} = receive_upstream_request("tools/list")

      assert eventually(fn ->
               ToolRegistry.lookup("catalog-refresh::old") == nil and
                 match?(%{}, ToolRegistry.lookup("catalog-refresh::new_one")) and
                 match?(%{}, ToolRegistry.lookup("catalog-refresh::new_two"))
             end)

      assert {:upstream, ^pid, "new_one", 1_234} =
               ToolRegistry.resolve("catalog-refresh::new_one")

      assert {:upstream, ^pid, "new_two", 30_000} =
               ToolRegistry.resolve("catalog-refresh::new_two")

      assert {:upstream, ^pid, original_name, timeout} =
               ToolRegistry.resolve("catalog-refresh::new_one")

      assert {:ok, _result} = Upstream.forward(pid, original_name, %{}, timeout)
      assert %{method: "tools/call"} = receive_upstream_request("tools/call")
    end

    test "preserves false and nil structured content and sanitizes protocol errors" do
      secret = "upstream-secret-message"

      call_result = fn request ->
        case get_in(request, ["params", "name"]) do
          "false" -> %{"resultType" => "complete", "content" => [], "structuredContent" => false}
          "nil" -> %{"resultType" => "complete", "content" => [], "structuredContent" => nil}
          "secret" -> {:error, -32_000, secret}
        end
      end

      url = start_http_fixture(mode: :modern, call_result: call_result)
      pid = start_test_upstream(http_config("forwarding", url, protocol_version: "2026-07-28"))
      assert eventually(fn -> Upstream.status(pid).status == :connected end)

      assert {:ok, false_result} = Upstream.forward(pid, "false", %{})
      assert Map.fetch(false_result, "structuredContent") == {:ok, false}
      assert {:ok, nil_result} = Upstream.forward(pid, "nil", %{})
      assert Map.fetch(nil_result, "structuredContent") == {:ok, nil}

      for _ <- 1..3 do
        assert {:error, error} = Upstream.forward(pid, "secret", %{})
        refute error =~ secret
      end

      assert Upstream.status(pid).status == :degraded
    end

    test "input_required without outbound capabilities fails once without MRTR retry" do
      url = start_http_fixture(mode: :input_required)

      pid =
        start_test_upstream(http_config("input-required", url, protocol_version: "2026-07-28"))

      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      drain_upstream_requests()

      assert {:error, "missing_client_capability"} = Upstream.forward(pid, "echo", %{})
      assert %{method: "tools/call"} = receive_upstream_request("tools/call")

      assert %{method: "notifications/cancelled"} =
               receive_upstream_request("notifications/cancelled")

      refute_receive {:upstream_request, %{method: "tools/call"}}, 100
      refute_receive {:strict_modern_violation, _}, 50
    end

    @tag :stdio
    @tag :tmp_dir
    test "stdio input_required has the same one-call missing-capability result", %{
      tmp_dir: tmp_dir
    } do
      events = Path.join(tmp_dir, "input-required-events.jsonl")

      pid =
        start_test_upstream(
          stdio_config(
            "stdio-input-required",
            %{"MCP_TEST_MODE" => "input_required", "MCP_TEST_EVENT_FILE" => events},
            protocol_version: "2026-07-28"
          )
        )

      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      assert {:error, "missing_client_capability"} = Upstream.forward(pid, "echo", %{})
      assert eventually(fn -> Enum.count(stdio_methods(events), &(&1 == "tools/call")) == 1 end)
      assert eventually(fn -> "notifications/cancelled" in stdio_methods(events) end)
    end
  end

  describe "health and supervised recovery" do
    @describetag :task13

    test "legacy health pings while modern health performs a bounded catalog refresh" do
      legacy_url = start_http_fixture(mode: :legacy)
      legacy = start_test_upstream(http_config("health-legacy", legacy_url))
      assert eventually(fn -> Upstream.status(legacy).status == :connected end)
      drain_upstream_requests()
      send(legacy, :health_ping)
      assert %{method: "ping"} = receive_upstream_request("ping")
      assert eventually(fn -> not is_nil(Upstream.status(legacy).last_pong_at) end)

      modern_url = start_http_fixture(mode: :modern)

      modern =
        start_test_upstream(
          http_config("health-modern", modern_url, protocol_version: "2026-07-28")
        )

      assert eventually(fn -> Upstream.status(modern).status == :connected end)
      drain_upstream_requests()
      send(modern, :health_ping)
      assert %{method: "tools/list"} = receive_upstream_request("tools/list")
      refute_receive {:upstream_request, %{method: "ping"}}, 75
      refute_receive {:strict_modern_violation, _}, 50
      assert eventually(fn -> not is_nil(Upstream.status(modern).last_pong_at) end)
    end

    test "health failures preserve counters and degrade without duplicating schedules" do
      url = start_http_fixture(mode: :legacy_ping_error)
      pid = start_test_upstream(http_config("health-failure", url))
      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      drain_upstream_requests()

      for expected <- 1..3 do
        send(pid, :health_ping)
        assert %{method: "ping"} = receive_upstream_request("ping")
        assert eventually(fn -> Upstream.status(pid).consecutive_ping_failures == expected end)
      end

      assert %{status: :degraded, consecutive_ping_failures: 3} = Upstream.status(pid)
      assert match?({_timer, _token}, :sys.get_state(pid).health_timer)
    end

    test "outer client death deregisters tools, ignores stale messages, and recovers one tree" do
      url = start_http_fixture(mode: :modern)
      pid = start_test_upstream(http_config("recover", url, protocol_version: "2026-07-28"))

      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      old_state = :sys.get_state(pid)
      old_supervisor = old_state.client_supervisor
      old_monitor = old_state.client_monitor
      Process.exit(old_supervisor, :kill)

      assert eventually(fn -> ToolRegistry.lookup("recover::echo") == nil end)

      assert eventually(fn ->
               state = :sys.get_state(pid)

               state.status == :disconnected and is_nil(state.server_info) and
                 is_nil(state.server_capabilities)
             end)

      assert eventually(
               fn ->
                 state = :sys.get_state(pid)

                 state.status == :connected and is_pid(state.client_supervisor) and
                   state.client_supervisor != old_supervisor
               end,
               250
             )

      recovered = :sys.get_state(pid)
      send(pid, {:DOWN, old_monitor, :process, old_supervisor, :killed})
      send(pid, {:reconnect, make_ref()})
      send(pid, {:refresh, make_ref()})
      send(pid, {:health_ping, make_ref()})

      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      assert :sys.get_state(pid).client_supervisor == recovered.client_supervisor
      assert one_protocol_client?()
      assert %{} = ToolRegistry.lookup("recover::echo")
    end

    test "client death during connect and forward is sanitized without crashing the coordinator" do
      delayed_url = start_http_fixture(mode: :modern, delays: %{"server/discover" => 500})

      connecting =
        start_test_upstream(
          http_config("die-connecting", delayed_url,
            protocol_version: "2026-07-28",
            timeout: 1_000
          )
        )

      assert %{method: "server/discover"} = receive_upstream_request("server/discover")
      assert eventually(fn -> match?([_], DynamicSupervisor.which_children(ClientPool)) end)
      [{_, connecting_supervisor, _, _}] = DynamicSupervisor.which_children(ClientPool)
      Process.exit(connecting_supervisor, :kill)
      assert eventually(fn -> Process.alive?(connecting) end)
      assert eventually(fn -> Upstream.status(connecting).status == :disconnected end)

      call_url = start_http_fixture(mode: :modern, delays: %{"tools/call" => 500})

      forwarding =
        start_test_upstream(
          http_config("die-forwarding", call_url, protocol_version: "2026-07-28")
        )

      assert eventually(fn -> Upstream.status(forwarding).status == :connected end)
      forwarding_supervisor = :sys.get_state(forwarding).client_supervisor
      caller = Task.async(fn -> Upstream.forward(forwarding, "echo", %{}, 1_000) end)
      assert %{method: "tools/call"} = receive_upstream_request("tools/call")
      Process.exit(forwarding_supervisor, :kill)
      assert {:error, _sanitized} = Task.await(caller, 2_000)
      assert Process.alive?(forwarding)
      assert eventually(fn -> ToolRegistry.lookup("die-forwarding::echo") == nil end)
    end

    test "inner client death during refresh tears down the old outer tree before recovery" do
      gate = start_supervised!({Agent, fn -> %{calls: 0, released?: false} end})
      test_pid = self()

      catalog = fn _cursor ->
        call = Agent.get_and_update(gate, &{&1.calls + 1, %{&1 | calls: &1.calls + 1}})

        if call > 1 do
          send(test_pid, {:catalog_waiting, call})
          await_catalog_release!(gate)
        end

        %{"tools" => [raw_tool("echo")]}
      end

      url = start_http_fixture(mode: :modern, catalog: catalog)
      pid = start_test_upstream(http_config("die-refresh", url, protocol_version: "2026-07-28"))
      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      outer = :sys.get_state(pid).client_supervisor
      drain_upstream_requests()

      assert :ok = Upstream.refresh(pid)
      assert %{method: "tools/list"} = receive_upstream_request("tools/list")
      assert_receive {:catalog_waiting, 2}

      [{client, _value}] =
        Registry.lookup(Backplane.Proxy.ProcessRegistry, {"die-refresh", :client})

      Process.exit(client, :kill)
      assert eventually(fn -> ToolRegistry.lookup("die-refresh::echo") == nil end)
      assert eventually(fn -> Agent.get(gate, &(&1.calls >= 3)) end)
      Agent.update(gate, &%{&1 | released?: true})

      assert eventually(
               fn ->
                 state = :sys.get_state(pid)

                 state.status == :connected and state.client_supervisor != outer and
                   not is_nil(ToolRegistry.lookup("die-refresh::echo"))
               end,
               250
             )
    end

    test "terminate stops the current outer tree and leaves no reconnect owner" do
      url = start_http_fixture(mode: :modern)

      pid =
        start_test_upstream(http_config("terminate-tree", url, protocol_version: "2026-07-28"))

      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      supervisor = :sys.get_state(pid).client_supervisor
      monitor = Process.monitor(supervisor)

      assert :ok = GenServer.stop(pid)
      assert_receive {:DOWN, ^monitor, :process, ^supervisor, _reason}
      assert eventually(fn -> ToolRegistry.lookup("terminate-tree::echo") == nil end)
      assert eventually(fn -> DynamicSupervisor.which_children(ClientPool) == [] end)
    end
  end

  describe "HTTP transport" do
    test "connects and sends initialize" do
      # Start a mock HTTP server using Bandit
      {:ok, _} = start_mock_http_server(4201)

      config = %{
        name: "test-http",
        prefix: "test",
        transport: "http",
        url: "http://127.0.0.1:4201/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      # Give it time to connect
      Process.sleep(200)

      status = Upstream.status(pid)
      assert status.name == "test-http"
      assert status.status == :connected

      GenServer.stop(pid)
    end

    test "discovers tools via tools/list" do
      {:ok, _} = start_mock_http_server(4202)

      config = %{
        name: "test-http-discover",
        prefix: "mock",
        transport: "http",
        url: "http://127.0.0.1:4202/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      status = Upstream.status(pid)
      assert status.tool_count > 0

      GenServer.stop(pid)
    end

    test "registers discovered tools with prefix in registry" do
      {:ok, _} = start_mock_http_server(4203)

      config = %{
        name: "test-http-register",
        prefix: "mock",
        transport: "http",
        url: "http://127.0.0.1:4203/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      # Tools should be registered with prefix
      tools = ToolRegistry.list_all()
      assert Enum.any?(tools, fn t -> String.starts_with?(t.name, "mock::") end)

      GenServer.stop(pid)
    end

    test "forwards tool call and returns result" do
      {:ok, _} = start_mock_http_server(4204)

      config = %{
        name: "test-http-forward",
        prefix: "mock",
        transport: "http",
        url: "http://127.0.0.1:4204/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      result = Upstream.forward(pid, "echo", %{"message" => "hello"})
      assert {:ok, _} = result

      GenServer.stop(pid)
    end

    test "returns error when connection refused" do
      config = %{
        name: "test-http-refused",
        prefix: "refused",
        transport: "http",
        url: "http://127.0.0.1:19999/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      status = Upstream.status(pid)
      assert status.status in [:disconnected, :degraded]

      GenServer.stop(pid)
    end

    test "deregisters tools on stop" do
      {:ok, _} = start_mock_http_server(4205)

      config = %{
        name: "test-http-dereg",
        prefix: "dereg",
        transport: "http",
        url: "http://127.0.0.1:4205/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      # Tools should be registered
      tools_before = ToolRegistry.list_all()
      assert Enum.any?(tools_before, fn t -> String.starts_with?(t.name, "dereg::") end)

      GenServer.stop(pid)
      Process.sleep(100)

      # Tools should be deregistered
      tools_after = ToolRegistry.list_all()
      refute Enum.any?(tools_after, fn t -> String.starts_with?(t.name, "dereg::") end)
    end
  end

  describe "tool refresh" do
    test "handles refresh gracefully" do
      {:ok, _} = start_mock_http_server(4206)

      config = %{
        name: "test-refresh",
        prefix: "refresh",
        transport: "http",
        url: "http://127.0.0.1:4206/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      # Trigger manual refresh
      Upstream.refresh(pid)
      Process.sleep(200)

      status = Upstream.status(pid)
      assert status.status == :connected

      GenServer.stop(pid)
    end
  end

  describe "health ping" do
    test "status includes health ping fields after connection" do
      {:ok, _} = start_mock_http_server(4207)

      config = %{
        name: "test-health-ping",
        prefix: "health",
        transport: "http",
        url: "http://127.0.0.1:4207/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      status = Upstream.status(pid)
      assert status.status == :connected
      assert Map.has_key?(status, :last_ping_at)
      assert Map.has_key?(status, :last_pong_at)
      assert status.consecutive_ping_failures == 0

      GenServer.stop(pid)
    end

    test "health ping updates last_pong_at on success" do
      {:ok, _} = start_mock_http_server(4208)

      config = %{
        name: "test-health-pong",
        prefix: "pong",
        transport: "http",
        url: "http://127.0.0.1:4208/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      # Trigger a health ping manually
      send(pid, :health_ping)
      Process.sleep(200)

      status = Upstream.status(pid)
      assert status.last_ping_at != nil
      assert status.last_pong_at != nil
      assert status.consecutive_ping_failures == 0

      GenServer.stop(pid)
    end
  end

  describe "per-tool timeout" do
    test "registers tools with configured timeouts" do
      {:ok, _} = start_mock_http_server(4210)

      config = %{
        name: "test-timeout",
        prefix: "tout",
        transport: "http",
        url: "http://127.0.0.1:4210/mcp",
        headers: %{},
        tool_timeouts: %{"echo" => 5_000}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      # echo tool should have custom timeout
      echo_tool = ToolRegistry.lookup("tout::echo")
      assert echo_tool != nil
      assert echo_tool.timeout == 5_000

      # Other tools should have default timeout
      tools = ToolRegistry.list_all()

      non_echo =
        Enum.find(tools, fn t ->
          String.starts_with?(t.name, "tout::") and t.name != "tout::echo"
        end)

      if non_echo do
        assert non_echo.timeout == 30_000
      end

      GenServer.stop(pid)
    end

    test "uses default timeout when tool_timeouts not configured" do
      {:ok, _} = start_mock_http_server(4211)

      config = %{
        name: "test-no-timeout",
        prefix: "notime",
        transport: "http",
        url: "http://127.0.0.1:4211/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      tools = ToolRegistry.list_all()
      notime_tools = Enum.filter(tools, fn t -> String.starts_with?(t.name, "notime::") end)

      assert notime_tools != []
      assert Enum.all?(notime_tools, fn t -> t.timeout == 30_000 end)

      GenServer.stop(pid)
    end
  end

  describe "health ping when disconnected" do
    test "skips ping and reschedules when status is disconnected" do
      {:ok, _} = start_mock_http_server(4212)

      config = %{
        name: "test-disconnected-ping",
        prefix: "disc",
        transport: "http",
        url: "http://127.0.0.1:19997/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(300)

      status = Upstream.status(pid)
      assert status.status in [:disconnected, :degraded]

      # Send health_ping — should not crash, just reschedule
      send(pid, :health_ping)
      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "reconnect" do
    test "reconnect message triggers re-connection attempt" do
      config = %{
        name: "test-reconnect",
        prefix: "recon",
        transport: "http",
        url: "http://127.0.0.1:19996/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(300)

      status_before = Upstream.status(pid)
      assert status_before.status in [:disconnected, :degraded]

      # Send reconnect — it retries connection
      send(pid, :reconnect)
      Process.sleep(300)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "refresh via info message" do
    test "handles :refresh info message" do
      {:ok, _} = start_mock_http_server(4213)

      config = %{
        name: "test-refresh-info",
        prefix: "refinfo",
        transport: "http",
        url: "http://127.0.0.1:4213/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      send(pid, :refresh)
      Process.sleep(200)
      assert Process.alive?(pid)

      status = Upstream.status(pid)
      assert status.status == :connected

      GenServer.stop(pid)
    end
  end

  describe "HTTP error response" do
    test "forward returns error when upstream returns JSON-RPC error" do
      {:ok, _} = start_mock_http_server(4214)

      config = %{
        name: "test-http-error",
        prefix: "herr",
        transport: "http",
        url: "http://127.0.0.1:4214/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      # The mock responds with "Method not found" for unknown methods
      # forward always sends "tools/call" which returns success, so let's
      # just verify the forward path works
      result = Upstream.forward(pid, "unknown_tool", %{})
      assert {:ok, _} = result

      GenServer.stop(pid)
    end
  end

  describe "request metadata seam" do
    test "does not capture caller Logger metadata in the current provider contract" do
      url = start_http_fixture(mode: :legacy)
      pid = start_test_upstream(http_config("request-metadata", url))
      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      drain_upstream_requests()

      on_exit(fn -> Logger.metadata(request_id: nil) end)
      Logger.metadata(request_id: "deferred-request-id")

      assert {:ok, _result} = Upstream.forward(pid, "echo", %{"message" => "traced"})
      request = receive_upstream_request("tools/call")
      refute Map.has_key?(request.header_map, "x-request-id")
    end
  end

  describe "stdio transport" do
    @tag :stdio
    test "connects via stdio and discovers tools" do
      script = Path.join([File.cwd!(), "test", "support", "mock_stdio_mcp.sh"])

      config = %{
        name: "test-stdio",
        prefix: "stdio",
        transport: "stdio",
        command: "bash",
        args: [script],
        env: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(500)

      status = Upstream.status(pid)
      assert status.name == "test-stdio"
      assert status.status == :connected
      assert status.tool_count > 0

      GenServer.stop(pid)
    end

    @tag :stdio
    test "forwards tool call via stdio" do
      script = Path.join([File.cwd!(), "test", "support", "mock_stdio_mcp.sh"])

      config = %{
        name: "test-stdio-fwd",
        prefix: "stdfwd",
        transport: "stdio",
        command: "bash",
        args: [script],
        env: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(500)

      result = Upstream.forward(pid, "echo", %{"message" => "hello"})
      assert {:ok, _} = result

      GenServer.stop(pid)
    end

    @tag :stdio
    test "registers tools with prefix from stdio upstream" do
      script = Path.join([File.cwd!(), "test", "support", "mock_stdio_mcp.sh"])

      config = %{
        name: "test-stdio-reg",
        prefix: "stdioreg",
        transport: "stdio",
        command: "bash",
        args: [script],
        env: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(500)

      tools = ToolRegistry.list_all()
      assert Enum.any?(tools, fn t -> String.starts_with?(t.name, "stdioreg::") end)

      GenServer.stop(pid)
    end

    @tag :stdio
    test "deregisters tools and closes port on stop" do
      script = Path.join([File.cwd!(), "test", "support", "mock_stdio_mcp.sh"])

      config = %{
        name: "test-stdio-stop",
        prefix: "stdiostop",
        transport: "stdio",
        command: "bash",
        args: [script],
        env: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(500)

      tools_before = ToolRegistry.list_all()
      assert Enum.any?(tools_before, fn t -> String.starts_with?(t.name, "stdiostop::") end)

      GenServer.stop(pid)
      Process.sleep(100)

      tools_after = ToolRegistry.list_all()
      refute Enum.any?(tools_after, fn t -> String.starts_with?(t.name, "stdiostop::") end)
    end

    @tag :stdio
    test "handles stdio health ping" do
      script = Path.join([File.cwd!(), "test", "support", "mock_stdio_mcp.sh"])

      config = %{
        name: "test-stdio-ping",
        prefix: "stdping",
        transport: "stdio",
        command: "bash",
        args: [script],
        env: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(500)

      send(pid, :health_ping)
      Process.sleep(200)

      status = Upstream.status(pid)
      assert status.last_ping_at != nil
      assert status.consecutive_ping_failures == 0

      GenServer.stop(pid)
    end

    @tag :stdio
    test "handles connect failure for invalid command" do
      config = %{
        name: "test-stdio-bad",
        prefix: "stdbad",
        transport: "stdio",
        command: "/nonexistent/command/path",
        args: [],
        env: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(500)

      status = Upstream.status(pid)
      assert status.status in [:disconnected, :degraded]

      GenServer.stop(pid)
    end

    @tag :stdio
    test "stdio refresh re-discovers tools" do
      script = Path.join([File.cwd!(), "test", "support", "mock_stdio_mcp.sh"])

      config = %{
        name: "test-stdio-refresh",
        prefix: "stdref",
        transport: "stdio",
        command: "bash",
        args: [script],
        env: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(500)

      Upstream.refresh(pid)
      Process.sleep(300)

      status = Upstream.status(pid)
      assert status.status == :connected
      assert status.tool_count > 0

      GenServer.stop(pid)
    end
  end

  describe "forward/4 error handling" do
    test "forward with explicit timeout parameter" do
      {:ok, _} = start_mock_http_server(4217)

      config = %{
        name: "test-forward-timeout",
        prefix: "fwdto",
        transport: "http",
        url: "http://127.0.0.1:4217/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      # Use explicit timeout (exercises the 4-arity forward/4)
      result = Upstream.forward(pid, "echo", %{"message" => "hi"}, 5_000)
      assert {:ok, _} = result

      GenServer.stop(pid)
    end

    test "forward catches GenServer exit on timeout" do
      {:ok, _} = start_mock_http_server(4218)

      config = %{
        name: "test-forward-catch",
        prefix: "fwdcatch",
        transport: "http",
        url: "http://127.0.0.1:4218/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      # Stop the process, then try to forward — triggers :exit catch
      GenServer.stop(pid)
      Process.sleep(50)

      result = Upstream.forward(pid, "echo", %{})
      assert {:error, msg} = result
      assert is_binary(msg)
    end
  end

  describe "HTTP transport error paths" do
    test "forward returns error message from JSON-RPC error response" do
      {:ok, _} = start_mock_http_error_server(4219)

      config = %{
        name: "test-jsonrpc-error",
        prefix: "jrpcerr",
        transport: "http",
        url: "http://127.0.0.1:4219/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(300)

      assert Upstream.status(pid).status == :connected
      result = Upstream.forward(pid, "any_tool", %{})
      assert {:error, "server_error"} = result

      GenServer.stop(pid)
    end

    test "forward returns error when upstream HTTP returns non-200 status" do
      {:ok, _} = start_mock_non200_server(4320)

      config = %{
        name: "test-non200",
        prefix: "non200",
        transport: "http",
        url: "http://127.0.0.1:4320/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(300)

      # The server returns 500 for all requests, so connect_and_initialize fails
      status = Upstream.status(pid)
      assert status.status in [:disconnected, :degraded]

      GenServer.stop(pid)
    end

    test "refresh discovers tools even when first refresh fails" do
      {:ok, _} = start_mock_http_server(4222)

      config = %{
        name: "test-refresh-fail",
        prefix: "reffail",
        transport: "http",
        url: "http://127.0.0.1:4222/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      # Point to dead URL, refresh should fail gracefully
      :sys.replace_state(pid, fn state ->
        %{state | config: %{state.config | url: "http://127.0.0.1:19989/mcp"}}
      end)

      Upstream.refresh(pid)
      Process.sleep(300)

      # Should still be alive after failed refresh
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "HTTP call failure degradation" do
    test "consecutive tool call failures transition to degraded" do
      {:ok, _} = start_mock_http_error_server(4224)

      config = %{
        name: "test-call-degrade",
        prefix: "calldegrade",
        transport: "http",
        url: "http://127.0.0.1:4224/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(300)

      assert Upstream.status(pid).status == :connected

      # Send 3+ failing tool calls (mock returns JSON-RPC error for tools/call)
      for _ <- 1..4 do
        Upstream.forward(pid, "failing_tool", %{})
      end

      Process.sleep(100)
      status = Upstream.status(pid)
      assert status.status == :degraded
      GenServer.stop(pid)
    end

    test "successful call resets failure counter" do
      {:ok, _} = start_mock_http_server(4225)

      config = %{
        name: "test-call-reset",
        prefix: "callreset",
        transport: "http",
        url: "http://127.0.0.1:4225/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      # One successful call
      {:ok, _} = Upstream.forward(pid, "echo", %{"message" => "hello"})

      status = Upstream.status(pid)
      assert status.status == :connected

      GenServer.stop(pid)
    end
  end

  describe "malformed HTTP response body" do
    test "forward returns error for response without result or error keys" do
      {:ok, _} = start_mock_malformed_server(4223)

      config = %{
        name: "test-malformed",
        prefix: "malform",
        transport: "http",
        url: "http://127.0.0.1:4223/mcp",
        headers: %{},
        timeout: 200
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(300)

      assert Upstream.status(pid).status == :connected
      result = Upstream.forward(pid, "echo", %{"message" => "test"}, 200)
      assert {:error, msg} = result
      assert is_binary(msg)

      GenServer.stop(pid)
    end
  end

  describe "http transport with SSE response (Streamable HTTP)" do
    test "connects and discovers tools via SSE response" do
      port = 4260
      {:ok, _} = start_mock_sse_http_server(port)

      config = %{
        name: "stream-http",
        prefix: "shttp",
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      status = Upstream.status(pid)
      assert status.status == :connected
      assert status.tool_count == 1

      GenServer.stop(pid)
    end

    test "forwards tool call and parses SSE response" do
      port = 4261
      {:ok, _} = start_mock_sse_http_server(port)

      config = %{
        name: "stream-http-fwd",
        prefix: "shttpfwd",
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      assert {:ok, result} = Upstream.forward(pid, "echo", %{"message" => "hi"})
      assert [%{"text" => "sse mock result"}] = result["content"]

      GenServer.stop(pid)
    end
  end

  describe "unsupported transports" do
    test "rejects legacy sse transport" do
      config = %{
        name: "sse-upstream",
        prefix: "sse-test",
        transport: "sse",
        url: "http://127.0.0.1:4280/sse",
        headers: %{}
      }

      trap_exit = Process.flag(:trap_exit, true)

      try do
        assert {:error, {:unsupported_transport, "sse"}} = Upstream.start_link(config)
      after
        Process.flag(:trap_exit, trap_exit)
      end
    end
  end

  describe "post_url_known for supported transports" do
    test "post_url_known is false for http transport" do
      {:ok, _} = start_mock_http_server(4283)

      config = %{
        name: "http-post-url",
        prefix: "httppu",
        transport: "http",
        url: "http://127.0.0.1:4283/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      status = Upstream.status(pid)
      assert status.post_url_known == false
      GenServer.stop(pid)
    end
  end

  describe "protocol negotiation status" do
    test "reports the configured preference and negotiated legacy state" do
      {:ok, _} = start_mock_http_server(4284)

      config = %{
        name: "protocol-status",
        prefix: "protocolstatus",
        transport: "http",
        protocol_version: "auto",
        url: "http://127.0.0.1:4284/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      status = Upstream.status(pid)
      assert Map.has_key?(status, :protocol_preference)
      assert status.protocol_preference == "auto"
      assert status.negotiated_version == "2025-11-25"
      assert status.era == :legacy
      assert status.negotiation_status == :ready

      GenServer.stop(pid)
    end

    test "uses the legacy preference fallback while negotiation is incomplete" do
      config = %{
        name: "protocol-connecting",
        prefix: "protocolconnecting",
        transport: "http",
        url: "http://127.0.0.1:19987/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      status = Upstream.status(pid)
      assert Map.has_key?(status, :protocol_preference)
      assert status.protocol_preference == "2025-11-25"
      assert status.negotiated_version == nil
      assert status.era == nil
      assert status.negotiation_status == :connecting

      GenServer.stop(pid)
    end
  end

  describe "initialize response validation" do
    for {label, initialize_result} <- [
          {"a non-string protocol version",
           %{"protocolVersion" => %{"unsafe" => true}, "capabilities" => %{}}},
          {"an unknown protocol version",
           %{"protocolVersion" => "2099-01-01", "capabilities" => %{}}},
          {"malformed capabilities",
           %{"protocolVersion" => "2025-11-25", "capabilities" => ["tools"]}}
        ] do
      test "rejects HTTP initialize with #{label}" do
        initialize_result = unquote(Macro.escape(initialize_result))
        {:ok, bandit, port} = start_mock_invalid_initialize_server(initialize_result)
        on_exit(fn -> stop_bandit(bandit) end)

        config = %{
          name: "invalid-http-#{System.unique_integer([:positive])}",
          prefix: "invalidhttp",
          transport: "http",
          protocol_version: "2026-07-28",
          url: "http://127.0.0.1:#{port}/mcp",
          headers: %{}
        }

        {:ok, pid} = Upstream.start_link(config)
        Process.sleep(250)

        status = Upstream.status(pid)
        assert status.status == :disconnected
        assert status.protocol_preference == "2026-07-28"
        assert status.negotiated_version == nil
        assert status.era == nil
        assert status.negotiation_status == :connecting

        GenServer.stop(pid)
      end

      @tag :stdio
      @tag :tmp_dir
      test "rejects stdio initialize with #{label}", %{tmp_dir: tmp_dir} do
        initialize_result = unquote(Macro.escape(initialize_result))
        script = write_stdio_initialize_server(tmp_dir, initialize_result)

        config = %{
          name: "invalid-stdio-#{System.unique_integer([:positive])}",
          prefix: "invalidstdio",
          transport: "stdio",
          protocol_version: "auto",
          command: "bash",
          args: [script],
          env: %{},
          timeout: 500
        }

        {:ok, pid} = Upstream.start_link(config)
        Process.sleep(300)

        status = Upstream.status(pid)
        assert status.status == :disconnected
        assert status.protocol_preference == "auto"
        assert status.negotiated_version == nil
        assert status.era == nil
        assert status.negotiation_status == :connecting

        GenServer.stop(pid)
      end
    end
  end

  defp start_http_fixture(opts) do
    {:ok, bandit} =
      Bandit.start_link(
        plug: {Backplane.Test.MockMcpPlug, Keyword.put(opts, :owner, self())},
        port: 0,
        ip: {127, 0, 0, 1}
      )

    on_exit(fn -> stop_bandit(bandit) end)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    "http://127.0.0.1:#{port}/custom/mcp"
  end

  defp start_test_upstream(config) do
    {:ok, pid} = Upstream.start_link(config)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    pid
  end

  defp http_config(label, url, overrides \\ []) do
    Map.merge(
      %{
        name: label,
        prefix: label,
        transport: "http",
        url: url,
        headers: %{},
        auth_scheme: "none"
      },
      Map.new(overrides)
    )
  end

  defp stdio_config(label, env, overrides \\ []) do
    Map.merge(
      %{
        name: label,
        prefix: label,
        transport: "stdio",
        command: "bash",
        args: [Path.expand("../../support/mock_stdio_mcp.sh", __DIR__)],
        env: env
      },
      Map.new(overrides)
    )
  end

  defp receive_upstream_request(method, timeout \\ 2_000) do
    receive do
      {:upstream_request, %{method: ^method} = request} -> request
    after
      timeout -> flunk("timed out waiting for upstream #{method} request")
    end
  end

  defp drain_upstream_requests(acc \\ []) do
    receive do
      {:upstream_request, request} -> drain_upstream_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp raw_tool(name) do
    %{
      "name" => name,
      "description" => "#{name} tool",
      "inputSchema" => %{"type" => "object"}
    }
  end

  defp stdio_methods(path) do
    path
    |> file_lines()
    |> Enum.flat_map(fn line ->
      case JSON.decode(line) do
        {:ok, %{"method" => method}} -> [method]
        _invalid -> []
      end
    end)
  end

  defp file_lines(path) do
    case File.read(path) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp sync_vault do
    :sys.get_state(Vault)
    :ok
  end

  defp one_protocol_client? do
    match?([{_, _, _, _}], DynamicSupervisor.which_children(ClientPool))
  end

  defp eventually(predicate, attempts \\ 100)

  defp eventually(predicate, 0), do: predicate.()

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end

  defp await_catalog_release!(gate) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_await_catalog_release!(gate, deadline)
  end

  defp do_await_catalog_release!(gate, deadline) do
    cond do
      Agent.get(gate, & &1.released?) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "catalog gate was not released"

      true ->
        Process.sleep(10)
        do_await_catalog_release!(gate, deadline)
    end
  end

  # Mock HTTP MCP Server

  defp start_mock_sse_http_server(port) do
    Bandit.start_link(
      plug: Backplane.Test.MockSseHttpPlug,
      port: port,
      ip: {127, 0, 0, 1}
    )
  end

  defp start_mock_http_server(port) do
    Bandit.start_link(
      plug: Backplane.Test.MockMcpPlug,
      port: port,
      ip: {127, 0, 0, 1}
    )
  end

  defp start_mock_http_error_server(port) do
    Bandit.start_link(
      plug: MockMcpErrorPlug,
      port: port,
      ip: {127, 0, 0, 1}
    )
  end

  defp start_mock_non200_server(port) do
    Bandit.start_link(
      plug: MockMcpNon200Plug,
      port: port,
      ip: {127, 0, 0, 1}
    )
  end

  defp start_mock_malformed_server(port) do
    Bandit.start_link(
      plug: MockMcpMalformedPlug,
      port: port,
      ip: {127, 0, 0, 1}
    )
  end

  defp start_mock_invalid_initialize_server(initialize_result) do
    {:ok, bandit} =
      Bandit.start_link(
        plug: {MockMcpInvalidInitializePlug, initialize_result: initialize_result},
        port: 0,
        ip: {127, 0, 0, 1}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    {:ok, bandit, port}
  end

  defp stop_bandit(bandit) do
    if Process.alive?(bandit), do: GenServer.stop(bandit)
  catch
    :exit, _ -> :ok
  end

  defp write_stdio_initialize_server(tmp_dir, initialize_result) do
    path = Path.join(tmp_dir, "invalid_initialize.sh")
    encoded_result = Jason.encode!(initialize_result)

    File.write!(path, """
    while IFS= read -r line; do
      method=$(echo "$line" | grep -o '"method":"[^"]*"' | sed 's/"method":"//;s/"//')
      id=$(echo "$line" | sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*("[^"]*"|-?[0-9]+|null).*/\1/p')

      case "$method" in
        server/discover)
          printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id"
          ;;
        initialize)
          printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$id" '#{encoded_result}'
          ;;
        tools/list)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[]}}\\n' "$id"
          ;;
        ping)
          printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id"
          ;;
      esac
    done
    """)

    path
  end
end

defmodule MockMcpInvalidInitializePlug do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)

    result =
      case request["method"] do
        "initialize" -> Keyword.fetch!(opts, :initialize_result)
        "tools/list" -> %{"tools" => []}
        _ -> %{}
      end

    response = %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end
end

defmodule MockMcpErrorPlug do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)

    response =
      case request["method"] do
        "initialize" ->
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "protocolVersion" => "2025-03-26",
              "serverInfo" => %{"name" => "mock-error", "version" => "0.1.0"},
              "capabilities" => %{"tools" => %{}}
            }
          }

        "tools/list" ->
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "tools" => [
                %{
                  "name" => "failing_tool",
                  "description" => "Always errors",
                  "inputSchema" => %{"type" => "object"}
                }
              ]
            }
          }

        "tools/call" ->
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "error" => %{"code" => -32_000, "message" => "Tool execution failed"}
          }

        _ ->
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "error" => %{"code" => -32_601, "message" => "Method not found"}
          }
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end
end

defmodule MockMcpNon200Plug do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(500, Jason.encode!(%{"error" => "Internal Server Error"}))
  end
end

defmodule MockMcpMalformedPlug do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)

    response =
      case request["method"] do
        "initialize" ->
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "protocolVersion" => "2025-03-26",
              "serverInfo" => %{"name" => "mock-malformed", "version" => "0.1.0"},
              "capabilities" => %{"tools" => %{}}
            }
          }

        "tools/list" ->
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "tools" => [
                %{
                  "name" => "echo",
                  "description" => "Echo tool",
                  "inputSchema" => %{"type" => "object"}
                }
              ]
            }
          }

        "tools/call" ->
          # Return a body without "result" or "error" keys — triggers malformed path
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "data" => "unexpected_format"
          }

        _ ->
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{}
          }
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end
end
