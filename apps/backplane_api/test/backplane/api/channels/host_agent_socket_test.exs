defmodule Backplane.Api.HostAgentSocketTest do
  use Backplane.Api.ChannelCase, async: false

  alias Backplane.Skills.{AgentManage, Hosts}
  alias Backplane.Api.HostAgentSocket

  setup do
    AgentManage.clear()
    on_exit(fn -> AgentManage.clear() end)
  end

  test "endpoint requests x_headers and peer_data for the host agent websocket" do
    assert {"/host-agent/socket", HostAgentSocket, opts} =
             Enum.find(Backplane.Api.Endpoint.__sockets__(), fn {path, _socket, _opts} ->
               path == "/host-agent/socket"
             end)

    assert get_in(opts, [:websocket, :connect_info]) == [:x_headers, :peer_data]
    assert Keyword.fetch!(opts, :longpoll) == false
  end

  describe "connect/3" do
    test "connects with matching host_id and token and assigns connection IP" do
      {host, auth_token, token} = create_agent_with_token!("socket-host")

      assert {:ok, socket} =
               connect(HostAgentSocket, %{"host_id" => host.id},
                 connect_info: %{
                   x_headers: [{"x-backplane-host-token", token}, {"x-real-ip", "203.0.113.9"}],
                   peer_data: %{address: {127, 0, 0, 1}}
                 }
               )

      assert socket.assigns.host.id == host.id
      assert socket.assigns.auth_token.id == auth_token.id
      assert socket.assigns.connection_metadata.connect_ip == "203.0.113.9"
      assert socket.assigns.connection_metadata.connect_ip_source == "x-real-ip"
      assert HostAgentSocket.id(socket) == "host_agent:#{host.id}"
    end

    test "falls back to x-forwarded-for and peer IP" do
      {host, _auth_token, token} = create_agent_with_token!("forwarded-socket-host")

      assert {:ok, socket} =
               connect(HostAgentSocket, %{"host_id" => host.id},
                 connect_info: %{
                   x_headers: [
                     {"x-backplane-host-token", token},
                     {"x-forwarded-for", "198.51.100.20, 10.0.0.1"}
                   ],
                   peer_data: %{address: {127, 0, 0, 1}}
                 }
               )

      assert socket.assigns.connection_metadata.connect_ip == "198.51.100.20"
      assert socket.assigns.connection_metadata.connect_ip_source == "x-forwarded-for"

      assert {:ok, socket} =
               connect(HostAgentSocket, %{"host_id" => host.id},
                 connect_info: %{
                   x_headers: [{"x-backplane-host-token", token}],
                   peer_data: %{address: {127, 0, 0, 1}}
                 }
               )

      assert socket.assigns.connection_metadata.connect_ip == "127.0.0.1"
      assert socket.assigns.connection_metadata.connect_ip_source == "peer"
    end

    test "connects with valid uppercase X-Backplane-Host-Token header" do
      {host, _auth_token, token} = create_agent_with_token!("uppercase-socket-host")

      assert {:ok, socket} =
               connect(HostAgentSocket, %{"host_id" => host.id},
                 connect_info: %{
                   x_headers: [{"X-Backplane-Host-Token", token}]
                 }
               )

      assert socket.assigns.host.id == host.id
    end

    test "connects without waiting on the host manager process" do
      {host, _auth_token, token} = create_agent_with_token!("suspended-manager-host")

      [{manager_pid, _auth_cache}] =
        Registry.lookup(Backplane.Skills.AgentManage.Registry, host.id)

      :sys.suspend(manager_pid)

      try do
        assert {:ok, socket} =
                 connect(HostAgentSocket, %{"host_id" => host.id},
                   connect_info: %{
                     x_headers: [{"x-backplane-host-token", token}]
                   }
                 )

        assert socket.assigns.host.id == host.id
      after
        :sys.resume(manager_pid)
      end
    end

    test "rejects invalid, missing, or mismatched host tokens" do
      {host, _auth_token, token} = create_agent_with_token!("mismatch-host")

      assert :error =
               connect(HostAgentSocket, %{"host_id" => host.id},
                 connect_info: %{
                   x_headers: [{"x-backplane-host-token", "invalid-token"}]
                 }
               )

      assert :error =
               connect(HostAgentSocket, %{},
                 connect_info: %{
                   x_headers: [{"x-backplane-host-token", token}]
                 }
               )

      assert :error =
               connect(HostAgentSocket, %{"host_id" => Ecto.UUID.generate()},
                 connect_info: %{
                   x_headers: [{"x-backplane-host-token", token}]
                 }
               )
    end
  end

  defp create_agent_with_token!(name) do
    assert {:ok, host, auth_token, token} = Hosts.create_agent_with_token(%{"name" => name})
    {host, auth_token, token}
  end
end
