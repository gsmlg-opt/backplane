defmodule Backplane.Proxy.PoolTest do
  use ExUnit.Case, async: false

  alias Backplane.Proxy.{ClientPool, Pool, ProtocolClient}

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
    test "terminates an upstream by pid" do
      {bandit, port} = start_mock_server()
      on_exit(fn -> stop_bandit(bandit) end)

      config = %{
        name: "stop-test",
        prefix: "stoptest",
        transport: "http",
        url: "http://127.0.0.1:#{port}/mcp",
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
  defp start_mock_server do
    {:ok, bandit} =
      Bandit.start_link(
        plug: Backplane.Test.MockMcpPlug,
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
end
