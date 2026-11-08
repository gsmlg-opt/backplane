defmodule Backplane.HostAgent.ChannelTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Channel

  defmodule FakeSocketClient do
    def start_link(opts) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:start_link, opts})
      {:ok, owner}
    end

    def connect(pid) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:connect, pid})
      :ok
    end
  end

  defmodule AlreadyStartedSocketClient do
    def start_link(opts) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:start_link, opts})
      {:error, {:already_started, owner}}
    end

    def connected?(pid) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:connected?, pid})
      true
    end

    def connect(pid) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:connect, pid})
      :ok
    end
  end

  defmodule FailedSocketClient do
    def start_link(_opts) do
      {:ok, socket} = Agent.start_link(fn -> nil end)
      send(self(), {:failed_socket, socket})
      {:ok, socket}
    end

    def connect(_socket), do: {:error, :no_socket_found}
    def disconnect(_socket), do: :ok
  end

  defmodule FakeAgentChannel do
    use Phoenix.SocketClient.Channel

    @impl true
    def handle_message(_event, _payload, state), do: {:noreply, state}
  end

  defmodule FakeSocketChannelJoin do
    def join(socket, topic, payload) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:join, socket, topic, payload})
      {:ok, %{}, owner}
    end
  end

  setup do
    previous = Application.get_env(:backplane_host_agent, :socket_client_module)
    previous_channel = Application.get_env(:backplane_host_agent, :socket_channel_module)

    previous_channel_join =
      Application.get_env(:backplane_host_agent, :socket_channel_join_module)

    previous_store = Application.get_env(:backplane_host_agent, :memory_store)
    previous_memory_config = Application.get_env(:backplane_host_agent, :memory_config)

    :persistent_term.put({FakeSocketClient, :owner}, self())
    :persistent_term.put({AlreadyStartedSocketClient, :owner}, self())
    :persistent_term.put({FakeSocketChannelJoin, :owner}, self())
    Application.put_env(:backplane_host_agent, :socket_client_module, FakeSocketClient)
    Application.put_env(:backplane_host_agent, :memory_config, %{enabled: true})

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane_host_agent, :socket_client_module, previous)
      else
        Application.delete_env(:backplane_host_agent, :socket_client_module)
      end

      restore_env(:socket_channel_module, previous_channel)
      restore_env(:socket_channel_join_module, previous_channel_join)
      restore_env(:memory_store, previous_store)
      restore_env(:memory_config, previous_memory_config)

      :persistent_term.erase({FakeSocketClient, :owner})
      :persistent_term.erase({AlreadyStartedSocketClient, :owner})
      :persistent_term.erase({FakeSocketChannelJoin, :owner})
    end)
  end

  test "starts socket with auto connect disabled and connects once explicitly" do
    config = %{
      interval_ms: 60_000,
      socket_url: "ws://localhost:4220/host-agent/socket/websocket",
      token: "host-token"
    }

    assert {:ok, socket} = Channel.start_socket(config)
    assert socket == self()

    assert_receive {:start_link, opts}
    assert opts[:auto_connect] == false
    assert opts[:reconnect?] == false
    assert opts[:default_channel_module] == Backplane.HostAgent.AgentChannel
    assert opts[:headers] == [{"X-Backplane-Host-Token", "host-token"}]

    assert_receive {:connect, ^socket}
    refute_receive {:connect, ^socket}
  end

  test "uses configured host-agent channel callback module for socket channels" do
    Application.put_env(:backplane_host_agent, :socket_channel_module, FakeAgentChannel)

    config = %{
      interval_ms: 60_000,
      socket_url: "ws://localhost:4220/host-agent/socket/websocket",
      token: "host-token"
    }

    assert {:ok, socket} = Channel.start_socket(config)
    assert socket == self()

    assert_receive {:start_link, opts}
    assert opts[:default_channel_module] == FakeAgentChannel
  end

  test "reuses an already started connected socket" do
    Application.put_env(
      :backplane_host_agent,
      :socket_client_module,
      AlreadyStartedSocketClient
    )

    config = %{
      interval_ms: 60_000,
      socket_url: "ws://localhost:4220/host-agent/socket/websocket",
      token: "host-token"
    }

    assert {:ok, socket} = Channel.start_socket(config)
    assert socket == self()

    assert_receive {:start_link, opts}
    assert opts[:auto_connect] == false
    assert_receive {:connected?, ^socket}
    refute_receive {:connect, ^socket}
  end

  test "a synchronous connect failure retires its newly started socket" do
    Application.put_env(:backplane_host_agent, :socket_client_module, FailedSocketClient)

    assert {:error, :no_socket_found} =
             Channel.start_socket(%{socket_url: "ws://localhost/socket", token: "fixture"})

    assert_receive {:failed_socket, socket}
    refute Process.alive?(socket)
  end

  test "retirement is bounded even when an owned channel cannot handle system messages" do
    channel = spawn(fn -> receive do: (:finish -> :ok) end)
    on_exit(fn -> if Process.alive?(channel), do: Process.exit(channel, :kill) end)
    started = System.monotonic_time(:millisecond)
    assert :ok = Channel.retire(channel)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 4_900
    assert elapsed < 7_000
    refute Process.alive?(channel)
  end

  test "disabled memory omits all memory offers while retaining host API" do
    Application.put_env(:backplane_host_agent, :socket_channel_join_module, FakeSocketChannelJoin)
    Application.put_env(:backplane_host_agent, :memory_config, %{enabled: false})
    assert {:ok, %{}, _} = Channel.join(self(), "host-disabled")
    assert_receive {:join, _, "host_agent:host-disabled", payload}
    assert payload == %{"host_api" => %{"protocol" => "host_api.v1"}}
  end

  test "explicit join config takes precedence over previous memory settings" do
    Application.put_env(:backplane_host_agent, :socket_channel_join_module, FakeSocketChannelJoin)
    Application.put_env(:backplane_host_agent, :memory_config, %{enabled: true})
    assert {:ok, %{}, _} = Channel.join(self(), "host-disabled", %{memory: %{enabled: false}})
    assert_receive {:join, _, "host_agent:host-disabled", payload}
    refute Map.has_key?(payload, "memory_v2")
  end

  test "join offers only the capture extensions without access or edge negotiation" do
    Application.put_env(:backplane_host_agent, :socket_channel_join_module, FakeSocketChannelJoin)
    assert {:ok, %{}, _channel} = Channel.join(self(), "host-1")
    assert_receive {:join, _, "host_agent:host-1", payload}

    assert payload == %{
             "host_api" => %{"protocol" => "host_api.v1"},
             "memory_v2" => %{"extensions" => ["hermes_capture.v1", "openclaw_capture.v1"]}
           }
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane_host_agent, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_host_agent, key, value)
end
