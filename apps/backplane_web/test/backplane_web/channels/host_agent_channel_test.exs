defmodule BackplaneWeb.HostAgentChannelTest do
  use Backplane.ChannelCase, async: false

  alias Backplane.Repo
  alias Backplane.Skills.{HostConnectionRegistry, HostStatus, Hosts}
  alias BackplaneWeb.HostAgentSocket

  setup do
    HostConnectionRegistry.clear()
    on_exit(fn -> HostConnectionRegistry.clear() end)

    {host, _auth_token, token} = create_agent_with_token!("channel-host")

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
    assert %{host: connected_host} = HostConnectionRegistry.get(host.id)
    assert connected_host.id == host.id

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "host_agent:00000000-0000-0000-0000-000000000000", %{})
  end

  test "heartbeat updates live runtime state only", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref =
      push(socket, "heartbeat", %{
        "status" => "syncing",
        "agent_version" => "0.3.0",
        "targets" => [%{"name" => "agents"}]
      })

    assert_reply(ref, :ok, %{"ok" => true})

    assert %{runtime: runtime} = HostConnectionRegistry.get(host.id)
    assert runtime.status == "syncing"
    assert runtime.agent_version == "0.3.0"
    assert runtime.targets == [%{"name" => "agents"}]
    assert Hosts.get_host(host.id).name == "channel-host"
  end

  test "heartbeat replies with an error for invalid targets", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref = push(socket, "heartbeat", %{"targets" => "not-a-list"})
    assert_reply(ref, :error, %{"reason" => "invalid_payload"})
  end

  test "config_report stores the latest runtime config", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref =
      push(socket, "config_report", %{
        "agent" => %{"machine_name" => "channel-host"},
        "targets" => [%{"name" => "agents", "path" => "/tmp/skills"}]
      })

    assert_reply(ref, :ok, %{"ok" => true})

    assert %{config: config} = HostConnectionRegistry.get(host.id)
    assert config["agent"]["machine_name"] == "channel-host"
  end

  test "config_report rejects malformed payloads", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref = push(socket, "config_report", "not-a-map")
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

  test "sync_result replies ok and persists reported skill status", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref =
      push(socket, "sync_result", %{
        "results" => [
          %{
            "skill_name" => "agent-tools",
            "skill_slug" => "agent-tools",
            "checksum" => "sha256:abc",
            "targets" => ["agents"],
            "status" => "installed"
          }
        ]
      })

    assert_reply(ref, :ok, %{"ok" => true})

    persisted = Repo.get_by!(HostStatus, host_id: host.id, skill_name: "agent-tools")
    assert persisted.status == "installed"
    assert persisted.skill_slug == "agent-tools"
    assert persisted.desired_checksum == "sha256:abc"
    assert persisted.installed_checksum == "sha256:abc"
    assert persisted.targets == ["agents"]
  end

  test "sync_result rejects malformed payloads", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref = push(socket, "sync_result", "not-a-map")
    assert_reply(ref, :error, %{"reason" => "invalid_payload"})
  end

  test "sync_result rejects invalid optional field shapes", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref =
      push(socket, "sync_result", %{
        "results" => [
          %{"skill_name" => "agent-tools", "targets" => "not-a-list", "status" => "failed"}
        ]
      })

    assert_reply(ref, :error, %{"reason" => "invalid_payload"})
  end

  defmodule StubMemoryService do
    def handle_remember(args), do: send_and_ok({:remember, args})
    def handle_recall(args), do: send_and_ok({:recall, args})
    def handle_list(args), do: send_and_ok({:list, args})
    def handle_forget(args), do: send_and_ok({:forget, args})
    def handle_stats(args), do: send_and_ok({:stats, args})

    defp send_and_ok(message) do
      owner = :persistent_term.get({__MODULE__, :owner}, nil)
      if owner, do: send(owner, {:memory_service, message})
      {:ok, %{"echo" => elem(message, 0) |> to_string()}}
    end
  end

  describe "memory_call" do
    setup %{host: host, socket: socket} do
      :persistent_term.put({StubMemoryService, :owner}, self())
      Application.put_env(:backplane_web, :memory_service, StubMemoryService)
      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      on_exit(fn ->
        Application.delete_env(:backplane_web, :memory_service)
        _ = :persistent_term.erase({StubMemoryService, :owner})
      end)

      %{socket: socket}
    end

    test "remember injects host_id and dispatches to the memory service",
         %{host: host, socket: socket} do
      ref =
        push(socket, "memory_call", %{
          "method" => "remember",
          "arguments" => %{"content" => "hi", "agent_id" => "agt_1"}
        })

      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"echo" => "remember"}})
      assert_received {:memory_service, {:remember, args}}
      assert args["host_id"] == host.id
      assert args["agent_id"] == "agt_1"
      assert args["content"] == "hi"
    end

    test "unknown method returns an error reply", %{socket: socket} do
      ref = push(socket, "memory_call", %{"method" => "teleport", "arguments" => %{}})
      assert_reply(ref, :ok, %{"ok" => false, "error" => "unknown memory method: teleport"})
    end

    test "malformed payload returns an invalid_payload error", %{socket: socket} do
      ref = push(socket, "memory_call", %{"bad" => true})
      assert_reply(ref, :error, %{"reason" => "invalid_payload"})
    end
  end

  defp create_agent_with_token!(name) do
    assert {:ok, auth_token, token} = Hosts.create_auth_token(%{"name" => "#{name} token"})

    assert {:ok, host} =
             Hosts.create_agent(%{"name" => name, "auth_token_ids" => [auth_token.id]})

    {host, auth_token, token}
  end
end
