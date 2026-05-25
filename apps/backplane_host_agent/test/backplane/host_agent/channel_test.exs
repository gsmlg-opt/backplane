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

  setup do
    previous = Application.get_env(:backplane_host_agent, :socket_client_module)
    :persistent_term.put({FakeSocketClient, :owner}, self())
    :persistent_term.put({AlreadyStartedSocketClient, :owner}, self())
    Application.put_env(:backplane_host_agent, :socket_client_module, FakeSocketClient)

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane_host_agent, :socket_client_module, previous)
      else
        Application.delete_env(:backplane_host_agent, :socket_client_module)
      end

      :persistent_term.erase({FakeSocketClient, :owner})
      :persistent_term.erase({AlreadyStartedSocketClient, :owner})
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
    assert opts[:reconnect?] == true
    assert opts[:transport_opts] == [headers: [{"X-Backplane-Host-Token", "host-token"}]]

    assert_receive {:connect, ^socket}
    refute_receive {:connect, ^socket}
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
end
