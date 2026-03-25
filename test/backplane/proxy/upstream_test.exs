defmodule Backplane.Proxy.UpstreamTest do
  use ExUnit.Case

  alias Backplane.Registry.ToolRegistry
  alias Backplane.Proxy.Upstream

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

  # Mock HTTP MCP Server

  defp start_mock_http_server(port) do
    Bandit.start_link(
      plug: Backplane.Test.MockMcpPlug,
      port: port,
      ip: {127, 0, 0, 1}
    )
  end
end
