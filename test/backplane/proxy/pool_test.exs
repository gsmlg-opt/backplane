defmodule Backplane.Proxy.PoolTest do
  use ExUnit.Case, async: false

  alias Backplane.Proxy.Pool

  setup do
    :ets.delete_all_objects(:backplane_tools)

    # Pool is started by the Application supervisor, so just clean its children
    Pool
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      if is_pid(pid), do: DynamicSupervisor.terminate_child(Pool, pid)
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts with empty upstream list" do
      upstreams = Pool.list_upstreams()
      assert upstreams == []
    end
  end

  describe "start_upstream/1" do
    test "dynamically adds new upstream connection" do
      {:ok, bandit} =
        Bandit.start_link(
          plug: Backplane.Test.MockMcpPlug,
          port: 4210,
          ip: {127, 0, 0, 1}
        )

      on_exit(fn ->
        if Process.alive?(bandit) do
          try do
            GenServer.stop(bandit)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      config = %{
        name: "pool-test",
        prefix: "pooltest",
        transport: "http",
        url: "http://127.0.0.1:4210/mcp",
        headers: %{}
      }

      {:ok, _pid} = Pool.start_upstream(config)
      Process.sleep(300)

      upstreams = Pool.list_upstreams()
      assert length(upstreams) >= 1
      assert Enum.any?(upstreams, fn u -> u.name == "pool-test" end)
    end
  end

  describe "list_upstreams/0" do
    test "returns empty when no upstreams configured" do
      assert Pool.list_upstreams() == []
    end
  end
end
