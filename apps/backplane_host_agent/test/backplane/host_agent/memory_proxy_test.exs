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

  defmodule AlreadyJoinedChannel do
    def join(socket, host_id) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:join, socket, host_id})
      {:error, {:already_started, owner}}
    end

    def push(channel, event, payload, _timeout \\ 5_000) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:push, channel, event, payload})

      {:ok, %{"ok" => true, "result" => %{"status" => "ok"}}}
    end
  end

  defmodule SlowConnector do
    def connect(config) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:connect, config})
      Process.sleep(50)

      {:ok, %{channel: owner, host_id: "host-1", host_name: "t430", socket: owner}}
    end
  end

  defmodule FakeSocketClient do
    def disconnect(pid) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:disconnect, pid})
      :ok
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
    previous_socket_client = Application.get_env(:backplane_host_agent, :socket_client_module)

    MemoryProxy.set_channel(nil)
    :persistent_term.put({FakeConnector, :owner}, self())
    :persistent_term.put({FakeChannel, :owner}, self())
    :persistent_term.put({RejoinChannel, :owner}, self())
    :persistent_term.put({AlreadyJoinedChannel, :owner}, self())
    :persistent_term.put({SlowConnector, :owner}, self())
    :persistent_term.put({FakeSocketClient, :owner}, self())
    :persistent_term.put({UnexpectedConnector, :owner}, self())
    Application.put_env(:backplane_host_agent, :socket_client_module, FakeSocketClient)

    on_exit(fn ->
      MemoryProxy.set_channel(nil)
      :persistent_term.erase({FakeConnector, :owner})
      :persistent_term.erase({FakeChannel, :owner})
      :persistent_term.erase({RejoinChannel, :owner})
      :persistent_term.erase({AlreadyJoinedChannel, :owner})
      :persistent_term.erase({SlowConnector, :owner})
      :persistent_term.erase({FakeSocketClient, :owner})
      :persistent_term.erase({UnexpectedConnector, :owner})

      if previous_socket_client do
        Application.put_env(:backplane_host_agent, :socket_client_module, previous_socket_client)
      else
        Application.delete_env(:backplane_host_agent, :socket_client_module)
      end
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

  test "reuses already joined channel before starting a new socket" do
    config = %{hub_url: "http://localhost:4220", token: "host-token", machine_name: "t430"}

    MemoryProxy.set_connection(
      %{channel: dead_pid(), host_id: "host-1", host_name: "t430", socket: self()},
      config
    )

    assert {:ok, %{"status" => "ok"}} =
             MemoryProxy.call("list", %{"scope" => "/tmp"},
               agent_id: "hermes",
               channel_module: AlreadyJoinedChannel,
               connector_module: UnexpectedConnector
             )

    assert_receive {:join, socket, "host-1"}
    assert socket == self()

    assert_receive {:push, channel, "memory_call", %{"method" => "list"}}
    assert channel == self()
    refute_received {:unexpected_connect, ^config}
  end

  test "serializes concurrent reconnect attempts" do
    config = %{hub_url: "http://localhost:4220", token: "host-token", machine_name: "t430"}
    MemoryProxy.set_config(config)

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          MemoryProxy.call("list", %{"scope" => "/tmp"},
            agent_id: "hermes",
            channel_module: FakeChannel,
            connector_module: SlowConnector
          )
        end)
      end

    assert Enum.all?(tasks, fn task ->
             Task.await(task) == {:ok, %{"status" => "ok"}}
           end)

    assert_receive {:connect, ^config}
    refute_receive {:connect, ^config}, 100
  end

  test "disconnects stale socket when replacing the connection" do
    config = %{hub_url: "http://localhost:4220", token: "host-token", machine_name: "t430"}
    old_socket = spawn(fn -> Process.sleep(:infinity) end)
    new_socket = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      Process.exit(old_socket, :kill)
      Process.exit(new_socket, :kill)
    end)

    MemoryProxy.set_connection(
      %{channel: self(), host_id: "host-1", host_name: "t430", socket: old_socket},
      config
    )

    MemoryProxy.set_connection(
      %{channel: self(), host_id: "host-1", host_name: "t430", socket: new_socket},
      config
    )

    assert_receive {:disconnect, ^old_socket}
    refute_received {:disconnect, ^new_socket}
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
