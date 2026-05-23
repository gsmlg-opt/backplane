defmodule Backplane.Skills.HostConnectionRegistryTest do
  use Backplane.DataCase, async: false

  alias Backplane.Skills.{HostConnectionRegistry, Hosts}

  setup do
    HostConnectionRegistry.clear()
    on_exit(fn -> HostConnectionRegistry.clear() end)

    assert {:ok, auth_token, _token} = Hosts.create_auth_token(%{"name" => "workstations"})

    assert {:ok, host} =
             Hosts.create_agent(%{"name" => "t430", "auth_token_ids" => [auth_token.id]})

    %{auth_token: auth_token, host: host}
  end

  test "tracks live connections in memory", %{auth_token: auth_token, host: host} do
    assert :ok = HostConnectionRegistry.register(host, auth_token, self())

    assert [
             %{
               auth_token_id: auth_token_id,
               connected_at: %DateTime{},
               host: connected_host,
               pid: pid,
               runtime: %{},
               config: nil
             }
           ] = HostConnectionRegistry.list_connected()

    assert auth_token_id == auth_token.id
    assert connected_host.id == host.id
    assert pid == self()
  end

  test "replaces an existing connection for the same agent", %{
    auth_token: first_token,
    host: host
  } do
    parent = self()

    old_pid =
      spawn(fn ->
        receive do
          message -> send(parent, {:old_connection_message, message})
        end
      end)

    assert {:ok, second_token, _token} = Hosts.create_auth_token(%{"name" => "rotation"})

    assert {:ok, _host} =
             Hosts.update_agent(host, %{
               "name" => "t430",
               "auth_token_ids" => [first_token.id, second_token.id]
             })

    assert :ok = HostConnectionRegistry.register(host, first_token, old_pid)
    assert :ok = HostConnectionRegistry.register(host, second_token, self())

    assert_receive {:old_connection_message, :disconnect}
    assert [%{pid: pid, auth_token_id: auth_token_id}] = HostConnectionRegistry.list_connected()
    assert pid == self()
    assert auth_token_id == second_token.id
  end

  test "removes the connection when the channel process exits", %{
    auth_token: auth_token,
    host: host
  } do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = HostConnectionRegistry.register(host, auth_token, pid)
    send(pid, :stop)

    assert eventually(fn -> HostConnectionRegistry.list_connected() == [] end)
  end

  test "stores heartbeat runtime and reported config", %{auth_token: auth_token, host: host} do
    assert :ok = HostConnectionRegistry.register(host, auth_token, self())

    assert :ok =
             HostConnectionRegistry.update_runtime(host.id, %{
               "status" => "syncing",
               "agent_version" => "0.1.0",
               "targets" => [%{"name" => "agents", "enabled" => true}]
             })

    assert :ok =
             HostConnectionRegistry.report_config(host.id, %{
               "agent" => %{"machine_name" => "t430"},
               "targets" => [%{"name" => "agents", "path" => "/tmp/skills"}]
             })

    assert %{runtime: runtime, config: config} = HostConnectionRegistry.get(host.id)
    assert runtime.status == "syncing"
    assert runtime.agent_version == "0.1.0"
    assert runtime.targets == [%{"name" => "agents", "enabled" => true}]
    assert config["agent"]["machine_name"] == "t430"
  end

  test "rejects malformed runtime and config payloads", %{auth_token: auth_token, host: host} do
    assert :ok = HostConnectionRegistry.register(host, auth_token, self())

    assert {:error, :invalid_payload} =
             HostConnectionRegistry.update_runtime(host.id, %{"targets" => "not-a-list"})

    assert {:error, :invalid_payload} = HostConnectionRegistry.report_config(host.id, "bad")
  end

  test "read APIs do not crash when the registry name is temporarily absent" do
    pid = Process.whereis(HostConnectionRegistry)
    Process.unregister(HostConnectionRegistry)

    on_exit(fn ->
      if is_pid(pid) and Process.alive?(pid) and Process.whereis(HostConnectionRegistry) == nil do
        Process.register(pid, HostConnectionRegistry)
      end
    end)

    assert [] = HostConnectionRegistry.list_connected()
    assert nil == HostConnectionRegistry.get(Ecto.UUID.generate())
    assert :ok = HostConnectionRegistry.disconnect(Ecto.UUID.generate())
    assert :ok = HostConnectionRegistry.clear()

    assert {:error, :not_connected} =
             HostConnectionRegistry.update_runtime(Ecto.UUID.generate(), %{})

    assert {:error, :not_connected} =
             HostConnectionRegistry.report_config(Ecto.UUID.generate(), %{})
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
