defmodule BackplaneWeb.HostAgentChannelTest do
  use Backplane.ChannelCase, async: true

  alias Backplane.Skills.Hosts
  alias BackplaneWeb.HostAgentSocket

  setup do
    assert {:ok, host, token} = Hosts.create_host(%{"name" => "channel-host"})

    assert {:ok, socket} =
             connect(HostAgentSocket, %{},
               connect_info: %{
                 x_headers: [{"x-backplane-host-token", token}]
               }
             )

    %{host: host, socket: socket}
  end

  test "joins only its own host topic", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "host_agent:00000000-0000-0000-0000-000000000000", %{})
  end

  test "heartbeat updates persisted host state", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref = push(socket, "heartbeat", %{"agent_version" => "0.3.0"})
    assert_reply(ref, :ok, %{"ok" => true})

    persisted = Hosts.get_host(host.id)
    assert persisted.status == "online"
    assert persisted.agent_version == "0.3.0"
    assert %DateTime{} = persisted.last_seen_at
  end

  test "heartbeat replies with an error for invalid host metadata", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref = push(socket, "heartbeat", %{"metadata" => "not-a-map"})
    assert_reply(ref, :error, %{"reason" => "invalid_payload"})
  end

  test "get_desired replies with JSON-shaped desired state for no assignments", %{
    host: host,
    socket: socket
  } do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref = push(socket, "get_desired", %{})
    assert_reply(ref, :ok, %{"schema_version" => 1, "skills" => []})
  end

  test "sync_result replies ok with payload fields", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref = push(socket, "sync_result", %{"target" => "agents", "changed" => 2})
    assert_reply(ref, :ok, %{"ok" => true, "target" => "agents", "changed" => 2})
  end

  test "sync_result rejects malformed payloads", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref = push(socket, "sync_result", "not-a-map")
    assert_reply(ref, :error, %{"reason" => "invalid_payload"})
  end
end
