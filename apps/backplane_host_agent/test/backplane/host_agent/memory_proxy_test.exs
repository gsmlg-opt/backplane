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

  defmodule RejoinChannel do
    def join(socket, host_id) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:join, socket, host_id})
      {:ok, owner}
    end

    def push(channel, event, payload, _timeout \\ 5_000) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:push, channel, event, payload})

      {:ok, %{"ok" => true, "result" => %{"status" => "ok"}}}
    end
  end

  defmodule UnexpectedConnector do
    def connect(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:unexpected_connect, config})
      {:error, :unexpected_reconnect}
    end
  end

  setup do
    MemoryProxy.set_channel(nil)
    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeChannel, :owner}, self())
    :persistent_term.put({RejoinChannel, :owner}, self())
    :persistent_term.put({UnexpectedConnector, :owner}, self())

    on_exit(fn ->
      MemoryProxy.set_channel(nil)
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeChannel, :owner})
      :persistent_term.erase({RejoinChannel, :owner})
      :persistent_term.erase({UnexpectedConnector, :owner})
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

  test "reconnects with stored config before any channel exists" do
    config = %{hub_url: "http://localhost:4220", token: "host-token", machine_name: "t430"}

    MemoryProxy.set_config(config)

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("list", %{"scope" => "/tmp"},
               agent_id: "hermes",
               channel_module: FakeChannel,
               connector_module: FakeConnector
             )

    assert_receive {:connect, ^config}
    assert_receive {:push, channel, "memory_call", %{"method" => "list"}}
    assert channel == self()
    assert MemoryProxy.channel() == self()
  end

  test "rejoins stored live socket before starting a new socket" do
    config = %{hub_url: "http://localhost:4220", token: "host-token", machine_name: "t430"}

    MemoryProxy.set_connection(
      %{channel: dead_pid(), host_id: "host-1", host_name: "t430", socket: self()},
      config
    )

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("list", %{"scope" => "/tmp"},
               agent_id: "hermes",
               channel_module: RejoinChannel,
               connector_module: UnexpectedConnector
             )

    assert_receive {:join, socket, "host-1"}
    assert socket == self()

    assert_receive {:push, channel, "memory_call",
                    %{
                      "method" => "list",
                      "arguments" => %{"agent_id" => "hermes", "scope" => "/tmp"}
                    }}

    assert channel == self()
    refute_received {:unexpected_connect, ^config}
  end

  test "emits telemetry for memory calls" do
    attach_telemetry("memory-proxy-call")
    MemoryProxy.set_channel(self())

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("list", %{"scope" => "/tmp"},
               agent_id: "hermes",
               channel_module: FakeChannel
             )

    assert_receive {:telemetry, [:backplane, :host_agent, :memory, :call, :start],
                    %{system_time: _},
                    %{agent_id: "hermes", method: "list", argument_keys: ["scope"]}}

    assert_receive {:telemetry, [:backplane, :host_agent, :memory, :call, :stop],
                    %{duration: duration}, %{agent_id: "hermes", method: "list", result: :ok}}

    assert is_integer(duration)
  end

  test "emits telemetry for memory call errors" do
    attach_telemetry("memory-proxy-error")

    assert {:error, :not_connected} = MemoryProxy.call("list", %{}, agent_id: "hermes")

    assert_receive {:telemetry, [:backplane, :host_agent, :memory, :call, :stop],
                    %{duration: duration},
                    %{agent_id: "hermes", method: "list", result: :error, error: ":not_connected"}}

    assert is_integer(duration)
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end

  defp attach_telemetry(id) do
    owner = self()
    handler_id = "#{id}-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:backplane, :host_agent, :memory, :call, :start],
        [:backplane, :host_agent, :memory, :call, :stop],
        [:backplane, :host_agent, :memory, :call, :exception]
      ],
      fn event, measurements, metadata, _config ->
        send(owner, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
