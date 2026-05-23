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
      {host, auth_token, token} = create_agent_with_token!("socket-host")

      assert {:ok, socket} =
               connect(HostAgentSocket, %{},
                 connect_info: %{
                   x_headers: [{"x-backplane-host-token", token}]
                 }
               )

      assert socket.assigns.host.id == host.id
      assert socket.assigns.auth_token.id == auth_token.id
      assert HostAgentSocket.id(socket) == "host_agent:#{host.id}"
    end

    test "connects with valid uppercase X-Backplane-Host-Token header" do
      {host, _auth_token, token} = create_agent_with_token!("uppercase-socket-host")

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

  defp create_agent_with_token!(name) do
    assert {:ok, auth_token, token} = Hosts.create_auth_token(%{"name" => "#{name} token"})

    assert {:ok, host} =
             Hosts.create_agent(%{"name" => name, "auth_token_ids" => [auth_token.id]})

    {host, auth_token, token}
  end
end
