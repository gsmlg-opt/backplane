defmodule Backplane.Api.HostAgentChannelTest do
  use Backplane.Api.ChannelCase, async: false

  import ExUnit.CaptureLog
  import Backplane.SkillArchiveCase
  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.MemorySpaces
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

    %{host: host, auth_token: auth_token, token: token, socket: socket}
  end

  test "joins only its own host topic", %{host: host, socket: socket} do
    assert {:ok,
            %{
              "memory_partition" => %{
                "memory_space_id" => memory_space_id,
                "scope" => scope,
                "namespace" => "private"
              }
            }, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    assert memory_space_id == MemorySpaces.private_host_space_id(host.id)
    assert scope == host.memory_scope
    assert {:ok, %{host: connected_host}} = AgentManage.get_agent(host.id)
    assert connected_host.id == host.id

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "host_agent:00000000-0000-0000-0000-000000000000", %{})
  end

  test "revoking an assigned token denies the already joined channel", %{
    host: host,
    auth_token: token,
    socket: socket
  } do
    assert {:ok, _, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})
    ref = push(socket, "memory_call", %{"method" => "stats", "arguments" => %{}})
    assert_reply(ref, :ok, %{"ok" => true})
    assert {:ok, _} = Hosts.revoke_auth_token_for_agent(host, token.id)

    for event <-
          ~w(memory_call mcp_tool_call memory_sync memory_import_batch memory_events memory_next memory_ack) do
      ref = push(socket, event, %{"method" => "stats", "arguments" => %{}})
      assert_reply(ref, :error, %{"code" => "unauthorized", "retryable" => false})
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

  test "memory negotiation rejects malformed offers explicitly", %{host: host, socket: socket} do
    for payload <- [
          %{"memory_v2" => 42},
          %{"memory" => %{"protocol" => "host_memory.v1", "scopes" => "bad"}},
          %{"memory" => %{"protocol" => "host_memory.v1", "scopes" => [%{"scope" => 42}]}}
        ] do
      assert {:error, %{"code" => "invalid_request", "retryable" => false}} =
               subscribe_and_join(socket, "host_agent:#{host.id}", payload)
    end
  end

  test "shared extensions return complete effective inventory and refresh rechecks assignment",
       c do
    previous = Backplane.Settings.get("memory.host_sync.enabled")
    :ets.insert(:backplane_settings, {"memory.host_sync.enabled", true})

    on_exit(fn ->
      :ets.insert(:backplane_settings, {"memory.host_sync.enabled", previous})
      Application.delete_env(:backplane_api, :host_agent_scopes)
    end)

    {owner, _, _} = create_agent_with_token!("shared-owner")
    {:ok, target} = MemorySpaces.resolve_host_partition(owner.id, nil, "private")

    {:ok, access} =
      MemorySpaces.grant_host_access(
        %{kind: :system, ref: nil, request_id: Ecto.UUID.generate()},
        c.host.id,
        target,
        [:read, :deliver, :remember],
        expected_version: 0,
        reason: "channel shared fixture"
      )

    Application.put_env(:backplane_api, :host_agent_scopes, ["host_agent.import"])

    offer = %{
      "memory_v2" => %{
        "offers" => ["host_memory.v2"],
        "partitions" => [],
        "extensions" => ["memory_access.v1", "memory_commands.v2"]
      }
    }

    assert {:ok, reply, socket} = subscribe_and_join(c.socket, "host_agent:#{c.host.id}", offer)
    assert reply["extensions"] == ["memory_access.v1", "memory_commands.v2"]
    assert reply["partitions"] == []
    assert length(reply["accesses"]) == 2

    assert Enum.any?(
             reply["accesses"],
             &(&1["access_id"] == access.access_id and &1["capabilities"] == ["remember"])
           )

    ref = push(socket, "memory_access_refresh", %{})
    assert_reply(ref, :ok, %{"accesses" => accesses, "partitions" => []})
    assert length(accesses) == 2
    claim = %{"access_id" => access.access_id, "authority_version" => 1}

    command = %{
      "command_id" => Ecto.UUID.generate(),
      "op" => "remember",
      "access" => claim,
      "partition" => Map.new(target, fn {k, v} -> {to_string(k), v} end),
      "arguments" => %{"content" => "import-only shared wire fixture"}
    }

    ref = push(socket, "memory_sync", %{"protocol" => "memory_commands.v2", "items" => [command]})
    assert_reply(ref, :ok, %{"items" => [%{"status" => "committed"}]})

    ref =
      push(socket, "memory_call", %{"method" => "list", "arguments" => %{}, "access" => claim})

    assert_reply(ref, :ok, %{"ok" => false, "error" => "unauthorized"})
    hint = target |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("current_revision", 0)
    send(socket.channel_pid, {:memory_available, hint})
    refute_push("memory_available", _)
    Application.delete_env(:backplane_api, :host_agent_scopes)
    send(socket.channel_pid, {:memory_available, hint})
    assert_push("memory_available", ^hint)

    access_hint = %{
      "access_id" => access.access_id,
      "authority_version" => 2,
      "status" => "revoked"
    }

    send(socket.channel_pid, {:memory_access_changed, access_hint})
    assert_push("memory_access_changed", ^access_hint)
    # Remove only the authoritative assignment: the manager's cached entry remains.
    Repo.delete_all(
      from a in Backplane.Skills.HostAgentToken, where: a.auth_token_id == ^c.auth_token.id
    )

    ref = push(socket, "memory_access_refresh", %{})
    assert_reply(ref, :error, %{"code" => "unauthorized", "retryable" => false})
  end

  test "joined shared channel forwards one access notification per PubSub broadcast", c do
    previous = Backplane.Settings.get("memory.host_sync.enabled")
    :ets.insert(:backplane_settings, {"memory.host_sync.enabled", true})
    on_exit(fn -> :ets.insert(:backplane_settings, {"memory.host_sync.enabled", previous}) end)

    offer = %{
      "memory_v2" => %{
        "offers" => ["host_memory.v2"],
        "partitions" => [],
        "extensions" => ["memory_access.v1", "memory_commands.v2"]
      }
    }

    topic = "host_agent:#{c.host.id}"
    assert {:ok, _, socket} = subscribe_and_join(c.socket, topic, offer)
    hint = %{"access_id" => Ecto.UUID.generate(), "authority_version" => 2, "status" => "revoked"}
    assert :ok = Phoenix.PubSub.broadcast(Backplane.PubSub, topic, {:memory_access_changed, hint})
    assert_push("memory_access_changed", ^hint)
    # The channel has consumed its broadcast messages before this barrier returns.
    _ = :sys.get_state(socket.channel_pid)
    refute_push("memory_access_changed", ^hint)
  end

  test "negotiated shared reads and commands use explicit authority without private fallback",
       c do
    previous = Backplane.Settings.get("memory.host_sync.enabled")
    :ets.insert(:backplane_settings, {"memory.host_sync.enabled", true})
    on_exit(fn -> :ets.insert(:backplane_settings, {"memory.host_sync.enabled", previous}) end)
    {owner, _, _} = create_agent_with_token!("shared-channel-owner")
    {:ok, target} = MemorySpaces.resolve_host_partition(owner.id, nil, "private")

    {:ok, access} =
      MemorySpaces.grant_host_access(
        %{kind: :system, ref: nil, request_id: Ecto.UUID.generate()},
        c.host.id,
        target,
        [:read, :remember],
        expected_version: 0,
        reason: "channel shared commands"
      )

    offer = %{
      "memory_v2" => %{
        "offers" => ["host_memory.v2"],
        "partitions" => [],
        "extensions" => ["memory_access.v1", "memory_commands.v2"]
      }
    }

    assert {:ok, _, socket} = subscribe_and_join(c.socket, "host_agent:#{c.host.id}", offer)
    claim = %{"access_id" => access.access_id, "authority_version" => access.authority_version}
    partition = Map.new(target, fn {k, v} -> {to_string(k), v} end)

    command = %{
      "command_id" => Ecto.UUID.generate(),
      "op" => "remember",
      "access" => claim,
      "partition" => partition,
      "arguments" => %{"content" => "shared channel synthetic fixture"}
    }

    ref = push(socket, "memory_sync", %{"protocol" => "memory_commands.v2", "items" => [command]})

    assert_reply(ref, :ok, %{
      "protocol" => "memory_commands.v2",
      "items" => [%{"status" => "committed", "canonical_id" => id}]
    })

    assert is_binary(id)
    ref = push(socket, "memory_sync", %{"protocol" => "memory_commands.v2", "items" => [command]})
    assert_reply(ref, :ok, %{"items" => [%{"status" => "duplicate", "canonical_id" => ^id}]})
    conflict = put_in(command, ["arguments", "content"], "changed immutable payload")

    ref =
      push(socket, "memory_sync", %{"protocol" => "memory_commands.v2", "items" => [conflict]})

    assert_reply(ref, :ok, %{
      "items" => [%{"status" => "rejected", "code" => "idempotency_conflict"}]
    })

    rejected = %{
      command
      | "command_id" => Ecto.UUID.generate(),
        "op" => "forget",
        "arguments" => %{"id" => id}
    }

    ref =
      push(socket, "memory_sync", %{"protocol" => "memory_commands.v2", "items" => [rejected]})

    assert_reply(ref, :ok, %{"items" => [%{"status" => "rejected", "code" => "unauthorized"}]})

    payload = %{"method" => "list", "arguments" => %{}, "access" => claim}
    ref = push(socket, "memory_call", payload)
    assert_reply(ref, :ok, %{"ok" => true, "result" => direct_result})

    assert %{
             "access" => ^claim,
             "partition" => ^partition,
             "result" => %{"results" => [%{"id" => ^id}]}
           } = direct_result

    stored = Repo.get!(Backplane.Memory.Memories.Memory, id)
    assert Map.take(stored, [:memory_space_id, :scope, :namespace]) == target
    assert stored.host_id == c.host.id

    # Shared MCP installs a trace context before MemoryProxy creates this envelope.
    traced =
      Map.put(payload, "traceparent", "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01")

    ref = push(socket, "memory_call", traced)
    assert_reply(ref, :ok, %{"ok" => true, "result" => ^direct_result})

    for envelope <- [payload, traced] do
      for {key, value} <- [
            {"unknown", true},
            {"host_id", owner.id},
            {"partition", partition},
            {"auth", %{"host_id" => owner.id}},
            {"authority_version", access.authority_version}
          ] do
        ref = push(socket, "memory_call", Map.put(envelope, key, value))
        assert_reply(ref, :ok, %{"ok" => false, "error" => "invalid_request"})
      end

      for arguments <- [%{"host_id" => owner.id}, %{"memory_access_id" => access.access_id}] do
        ref = push(socket, "memory_call", %{envelope | "arguments" => arguments})
        assert_reply(ref, :ok, %{"ok" => false, "error" => "invalid_request"})
      end

      ref =
        push(socket, "memory_call", %{
          envelope
          | "access" => Map.put(claim, "host_id", owner.id)
        })

      assert_reply(ref, :ok, %{"ok" => false, "error" => "invalid_request"})
    end

    ref =
      push(socket, "memory_call", %{
        "method" => "remember",
        "arguments" => %{"content" => "denied"},
        "access" => claim
      })

    assert_reply(ref, :ok, %{"ok" => false})

    ref =
      push(socket, "memory_call", %{
        "method" => "list",
        "arguments" => %{},
        "access" => %{claim | "access_id" => Ecto.UUID.generate()}
      })

    assert_reply(ref, :ok, %{"ok" => false, "error" => "unauthorized"})

    ref =
      push(socket, "memory_next", %{
        "protocol" => "host_memory.v2",
        "partition" => partition,
        "access" => claim,
        "applied_revision" => 0
      })

    assert_reply(ref, :error, denial)
    assert denial == %{"code" => "unauthorized"}
    ref = push(socket, "memory_call", %{"method" => "stats", "arguments" => %{}})
    assert_reply(ref, :ok, %{"ok" => true})

    ref =
      push(socket, "memory_sync", %{
        "protocol" => "memory_commands.v2",
        "items" => List.duplicate(command, 51)
      })

    assert_reply(ref, :error, %{"code" => "payload_too_large"})

    assert {:ok, _} =
             MemorySpaces.change_host_access(
               %{kind: :system, ref: nil, request_id: Ecto.UUID.generate()},
               access.access_id,
               1,
               %{capabilities: [:read, :remember, :forget]},
               "allow future forget"
             )

    ref =
      push(socket, "memory_sync", %{"protocol" => "memory_commands.v2", "items" => [rejected]})

    assert_reply(ref, :ok, %{"items" => [%{"status" => "rejected", "code" => "unauthorized"}]})
    assert is_nil(Repo.get!(Backplane.Memory.Memories.Memory, id).deleted_at)
  end

  test "extended peer with revoked private default retains shared access without retargeting",
       c do
    previous = Backplane.Settings.get("memory.host_sync.enabled")
    :ets.insert(:backplane_settings, {"memory.host_sync.enabled", true})
    on_exit(fn -> :ets.insert(:backplane_settings, {"memory.host_sync.enabled", previous}) end)
    {owner, _, _} = create_agent_with_token!("no-default-shared-owner")
    {:ok, target} = MemorySpaces.resolve_host_partition(owner.id, nil, "private")
    operator = %{kind: :system, ref: nil, request_id: Ecto.UUID.generate()}

    {:ok, access} =
      MemorySpaces.grant_host_access(operator, c.host.id, target, [:read],
        expected_version: 0,
        reason: "independent shared access"
      )

    {:ok, private} = MemorySpaces.resolve_host_access(c.host.id, :default, :read)

    {:ok, _} =
      MemorySpaces.revoke_host_access(operator, private.access_id, 1, "private withdrawn")

    offer = %{
      "memory_v2" => %{
        "offers" => ["host_memory.v2"],
        "partitions" => [],
        "extensions" => ["memory_access.v1"]
      }
    }

    assert {:ok, %{"default_access_id" => nil, "accesses" => [descriptor]}, socket} =
             subscribe_and_join(c.socket, "host_agent:#{c.host.id}", offer)

    assert descriptor["access_id"] == access.access_id
    ref = push(socket, "memory_sync", %{"protocol" => "memory_commands.v2", "items" => []})
    assert_reply(ref, :error, %{"code" => "unsupported_protocol"})
    ref = push(socket, "memory_call", %{"method" => "stats", "arguments" => %{}})
    assert_reply(ref, :ok, %{"ok" => false, "error" => "unauthorized"})

    ref =
      push(socket, "memory_call", %{
        "method" => "stats",
        "arguments" => %{},
        "access" => %{"access_id" => access.access_id, "authority_version" => 1}
      })

    assert_reply(ref, :ok, %{"ok" => true})
  end

  test "legacy sync cannot bypass default capability withdrawal", c do
    assert {:ok, _, socket} = subscribe_and_join(c.socket, "host_agent:#{c.host.id}", %{})
    {:ok, access} = MemorySpaces.resolve_host_access(c.host.id, :default, :remember)

    assert {:ok, _} =
             MemorySpaces.change_host_access(
               %{kind: :system, ref: nil, request_id: Ecto.UUID.generate()},
               access.access_id,
               1,
               %{capabilities: [:read, :deliver]},
               "withdraw private write"
             )

    ref =
      push(socket, "memory_sync", %{
        "protocol" => "host_memory.v1",
        "items" => [
          %{
            "op" => "remember",
            "id" => "withdrawn-private",
            "content" => "must not persist",
            "agent_id" => "capability-test",
            "scope" => c.host.memory_scope
          }
        ]
      })

    assert_reply(ref, :error, %{"code" => "unsupported_protocol"})

    refute Repo.exists?(
             from m in Backplane.Memory.Memories.Memory, where: m.content == "must not persist"
           )
  end

  test "commands negotiate independently of disabled mirror delivery", %{
    host: host,
    socket: socket
  } do
    previous = Backplane.Settings.get("memory.host_sync.enabled")
    :ets.insert(:backplane_settings, {"memory.host_sync.enabled", false})
    on_exit(fn -> :ets.insert(:backplane_settings, {"memory.host_sync.enabled", previous}) end)

    offer = %{
      "memory_v2" => %{
        "offers" => ["host_memory.v2"],
        "partitions" => [],
        "extensions" => ["memory_access.v1", "memory_commands.v2"]
      }
    }

    assert {:ok, reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", offer)
    assert reply["selected"] == "host_memory.v2"
    assert reply["partitions"] == []
    access_id = reply["default_access_id"]
    assert is_binary(access_id)
    descriptor = Enum.find(reply["accesses"], &(&1["access_id"] == access_id))
    assert Enum.sort(descriptor["capabilities"]) == ~w(forget read remember)
    assert descriptor["offline_read_lease_seconds"] == 0

    command = %{
      "command_id" => Ecto.UUID.generate(),
      "op" => "remember",
      "access" => Map.take(descriptor, ~w(access_id authority_version)),
      "partition" => descriptor["partition"],
      "arguments" => %{"content" => "commands without mirror", "type" => "working"}
    }

    ref = push(socket, "memory_sync", %{"protocol" => "memory_commands.v2", "items" => [command]})

    assert_reply(ref, :ok, %{
      "items" => [
        %{
          "status" => "committed",
          "canonical_id" => id,
          "revision" => nil,
          "mirror_status" => "not_eligible"
        }
      ]
    })

    assert Repo.get!(Backplane.Memory.Memories.Memory, id).content == "commands without mirror"

    claim = command["access"]
    partition = descriptor["partition"]

    ref =
      push(socket, "memory_call", %{"access" => claim, "method" => "stats", "arguments" => %{}})

    assert_reply(ref, :ok, %{
      "ok" => true,
      "result" => %{"access" => ^claim, "partition" => ^partition, "result" => statistics}
    })

    assert is_map(statistics)

    for event <- ~w(memory_next memory_ack) do
      ref =
        push(socket, event, %{
          "protocol" => "host_memory.v2",
          "access" => command["access"],
          "partition" => descriptor["partition"]
        })

      assert_reply(ref, :error, %{"code" => "protocol_disabled"})
    end
  end

  test "retired top-level offers stay rejected when mirror delivery is disabled", c do
    previous = Backplane.Settings.get("memory.host_sync.enabled")
    :ets.insert(:backplane_settings, {"memory.host_sync.enabled", false})
    on_exit(fn -> :ets.insert(:backplane_settings, {"memory.host_sync.enabled", previous}) end)

    offer = %{"memory" => %{"protocol" => "host_memory.v1", "scopes" => []}}

    for payload <- [offer, Map.put(offer, "selected", "host_memory.v2")] do
      assert {:error, %{"code" => "invalid_request", "retryable" => false}} =
               subscribe_and_join(c.socket, "host_agent:#{c.host.id}", payload)
    end
  end

  test "OpenClaw capture negotiation does not advertise unavailable capture permission", c do
    previous = Backplane.Settings.get("memory.host_sync.enabled")
    scopes = Application.get_env(:backplane_api, :host_agent_scopes)
    :ets.insert(:backplane_settings, {"memory.host_sync.enabled", true})

    Application.put_env(
      :backplane_api,
      :host_agent_scopes,
      ~w(host_agent.recall host_agent.import)
    )

    on_exit(fn ->
      :ets.insert(:backplane_settings, {"memory.host_sync.enabled", previous})

      if scopes,
        do: Application.put_env(:backplane_api, :host_agent_scopes, scopes),
        else: Application.delete_env(:backplane_api, :host_agent_scopes)
    end)

    extensions =
      ~w(memory_access.v1 memory_commands.v2 memory_sources.v1 openclaw_source.v1 openclaw_capture.v1)

    offer = %{
      "memory_v2" => %{
        "offers" => ["host_memory.v2"],
        "partitions" => [],
        "extensions" => extensions
      }
    }

    assert {:ok, reply, _socket} = subscribe_and_join(c.socket, "host_agent:#{c.host.id}", offer)
    assert "openclaw_source.v1" in reply["extensions"]
    refute "openclaw_capture.v1" in reply["extensions"]
  end

  test "OpenClaw capture requires separately negotiated support and frozen default authority",
       c do
    previous = Backplane.Settings.get("memory.host_sync.enabled")
    :ets.insert(:backplane_settings, {"memory.host_sync.enabled", true})
    on_exit(fn -> :ets.insert(:backplane_settings, {"memory.host_sync.enabled", previous}) end)

    extensions =
      ~w(memory_access.v1 memory_commands.v2 memory_sources.v1 openclaw_source.v1 openclaw_capture.v1)

    offer = %{
      "memory_v2" => %{
        "offers" => ["host_memory.v2"],
        "partitions" => [],
        "extensions" => extensions
      }
    }

    assert {:ok, reply, socket} = subscribe_and_join(c.socket, "host_agent:#{c.host.id}", offer)
    assert reply["extensions"] == extensions
    access = Enum.find(reply["accesses"], &(&1["access_id"] == reply["default_access_id"]))

    fingerprint =
      Backplane.MemorySourceContract.digest(
        Map.take(access, ~w(access_id authority_version partition))
      )

    event = openclaw_event(c.host, fingerprint)
    ref = push_memory_events(socket, c.host, "openclaw-capture", event)
    assert_reply(ref, :ok, %{"results" => [%{"status" => "accepted"}]})
    stored = Repo.get!(MemoryEvent, event["event_id"])
    assert stored.content == "OpenClaw full source evidence"
    assert stored.role == "user"
    assert stored.agent_id == "rikka"
    assert get_in(stored.payload, ["source", "run_id"]) == "actual-run"
    assert stored.source_sequence == 1
    assert get_in(stored.payload, ["source", "source_sequence"]) == 20

    stale = openclaw_event(c.host, String.duplicate("b", 64))
    ref = push_memory_events(socket, c.host, "openclaw-stale", stale)
    assert_reply(ref, :error, %{"reason" => "authority_changed"})
    refute Repo.get(MemoryEvent, stale["event_id"])

    operator = %{kind: :system, ref: nil, request_id: Ecto.UUID.generate()}

    assert {:ok, _} =
             MemorySpaces.revoke_host_access(
               operator,
               access["access_id"],
               access["authority_version"],
               "OpenClaw revoked fixture"
             )

    late = openclaw_event(c.host, fingerprint)
    ref = push_memory_events(socket, c.host, "openclaw-revoked", late)
    assert_reply(ref, :error, %{"reason" => "unauthorized"})
    refute Repo.get(MemoryEvent, late["event_id"])
  end

  test "real channel capture keeps the host partition across assigned token rotation", %{
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

    test "get forwards only the exact canonical selector through the authenticated service", %{
      socket: socket,
      host: host
    } do
      id = Ecto.UUID.generate()
      args = %{"id" => id, "project" => "backplane"}
      ref = push(socket, "memory_call", %{"method" => "get", "arguments" => args})
      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"echo" => "get"}})
      assert_received {:memory_service, {:get, ^args, auth}}
      assert auth.principal_metadata["memory_partition_id"] == "host:" <> host.id
      assert "memory.read" in auth.scopes

      ref =
        push(socket, "memory_call", %{
          "method" => "get",
          "arguments" => Map.put(args, "scope", host.memory_scope)
        })

      assert_reply(ref, :ok, %{"ok" => false, "error" => "invalid_arguments"})
      refute_received {:memory_service, _}
    end

    test "mutations require the immutable command protocol", %{socket: socket} do
      for {method, arguments} <- [
            {"remember", %{"content" => "hi", "agent_id" => "agt_1"}},
            {"forget", %{"id" => Ecto.UUID.generate()}}
          ] do
        ref = push(socket, "memory_call", %{"method" => method, "arguments" => arguments})
        assert_reply(ref, :ok, %{"ok" => false, "error" => "unsupported_protocol"})
        refute_received {:memory_service, _}
      end
    end

    test "advertised scope selects only the authenticated read partition", %{
      host: host,
      socket: socket
    } do
      for method <- ["recall", "list"] do
        ref =
          push(socket, "memory_call", %{
            "method" => method,
            "arguments" => %{"scope" => host.memory_scope, "query" => "fixture"}
          })

        assert_reply(ref, :ok, %{"ok" => true})
        assert_receive {:memory_service, {_operation, args, auth}}
        refute Map.has_key?(args, "scope")
        assert auth.principal_metadata["scope"] == host.memory_scope

        for claim <- [
              %{"scope" => "foreign"},
              %{"scope" => nil},
              %{"scope" => host.memory_scope, "client_id" => host.id},
              %{
                "scope" => host.memory_scope,
                "memory_space_id" => MemorySpaces.private_host_space_id(host.id)
              }
            ] do
          rejected = push(socket, "memory_call", %{"method" => method, "arguments" => claim})
          assert_reply(rejected, :ok, %{"ok" => false, "error" => "invalid_arguments"})
          refute_received {:memory_service, _}
        end
      end
    end

    test "remember rejects caller-supplied canonical ownership", %{socket: socket} do
      ref =
        push(socket, "memory_call", %{
          "method" => "remember",
          "arguments" => %{
            "content" => "hi",
            "agent_id" => "agt_1",
            "memory_space_id" => Ecto.UUID.generate()
          }
        })

      assert_reply(ref, :ok, %{"ok" => false, "error" => "invalid_arguments"})
      refute_received {:memory_service, _message}
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

      assert auth.principal_metadata == %{
               "memory_partition_id" => "host:#{host.id}",
               "memory_space_id" => MemorySpaces.private_host_space_id(host.id),
               "scope" => host.memory_scope,
               "namespace" => "private"
             }
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
    test "list dispatches with limit and authenticated partition injected",
         %{host: host, socket: socket} do
      ref =
        push(socket, "memory_call", %{
          "method" => "list",
          "arguments" => %{"limit" => 10, "agent_id" => "agt_1"}
        })

      assert_reply(ref, :ok, %{"ok" => true, "result" => %{"echo" => "list"}})
      assert_received {:memory_service, {:list, args, auth}}
      refute Map.has_key?(args, "host_id")
      assert auth.client_id == host.id
      refute Map.has_key?(args, "scope")
      assert args["limit"] == 10
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

    test "memory_events refreshes the durable host partition after a scope change", %{
      host: host,
      socket: socket
    } do
      old_scope = host.memory_scope
      new_scope = "team_shared"

      assert {:ok, updated_host} = Hosts.update_agent(host, %{"memory_scope" => new_scope})
      assert updated_host.memory_scope == new_scope

      payload = %{
        "protocol" => "host_events.v1",
        "batch_id" => "batch-refreshed-scope",
        "host_id" => host.id,
        "events" => [%{"event_id" => "event-old-payload-scope", "scope" => old_scope}]
      }

      reply = %{"batch_id" => "batch-refreshed-scope", "results" => []}
      :persistent_term.put({StubHostEventIngest, :reply}, {:ok, reply})

      ref = push(socket, "memory_events", payload)
      assert_reply(ref, :ok, ^reply)

      assert_received {:host_event_ingest,
                       %{
                         host_id: host_id,
                         partition: %{
                           host_id: partition_host_id,
                           partition_id: partition_id,
                           scope: ^new_scope,
                           namespace: "private"
                         }
                       }, ^payload}

      assert host_id == host.id
      assert partition_host_id == host.id
      assert partition_id == "host:#{host.id}"
      refute new_scope == old_scope
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

  test "retired host Memory offers never start facts or wipe reconciliation", %{
    host: host,
    socket: socket
  } do
    assert {:error, %{"code" => "invalid_request"}} =
             subscribe_and_join(socket, "host_agent:#{host.id}", %{
               "memory" => %{"protocol" => "host_memory.v1", "scopes" => []}
             })

    refute_push("memory_facts", _)
    refute_push("memory_wipe", _)
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

  defp openclaw_event(host, fingerprint) do
    content = "OpenClaw full source evidence"
    event = captured_memory_event(host, 1)

    source = %{
      "protocol" => "openclaw_capture.v1",
      "event_id" => event["event_id"],
      "installation_id" => Ecto.UUID.generate(),
      "profile_id" => "primary",
      "source_sequence" => 20,
      "session_id" => event["session_id"],
      "run_id" => "actual-run",
      "agent_id" => "rikka",
      "occurrence_id" => "actual-run:0",
      "binding_fingerprint" => fingerprint,
      "occurred_at" => event["occurred_at"],
      "captured_at" => event["captured_at"],
      "role" => "user",
      "content" => content,
      "completeness" => %{
        "truncated" => false,
        "coverage" => "full",
        "original_length" => String.length(content),
        "original_sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower)
      }
    }

    payload = %{"hook" => "message", "source" => source}

    Map.merge(event, %{
      "agent_id" => "rikka",
      "client_id" => "openclaw",
      "integration" => "openclaw",
      "event_type" => "conversation.user_message",
      "payload" => payload,
      "payload_hash" => EventValidator.payload_hash(payload),
      "idempotency_key" => "openclaw:" <> event["event_id"]
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
