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
      assert upstreams != []
      assert Enum.any?(upstreams, fn u -> u.name == "pool-test" end)
    end
  end

  describe "list_upstreams/0" do
    test "returns empty when no upstreams configured" do
      assert Pool.list_upstreams() == []
    end
  end

  describe "stop_upstream/1" do
    test "terminates an upstream by pid" do
      {:ok, bandit} =
        Bandit.start_link(
          plug: Backplane.Test.MockMcpPlug,
          port: 4211,
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
        name: "stop-test",
        prefix: "stoptest",
        transport: "http",
        url: "http://127.0.0.1:4211/mcp",
        headers: %{}
      }

      {:ok, pid} = Pool.start_upstream(config)
      Process.sleep(300)

      assert Pool.list_upstreams() != []
      assert :ok = Pool.stop_upstream(pid)
      Process.sleep(100)
      assert Pool.list_upstreams() == []
    end
  end

  describe "list_upstream_pids/0" do
    test "returns pid-status tuples for running upstreams" do
      {:ok, bandit} =
        Bandit.start_link(
          plug: Backplane.Test.MockMcpPlug,
          port: 4212,
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
        name: "pids-test",
        prefix: "pidstest",
        transport: "http",
        url: "http://127.0.0.1:4212/mcp",
        headers: %{}
      }

      {:ok, pid} = Pool.start_upstream(config)
      Process.sleep(300)

      pids = Pool.list_upstream_pids()
      assert length(pids) == 1
      [{returned_pid, status}] = pids
      assert returned_pid == pid
      assert status.name == "pids-test"
      assert status.prefix == "pidstest"
    end

    test "returns empty list when no upstreams" do
      assert Pool.list_upstream_pids() == []
    end
  end
end
