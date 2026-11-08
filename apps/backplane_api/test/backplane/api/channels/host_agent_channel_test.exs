defmodule Backplane.Api.HostAgentChannelTest do
  use Backplane.Api.ChannelCase, async: false

  import ExUnit.CaptureLog
  import Backplane.SkillArchiveCase
  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.AgentTraces.Event
  alias Backplane.Memory.Events.Event, as: MemoryEvent
  alias Backplane.Memory.Ingest.EventValidator
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

    %{host: host, auth_token: auth_token, token: token, socket: socket}
  end

  test "joins only its own host topic", %{host: host, socket: socket} do
    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})
    assert {:ok, %{host: connected_host}} = AgentManage.get_agent(host.id)
    assert connected_host.id == host.id

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "host_agent:00000000-0000-0000-0000-000000000000", %{})
  end

  test "join reply has no memory partition keys", %{host: host, socket: socket} do
    assert {:ok, reply, _socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    assert reply == %{}
  end

  test "revoking an assigned token denies the already joined channel", %{
    host: host,
    auth_token: token,
    socket: socket
  } do
    assert {:ok, _, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})
    ref = push(socket, "mcp_tools_list", %{})
    assert_reply(ref, :ok, %{"ok" => true})
    assert {:ok, _} = Hosts.revoke_auth_token_for_agent(host, token.id)

    for event <- ~w(mcp_tools_list mcp_tool_call memory_events) do
      ref = push(socket, event, %{"name" => "memory::search", "arguments" => %{}})
      assert_reply(ref, :error, %{"code" => "unauthorized", "retryable" => false})
    end
  end

  test "retired memory partition events are unsupported", %{host: host, socket: socket} do
    assert {:ok, _, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    for event <-
          ~w(memory_call memory_sync memory_next memory_ack memory_import_batch memory_access_refresh) do
      ref = push(socket, event, %{"method" => "stats", "arguments" => %{}})
      assert_reply(ref, :error, %{"code" => "unsupported_protocol", "retryable" => false})
    end
  end

  test "revocation between socket authentication and join rejects cached credentials", %{
    host: host,
    auth_token: token,
    socket: socket
  } do
    assert {:ok, _} = Hosts.revoke_auth_token_for_agent(host, token.id)

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "host_agent:#{host.id}", %{})
  end

  test "memory_events from a host with no memory_scope are ingested", %{
    host: host,
    socket: socket
  } do
    Application.delete_env(:backplane_api, :host_event_ingest_adapter)
    refute Map.has_key?(Repo.reload!(host), :memory_scope)

    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref = push_memory_events(socket, host, "batch-no-scope", captured_memory_event(host, 1))
    assert_reply(ref, :ok, %{"results" => [%{"status" => "accepted"}]})

    assert [%MemoryEvent{host_id: host_id}] =
             Repo.all(from(event in MemoryEvent, where: event.host_id == ^host.id))

    assert host_id == host.id
  end

  test "real channel capture keeps the host identity across assigned token rotation", %{
    host: host,
    auth_token: token_a_record,
    token: token_a,
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

    assert :error =
             connect(HostAgentSocket, %{"host_id" => host.id},
               connect_info: %{x_headers: [{"x-backplane-host-token", token_a}]}
             )

    assert {:ok, token_b_socket} =
             connect(HostAgentSocket, %{"host_id" => host.id},
               connect_info: %{x_headers: [{"x-backplane-host-token", token_b}]}
             )

    assert token_b_socket.assigns.auth_token.id == token_b_record.id

    assert {:ok, _reply, token_b_socket} =
             subscribe_and_join(token_b_socket, "host_agent:#{host.id}", %{})

    second = captured_memory_event(host, 2)
    second_ref = push_memory_events(token_b_socket, host, "batch-token-b", second)
    assert_reply(second_ref, :ok, %{"results" => [%{"status" => "accepted"}]})

    events = Repo.all(from(event in MemoryEvent, where: event.host_id == ^host.id))
    assert length(events) == 2
    assert Enum.all?(events, &(&1.client_id == "caller-controlled-client"))

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

    test "mcp_tool_call memory::remember stamps channel host", %{host: host, socket: socket} do
      ToolRegistry.deregister_native("memory::remember")
      :ok = ToolRegistry.register_managed("memory", Backplane.Memory.Tools.tools())

      ref =
        push(socket, "mcp_tool_call", %{
          "name" => "memory::remember",
          "arguments" => %{"content" => "channel host stamp", "host" => "spoofed-host"}
        })

      assert_reply(ref, :ok, %{"ok" => true})

      assert [record] =
               Repo.all(
                 from(r in Backplane.Memory.Record, where: r.content == "channel host stamp")
               )

      assert record.host_id == host.id
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

      assert_received {:host_event_ingest, auth_context, ^payload}

      assert %{host_id: host_id, auth_token_id: auth_token_id, scopes: scopes} = auth_context
      assert host_id == host.id
      assert auth_token_id == auth_token.id
      assert "host_agent.capture" in scopes
      refute Map.has_key?(auth_context, :partition)
    end

    test "memory_events fails closed when the durable host registration disappears", %{
      host: host,
      socket: socket
    } do
      assert {:ok, _deleted_host} = Repo.delete(host)

      ref =
        push(socket, "memory_events", %{
          "protocol" => "host_events.v1",
          "batch_id" => "batch-missing-host",
          "host_id" => host.id,
          "events" => []
        })

      assert_reply(ref, :error, %{"code" => "unauthorized", "retryable" => false})
      refute_received {:host_event_ingest, _, _}
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
