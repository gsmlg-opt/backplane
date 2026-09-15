defmodule Backplane.MetricsIntegrationTest do
  use ExUnit.Case, async: false

  alias Backplane.Metrics
  alias Backplane.Proxy.Pool

  test "snapshot maps live upstream status" do
    {:ok, bandit} =
      Bandit.start_link(
        plug: Backplane.Test.MockMcpPlug,
        port: 0,
        ip: {127, 0, 0, 1}
      )

    on_exit(fn ->
      if Process.alive?(bandit), do: GenServer.stop(bandit)
    end)

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
      if Process.alive?(upstream_pid), do: GenServer.stop(upstream_pid)
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
