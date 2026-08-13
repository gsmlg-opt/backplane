defmodule Backplane.Memory.Operations.RepairTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Memories}
  alias Backplane.Memory.Operations.{Health, Repair}
  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Projections.{ActivityDaily, Rebuild}

  @partition %{
    host_id: "repair-host",
    client_id: "repair-client",
    scope: "repair-scope",
    namespace: "private"
  }

  test "re-embed repair is exact-partition, idempotent, and audited without content" do
    assert {:ok, memory} =
             Memories.remember("repair content must stay out of operations telemetry and audit",
               agent_id: "repair-agent",
               host_id: @partition.host_id,
               client_id: @partition.client_id,
               scope: @partition.scope,
               namespace: @partition.namespace,
               idempotency_scope: "repair-test",
               idempotency_key: "memory-1"
             )

    args = %{
      "kind" => "reembed",
      "target_id" => memory.id,
      "idempotency_key" => "repair-reembed-1"
    }

    assert {:ok, %{status: "dispatched", kind: "reembed", affected: 1}} =
             Repair.run(args, @partition, "repair-operator")

    assert {:ok, %{status: "already_applied", kind: "reembed", affected: 1}} =
             Repair.run(args, @partition, "repair-operator")

    assert [%{actor: "repair-operator", metadata: metadata}] =
             Audit.list(operation: "memory.repair")

    assert metadata["kind"] == "reembed"
    assert metadata["result"] == "dispatched"
    assert metadata["host_id"] == @partition.host_id
    refute inspect(metadata) =~ "repair content"
  end

  test "repair rejects a foreign target before dispatch or audit" do
    foreign = Map.put(@partition, :host_id, "foreign-host")

    assert {:ok, memory} =
             Memories.remember("foreign",
               agent_id: "repair-agent",
               host_id: foreign.host_id,
               client_id: foreign.client_id,
               scope: foreign.scope,
               namespace: foreign.namespace,
               idempotency_scope: "repair-test",
               idempotency_key: "foreign-memory"
             )

    assert {:error, :not_found} =
             Repair.run(
               %{
                 "kind" => "reembed",
                 "target_id" => memory.id,
                 "idempotency_key" => "foreign-repair"
               },
               @partition,
               "repair-operator"
             )

    assert [%{metadata: %{"result" => "failed", "error_class" => "not_found"}}] =
             Audit.list(operation: "memory.repair")
  end

  test "repair requires an explicit stable idempotency key" do
    assert {:error, :invalid_arguments} =
             Repair.run(%{"kind" => "coordination"}, @partition, "repair-operator")
  end

  test "one caller key cannot be replayed for a different repair request" do
    first = %{"kind" => "coordination", "idempotency_key" => "shared-key"}

    assert {:ok, %{status: "dispatched", kind: "coordination"}} =
             Repair.run(first, @partition, "repair-operator")

    assert {:error, :idempotency_conflict} =
             Repair.run(
               %{
                 "kind" => "activity",
                 "date_from" => "2026-05-01",
                 "date_to" => "2026-05-01",
                 "idempotency_key" => "shared-key"
               },
               @partition,
               "repair-operator"
             )
  end

  test "a failed repair also prevents caller-key reuse for a different request" do
    missing_id = Ecto.UUID.generate()

    assert {:error, :not_found} =
             Repair.run(
               %{
                 "kind" => "reembed",
                 "target_id" => missing_id,
                 "idempotency_key" => "failed-shared-key"
               },
               @partition,
               "repair-operator"
             )

    assert {:error, :idempotency_conflict} =
             Repair.run(
               %{"kind" => "coordination", "idempotency_key" => "failed-shared-key"},
               @partition,
               "repair-operator"
             )

    assert {:error, :not_found} =
             Repair.run(
               %{
                 "kind" => "reembed",
                 "target_id" => missing_id,
                 "idempotency_key" => "failed-shared-key"
               },
               @partition,
               "repair-operator"
             )
  end

  test "activity repair changes only the authenticated host in the exact partition" do
    owned_session = "repair-owned-#{System.unique_integer([:positive])}"
    foreign_session = "repair-foreign-#{System.unique_integer([:positive])}"

    append_activity_event!(@partition.host_id, owned_session, "owned")
    append_activity_event!("foreign-repair-host", foreign_session, "foreign")
    assert {:ok, _} = Rebuild.session(@partition.host_id, owned_session)
    assert {:ok, _} = Rebuild.session("foreign-repair-host", foreign_session)

    repo().update_all(
      from(row in ActivityDaily,
        where:
          row.host_id in [^@partition.host_id, "foreign-repair-host"] and
            row.client_id == ^@partition.client_id and row.scope == ^@partition.scope and
            row.namespace == ^@partition.namespace
      ),
      set: [event_count: 9]
    )

    assert {:ok, %{status: "dispatched", kind: "activity", affected: 1}} =
             Repair.run(
               %{
                 "kind" => "activity",
                 "date_from" => "2026-05-01",
                 "date_to" => "2026-05-01",
                 "idempotency_key" => "host-scoped-activity"
               },
               @partition,
               "repair-operator"
             )

    assert [%ActivityDaily{event_count: 1}] =
             repo().all(from(row in ActivityDaily, where: row.host_id == ^@partition.host_id))

    assert [%ActivityDaily{event_count: 9}] =
             repo().all(from(row in ActivityDaily, where: row.host_id == "foreign-repair-host"))
  end

  test "processing diagnosis counts only the exact partition and exposes no content" do
    assert {:ok, _owned} =
             Memories.remember("owned diagnosis content",
               agent_id: "repair-agent",
               host_id: @partition.host_id,
               client_id: @partition.client_id,
               scope: @partition.scope,
               namespace: @partition.namespace,
               idempotency_scope: "repair-health",
               idempotency_key: "owned"
             )

    assert {:ok, _foreign} =
             Memories.remember("foreign diagnosis content",
               agent_id: "repair-agent",
               host_id: "foreign-health-host",
               client_id: @partition.client_id,
               scope: @partition.scope,
               namespace: @partition.namespace,
               idempotency_scope: "repair-health",
               idempotency_key: "foreign"
             )

    assert %{
             projections: %{},
             unembedded_memories: 1,
             relation_candidates: 0,
             lesson_candidates: 0,
             bounded: true,
             content_exposed: false
           } = Health.snapshot(@partition)
  end

  defp append_activity_event!(host_id, session_id, project) do
    suffix = System.unique_integer([:positive])

    assert {:ok, {:inserted, _event}} =
             Store.append_tagged(%{
               id: Ecto.UUID.generate(),
               stream_id: "capture:#{host_id}:#{session_id}",
               host_id: host_id,
               client_id: @partition.client_id,
               scope: @partition.scope,
               namespace: @partition.namespace,
               session_id: session_id,
               project: project,
               agent_id: "repair-agent",
               source_sequence: 1,
               event_type: "memory.recalled",
               occurred_at: "2026-05-01T01:00:00.000000Z",
               idempotency_key: "repair-activity:#{suffix}",
               payload: %{},
               payload_hash: "sha256:repair-#{suffix}",
               schema_version: 1
             })
  end
end
