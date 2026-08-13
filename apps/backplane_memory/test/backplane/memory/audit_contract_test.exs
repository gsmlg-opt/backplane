defmodule Backplane.Memory.AuditContractTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query

  alias Backplane.Memory.{Audit, Memories, Service}
  alias Backplane.Memory.Coordination.{Action, Lease}
  alias Backplane.Skills.Hosts

  setup do
    previous = :ets.lookup(:backplane_settings, "memory.tools")
    :ets.insert(:backplane_settings, {"memory.tools", "all"})

    on_exit(fn ->
      :ets.delete(:backplane_settings, "memory.tools")
      if previous != [], do: :ets.insert(:backplane_settings, previous)
    end)

    :ok
  end

  test "enumerates the M14 lifecycle, repair, and coordination audit contract" do
    assert Audit.contract_operations() == [
             "activity.repair",
             "coordination.action.create",
             "coordination.action.status",
             "coordination.heal",
             "coordination.lease.acquire",
             "coordination.lease.cleanup",
             "coordination.signal.read",
             "coordination.signal.send",
             "crystal.crystallize",
             "forget",
             "governance_delete",
             "hard_delete",
             "lesson.candidate",
             "lesson.save",
             "lesson.strengthen",
             "lesson.transition",
             "memory.activity.purge",
             "memory.activity.summary",
             "memory.apply",
             "memory.archive",
             "memory.config.set",
             "memory.export",
             "memory.gate.set",
             "memory.import.completed",
             "memory.import.failed",
             "memory.import.started",
             "memory.recall_trace.purge",
             "memory.repair",
             "memory.replay.import_dispatched",
             "memory.replay.load",
             "memory.replay.sessions",
             "memory_relation.candidate",
             "memory_relation.policy",
             "memory_relation.resolve",
             "projection.rebuild",
             "projection.repair",
             "remember",
             "session.abandoned",
             "session.lifecycle_transition",
             "session.summary_enqueued"
           ]
  end

  test "remember audit carries exact partition and request correlation without memory content" do
    correlation_id = Ecto.UUID.generate()

    captured =
      Backplane.Memory.IngestFixtures.valid_event(%{
        "host_id" => "audit-host",
        "agent_id" => "audit-agent",
        "client_id" => "audit-client",
        "scope" => "audit-scope",
        "project" => "audit-project",
        "session_id" => "audit-session",
        "trace" => %{"correlation_id" => correlation_id},
        "payload" => %{"message" => "source text must not enter audit"}
      })

    auth = %{
      host_id: "audit-host",
      auth_token_id: Ecto.UUID.generate(),
      scopes: ["host_agent.capture"]
    }

    assert {:ok, %{"results" => [%{"server_event_id" => event_id}]}} =
             Backplane.Memory.Ingest.ingest_batch(auth, %{
               "batch_id" => Ecto.UUID.generate(),
               "host_id" => "audit-host",
               "events" => [captured]
             })

    assert {:ok, memory} =
             Memories.remember("derived text must not enter audit",
               agent_id: "audit-agent",
               host_id: "audit-host",
               client_id: "audit-client",
               scope: "audit-scope",
               namespace: "private",
               session_id: "audit-session",
               idempotency_scope: "audit-test",
               idempotency_key: "correlated-remember",
               evidence: [
                 %{
                   source_event_id: event_id,
                   host_id: "audit-host",
                   session_id: "audit-session",
                   agent_id: "audit-agent",
                   evidence_kind: "derives",
                   support_score: 1.0
                 }
               ]
             )

    assert [%{target_ids: [memory_id], actor: "audit-agent", metadata: metadata}] =
             Audit.list_for_target(memory.id)
             |> Enum.filter(&(&1.operation == "remember"))

    assert memory_id == memory.id
    assert metadata["host_id"] == "audit-host"
    assert metadata["client_id"] == "audit-client"
    assert metadata["scope"] == "audit-scope"
    assert metadata["namespace"] == "private"
    assert metadata["result"] == "created"
    assert metadata["correlation_id"] == correlation_id
    assert metadata["correlation_ids"] == [correlation_id]
    assert {:ok, _request_id} = Ecto.UUID.cast(metadata["request_id"])
    refute Map.has_key?(metadata, "content")
    refute Map.has_key?(metadata, "raw")

    assert {:ok, ^memory} =
             Memories.remember("derived text must not enter audit",
               agent_id: "audit-agent",
               host_id: "audit-host",
               client_id: "audit-client",
               scope: "audit-scope",
               namespace: "private",
               session_id: "audit-session",
               idempotency_scope: "audit-test",
               idempotency_key: "correlated-remember",
               evidence: [
                 %{
                   source_event_id: event_id,
                   host_id: "audit-host",
                   session_id: "audit-session",
                   agent_id: "audit-agent",
                   evidence_kind: "derives",
                   support_score: 1.0
                 }
               ]
             )

    assert [_one] =
             Audit.list_for_target(memory.id)
             |> Enum.filter(&(&1.operation == "remember"))
  end

  test "partition listing applies ownership before pagination" do
    owner = %{
      host_id: "owner-host",
      client_id: "owner-client",
      scope: "owner-scope",
      namespace: "private"
    }

    foreign = %{
      host_id: "foreign-host",
      client_id: "foreign-client",
      scope: "foreign-scope",
      namespace: "private"
    }

    Audit.log("remember", "owner", ["owner-old"], Map.merge(owner, %{request_id: "owner-old"}))

    for ordinal <- 1..3 do
      Audit.log(
        "remember",
        "foreign",
        ["foreign-#{ordinal}"],
        Map.merge(foreign, %{request_id: "foreign-#{ordinal}"})
      )
    end

    Audit.log("remember", "owner", ["owner-new"], Map.merge(owner, %{request_id: "owner-new"}))

    assert [%{target_ids: ["owner-new"]}] = Audit.list(owner, operation: "remember", limit: 1)

    assert [%{target_ids: ["owner-old"]}] =
             Audit.list(owner, operation: "remember", limit: 1, offset: 1)
  end

  test "audit logging strips raw and content fields recursively" do
    target_id = Ecto.UUID.generate()

    :ok =
      Audit.log("privacy.contract", "system", [target_id], %{
        "content" => "secret",
        "raw" => "secret",
        "nested" => %{"content" => "secret", "safe" => "retained"}
      })

    assert [%{metadata: %{"nested" => %{"safe" => "retained"}}}] =
             Audit.list_for_target(target_id)
  end

  test "heal audits the partition-scoped repair even when only coordination state changes" do
    scope = "audit-heal-scope"

    {:ok, host, _token, _plaintext} =
      Hosts.create_agent_with_token(%{
        "name" => "audit-heal-#{System.unique_integer([:positive])}",
        "memory_scope" => scope
      })

    auth = %{
      kind: :client_token,
      client_id: Ecto.UUID.generate(),
      scopes: ["memory::*"],
      principal_metadata: %{"memory_partition_id" => "host:#{host.id}"}
    }

    partition = %{
      host_id: host.id,
      client_id: "host:#{host.id}",
      scope: scope,
      namespace: "private"
    }

    {:ok, action} = Action.create(%{"title" => "expired heal lease"}, [], partition)

    {:ok, lease_id} = Lease.acquire(action.id, "agent", 300, partition)

    repo().update_all(
      from(l in Lease, where: l.id == ^lease_id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:ok, %{status: "healed", expired_leases_cleared: 1}} =
             Service.handle_heal(%{}, auth)

    assert [%{operation: "coordination.heal", metadata: metadata}] =
             Audit.list(operation: "coordination.heal")

    assert metadata["host_id"] == host.id
    assert metadata["expired_leases_cleared"] == 1
  end
end
