defmodule Backplane.HostAgent.MemoryProxyTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.MemoryProxy

  defmodule FakeSocketClient do
    def disconnect(pid) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:disconnect, pid})
      :ok
    end
  end

  setup do
    previous_socket_client = Application.get_env(:backplane_host_agent, :socket_client_module)

    MemoryProxy.set_channel(nil)
    :persistent_term.put({FakeSocketClient, :owner}, self())
    Application.put_env(:backplane_host_agent, :socket_client_module, FakeSocketClient)

    on_exit(fn ->
      MemoryProxy.set_channel(nil)
      :persistent_term.erase({FakeSocketClient, :owner})

      if previous_socket_client do
        Application.put_env(:backplane_host_agent, :socket_client_module, previous_socket_client)
      else
        Application.delete_env(:backplane_host_agent, :socket_client_module)
      end
    end)

    :ok
  end

  test "tracks the live channel" do
    assert MemoryProxy.channel() == nil
    assert :ok = MemoryProxy.set_channel(self())
    assert MemoryProxy.channel() == self()
    assert :ok = MemoryProxy.set_channel(nil)
    assert MemoryProxy.channel() == nil
  end

  test "set_connection publishes the joined channel" do
    channel = start_supervised!({Agent, fn -> nil end})

    assert :ok = MemoryProxy.set_connection(%{channel: channel, host_id: "host-1"})
    assert MemoryProxy.channel() == channel
  end

  test "a live owner cannot be replaced and stale cleanup cannot erase the new owner" do
    assert :ok = MemoryProxy.set_connection_owner(self())
    next_owner = start_supervised!({Agent, fn -> nil end})
    assert {:error, :connection_owned} = MemoryProxy.set_connection_owner(next_owner)
    assert :ok = MemoryProxy.clear_connection_owner(self())
    assert :ok = MemoryProxy.set_connection_owner(next_owner)
    assert :ok = MemoryProxy.clear_connection_owner(self())
    assert {:error, :connection_owned} = MemoryProxy.set_connection_owner(self())
  end

  test "a replacement owner retires the previous owner's channel" do
    MemoryProxy.set_connection_owner(dead_pid())
    old_channel = start_supervised!({Agent, fn -> nil end})
    MemoryProxy.set_connection(%{channel: old_channel})

    assert :ok = MemoryProxy.set_connection_owner(self())
    refute Process.alive?(old_channel)
    assert MemoryProxy.channel() == nil
  end

  test "set_connection keeps the current owner" do
    assert :ok = MemoryProxy.set_connection_owner(self())
    MemoryProxy.set_connection(%{channel: self()})

    next_owner = start_supervised!({Agent, fn -> nil end})
    assert {:error, :connection_owned} = MemoryProxy.set_connection_owner(next_owner)
  end

  test "disconnects and stops stale socket when replacing the connection" do
    {:ok, old_socket} = Supervisor.start_link([], strategy: :one_for_one)
    {:ok, new_socket} = Supervisor.start_link([], strategy: :one_for_one)
    old_ref = Process.monitor(old_socket)

    on_exit(fn ->
      if Process.alive?(new_socket), do: Supervisor.stop(new_socket)
    end)

    MemoryProxy.set_connection(%{channel: self(), host_id: "host-1", socket: old_socket})
    MemoryProxy.set_connection(%{channel: self(), host_id: "host-1", socket: new_socket})

    assert_receive {:disconnect, ^old_socket}
    assert_receive {:DOWN, ^old_ref, :process, ^old_socket, :normal}
    refute_received {:disconnect, ^new_socket}
    assert Process.alive?(new_socket)
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end
end
