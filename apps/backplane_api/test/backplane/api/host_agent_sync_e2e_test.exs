defmodule Backplane.Api.HostAgentSyncE2ETest do
  use Backplane.Api.ChannelCase, async: false

  alias Backplane.Api.Fixtures
  alias Backplane.Skills.{Assignments, DesiredState, Hosts}

  test "v1 pushes issued receipts and acknowledges their exact application durably" do
    {:ok, host, _, token} = Hosts.create_agent_with_token(%{"name" => "compat-channel"})

    {:ok, socket} =
      connect(Backplane.Api.HostAgentSocket, %{"host_id" => host.id},
        connect_info: %{x_headers: [{"x-backplane-host-token", token}]}
      )

    offer = %{
      "memory" => %{"protocol" => "host_memory.v1", "scopes" => [%{"scope" => host.memory_scope}]}
    }

    assert {:ok, %{"selected" => "host_memory.v1"}, socket} =
             subscribe_and_join(socket, "host_agent:#{host.id}", offer)

    send(socket.channel_pid, {:memory_available, %{"current_revision" => 1}})
    refute_push("memory_available", _)
    assert_push("memory_facts", %{"receipt_key" => key, "payload_hash" => hash, "facts" => []})
    receipt = Backplane.Repo.one!(Backplane.Memory.EdgeSync.CompatReceipt)
    assert receipt.receipt_key == key
    assert receipt.payload_hash == hash
    assert is_nil(receipt.acknowledged_at)

    ack = %{
      "receipt_key" => key,
      "payload_hash" => hash,
      "scope" => host.memory_scope,
      "status" => "applied"
    }

    ref = push(socket, "memory_facts_ack", Map.put(ack, "status", "failed"))
    assert_reply(ref, :error, %{"code" => "invalid_ack"})
    assert is_nil(Backplane.Repo.one!(Backplane.Memory.EdgeSync.CompatReceipt).acknowledged_at)
    ref = push(socket, "memory_facts_ack", ack)
    assert_reply(ref, :ok, %{"status" => "acknowledged"})
    ref = push(socket, "memory_facts_ack", ack)
    assert_reply(ref, :ok, %{"status" => "duplicate"})
    ref = push(socket, "memory_facts_ack", Map.put(ack, "payload_hash", "conflict"))
    assert_reply(ref, :error, %{"code" => "batch_conflict"})
    assert Backplane.Repo.one!(Backplane.Memory.EdgeSync.CompatReceipt).acknowledged_at
    assert Backplane.Repo.aggregate(Backplane.Memory.EdgeSync.Cursor, :count) == 0
  end

  test "v2 join preserves the negotiated frame bound without extra legacy metadata" do
    previous = Backplane.Settings.get("memory.host_sync_v2.enabled")
    :ets.insert(:backplane_settings, {"memory.host_sync_v2.enabled", true})
    on_exit(fn -> :ets.insert(:backplane_settings, {"memory.host_sync_v2.enabled", previous}) end)
    {:ok, host, _, token} = Hosts.create_agent_with_token(%{"name" => "bounded-edge-channel"})

    {:ok, socket} =
      connect(Backplane.Api.HostAgentSocket, %{"host_id" => host.id},
        connect_info: %{x_headers: [{"x-backplane-host-token", token}]}
      )

    offer = %{"memory_v2" => %{"offers" => ["host_memory.v2"], "partitions" => []}}
    {:ok, inventory} = Backplane.Memory.EdgeSync.negotiate(host.id, offer)
    bound = byte_size(Jason.encode!(inventory))
    offer = put_in(offer, ["memory_v2", "max_frame_bytes"], bound)
    assert {:ok, reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", offer)
    assert byte_size(Jason.encode!(reply)) <= bound
    refute Map.has_key?(reply, "memory_partition")
    [partition] = reply["partitions"]

    request = %{
      "protocol" => "host_memory.v2",
      "partition" => Map.take(partition, ["memory_space_id", "scope", "namespace"]),
      "applied_revision" => 0
    }

    for request <- [request, Map.put(request, "max_frame_bytes", 524_288)] do
      ref = push(socket, "memory_next", request)
      assert_reply(ref, :error, %{"code" => "payload_too_large"})
    end
  end

  test "v2 channel negotiates, retries and acknowledges durable snapshot without v1 downgrade" do
    previous = Backplane.Settings.get("memory.host_sync_v2.enabled")
    :ets.insert(:backplane_settings, {"memory.host_sync_v2.enabled", true})
    on_exit(fn -> :ets.insert(:backplane_settings, {"memory.host_sync_v2.enabled", previous}) end)

    {:ok, host, _, token} =
      Hosts.create_agent_with_token(%{"name" => "edge-channel", "memory_scope" => "edge"})

    {:ok, socket} =
      connect(Backplane.Api.HostAgentSocket, %{"host_id" => host.id},
        connect_info: %{x_headers: [{"x-backplane-host-token", token}]}
      )

    offer = %{
      "memory" => %{"protocol" => "host_memory.v1", "scopes" => [%{"scope" => "edge"}]},
      "memory_v2" => %{"offers" => ["host_memory.v2"], "partitions" => []}
    }

    assert {:ok, %{"selected" => "host_memory.v2", "partitions" => [partition]}, socket} =
             subscribe_and_join(socket, "host_agent:#{host.id}", offer)

    partition = Map.take(partition, ["memory_space_id", "scope", "namespace"])
    hint = Map.put(partition, "current_revision", 1)
    Phoenix.PubSub.broadcast(Backplane.PubSub, "memory:edge:available", {:memory_available, hint})
    assert_push("memory_available", ^hint)
    send(socket.channel_pid, {:memory_available, Map.put(hint, "content", "must not leak")})

    send(
      socket.channel_pid,
      {:memory_available, Map.put(hint, "memory_space_id", Ecto.UUID.generate())}
    )

    refute_push("memory_available", _)
    request = %{"protocol" => "host_memory.v2", "partition" => partition, "applied_revision" => 0}
    ref = push(socket, "memory_next", request)
    assert_reply(ref, :ok, %{"kind" => "snapshot_chunk"} = batch)
    ref = push(socket, "memory_next", request)
    assert_reply(ref, :ok, ^batch)
    assert Backplane.Repo.one!(Backplane.Memory.EdgeSync.Cursor).applied_revision == 0

    ack =
      Map.merge(request, %{
        "batch_id" => batch["batch_id"],
        "status" => "applied",
        "applied_revision" => batch["to_revision"],
        "snapshot_id" => batch["snapshot_id"],
        "next_chunk_index" => batch["chunk_index"] + 1,
        "chunk_hash" => batch["chunk_hash"],
        "integrity_hash" => batch["integrity_hash"]
      })

    ref = push(socket, "memory_ack", ack)
    assert_reply(ref, :ok, %{"status" => "advanced"})
    ref = push(socket, "memory_ack", ack)
    assert_reply(ref, :ok, %{"status" => "duplicate"})
    ref = push(socket, "memory_next", put_in(request, ["partition", "namespace"], "foreign"))
    assert_reply(ref, :error, %{"retryable" => false})
    ref = push(socket, "memory_facts_ack", %{})
    assert_reply(ref, :error, %{"code" => "unsupported_protocol"})
    ref = push(socket, "memory_next", %{})
    assert_reply(ref, :error, %{"code" => "invalid_request"})
    Application.put_env(:backplane_api, :host_agent_scopes, ["host_agent.capture"])
    on_exit(fn -> Application.delete_env(:backplane_api, :host_agent_scopes) end)
    ref = push(socket, "memory_next", request)
    assert_reply(ref, :error, %{"code" => "unauthorized"})
    Application.delete_env(:backplane_api, :host_agent_scopes)
    :ets.insert(:backplane_settings, {"memory.host_sync_v2.enabled", false})
    ref = push(socket, "memory_next", request)
    assert_reply(ref, :error, %{"code" => "protocol_disabled"})
    refute_push("memory_facts", _)
    refute_push("memory_wipe", _)
  end

  test "host receives desired state for an assigned archive-backed skill" do
    archive_hash = String.duplicate("c", 64)

    {:ok, host} = Hosts.create_agent(%{"name" => "sync-host"})

    skill =
      Fixtures.insert_skill(
        id: "db/sync-review",
        slug: "sync-review",
        name: "Sync Review",
        content_hash: "sha256:#{archive_hash}",
        archive_ref: "sha256/#{archive_hash}.tar.gz",
        source_kind: "archive",
        enabled: true
      )

    assert {:ok, _assignment} =
             Assignments.assign_skill(host, skill, %{"targets" => ["agents", "commands"]})

    assert {:ok, %{skills: [desired_skill]}} = DesiredState.for_host(host)

    assert %{
             slug: "sync-review",
             targets: ["agents", "commands"],
             bundle: %{transport: "websocket", event: "get_skill_bundle"}
           } = desired_skill

    refute Map.has_key?(desired_skill, :download_url)
  end
end
