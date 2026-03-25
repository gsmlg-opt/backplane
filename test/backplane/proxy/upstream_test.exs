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

  # Mock HTTP MCP Server

  defp start_mock_http_server(port) do
    Bandit.start_link(
      plug: Backplane.Test.MockMcpPlug,
      port: port,
      ip: {127, 0, 0, 1}
    )
  end
end
