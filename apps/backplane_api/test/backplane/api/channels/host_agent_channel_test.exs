defmodule Backplane.Api.HostAgentChannelTest do
  use Backplane.Api.ChannelCase, async: false

  import ExUnit.CaptureLog
  import Backplane.SkillArchiveCase
  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.AgentTraces.Event
  alias Backplane.Memory.Events.Event, as: MemoryEvent
  alias Backplane.Memory.Ingest.EventValidator
  alias Backplane.Memory.Imports.ImportBatch
  alias Backplane.Registry.{Tool, ToolRegistry}
  alias Backplane.Skills
  alias Backplane.Skills.{AgentManage, AgentPlugins, Assignments, HostStatus, Hosts}
  alias Backplane.Api.HostAgentSocket

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
      ToolRegistry.deregister_native("test::host_agent_channel_echo")
    end)

    {host, auth_token, token} = create_agent_with_token!("channel-host")

    assert {:ok, socket} =
             connect(HostAgentSocket, %{"host_id" => host.id},
               connect_info: %{
                 x_headers: [{"x-backplane-host-token", token}]
               }
             )

    %{host: host, auth_token: auth_token, socket: socket}
  end

  test "joins only its own host topic", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})
    assert {:ok, %{host: connected_host}} = AgentManage.get_agent(host.id)
    assert connected_host.id == host.id

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "host_agent:00000000-0000-0000-0000-000000000000", %{})
  end

  test "real channel capture keeps the host partition across assigned token rotation", %{
    host: host,
    auth_token: token_a_record,
    socket: token_a_socket
  } do
    Application.delete_env(:backplane_api, :host_event_ingest_adapter)

    assert {:ok, _reply, token_a_socket} =
             subscribe_and_join(token_a_socket, "host_agent:#{host.id}", %{})

    first = captured_memory_event(host, 1)
    first_ref = push_memory_events(token_a_socket, host, "batch-token-a", first)
    assert_reply(first_ref, :ok, %{"results" => [%{"status" => "accepted"}]})

    assert {:ok, token_b_record, token_b} =
             Hosts.create_auth_token_for_agent(host, %{"name" => "rotated token"})

    assert {:ok, _revoked} = Hosts.revoke_auth_token_for_agent(host, token_a_record.id)

    assert {:ok, token_b_socket} =
             connect(HostAgentSocket, %{"host_id" => host.id},
               connect_info: %{x_headers: [{"x-backplane-host-token", token_b}]}
             )

    assert {:ok, _reply, token_b_socket} =
             subscribe_and_join(token_b_socket, "host_agent:#{host.id}", %{})

    second = captured_memory_event(host, 2)
    second_ref = push_memory_events(token_b_socket, host, "batch-token-b", second)
    assert_reply(second_ref, :ok, %{"results" => [%{"status" => "accepted"}]})

    events = Repo.all(from(event in MemoryEvent, where: event.host_id == ^host.id))
    assert length(events) == 2
    assert Enum.all?(events, &(&1.client_id == "host:#{host.id}"))
    assert Enum.all?(events, &(&1.scope == host.memory_scope))

    assert MapSet.new(events, & &1.ingest_auth_token_id) ==
             MapSet.new([token_a_record.id, token_b_record.id])
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

  test "plugin_call_result completes an admin-initiated host-agent plugin call", %{
    host: host,
    socket: socket
  } do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})
    assert {:ok, entry} = AgentManage.get_agent(host.id)

    task =
      Task.async(fn ->
        AgentPlugins.install(entry, %{
          "plugin" => "memory",
          "runtime" => "hermes",
          "force" => "true"
        })
      end)

    assert_push("plugin_call", %{
      "call_id" => call_id,
      "name" => "host_agent::install_plugin",
      "arguments" => %{"plugin" => "memory", "runtime" => "hermes", "force" => true}
    })

    status = %{"plugin" => "memory", "runtime" => "hermes", "installed" => true}

    ref =
      push(socket, "plugin_call_result", %{
        "call_id" => call_id,
        "ok" => true,
        "result" => status
      })

    assert_reply(ref, :ok, %{"ok" => true})
    assert {:ok, ^status} = Task.await(task)
  end

  defmodule StubMemoryService do
    def handle_remember(args), do: send_and_ok({:remember, args})
    def handle_remember(args, auth), do: send_and_ok({:remember, args, auth})
    def handle_lifecycle_context(args, auth), do: send_and_ok({:lifecycle_context, args, auth})

    def call("memory::" <> operation, args, auth) do
      send_and_ok({String.to_existing_atom(operation), args, auth})
    end

    defp send_and_ok(message) do
      owner = :persistent_term.get({__MODULE__, :owner}, nil)
      if owner, do: send(owner, {:memory_service, message})
      {:ok, %{"echo" => elem(message, 0) |> to_string()}}
    end
  end

  defmodule RaisingLifecycleContext do
    def build(_project, _session_id, _opts) do
      send(:persistent_term.get({__MODULE__, :owner}), :channel_context_builder_called)
      raise "channel context builder secret"
    end
  end

  describe "memory_call" do
    setup %{host: host, socket: socket} do
      :persistent_term.put({StubMemoryService, :owner}, self())
      Application.put_env(:backplane_api, :memory_service, StubMemoryService)
      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      on_exit(fn ->
        Application.delete_env(:backplane_api, :memory_service)
        _ = :persistent_term.erase({StubMemoryService, :owner})
      end)

      %{socket: socket}
    end

    test "remember derives the canonical host partition outside wire arguments",
         %{host: host, socket: socket} do
      ref =
        push(socket, "memory_call", %{
          "method" => "remember",
          "arguments" => %{"content" => "hi", "agent_id" => "agt_1"}
        })

      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"echo" => "remember"}})
      assert_received {:memory_service, {:remember, args, auth}}
      refute Map.has_key?(args, "host_id")
      refute Map.has_key?(args, "client_id")
      assert auth.principal_metadata == %{"memory_partition_id" => "host:#{host.id}"}
      assert args["agent_id"] == "agt_1"
      assert args["content"] == "hi"
    end

    test "lifecycle_context forwards only request data with authenticated host identity",
         %{host: host, socket: socket} do
      args = %{
        "kind" => "session_start",
        "session_id" => "session-1",
        "project" => "/workspace/project",
        "agent_id" => "agt_1"
      }

      ref =
        push(socket, "memory_call", %{
          "method" => "lifecycle_context",
          "arguments" => args
        })

      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"echo" => "lifecycle_context"}})
      assert_received {:memory_service, {:lifecycle_context, ^args, auth}}
      assert auth.client_id == host.id
      assert auth.subject == host.id
      assert auth.principal_metadata == %{"memory_partition_id" => "host:#{host.id}"}
    end

    test "lifecycle_context rejects spoofed ownership through the production handler",
         %{socket: socket} do
      Application.delete_env(:backplane_api, :memory_service)

      ref =
        push(socket, "memory_call", %{
          "method" => "lifecycle_context",
          "arguments" => %{
            "kind" => "session_start",
            "session_id" => "session-1",
            "project" => "/workspace/project",
            "agent_id" => "agt_1",
            "scope" => "scope:attacker"
          }
        })

      assert_reply(ref, :ok, %{"ok" => false, "error" => "invalid_arguments"})
    end

    test "lifecycle_context keeps the channel alive when context construction raises",
         %{socket: socket} do
      previous_context_module = Application.get_env(:backplane_memory, :context_module)
      previous_inject_context = Backplane.Settings.get("memory.inject_context")
      Application.delete_env(:backplane_api, :memory_service)
      Application.put_env(:backplane_memory, :context_module, RaisingLifecycleContext)
      :ok = Backplane.Settings.set("memory.inject_context", "true")
      :persistent_term.put({RaisingLifecycleContext, :owner}, self())

      on_exit(fn ->
        :persistent_term.erase({RaisingLifecycleContext, :owner})
        Backplane.Settings.set("memory.inject_context", previous_inject_context)

        if previous_context_module do
          Application.put_env(:backplane_memory, :context_module, previous_context_module)
        else
          Application.delete_env(:backplane_memory, :context_module)
        end
      end)

      ref =
        push(socket, "memory_call", %{
          "method" => "lifecycle_context",
          "arguments" => %{
            "kind" => "session_start",
            "session_id" => "session-raise",
            "project" => "/workspace/project",
            "agent_id" => "agt_1"
          }
        })

      assert_reply(ref, :ok, %{
        "ok" => true,
        "result" => %{
          kind: "session_start",
          context: nil,
          source_revision: nil,
          cached: false,
          stale: false
        }
      })

      assert_received :channel_context_builder_called

      heartbeat_ref = push(socket, "heartbeat", %{})
      assert_reply(heartbeat_ref, :ok, %{"ok" => true})
    end

    # Hermes prefetch / OpenClaw before_agent_start route here.
    test "recall dispatches with host_id injected", %{host: host, socket: socket} do
      ref =
        push(socket, "memory_call", %{
          "method" => "recall",
          "arguments" => %{"query" => "what", "limit" => 5, "agent_id" => "agt_1"}
        })

      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"echo" => "recall"}})
      assert_received {:memory_service, {:recall, args, auth}}
      refute Map.has_key?(args, "host_id")
      assert auth.client_id == host.id
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
      assert_received {:memory_service, {:list, args, auth}}
      refute Map.has_key?(args, "host_id")
      assert auth.client_id == host.id
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
      assert_received {:memory_service, {:forget, args, auth}}
      refute Map.has_key?(args, "host_id")
      assert auth.client_id == host.id
      assert args["id"] == "mem_42"
    end

    test "stats dispatches with host_id injected", %{host: host, socket: socket} do
      ref =
        push(socket, "memory_call", %{
          "method" => "stats",
          "arguments" => %{"agent_id" => "agt_1"}
        })

      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"echo" => "stats"}})
      assert_received {:memory_service, {:stats, args, auth}}
      refute Map.has_key?(args, "host_id")
      assert auth.client_id == host.id
    end

    test "recall and import methods require independent host-agent permissions", %{socket: socket} do
      Application.put_env(:backplane_api, :host_agent_scopes, ["host_agent.capture"])
      on_exit(fn -> Application.delete_env(:backplane_api, :host_agent_scopes) end)

      recall_ref =
        push(socket, "memory_call", %{
          "method" => "recall",
          "arguments" => %{"query" => "hidden"}
        })

      import_ref =
        push(socket, "memory_call", %{
          "method" => "remember",
          "arguments" => %{"content" => "hidden", "agent_id" => "agent"}
        })

      assert_reply(recall_ref, :ok, %{"ok" => false, "error" => "unauthorized"})
      assert_reply(import_ref, :ok, %{"ok" => false, "error" => "unauthorized"})
      refute_received {:memory_service, _call}
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

  defmodule StubMcpTool do
    def call(args), do: {:ok, %{"echo" => args}}
  end

  describe "hub MCP proxy events" do
    setup %{host: host, socket: socket} do
      ToolRegistry.deregister_native("test::host_agent_channel_echo")

      :ok =
        ToolRegistry.register_native(%Tool{
          name: "test::host_agent_channel_echo",
          description: "Echo test tool",
          input_schema: %{
            "type" => "object",
            "properties" => %{"value" => %{"type" => "string"}}
          },
          origin: :native,
          module: StubMcpTool
        })

      for name <- ["memory::recall", "memory::remember"] do
        ToolRegistry.deregister_native(name)

        :ok =
          ToolRegistry.register_native(%Tool{
            name: name,
            description: "Host Memory scope test tool",
            input_schema: %{"type" => "object"},
            origin: :native,
            module: StubMcpTool
          })
      end

      on_exit(fn ->
        ToolRegistry.deregister_native("memory::recall")
        ToolRegistry.deregister_native("memory::remember")
      end)

      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      %{socket: socket}
    end

    test "mcp_tools_list hides tools outside the host Memory scope", %{socket: socket} do
      ref = push(socket, "mcp_tools_list", %{})

      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"tools" => tools}})

      refute Enum.any?(tools, &(&1["name"] == "test::host_agent_channel_echo"))
    end

    test "mcp_tools_list exposes only the independently granted host Memory surfaces", %{
      socket: socket
    } do
      Application.put_env(:backplane_api, :host_agent_scopes, ["host_agent.recall"])
      on_exit(fn -> Application.delete_env(:backplane_api, :host_agent_scopes) end)

      ref = push(socket, "mcp_tools_list", %{})
      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"tools" => recall_tools}})
      recall_names = MapSet.new(recall_tools, & &1["name"])
      assert MapSet.member?(recall_names, "memory::recall")
      refute MapSet.member?(recall_names, "memory::remember")

      Application.put_env(:backplane_api, :host_agent_scopes, ["host_agent.import"])

      ref = push(socket, "mcp_tools_list", %{})
      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"tools" => import_tools}})
      import_names = MapSet.new(import_tools, & &1["name"])
      assert MapSet.member?(import_names, "memory::remember")
      refute MapSet.member?(import_names, "memory::recall")

      Application.put_env(:backplane_api, :host_agent_scopes, ["host_agent.capture"])

      ref = push(socket, "mcp_tools_list", %{})
      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"tools" => []}})
    end

    test "mcp_tool_call rejects tools outside the host Memory scope", %{socket: socket} do
      ref =
        push(socket, "mcp_tool_call", %{
          "name" => "test::host_agent_channel_echo",
          "arguments" => %{"value" => "ok"}
        })

      assert_reply(ref, :ok, %{"ok" => false, "error" => "unauthorized"})
    end

    test "mcp_tool_call returns invalid_payload for malformed payloads", %{socket: socket} do
      ref = push(socket, "mcp_tool_call", %{"name" => "test::host_agent_channel_echo"})
      assert_reply(ref, :error, %{"reason" => "invalid_payload"})
    end
  end

  defmodule StubHostEventIngest do
    def ingest_batch(auth_context, payload) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:host_event_ingest, auth_context, payload})

      case :persistent_term.get({__MODULE__, :reply}) do
        {:raise, message} -> raise message
        {:exit, reason} -> exit(reason)
        reply -> reply
      end
    end
  end

  describe "host-local memory import lifecycle" do
    test "records only remote-safe batch metadata under the import scope", %{
      host: host,
      socket: socket
    } do
      Application.put_env(:backplane_api, :host_agent_scopes, ["host_agent.import"])
      on_exit(fn -> Application.delete_env(:backplane_api, :host_agent_scopes) end)

      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})
      batch_id = Ecto.UUID.generate()

      started = %{
        "protocol" => "host_import.v1",
        "action" => "started",
        "batch_id" => batch_id,
        "integration" => "claude_code",
        "source_format" => "claude_code_jsonl",
        "source_path_fingerprint" => "sha256:" <> String.duplicate("b", 64)
      }

      ref = push(socket, "memory_import_batch", started)
      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"status" => "started"}})

      ref =
        push(
          socket,
          "memory_import_batch",
          Map.merge(started, %{
            "action" => "completed",
            "discovered_count" => 3,
            "imported_count" => 2,
            "duplicate_count" => 0,
            "rejected_count" => 1
          })
        )

      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"status" => "completed"}})

      assert %ImportBatch{host_id: host_id, status: "completed"} =
               Repo.get!(ImportBatch, batch_id)

      assert host_id == host.id
    end

    test "rejects import lifecycle messages without the import scope", %{
      host: host,
      socket: socket
    } do
      Application.put_env(:backplane_api, :host_agent_scopes, ["host_agent.capture"])
      on_exit(fn -> Application.delete_env(:backplane_api, :host_agent_scopes) end)
      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      ref =
        push(socket, "memory_import_batch", %{
          "protocol" => "host_import.v1",
          "action" => "started"
        })

      assert_reply(ref, :error, %{"reason" => "unauthorized"})
    end
  end

  describe "host memory event ingest" do
    setup %{host: host, socket: socket} do
      :persistent_term.put({StubHostEventIngest, :owner}, self())

      Application.put_env(
        :backplane_api,
        :host_event_ingest_adapter,
        StubHostEventIngest
      )

      on_exit(fn ->
        Application.delete_env(:backplane_api, :host_event_ingest_adapter)
        _ = :persistent_term.erase({StubHostEventIngest, :owner})
        _ = :persistent_term.erase({StubHostEventIngest, :reply})
      end)

      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})
      %{socket: socket}
    end

    test "memory_events returns the exact mixed acknowledgement and trusted auth context", %{
      host: host,
      auth_token: auth_token,
      socket: socket
    } do
      payload = %{
        "protocol" => "host_events.v1",
        "batch_id" => "batch_1",
        "host_id" => host.id,
        "events" => [%{"event_id" => "event_1"}, %{"event_id" => "event_2"}]
      }

      reply = %{
        "batch_id" => "batch_1",
        "results" => [
          %{
            "event_id" => "event_1",
            "status" => "accepted",
            "server_event_id" => "server_1"
          },
          %{
            "event_id" => "event_2",
            "status" => "rejected",
            "retryable" => false,
            "reason" => "host_mismatch"
          }
        ]
      }

      :persistent_term.put({StubHostEventIngest, :reply}, {:ok, reply})

      ref = push(socket, "memory_events", payload)
      assert_reply(ref, :ok, ^reply)

      assert_received {:host_event_ingest,
                       %{
                         host_id: host_id,
                         auth_token_id: auth_token_id,
                         scopes: scopes,
                         partition: %{
                           host_id: partition_host_id,
                           partition_id: partition_id,
                           scope: scope,
                           namespace: "private"
                         }
                       }, ^payload}

      assert host_id == host.id
      assert auth_token_id == auth_token.id
      assert "host_agent.capture" in scopes
      assert partition_host_id == host.id
      assert partition_id == "host:#{host.id}"
      assert scope == host.memory_scope
    end

    test "memory_events requires capture independently from recall and import", %{
      host: host,
      socket: socket
    } do
      Application.put_env(:backplane_api, :host_agent_scopes, [
        "host_agent.recall",
        "host_agent.import"
      ])

      on_exit(fn -> Application.delete_env(:backplane_api, :host_agent_scopes) end)

      ref =
        push(socket, "memory_events", %{
          "protocol" => "host_events.v1",
          "batch_id" => "capture-denied",
          "host_id" => host.id,
          "events" => []
        })

      assert_reply(ref, :error, %{"reason" => "unauthorized"})
      refute_received {:host_event_ingest, _, _}
    end

    test "memory_events rejects a spoofed batch host before calling the adapter", %{
      socket: socket
    } do
      :persistent_term.put({StubHostEventIngest, :reply}, {:ok, %{}})

      ref =
        push(socket, "memory_events", %{
          "protocol" => "host_events.v1",
          "batch_id" => "batch_1",
          "host_id" => Ecto.UUID.generate(),
          "events" => []
        })

      assert_reply(ref, :error, %{"reason" => "host_mismatch"})
      refute_received {:host_event_ingest, _, _}
    end

    test "memory_events rejects malformed protocol and fields", %{host: host, socket: socket} do
      malformed = [
        %{
          "protocol" => "host_events.v0",
          "batch_id" => "batch_1",
          "host_id" => host.id,
          "events" => []
        },
        %{"protocol" => "host_events.v1", "batch_id" => "", "host_id" => host.id, "events" => []},
        %{
          "protocol" => "host_events.v1",
          "batch_id" => "batch_1",
          "host_id" => "",
          "events" => []
        },
        %{
          "protocol" => "host_events.v1",
          "batch_id" => "batch_1",
          "host_id" => host.id,
          "events" => %{}
        },
        %{
          "protocol" => "host_events.v1",
          "batch_id" => "batch_1",
          "host_id" => host.id,
          "events" => [%{"payload" => self()}]
        },
        %{
          "protocol" => "host_events.v1",
          "batch_id" => <<255>>,
          "host_id" => host.id,
          "events" => []
        },
        "not-a-map"
      ]

      for payload <- malformed do
        ref = push(socket, "memory_events", payload)
        assert_reply(ref, :error, %{"reason" => "invalid_payload"})
      end

      refute_received {:host_event_ingest, _, _}
    end

    test "memory_events rejects batches over 100 events", %{host: host, socket: socket} do
      ref =
        push(socket, "memory_events", %{
          "protocol" => "host_events.v1",
          "batch_id" => "batch_1",
          "host_id" => host.id,
          "events" => Enum.map(1..101, &%{"event_id" => "event_#{&1}"})
        })

      assert_reply(ref, :error, %{"reason" => "batch_too_large"})
      refute_received {:host_event_ingest, _, _}
    end

    test "memory_events rejects encoded payloads over 512 KiB", %{host: host, socket: socket} do
      ref =
        push(socket, "memory_events", %{
          "protocol" => "host_events.v1",
          "batch_id" => "batch_1",
          "host_id" => host.id,
          "events" => [%{"event_id" => "event_1", "payload" => String.duplicate("x", 524_288)}]
        })

      assert_reply(ref, :error, %{"reason" => "payload_too_large"})
      refute_received {:host_event_ingest, _, _}
    end

    test "memory_events maps known domain errors to channel errors", %{
      host: host,
      socket: socket
    } do
      for {domain_reason, channel_reason} <- [
            {:invalid_batch, "invalid_payload"},
            {:host_mismatch, "host_mismatch"}
          ] do
        :persistent_term.put({StubHostEventIngest, :reply}, {:error, domain_reason})

        ref =
          push(socket, "memory_events", %{
            "protocol" => "host_events.v1",
            "batch_id" => "batch_1",
            "host_id" => host.id,
            "events" => []
          })

        assert_reply(ref, :error, %{"reason" => ^channel_reason})
      end
    end

    test "memory_events contains unexpected adapter errors", %{host: host, socket: socket} do
      assert_ingest_unavailable(socket, host, {:error, :database_went_away})
    end

    test "memory_events contains malformed adapter replies", %{host: host, socket: socket} do
      secret_marker = "must-not-appear-in-ingest-log"

      log =
        capture_log(fn ->
          assert_ingest_unavailable(socket, host, {:ok, %{"secret" => secret_marker}})
        end)

      refute log =~ secret_marker

      for reply <- [
            {:ok, %{}},
            {:ok, %{"batch_id" => "batch_1", "results" => [%{} | :improper]}},
            {:ok, %{"batch_id" => "batch_1", "results" => [self()]}},
            :not_an_ingest_reply
          ] do
        assert_ingest_unavailable(socket, host, reply)
      end
    end

    test "memory_events contains adapter exceptions", %{host: host, socket: socket} do
      assert_ingest_unavailable(socket, host, {:raise, "adapter exploded"})
    end

    test "memory_events contains adapter exits", %{host: host, socket: socket} do
      assert_ingest_unavailable(socket, host, {:exit, :adapter_stopped})
    end
  end

  defmodule StubHostMemorySync do
    def entitled_scopes(host) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:host_memory_sync, {:entitled_scopes, host.id}})
      MapSet.new(["proj_local"])
    end

    def facts_for_scope(host, scope, fact_set_hash) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:host_memory_sync, {:facts_for_scope, host.id, scope, fact_set_hash}})

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

    def active_wipes(host, scope) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:host_memory_sync, {:active_wipes, host.id, scope}})

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

  defmodule RaisingHostMemorySync do
    def entitled_scopes(_host) do
      send(:persistent_term.get({__MODULE__, :owner}), :memory_reconcile_attempted)
      raise "memory reconcile unavailable"
    end

    def facts_for_scope(_host, _scope, _fact_set_hash), do: :unchanged
    def active_wipes(_host, _scope), do: []
    def apply_sync_item(_host, _item), do: {:error, :transient, "unavailable"}
  end

  describe "host memory sync" do
    setup %{host: host, socket: socket} do
      :persistent_term.put({StubHostMemorySync, :owner}, self())
      Application.put_env(:backplane_api, :host_memory_sync_adapter, StubHostMemorySync)

      on_exit(fn ->
        Application.delete_env(:backplane_api, :host_memory_sync_adapter)
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

      host_id = host.id
      assert_received {:host_memory_sync, {:entitled_scopes, _host_id}}
      assert_received {:host_memory_sync, {:facts_for_scope, ^host_id, "proj_local", "old_hash"}}

      assert_received {:host_memory_sync, {:active_wipes, ^host_id, "proj_local"}}
      refute_received {:host_memory_sync, {:facts_for_scope, ^host_id, "secret", "secret_hash"}}

      refute_received {:host_memory_sync, {:active_wipes, ^host_id, "secret"}}
    end

    test "join memory reconcile failures do not disconnect the host", %{
      host: host,
      socket: socket
    } do
      previous_flag = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous_flag) end)

      Application.put_env(:backplane_api, :host_memory_sync_adapter, RaisingHostMemorySync)
      :persistent_term.put({RaisingHostMemorySync, :owner}, self())
      on_exit(fn -> :persistent_term.erase({RaisingHostMemorySync, :owner}) end)

      payload = %{
        "memory" => %{
          "protocol" => "host_memory.v1",
          "scopes" => [%{"scope" => "proj_local", "fact_set_hash" => "old_hash"}]
        }
      }

      log =
        capture_log(fn ->
          assert {:ok, _reply, socket} =
                   subscribe_and_join(socket, "host_agent:#{host.id}", payload)

          send(self(), {:joined_socket, socket})

          assert_receive :memory_reconcile_attempted

          ref = push(socket, "heartbeat", %{"agent_version" => "0.3.1"})
          assert_reply(ref, :ok, %{"ok" => true})

          Logger.flush()

          refute_receive {:EXIT, _pid, _reason}, 100
        end)

      assert log =~ "Host-agent memory reconcile failed"
      refute log =~ "memory reconcile unavailable"
      assert_receive {:joined_socket, socket}
      assert {:ok, %{status: :online}} = AgentManage.get_agent(host.id)

      ref = push(socket, "heartbeat", %{"agent_version" => "0.3.1"})
      assert_reply(ref, :ok, %{"ok" => true})
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

    test "memory_sync requires import independently from capture and recall", %{
      host: host,
      socket: socket
    } do
      Application.put_env(:backplane_api, :host_agent_scopes, [
        "host_agent.capture",
        "host_agent.recall"
      ])

      on_exit(fn -> Application.delete_env(:backplane_api, :host_agent_scopes) end)
      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      ref =
        push(socket, "memory_sync", %{
          "protocol" => "host_memory.v1",
          "items" => [%{"id" => "denied", "op" => "remember", "content" => "secret"}]
        })

      assert_reply(ref, :error, %{"reason" => "unauthorized"})
      refute_received {:host_memory_sync, {:apply_sync_item, _, _}}
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

    test "memory_sync rejects more than 50 items before calling the adapter", %{
      host: host,
      socket: socket
    } do
      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      items = Enum.map(1..51, &%{"id" => "item_#{&1}", "op" => "remember"})
      ref = push(socket, "memory_sync", %{"protocol" => "host_memory.v1", "items" => items})

      assert_reply(ref, :error, %{"reason" => "batch_too_large"})
      refute_received {:host_memory_sync, {:apply_sync_item, _, _}}
    end

    test "memory_sync rejects encoded payloads over 512 KiB before calling the adapter", %{
      host: host,
      socket: socket
    } do
      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      ref =
        push(socket, "memory_sync", %{
          "protocol" => "host_memory.v1",
          "items" => [%{"id" => "large", "content" => String.duplicate("x", 512 * 1024)}]
        })

      assert_reply(ref, :error, %{"reason" => "payload_too_large"})
      refute_received {:host_memory_sync, {:apply_sync_item, _, _}}
    end
  end

  describe "host trace sync" do
    test "trace_sync persists items and returns per-item ok acks", %{host: host, socket: socket} do
      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      ref =
        push(socket, "trace_sync", %{
          "protocol" => "host_trace.v1",
          "items" => [valid_trace_item(1)]
        })

      assert_reply(ref, :ok, %{
        "ok" => true,
        "result" => %{"items" => [%{"seq" => 1, "status" => "ok"}]}
      })

      event = Repo.get_by!(Event, host_id: host.id, agent_seq: 1)
      assert event.trace_id == "0123456789abcdef0123456789abcdef"
      assert event.span_id == "0123456789abcdef"
      assert event.event == "agent.started"
    end

    test "trace_sync returns mixed ok and error item acks", %{host: host, socket: socket} do
      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      ref =
        push(socket, "trace_sync", %{
          "protocol" => "host_trace.v1",
          "items" => [
            valid_trace_item(1),
            valid_trace_item(2, %{"span_id" => "bad"})
          ]
        })

      assert_reply(ref, :ok, %{
        "ok" => true,
        "result" => %{
          "items" => [
            %{"seq" => 1, "status" => "ok"},
            %{"seq" => 2, "status" => "error", "error" => error}
          ]
        }
      })

      assert error =~ "span_id"
      assert Repo.get_by!(Event, host_id: host.id, agent_seq: 1)
      refute Repo.get_by(Event, host_id: host.id, agent_seq: 2)
    end

    test "trace_sync rejects malformed payloads", %{host: host, socket: socket} do
      assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

      ref = push(socket, "trace_sync", %{"protocol" => "host_trace.v1", "items" => "bad"})
      assert_reply(ref, :error, %{"reason" => "invalid_payload"})
    end
  end

  defp create_agent_with_token!(name) do
    assert {:ok, host, auth_token, token} = Hosts.create_agent_with_token(%{"name" => name})
    {host, auth_token, token}
  end

  defp push_memory_events(socket, host, batch_id, event) do
    push(socket, "memory_events", %{
      "protocol" => "host_events.v1",
      "batch_id" => batch_id,
      "host_id" => host.id,
      "events" => [event]
    })
  end

  defp captured_memory_event(host, sequence) do
    payload = %{"message" => "capture #{sequence}"}

    %{
      "event_id" => Ecto.UUID.generate(),
      "schema_version" => 1,
      "host_id" => host.id,
      "agent_id" => "channel-agent",
      "client_id" => "caller-controlled-client",
      "integration" => "codex",
      "project" => "/workspace/backplane",
      "scope" => host.memory_scope,
      "session_id" => "rotation-session",
      "parent_session_id" => nil,
      "sequence" => sequence,
      "event_type" => "agent.prompt.submitted",
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "captured_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "idempotency_key" => "rotation-session:#{sequence}",
      "payload_hash" => EventValidator.payload_hash(payload),
      "privacy" => %{"filtered" => true, "filter_version" => "1"},
      "trace" => %{"correlation_id" => "rotation-#{sequence}"},
      "payload" => payload
    }
  end

  defp assert_ingest_unavailable(socket, host, adapter_reply) do
    :persistent_term.put({StubHostEventIngest, :reply}, adapter_reply)

    ref =
      push(socket, "memory_events", %{
        "protocol" => "host_events.v1",
        "batch_id" => "batch_1",
        "host_id" => host.id,
        "events" => []
      })

    assert_reply(ref, :error, %{"reason" => "ingest_unavailable"})

    heartbeat_ref = push(socket, "heartbeat", %{"agent_version" => "test"})
    assert_reply(heartbeat_ref, :ok, %{"ok" => true})
  end

  defp valid_trace_item(seq, overrides \\ %{}) do
    Map.merge(
      %{
        "seq" => seq,
        "trace_id" => "0123456789abcdef0123456789abcdef",
        "span_id" => "0123456789abcdef",
        "parent_id" => nil,
        "event" => "agent.started",
        "measurements" => %{"duration_ms" => 12.5},
        "metadata" => %{"tool" => "test"},
        "occurred_at" => "2026-07-06T10:15:30.123456Z"
      },
      overrides
    )
  end
end
