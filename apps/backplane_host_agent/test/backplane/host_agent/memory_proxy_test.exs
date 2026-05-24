defmodule Backplane.HostAgent.MemoryProxyTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.MemoryProxy

  defmodule FakeConnector do
    def connect(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:connect, config})

      {:ok, %{channel: owner, host_id: "host-1", host_name: "t430", socket: owner}}
    end
  end

  defmodule FakeChannel do
    def push(channel, event, payload, _timeout \\ 5_000) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:push, channel, event, payload})

      {:ok, %{"ok" => true, "result" => %{"status" => "ok"}}}
    end
  end

  setup do
    MemoryProxy.set_channel(nil)
    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeChannel, :owner}, self())

    on_exit(fn ->
      MemoryProxy.set_channel(nil)
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeChannel, :owner})
    end)

    :ok
  end

  test "returns not_connected instead of exiting when the cached channel pid is dead" do
    dead_channel = dead_pid()
    MemoryProxy.set_channel(dead_channel)

    assert {:error, :not_connected} = MemoryProxy.call("list", %{}, agent_id: "hermes")
    assert MemoryProxy.channel() == nil
  end

  test "reconnects with stored config when the cached channel pid is dead" do
    config = %{hub_url: "http://localhost:4220", token: "host-token", machine_name: "t430"}

    MemoryProxy.set_connection(
      %{channel: dead_pid(), host_id: "host-1", host_name: "t430", socket: nil},
      config
    )

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("list", %{"scope" => "/tmp"},
               agent_id: "hermes",
               channel_module: FakeChannel,
               connector_module: FakeConnector
             )

    assert_receive {:connect, ^config}

    assert_receive {:push, channel, "memory_call",
                    %{
                      "method" => "list",
                      "arguments" => %{"agent_id" => "hermes", "scope" => "/tmp"}
                    }}

    assert channel == self()
    assert MemoryProxy.channel() == self()
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end
end
