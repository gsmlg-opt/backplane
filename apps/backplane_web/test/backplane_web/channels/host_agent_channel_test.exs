defmodule BackplaneWeb.HostAgentChannelTest do
  use Backplane.ChannelCase, async: false

  import Backplane.SkillArchiveCase

  alias Backplane.Repo
  alias Backplane.Skills
  alias Backplane.Skills.{AgentManage, Assignments, HostStatus, Hosts}
  alias BackplaneWeb.HostAgentSocket

  @moduletag :tmp_dir
  @blob_setting "skills.blob.local_root"

  setup %{tmp_dir: tmp_dir} do
    previous_blob_root = Backplane.Settings.get(@blob_setting)
    blob_root = Path.join(tmp_dir, "blobs")

    :ets.insert(:backplane_settings, {@blob_setting, blob_root})
    AgentManage.clear()

    on_exit(fn ->
      :ets.insert(:backplane_settings, {@blob_setting, previous_blob_root})
      AgentManage.clear()
    end)

    {host, _auth_token, token} = create_agent_with_token!("channel-host")

    assert {:ok, socket} =
             connect(HostAgentSocket, %{"host_id" => host.id},
               connect_info: %{
                 x_headers: [{"x-backplane-host-token", token}]
               }
             )

    %{host: host, socket: socket}
  end

  test "joins only its own host topic", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})
    assert {:ok, %{host: connected_host}} = AgentManage.get_agent(host.id)
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

    assert {:ok, %{runtime: runtime}} = AgentManage.get_agent(host.id)
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

    assert {:ok, %{config: config}} = AgentManage.get_agent(host.id)
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
    host_id = host.id

    assert_reply(ref, :ok, %{
      "schema_version" => 2,
      "skills" => [],
      "mcp_servers" => [],
      "host" => %{"id" => ^host_id, "name" => "channel-host"}
    })
  end

  test "get_skill_bundle returns an assigned archive chunk", %{
    host: host,
    socket: socket,
    tmp_dir: tmp_dir
  } do
    archive_path =
      create_archive!(
        tmp_dir,
        [
          {"repo-review/SKILL.md", skill_md(name: "Repo Review")},
          {"repo-review/meta.json", Jason.encode!(%{"slug" => "repo-review"})}
        ],
        name: "repo-review.tar.gz"
      )

    assert {:ok, skill} = Skills.ingest_archive(archive_path, [])
    assert {:ok, _assignment} = Assignments.assign_skill(host, skill, %{"targets" => ["agents"]})
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref =
      push(socket, "get_skill_bundle", %{
        "slug" => "repo-review",
        "chunk_index" => 0,
        "chunk_size" => 8
      })

    assert_reply(ref, :ok, %{"ok" => true, "result" => chunk})
    assert chunk["slug"] == "repo-review"
    assert chunk["chunk_index"] == 0
    assert chunk["chunk_count"] > 1
    assert chunk["chunk_size"] == 8
    assert chunk["encoding"] == "base64"
    assert Base.decode64!(chunk["data"]) == binary_part(File.read!(archive_path), 0, 8)
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

    # Hermes prefetch / OpenClaw before_agent_start route here.
    test "recall dispatches with host_id injected", %{host: host, socket: socket} do
      ref =
        push(socket, "memory_call", %{
          "method" => "recall",
          "arguments" => %{"query" => "what", "limit" => 5, "agent_id" => "agt_1"}
        })

      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"echo" => "recall"}})
      assert_received {:memory_service, {:recall, args}}
      assert args["host_id"] == host.id
      assert args["query"] == "what"
      assert args["limit"] == 5
    end

    # Hermes system_prompt_block / memory_list tool routes here.
    test "list dispatches with scope+limit and host_id injected",
         %{host: host, socket: socket} do
      ref =
        push(socket, "memory_call", %{
          "method" => "list",
          "arguments" => %{"scope" => "/tmp/proj", "limit" => 10, "agent_id" => "agt_1"}
        })

      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"echo" => "list"}})
      assert_received {:memory_service, {:list, args}}
      assert args["host_id"] == host.id
      assert args["scope"] == "/tmp/proj"
      assert args["limit"] == 10
    end

    # Hermes memory_forget tool routes here.
    test "forget dispatches the id with host_id injected", %{host: host, socket: socket} do
      ref =
        push(socket, "memory_call", %{
          "method" => "forget",
          "arguments" => %{"id" => "mem_42", "agent_id" => "agt_1"}
        })

      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"echo" => "forget"}})
      assert_received {:memory_service, {:forget, args}}
      assert args["host_id"] == host.id
      assert args["id"] == "mem_42"
    end

    test "stats dispatches with host_id injected", %{host: host, socket: socket} do
      ref =
        push(socket, "memory_call", %{
          "method" => "stats",
          "arguments" => %{"agent_id" => "agt_1"}
        })

      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"echo" => "stats"}})
      assert_received {:memory_service, {:stats, args}}
      assert args["host_id"] == host.id
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

  defmodule StubHostMemorySync do
    def entitled_scopes(host) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:host_memory_sync, {:entitled_scopes, host.id}})
      MapSet.new(["proj_local"])
    end

    def facts_for_scope(scope, fact_set_hash) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:host_memory_sync, {:facts_for_scope, scope, fact_set_hash}})

      {:full,
       [
         %{
           "id" => "fact_1",
           "content" => "hub fact",
           "content_hash" => "hash_fact",
           "tags" => [],
           "metadata" => %{},
           "updated_at" => "2026-06-17T00:00:00Z"
         }
       ]}
    end

    def active_wipes(scope) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:host_memory_sync, {:active_wipes, scope}})

      [
        %{
          "directive_id" => "wipe_1",
          "content_hash" => "hash_wipe",
          "scope" => scope
        }
      ]
    end

    def apply_sync_item(host, item) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:host_memory_sync, {:apply_sync_item, host.id, item}})

      case item["id"] do
        "dup" -> {:ok, %{status: :duplicate, canonical_id: "hub_dup"}}
        "bad" -> {:error, :validation, "invalid scope"}
        "transient" -> {:error, :transient, "temporarily unavailable"}
        id -> {:ok, %{status: :ok, canonical_id: "hub_#{id}"}}
      end
    end
  end

  describe "host memory sync" do
    setup %{host: host, socket: socket} do
      :persistent_term.put({StubHostMemorySync, :owner}, self())
      Application.put_env(:backplane_web, :host_memory_sync_adapter, StubHostMemorySync)

      on_exit(fn ->
        Application.delete_env(:backplane_web, :host_memory_sync_adapter)
        _ = :persistent_term.erase({StubHostMemorySync, :owner})
      end)

      %{host: host, socket: socket}
    end

    test "join reconciles only entitled announced memory scopes", %{host: host, socket: socket} do
      payload = %{
        "memory" => %{
          "protocol" => "host_memory.v1",
          "scopes" => [
            %{"scope" => "proj_local", "fact_set_hash" => "old_hash"},
            %{"scope" => "secret", "fact_set_hash" => "secret_hash"}
          ]
        }
      }

      assert {:ok, _reply, _socket} = subscribe_and_join(socket, "host_agent:#{host.id}", payload)

      assert_push("memory_facts", %{
        "scope" => "proj_local",
        "full" => true,
        "facts" => [%{"id" => "fact_1"}]
      })

      assert_push("memory_wipe", %{
        "directive_id" => "wipe_1",
        "items" => [%{"content_hash" => "hash_wipe", "scope" => "proj_local"}]
      })

      assert_received {:host_memory_sync, {:entitled_scopes, _host_id}}
      assert_received {:host_memory_sync, {:facts_for_scope, "proj_local", "old_hash"}}
      assert_received {:host_memory_sync, {:active_wipes, "proj_local"}}
      refute_received {:host_memory_sync, {:facts_for_scope, "secret", "secret_hash"}}
      refute_received {:host_memory_sync, {:active_wipes, "secret"}}
    end

    test "memory_sync applies items and returns per-item acks", %{host: host, socket: socket} do
      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      ref =
        push(socket, "memory_sync", %{
          "protocol" => "host_memory.v1",
          "items" => [
            %{"id" => "local_1", "op" => "remember", "content" => "one"},
            %{"id" => "dup", "op" => "remember", "content" => "duplicate"},
            %{"id" => "bad", "op" => "remember", "content" => "bad"}
          ]
        })

      assert_reply(ref, :ok, %{
        "items" => [
          %{"id" => "local_1", "status" => "ok", "canonical_id" => "hub_local_1"},
          %{"id" => "dup", "status" => "duplicate", "canonical_id" => "hub_dup"},
          %{"id" => "bad", "status" => "error", "error" => "invalid scope"}
        ]
      })
    end

    test "memory_sync returns channel error for transient adapter failures", %{
      host: host,
      socket: socket
    } do
      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      ref =
        push(socket, "memory_sync", %{
          "protocol" => "host_memory.v1",
          "items" => [%{"id" => "transient", "op" => "remember", "content" => "later"}]
        })

      assert_reply(ref, :error, %{"reason" => "temporarily unavailable"})
    end

    test "facts and wipe acks are accepted", %{host: host, socket: socket} do
      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      facts_ref =
        push(socket, "memory_facts_ack", %{
          "scope" => "proj_local",
          "status" => "ok",
          "count" => 1
        })

      wipe_ref =
        push(socket, "memory_wipe_ack", %{
          "directive_id" => "wipe_1",
          "items" => [%{"content_hash" => "hash_wipe", "status" => "ok"}]
        })

      assert_reply(facts_ref, :ok, %{"ok" => true})
      assert_reply(wipe_ref, :ok, %{"ok" => true})
    end

    test "memory_sync rejects malformed payloads", %{host: host, socket: socket} do
      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      ref = push(socket, "memory_sync", %{"items" => "bad"})
      assert_reply(ref, :error, %{"reason" => "invalid_payload"})
    end
  end

  defp create_agent_with_token!(name) do
    assert {:ok, host, auth_token, token} = Hosts.create_agent_with_token(%{"name" => name})
    {host, auth_token, token}
  end
end
