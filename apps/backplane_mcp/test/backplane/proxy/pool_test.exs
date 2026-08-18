defmodule Backplane.Proxy.PoolTest do
  use ExUnit.Case, async: false

  alias Backplane.Proxy.{ClientLeaseManager, ClientPool, Pool, ProtocolClient, Upstream}
  alias Backplane.Registry.ToolRegistry

  setup do
    :ets.delete_all_objects(:backplane_tools)
    cleanup_pool()

    on_exit(fn -> cleanup_pool() end)

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
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)

      config = %{
        name: "pool-test",
        prefix: "pooltest",
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
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
    test "cleans the owned catalog and protocol client before terminating an upstream" do
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)
      prefix = unique_prefix("stop")

      config = %{
        name: prefix,
        prefix: prefix,
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
        headers: %{},
        auth_scheme: "none"
      }

      {:ok, pid} = Pool.start_upstream(config)
      tool_name = "#{prefix}::echo"

      assert eventually(fn ->
               Upstream.status(pid).status == :connected and
                 not is_nil(ToolRegistry.lookup(tool_name))
             end)

      outer = :sys.get_state(pid).client_supervisor
      assert is_pid(outer)
      assert is_pid(registry_pid(prefix, :client))
      assert is_pid(registry_pid(prefix, :transport))

      assert Pool.list_upstreams() != []
      assert :ok = Pool.stop_upstream(pid)

      refute Process.alive?(pid)
      refute Process.alive?(outer)
      assert ToolRegistry.lookup(tool_name) == nil
      assert ToolRegistry.resolve(tool_name) == :not_found
      assert registry_pid(prefix, :client) == nil
      assert registry_pid(prefix, :transport) == nil
      assert Pool.list_upstreams() == []
      assert_stays_stopped(prefix, tool_name)
    end

    test "leaves a live upstream untouched when it is not owned by the pool" do
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)
      prefix = unique_prefix("not-owned")

      config = %{
        name: prefix,
        prefix: prefix,
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
        headers: %{},
        auth_scheme: "none"
      }

      assert {:ok, pid} = Upstream.start_link(config)

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _reason -> :ok
        end
      end)

      tool_name = "#{prefix}::echo"

      assert eventually(fn ->
               Upstream.status(pid).status == :connected and
                 not is_nil(ToolRegistry.lookup(tool_name))
             end)

      assert {:error, :not_found} = Pool.stop_upstream(pid)
      assert Process.alive?(pid)
      assert Upstream.status(pid).status == :connected
      assert %Backplane.Registry.Tool{} = ToolRegistry.lookup(tool_name)
      assert is_pid(registry_pid(prefix, :client))
      assert is_pid(registry_pid(prefix, :transport))
    end

    test "bounds stop while catalog discovery is stalled and removes every owned resource" do
      {bandit, port} = start_mock_server(delays: %{"tools/list" => 1_500})
      on_exit(fn -> stop_bandit(bandit) end)
      prefix = unique_prefix("stalled-stop")

      config = %{
        name: prefix,
        prefix: prefix,
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
        headers: %{},
        auth_scheme: "none",
        timeout: 5_000
      }

      assert {:ok, pid} = Pool.start_upstream(config)
      tool_name = "#{prefix}::echo"
      assert eventually(fn -> is_pid(registry_pid(prefix, :client)) end)

      started_at = System.monotonic_time(:millisecond)
      assert :ok = Pool.stop_upstream(pid)
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert elapsed < 1_000
      refute Process.alive?(pid)
      assert ToolRegistry.lookup(tool_name) == nil
      assert ToolRegistry.resolve(tool_name) == :not_found
      assert registry_pid(prefix, :client) == nil
      assert registry_pid(prefix, :transport) == nil
      assert upstream_lease(pid) == nil
      assert_stays_stopped(prefix, tool_name)
    end

    test "a restarted coordinator removes the crashed owner's lease and client tree" do
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)
      prefix = unique_prefix("crash-restart")

      config = %{
        name: prefix,
        prefix: prefix,
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
        headers: %{},
        auth_scheme: "none"
      }

      assert {:ok, first} = Pool.start_upstream(config)
      tool_name = "#{prefix}::echo"

      assert eventually(fn ->
               Upstream.status(first).status == :connected and
                 not is_nil(ToolRegistry.lookup(tool_name))
             end)

      first_outer = :sys.get_state(first).client_supervisor
      assert is_pid(first_outer)
      Process.exit(first, :kill)

      assert eventually(fn ->
               case Pool.list_upstream_pids() do
                 [{replacement, %{status: :connected}}] when replacement != first ->
                   not is_nil(ToolRegistry.lookup(tool_name)) and upstream_lease(first) == nil and
                     match?({^prefix, outer} when is_pid(outer), upstream_lease(replacement))

                 _not_recovered ->
                   false
               end
             end)

      [{replacement, _status}] = Pool.list_upstream_pids()
      refute Process.alive?(first_outer)

      assert {^prefix, replacement_outer} = ClientPool.lease_snapshot(replacement)

      assert is_pid(replacement_outer)
      assert :ok = Pool.stop_upstream(replacement)
    end

    test "an abnormal pool restart cleans its coordinator catalog and client tree" do
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)
      prefix = unique_prefix("pool-crash")

      config = %{
        name: prefix,
        prefix: prefix,
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
        headers: %{},
        auth_scheme: "none"
      }

      assert {:ok, upstream} = Pool.start_upstream(config)
      tool_name = "#{prefix}::echo"

      assert eventually(fn ->
               Upstream.status(upstream).status == :connected and
                 not is_nil(ToolRegistry.lookup(tool_name))
             end)

      outer = :sys.get_state(upstream).client_supervisor
      pool = Process.whereis(Pool)
      pool_ref = Process.monitor(pool)
      upstream_ref = Process.monitor(upstream)

      Process.exit(pool, :kill)
      assert_receive {:DOWN, ^pool_ref, :process, ^pool, :killed}
      assert_receive {:DOWN, ^upstream_ref, :process, ^upstream, _reason}

      assert eventually(fn ->
               restarted_pool = Process.whereis(Pool)

               is_pid(restarted_pool) and restarted_pool != pool and
                 :ets.whereis(:backplane_client_leases) != :undefined and
                 ToolRegistry.lookup(tool_name) == nil and
                 registry_pid(prefix, :client) == nil and
                 registry_pid(prefix, :transport) == nil and
                 not Process.alive?(outer)
             end)

      assert Pool.list_upstreams() == []
      assert ClientPool.lease_snapshots() == []
    end

    test "owner death during early client connect leaves an attached lease for replacement cleanup" do
      {bandit, port} = start_mock_server(delays: %{"initialize" => 1_000})
      on_exit(fn -> stop_bandit(bandit) end)
      prefix = unique_prefix("early-owner-death")

      config = %{
        name: prefix,
        prefix: prefix,
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
        headers: %{},
        auth_scheme: "none"
      }

      assert {:ok, first} = Pool.start_upstream(config)
      tool_name = "#{prefix}::echo"

      assert eventually(fn ->
               is_pid(registry_pid(prefix, :client)) and
                 match?({^prefix, outer} when is_pid(outer), upstream_lease(first))
             end)

      {^prefix, first_outer} = upstream_lease(first)
      Process.exit(first, :kill)

      assert eventually(
               fn ->
                 case Pool.list_upstream_pids() do
                   [{replacement, %{status: :connected}}] when replacement != first ->
                     not is_nil(ToolRegistry.lookup(tool_name)) and upstream_lease(first) == nil and
                       match?({^prefix, outer} when is_pid(outer), upstream_lease(replacement))

                   _not_recovered ->
                     false
                 end
               end,
               300
             )

      [{replacement, _status}] = Pool.list_upstream_pids()
      refute Process.alive?(first_outer)
      assert :ok = Pool.stop_upstream(replacement)
    end

    test "lease manager restart reconstructs a live owner and exact client tree" do
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)
      prefix = unique_prefix("manager-restart")

      config = %{
        name: prefix,
        prefix: prefix,
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
        headers: %{},
        auth_scheme: "none"
      }

      assert {:ok, upstream} = Pool.start_upstream(config)
      tool_name = "#{prefix}::echo"

      assert eventually(fn ->
               Upstream.status(upstream).status == :connected and
                 not is_nil(ToolRegistry.lookup(tool_name))
             end)

      {^prefix, outer} = upstream_lease(upstream)
      manager = Process.whereis(ClientLeaseManager)
      manager_ref = Process.monitor(manager)
      Process.exit(manager, :kill)
      assert_receive {:DOWN, ^manager_ref, :process, ^manager, :killed}

      assert eventually(fn ->
               restarted = Process.whereis(ClientLeaseManager)

               is_pid(restarted) and restarted != manager and Process.alive?(upstream) and
                 Process.alive?(outer) and upstream_lease(upstream) == {prefix, outer} and
                 Upstream.status(upstream).status == :connected and
                 not is_nil(ToolRegistry.lookup(tool_name))
             end)

      assert :ok = Pool.stop_upstream(upstream)
    end

    test "tombstone finalization removes a catalog registered after fallback cleanup" do
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)
      prefix = unique_prefix("late-catalog")

      config = %{
        name: prefix,
        prefix: prefix,
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
        headers: %{},
        auth_scheme: "none"
      }

      assert {:ok, upstream} = Pool.start_upstream(config)
      tool_name = "#{prefix}::echo"

      assert eventually(fn ->
               Upstream.status(upstream).status == :connected and
                 not is_nil(ToolRegistry.lookup(tool_name))
             end)

      assert :ok = ClientLeaseManager.mark_stopping(upstream)
      assert :ok = ClientLeaseManager.cleanup(upstream)
      assert {^prefix, nil} = upstream_lease(upstream)

      assert %{stopping: true} =
               :sys.get_state(ClientLeaseManager).leases[upstream]

      late_tool = %Backplane.Registry.Tool{
        name: "echo",
        description: "Late catalog result",
        input_schema: %{"type" => "object"},
        origin: {:upstream, prefix}
      }

      assert :ok = ToolRegistry.register_upstream(prefix, upstream, [late_tool])
      assert %Backplane.Registry.Tool{} = ToolRegistry.lookup(tool_name)

      assert :ok = ClientLeaseManager.finalize_owner(upstream)
      assert ToolRegistry.lookup(tool_name) == nil
      assert upstream_lease(upstream) == nil
      assert :ok = Pool.stop_upstream(upstream)
    end
  end

  describe "list_upstream_pids/0" do
    test "returns pid-status tuples for running upstreams" do
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)

      config = %{
        name: "pids-test",
        prefix: "pidstest",
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
        headers: %{}
      }

      {:ok, pid} = Pool.start_upstream(config)
      Process.sleep(300)

      pids = Pool.list_upstream_pids()
      assert [{returned_pid, status}] = pids
      assert returned_pid == pid
      assert status.name == "pids-test"
      assert status.prefix == "pidstest"
    end

    test "returns empty list when no upstreams" do
      assert Pool.list_upstream_pids() == []
    end
  end

  describe "protocol client supervision" do
    setup do
      ClientPool
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        if is_pid(pid), do: DynamicSupervisor.terminate_child(ClientPool, pid)
      end)

      :ok
    end

    test "application starts the local registry and client pool" do
      assert is_pid(Process.whereis(Backplane.Proxy.ProcessRegistry))
      assert is_pid(Process.whereis(ClientPool))
    end

    test "starts and stops a temporary protocol client tree" do
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)
      prefix = unique_prefix("start-stop")

      assert {:ok, supervisor} = start_protocol_client(prefix, port)

      assert [{client, _value}] =
               Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, :client})

      assert is_pid(client)

      assert [{transport, _value}] =
               Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, :transport})

      assert is_pid(transport)

      assert [{:undefined, ^supervisor, :supervisor, _modules}] =
               DynamicSupervisor.which_children(ClientPool)

      assert :ok = ClientPool.stop_client(supervisor)
      refute Process.alive?(supervisor)

      assert eventually(fn ->
               is_nil(registry_pid(prefix, :client)) and
                 is_nil(registry_pid(prefix, :transport))
             end)

      assert Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, :client}) == []
      assert Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, :transport}) == []
    end

    test "rejects duplicate registry names without replacing the running client" do
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)
      prefix = unique_prefix("duplicate")
      options = protocol_client_options(prefix, port)

      assert {:ok, first} = start_protocol_client(options)
      first_client = registry_pid(prefix, :client)
      first_transport = registry_pid(prefix, :transport)
      assert is_pid(first_client)
      assert is_pid(first_transport)

      assert {:error, _reason} = ClientPool.start_client(options)
      assert Process.alive?(first)
      assert registry_pid(prefix, :client) == first_client
      assert registry_pid(prefix, :transport) == first_transport
      assert one_protocol_client?()
    end

    test "keeps the outer tree while the package replaces its one-for-all children" do
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)
      prefix = unique_prefix("inner-restart")

      assert {:ok, supervisor} = start_protocol_client(prefix, port)
      first_client = registry_pid(prefix, :client)
      first_transport = registry_pid(prefix, :transport)

      Process.exit(first_transport, :kill)

      assert eventually(fn ->
               restarted_client = registry_pid(prefix, :client)
               restarted_transport = registry_pid(prefix, :transport)

               is_pid(restarted_client) and restarted_client != first_client and
                 is_pid(restarted_transport) and restarted_transport != first_transport
             end)

      assert Process.alive?(supervisor)
      assert one_protocol_client?()
    end

    test "does not restart a cleanly stopped client tree" do
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)
      prefix = unique_prefix("clean-exit")

      assert {:ok, supervisor} = start_protocol_client(prefix, port)

      monitor = Process.monitor(supervisor)
      assert :ok = ClientPool.stop_client(supervisor)
      assert_receive {:DOWN, ^monitor, :process, ^supervisor, :shutdown}

      assert eventually(fn ->
               no_protocol_clients?() and is_nil(registry_pid(prefix, :client)) and
                 is_nil(registry_pid(prefix, :transport))
             end)

      assert Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, :client}) == []
      assert Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, :transport}) == []
    end

    test "does not restart a crashed client tree" do
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)
      prefix = unique_prefix("crash")

      assert {:ok, supervisor} = start_protocol_client(prefix, port)

      monitor = Process.monitor(supervisor)
      Process.exit(supervisor, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^supervisor, :killed}

      assert eventually(fn ->
               no_protocol_clients?() and is_nil(registry_pid(prefix, :client)) and
                 is_nil(registry_pid(prefix, :transport))
             end)

      assert Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, :client}) == []
      assert Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, :transport}) == []
    end
  end

  # Starts a mock MCP server on a random available port
  defp start_mock_server(opts \\ []) do
    {:ok, bandit} =
      Bandit.start_link(
        plug: {Backplane.Test.MockMcpPlug, opts},
        port: 0,
        ip: {127, 0, 0, 1}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    {bandit, port}
  end

  defp stop_bandit(bandit) do
    if Process.alive?(bandit) do
      try do
        GenServer.stop(bandit)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp protocol_client_options(prefix, port) do
    ProtocolClient.client_options(%{
      prefix: prefix,
      transport: "http",
      protocol_version: "2025-11-25",
      url: "http://127.0.0.1:#{port}/mcp",
      headers: %{},
      auth_scheme: "none"
    })
  end

  defp start_protocol_client(prefix, port) do
    prefix
    |> protocol_client_options(port)
    |> start_protocol_client()
  end

  defp start_protocol_client(options) do
    case ClientPool.start_client(options) do
      {:ok, supervisor} = started ->
        prefix = client_prefix(options)

        on_exit(fn ->
          if Process.alive?(supervisor), do: ClientPool.stop_client(supervisor)

          assert eventually(fn ->
                   is_nil(registry_pid(prefix, :client)) and
                     is_nil(registry_pid(prefix, :transport))
                 end)
        end)

        started

      {:error, _reason} = error ->
        error
    end
  end

  defp client_prefix(options) do
    {:via, Registry, {Backplane.Proxy.ProcessRegistry, {prefix, :client}}} =
      Keyword.fetch!(options, :name)

    prefix
  end

  defp unique_prefix(label) do
    "#{label}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp one_protocol_client? do
    match?([{_, _, _, _}], DynamicSupervisor.which_children(ClientPool))
  end

  defp no_protocol_clients? do
    DynamicSupervisor.which_children(ClientPool) == []
  end

  defp registry_pid(prefix, role) do
    case Registry.lookup(Backplane.Proxy.ProcessRegistry, {prefix, role}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp upstream_lease(owner) do
    ClientPool.lease_snapshot(owner)
  end

  defp cleanup_pool do
    Pool
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      if is_pid(pid), do: Pool.stop_upstream(pid)
    end)
  catch
    :exit, _reason -> :ok
  end

  defp eventually(predicate, attempts \\ 50)

  defp eventually(predicate, 0), do: predicate.()

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end

  defp assert_stays_stopped(prefix, tool_name, timeout_ms \\ 150) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_stays_stopped(prefix, tool_name, deadline)
  end

  defp do_assert_stays_stopped(prefix, tool_name, deadline) do
    assert ToolRegistry.lookup(tool_name) == nil
    assert registry_pid(prefix, :client) == nil
    assert registry_pid(prefix, :transport) == nil
    assert Pool.list_upstreams() == []

    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      do_assert_stays_stopped(prefix, tool_name, deadline)
    else
      :ok
    end
  end
end
