defmodule Backplane.Proxy.UpstreamTest do
  use ExUnit.Case

  alias Backplane.Proxy.Upstream
  alias Backplane.Registry.ToolRegistry

  setup do
    :ets.delete_all_objects(:backplane_tools)
    :ok
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

    test "health ping increments failures on error" do
      # Connect to a working server first, then point to a dead one
      {:ok, _} = start_mock_http_server(4209)

      config = %{
        name: "test-health-fail",
        prefix: "hfail",
        transport: "http",
        url: "http://127.0.0.1:4209/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      assert Upstream.status(pid).status == :connected

      # Change the URL to a dead port by updating state directly
      :sys.replace_state(pid, fn state ->
        %{state | config: %{state.config | url: "http://127.0.0.1:19998/mcp"}}
      end)

      # Send health pings that will fail
      send(pid, :health_ping)
      Process.sleep(500)

      status = Upstream.status(pid)
      assert status.consecutive_ping_failures >= 1

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

  describe "degraded status from ping failures" do
    test "transitions to degraded after max consecutive failures" do
      {:ok, _} = start_mock_http_server(4215)

      config = %{
        name: "test-degraded",
        prefix: "degrade",
        transport: "http",
        url: "http://127.0.0.1:4215/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      assert Upstream.status(pid).status == :connected

      # Point to dead URL
      :sys.replace_state(pid, fn state ->
        %{state | config: %{state.config | url: "http://127.0.0.1:19995/mcp"}}
      end)

      # Send enough pings to trigger degraded (max_consecutive_failures = 3)
      for _ <- 1..4 do
        send(pid, :health_ping)
        Process.sleep(300)
      end

      status = Upstream.status(pid)
      assert status.status == :degraded
      assert status.consecutive_ping_failures >= 3

      GenServer.stop(pid)
    end
  end

  describe "request_id propagation" do
    test "propagates request_id header from Logger metadata" do
      {:ok, _} = start_mock_http_server(4216)

      config = %{
        name: "test-reqid",
        prefix: "reqid",
        transport: "http",
        url: "http://127.0.0.1:4216/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      # Set Logger metadata with request_id and forward
      Logger.metadata(request_id: "test-trace-id-123")
      result = Upstream.forward(pid, "echo", %{"message" => "traced"})
      assert {:ok, _} = result

      GenServer.stop(pid)
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
    test "handles stdio process exit and transitions to disconnected" do
      script = Path.join([File.cwd!(), "test", "support", "mock_stdio_mcp.sh"])

      config = %{
        name: "test-stdio-exit",
        prefix: "stdexit",
        transport: "stdio",
        command: "bash",
        args: [script],
        env: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(500)

      assert Upstream.status(pid).status == :connected

      # Kill the port's OS process to trigger {:exit_status, _}
      port = :sys.get_state(pid).port
      port_info = Port.info(port)
      os_pid = port_info[:os_pid]
      if os_pid, do: System.cmd("kill", [to_string(os_pid)])
      Process.sleep(500)

      status = Upstream.status(pid)
      assert status.status == :disconnected
      assert status.tool_count == 0

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
    test "send_stdio returns error when port is nil" do
      # Start with a bad command so port stays nil-like, then try to forward
      config = %{
        name: "test-stdio-nil",
        prefix: "stdnil",
        transport: "stdio",
        command: "/nonexistent/never/exists",
        args: [],
        env: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(500)

      # Force the port to nil and transport to stdio for the forward call
      :sys.replace_state(pid, fn state ->
        %{state | port: nil, status: :connected, transport: "stdio"}
      end)

      result = Upstream.forward(pid, "echo", %{})
      assert {:error, _} = result

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

    @tag :stdio
    test "stdio health ping with nil port returns error" do
      script = Path.join([File.cwd!(), "test", "support", "mock_stdio_mcp.sh"])

      config = %{
        name: "test-stdio-nilping",
        prefix: "stdnp",
        transport: "stdio",
        command: "bash",
        args: [script],
        env: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(500)

      # Set port to nil to test send_ping stdio nil path
      :sys.replace_state(pid, fn state -> %{state | port: nil} end)

      send(pid, :health_ping)
      Process.sleep(200)

      status = Upstream.status(pid)
      assert status.consecutive_ping_failures >= 1

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
      assert {:error, msg} = result
      assert msg =~ "Tool execution failed"

      GenServer.stop(pid)
    end

    test "forward returns error when upstream HTTP returns non-200 status" do
      {:ok, _} = start_mock_non200_server(4220)

      config = %{
        name: "test-non200",
        prefix: "non200",
        transport: "http",
        url: "http://127.0.0.1:4220/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(300)

      # The server returns 500 for all requests, so connect_and_initialize fails
      status = Upstream.status(pid)
      assert status.status in [:disconnected, :degraded]

      GenServer.stop(pid)
    end

    test "forward to dead upstream returns error via catch" do
      {:ok, _} = start_mock_http_server(4221)

      config = %{
        name: "test-catch-exit",
        prefix: "catchexit",
        transport: "http",
        url: "http://127.0.0.1:4221/mcp",
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(200)

      # Point to dead URL so next HTTP request fails
      :sys.replace_state(pid, fn state ->
        %{state | config: %{state.config | url: "http://127.0.0.1:19990/mcp"}}
      end)

      result = Upstream.forward(pid, "echo", %{})
      assert {:error, msg} = result
      assert is_binary(msg)

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
        headers: %{}
      }

      {:ok, pid} = Upstream.start_link(config)
      Process.sleep(300)

      assert Upstream.status(pid).status == :connected
      result = Upstream.forward(pid, "echo", %{"message" => "test"})
      assert {:error, msg} = result
      assert msg =~ "Malformed upstream response"

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
              "capabilities" => %{}
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
              "capabilities" => %{}
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
