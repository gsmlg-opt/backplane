defmodule Backplane.MetricsIntegrationTest do
  use ExUnit.Case, async: false

  alias Backplane.Metrics
  alias Backplane.Proxy.Pool
  alias Backplane.Registry.ToolRegistry

  test "snapshot maps live upstream status" do
    bandit =
      start_supervised!({Bandit, plug: Backplane.Test.MockMcpPlug, port: 0, ip: {127, 0, 0, 1}})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    config = %{
      name: "metrics-upstream-test",
      prefix: "metup",
      transport: "http",
      url: "http://127.0.0.1:#{port}/mcp",
      headers: %{}
    }

    {:ok, upstream_pid} = Pool.start_upstream(config)

    on_exit(fn ->
      assert :ok = Pool.stop_upstream(upstream_pid)
      refute Pool.child?(upstream_pid)
      assert :not_found = ToolRegistry.resolve("metup::echo")
    end)

    Process.sleep(300)

    snapshot = Metrics.snapshot()
    assert is_list(snapshot.upstreams)
    assert snapshot.upstreams != []

    assert %{status: :connected, tool_count: tool_count, consecutive_ping_failures: failures} =
             Enum.find(snapshot.upstreams, &(&1.name == "metrics-upstream-test"))

    assert is_integer(tool_count)
    assert is_integer(failures)
  end
end
