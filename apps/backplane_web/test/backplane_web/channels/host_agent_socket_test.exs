defmodule BackplaneWeb.HostAgentSocketTest do
  use Backplane.ChannelCase, async: true

  alias Backplane.Skills.Hosts
  alias BackplaneWeb.HostAgentSocket

  test "endpoint requests x_headers for the host agent websocket" do
    assert {"/host-agent/socket", HostAgentSocket, opts} =
             Enum.find(BackplaneWeb.Endpoint.__sockets__(), fn {path, _socket, _opts} ->
               path == "/host-agent/socket"
             end)

    assert get_in(opts, [:websocket, :connect_info]) == [:x_headers]
    assert Keyword.fetch!(opts, :longpoll) == false
  end

  describe "connect/3" do
    test "connects with valid x-backplane-host-token and assigns the host" do
      assert {:ok, host, token} = Hosts.create_host(%{"name" => "socket-host"})

      assert {:ok, socket} =
               connect(HostAgentSocket, %{},
                 connect_info: %{
                   x_headers: [{"x-backplane-host-token", token}]
                 }
               )

      assert socket.assigns.host.id == host.id
      assert HostAgentSocket.id(socket) == "host_agent:#{host.id}"
    end

    test "connects with valid uppercase X-Backplane-Host-Token header" do
      assert {:ok, host, token} = Hosts.create_host(%{"name" => "uppercase-socket-host"})

      assert {:ok, socket} =
               connect(HostAgentSocket, %{},
                 connect_info: %{
                   x_headers: [{"X-Backplane-Host-Token", token}]
                 }
               )

      assert socket.assigns.host.id == host.id
    end

    test "rejects invalid host token" do
      assert :error =
               connect(HostAgentSocket, %{},
                 connect_info: %{
                   x_headers: [{"x-backplane-host-token", "invalid-token"}]
                 }
               )
    end
  end
end
