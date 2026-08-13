defmodule Backplane.Memory.Memories.RelationsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Memories}
  alias Backplane.Memory.Memories.{Memory, Relations}

  test "contradiction candidate is durable, idempotent, and changes lifecycle only when confirmed" do
    {:ok, first} = remember("first", "one")
    {:ok, second} = remember("second", "two")
    correlation_id = Ecto.UUID.generate()

    attrs =
      candidate_attrs("contradiction", "revision-1", first, second)
      |> Map.put(:actor, "spoofed-actor")
      |> Map.put(:host_id, "spoofed-host")
      |> Map.put(:client_id, "spoofed-client")
      |> Map.put(:correlation_id, correlation_id)

    assert {:ok, candidate} = Relations.create_candidate(first.id, second.id, attrs)
    assert candidate.correlation_id == correlation_id
    relation_view = Enum.find(Relations.list_relations(first.id), &(&1.id == candidate.id))
    candidate_audit = relation_audit!(first.id, "memory_relation.candidate", candidate.id)
    assert candidate_audit.actor == "system"
    assert candidate_audit.metadata["correlation_id"] == correlation_id
    assert candidate_audit.target_ids == [candidate.source_memory_id, candidate.target_memory_id]

    assert_audit_identity(
      candidate_audit.metadata,
      candidate,
      relation_view.evidence,
      "candidate"
    )

    assert {:ok, retry} =
             Relations.create_candidate(
               second.id,
               first.id,
               candidate_attrs("contradiction", "revision-1", second, first)
             )

    assert retry.id == candidate.id
    assert {:ok, %{lifecycle_state: "active"}} = Memories.trusted_get(first.id)

    assert {:ok, confirmed} = Relations.resolve_candidate(candidate.id, :confirmed)
    assert confirmed.status == "confirmed"
    assert {:ok, %{lifecycle_state: "disputed", confidence: 1.0}} = Memories.trusted_get(first.id)

    assert {:ok, %{lifecycle_state: "disputed", confidence: 1.0}} =
             Memories.trusted_get(second.id)

    resolution_audit = relation_audit!(first.id, "memory_relation.resolve", candidate.id)
    assert resolution_audit.actor == "system"
    assert resolution_audit.metadata["correlation_id"] == correlation_id

    assert_audit_identity(
      resolution_audit.metadata,
      confirmed,
      relation_view.evidence,
      "confirmed"
    )

    assert resolution_audit.metadata["lifecycle_transitions"] ==
             [first.id, second.id]
             |> Enum.sort()
             |> Enum.map(fn memory_id ->
               %{
                 "memory_id" => memory_id,
                 "before" => %{"lifecycle_state" => "active", "superseded_by" => nil},
                 "after" => %{"lifecycle_state" => "disputed", "superseded_by" => nil}
               }
             end)

    assert {:ok, same_confirmation} = Relations.resolve_candidate(candidate.id, :confirmed)
    assert same_confirmation.id == candidate.id
    assert {:error, :resolution_conflict} = Relations.resolve_candidate(candidate.id, :rejected)

    assert {:ok, second_candidate} =
             Relations.create_candidate(
               first.id,
               second.id,
               candidate_attrs("contradiction", "revision-2", first, second)
             )

    assert {:ok, rejected} = Relations.resolve_candidate(second_candidate.id, :rejected)
    assert rejected.status == "rejected"
    assert {:ok, same_rejection} = Relations.resolve_candidate(second_candidate.id, :rejected)
    assert same_rejection.id == second_candidate.id

    assert {:error, :resolution_conflict} =
             Relations.resolve_candidate(second_candidate.id, :confirmed)

    assert {:ok, %{lifecycle_state: "disputed"}} = Memories.trusted_get(first.id)
    assert {:ok, verification} = Memories.trusted_verify(first.id)
    assert verification.contradiction_count == 0
    assert verification.contradiction_relation_count == 1

    assert {:ok, service_verification} =
             Backplane.Memory.Service.trusted_call("memory::verify", %{"memory_id" => first.id})

    assert service_verification.contradiction_count == 0
    assert service_verification.contradiction_relation_count == 1
  end

  test "candidate requires the full memory partition and evidence from both endpoints" do
    {:ok, first} = remember("first", "partition-a")

    {:ok, other_scope} =
      Memories.remember("second", direct_opts("partition-b") |> Keyword.put(:scope, "other"))

    assert {:error, :partition_mismatch} =
             Relations.create_candidate(
               first.id,
               other_scope.id,
               candidate_attrs("contradiction", "r", first, other_scope)
             )
  end

  test "classifier candidate eligibility rejects archived and superseded endpoints under lock" do
    {:ok, archived} = remember("archived", "classifier-archived")
    {:ok, superseded} = remember("superseded", "classifier-superseded")
    {:ok, successor} = remember("successor", "classifier-successor")

    archived
    |> Memory.lifecycle_changeset(%{lifecycle_state: "archived", superseded_by: nil})
    |> repo().update!()

    superseded
    |> Memory.lifecycle_changeset(%{
      lifecycle_state: "superseded",
      superseded_by: successor.id
    })
    |> repo().update!()

    for endpoint <- [archived, superseded] do
      assert {:error, :not_found} =
               Relations.create_candidate(
                 endpoint.id,
                 successor.id,
                 candidate_attrs("extension", "classifier-#{endpoint.id}", endpoint, successor),
                 eligibility: :classifier
               )
    end

    assert {:ok, _manual_candidate} =
             Relations.create_candidate(
               archived.id,
               successor.id,
               candidate_attrs("extension", "manual-review", archived, successor)
             )
  end

  test "candidate rejects self-relations, malformed input, and changed retry evidence" do
    {:ok, first} = remember("first", "invalid-a")
    {:ok, second} = remember("second", "invalid-b")
    attrs = candidate_attrs("extension", "invalid-retry", first, second)

    assert {:error, :same_memory} = Relations.create_candidate(first.id, first.id, attrs)

    assert {:error, :invalid_candidate} =
             Relations.create_candidate(first.id, second.id, Map.delete(attrs, :classifier_model))

    assert {:error, :invalid_candidate} =
             Relations.create_candidate(
               first.id,
               second.id,
               Map.put(attrs, :correlation_id, "not-a-uuid")
             )

    assert {:ok, relation} = Relations.create_candidate(first.id, second.id, attrs)
    assert {:ok, _generated_correlation} = Ecto.UUID.cast(relation.correlation_id)

    assert relation_audit!(first.id, "memory_relation.candidate", relation.id).metadata[
             "correlation_id"
           ] == relation.correlation_id

    assert {:error, :idempotency_conflict} =
             Relations.create_candidate(
               first.id,
               second.id,
               Map.put(attrs, :correlation_id, Ecto.UUID.generate())
             )

    assert {:ok, same_first} = remember("first", "invalid-a-more-evidence")
    assert same_first.id == first.id

    assert {:error, :idempotency_conflict} =
             Relations.create_candidate(
               first.id,
               second.id,
               candidate_attrs("extension", "invalid-retry", first, second)
             )
  end

  test "temporal replacement requires parseable newer validity and supersedes the older memory" do
    {:ok, older} = remember("old value", "old", %{"valid_from" => "2025-01-01T00:00:00Z"})
    {:ok, newer} = remember("new value", "new", %{"valid_from" => "2026-01-01T00:00:00Z"})

    attrs = candidate_attrs("temporal_replacement", "temporal-1", older, newer)
    assert {:ok, relation} = Relations.create_candidate(older.id, newer.id, attrs)
    assert {:ok, _} = Relations.resolve_candidate(relation.id, :confirmed)

    assert {:ok, %{lifecycle_state: "superseded", superseded_by: successor}} =
             Memories.trusted_get(older.id)

    assert successor == newer.id
  end

  test "automatic confirmation rollback leaves no relation or audit on invalid temporal evidence" do
    {:ok, older} = remember("old invalid value", "invalid-auto-old")
    {:ok, newer} = remember("new invalid value", "invalid-auto-new")

    attrs =
      candidate_attrs("temporal_replacement", "invalid-auto", older, newer)
      |> Map.put(:automatic_confirmation, true)

    assert {:error, :invalid_temporal_replacement} =
             Relations.apply_classifier(older.id, newer.id, attrs)

    assert Relations.list_relations(older.id) == []

    operations = older.id |> Audit.list_for_target() |> Enum.map(& &1.operation)
    refute "memory_relation.candidate" in operations
    refute "memory_relation.resolve" in operations
    refute "memory_relation.policy" in operations
  end

  test "automatic unrelated outcome is an idempotent audited no-op" do
    {:ok, first} = remember("compatible first", "compatible-first")
    {:ok, second} = remember("compatible second", "compatible-second")
    attrs = candidate_attrs("unrelated", "compatible-noop", first, second)

    assert {:ok, :noop} = Relations.apply_classifier(first.id, second.id, attrs)
    assert {:ok, :noop} = Relations.apply_classifier(first.id, second.id, attrs)
    assert Relations.list_relations(first.id) == []
    assert {:ok, %{lifecycle_state: "active"}} = Memories.trusted_get(first.id)
    assert {:ok, %{lifecycle_state: "active"}} = Memories.trusted_get(second.id)

    assert [policy] =
             first.id
             |> Audit.list_for_target()
             |> Enum.filter(&(&1.operation == "memory_relation.policy"))

    assert policy.metadata["outcome"] == "reject_noop"
  end

  test "resolution revalidates endpoint liveness and the full partition after locking" do
    {:ok, first} = remember("first", "revalidate-a")
    {:ok, tombstoned} = remember("tombstoned", "revalidate-b")

    {:ok, tombstone_candidate} =
      Relations.create_candidate(
        first.id,
        tombstoned.id,
        candidate_attrs("extension", "tombstone", first, tombstoned)
      )

    assert :ok = Memories.trusted_forget(tombstoned.id)
    assert {:error, :not_found} = Relations.resolve_candidate(tombstone_candidate.id, :confirmed)
    assert relation_status(first.id, tombstone_candidate.id) == "candidate"

    {:ok, moved} = remember("moved", "revalidate-c")

    {:ok, partition_candidate} =
      Relations.create_candidate(
        first.id,
        moved.id,
        candidate_attrs("extension", "partition", first, moved)
      )

    moved |> Ecto.Changeset.change(scope: "other") |> repo().update!()

    assert {:error, :partition_mismatch} =
             Relations.resolve_candidate(partition_candidate.id, :confirmed)

    assert relation_status(first.id, partition_candidate.id) == "candidate"
  end

  test "one source has one confirmed supersession and a three-node cycle is rejected" do
    {:ok, old} = remember("old", "supersession-old", valid_from("2023-01-01T00:00:00Z"))
    {:ok, next} = remember("next", "supersession-next", valid_from("2024-01-01T00:00:00Z"))
    {:ok, newest} = remember("newest", "supersession-newest", valid_from("2025-01-01T00:00:00Z"))

    {:ok, first} = temporal_candidate(old, next, "first-supersession")
    assert {:ok, _confirmed} = Relations.resolve_candidate(first.id, :confirmed)

    {:ok, conflicting} = temporal_candidate(old, newest, "conflicting-supersession")

    assert {:error, :conflicting_supersession} =
             Relations.resolve_candidate(conflicting.id, :confirmed)

    assert relation_status(old.id, conflicting.id) == "candidate"

    {:ok, a} = remember("cycle-a", "cycle-a", valid_from("2023-01-01T00:00:00Z"))
    {:ok, b} = remember("cycle-b", "cycle-b", valid_from("2024-01-01T00:00:00Z"))
    {:ok, c} = remember("cycle-c", "cycle-c", valid_from("2025-01-01T00:00:00Z"))

    {:ok, ab} = temporal_candidate(a, b, "cycle-ab")
    assert {:ok, _} = Relations.resolve_candidate(ab.id, :confirmed)
    {:ok, bc} = temporal_candidate(b, c, "cycle-bc")
    assert {:ok, _} = Relations.resolve_candidate(bc.id, :confirmed)
    {:ok, ca} = temporal_candidate(c, a, "cycle-ca")
    assert {:error, :supersession_cycle} = Relations.resolve_candidate(ca.id, :confirmed)
    assert relation_status(c.id, ca.id) == "candidate"
  end

  test "invalid temporal and knowledge relations do not mutate lifecycle" do
    {:ok, first} = remember("first", "non-lifecycle-a")
    {:ok, second} = remember("second", "non-lifecycle-b")

    assert {:error, :invalid_evidence} =
             Relations.create_candidate(
               first.id,
               second.id,
               candidate_attrs("extension", "wrong-evidence", first, second)
               |> Map.put(:source_evidence_ids, evidence_ids(second))
             )

    assert {:error, :evidence_required} =
             Relations.create_candidate(
               first.id,
               second.id,
               candidate_attrs("extension", "missing-evidence", first, second)
               |> Map.put(:source_evidence_ids, [])
             )

    assert {:ok, extension} =
             Relations.create_candidate(
               first.id,
               second.id,
               candidate_attrs("extension", "extension", first, second)
             )

    assert {:ok, _confirmed} = Relations.resolve_candidate(extension.id, :confirmed)
    assert {:ok, %{lifecycle_state: "active"}} = Memories.trusted_get(first.id)

    assert {:ok, temporal} =
             Relations.create_candidate(
               first.id,
               second.id,
               candidate_attrs("temporal_replacement", "invalid-temporal", first, second)
             )

    assert {:error, :invalid_temporal_replacement} =
             Relations.resolve_candidate(temporal.id, :confirmed)

    assert {:ok, %{lifecycle_state: "active"}} = Memories.trusted_get(first.id)
  end

  test "forget atomically tombstones and verify returns relations and audit transitions" do
    {:ok, first} = remember("verify one", "verify-one")
    {:ok, second} = remember("verify two", "verify-two")

    {:ok, relation} =
      Relations.create_candidate(
        first.id,
        second.id,
        candidate_attrs("extension", "v", first, second)
      )

    assert :ok = Memories.trusted_forget(first.id)
    assert {:ok, verification} = Memories.trusted_verify(first.id)
    assert verification.memory.lifecycle_state == "tombstoned"
    assert Enum.any?(verification.relations, &(&1.id == relation.id))
    assert Enum.any?(verification.audit, &(&1.operation == "forget"))
  end

  defp remember(content, key, metadata \\ %{}) do
    Memories.remember(content, direct_opts(key) |> Keyword.put(:metadata, metadata))
  end

  defp direct_opts(key) do
    [
      agent_id: "agent",
      host_id: "host",
      scope: "scope",
      idempotency_scope: "test",
      idempotency_key: key
    ]
  end

  defp candidate_attrs(classification, revision, source, target) do
    %{
      classification: classification,
      confidence: 0.9,
      classifier_model: "test-model",
      classifier_version: "v1",
      input_revision: revision,
      source_evidence_ids: evidence_ids(source),
      target_evidence_ids: evidence_ids(target)
    }
  end

  defp evidence_ids(memory), do: Enum.map(Memories.list_evidence(memory.id), & &1.id)

  defp valid_from(value), do: %{"valid_from" => value}

  defp temporal_candidate(source, target, revision) do
    Relations.create_candidate(
      source.id,
      target.id,
      candidate_attrs("temporal_replacement", revision, source, target)
    )
  end

  defp relation_status(memory_id, relation_id) do
    Relations.list_relations(memory_id)
    |> Enum.find(&(&1.id == relation_id))
    |> Map.fetch!(:status)
  end

  defp relation_audit!(memory_id, operation, relation_id) do
    Audit.list_for_target(memory_id)
    |> Enum.find(fn entry ->
      entry.operation == operation and entry.metadata["relation_id"] == relation_id
    end)
  end

  defp assert_audit_identity(metadata, relation, evidence, result) do
    assert {:ok, _correlation_id} = Ecto.UUID.cast(metadata["correlation_id"])
    assert metadata["correlation_id"] == relation.correlation_id

    trace =
      Map.take(metadata, [
        "host_id",
        "client_id",
        "scope",
        "namespace",
        "request_id",
        "request_ids",
        "correlation_ids"
      ])

    assert trace["host_id"] == "host"
    assert trace["scope"] == "scope"
    assert trace["namespace"] == "private"
    assert is_binary(trace["request_id"])
    assert trace["request_id"] in trace["request_ids"]

    assert Map.drop(metadata, [
             "correlation_id",
             "lifecycle_transitions",
             "host_id",
             "client_id",
             "scope",
             "namespace",
             "request_id",
             "request_ids",
             "correlation_ids"
           ]) == %{
             "relation_id" => relation.id,
             "source_memory_id" => relation.source_memory_id,
             "target_memory_id" => relation.target_memory_id,
             "source_host_id" => "host",
             "source_client_id" => nil,
             "target_host_id" => "host",
             "target_client_id" => nil,
             "domain" => relation.domain,
             "relation_type" => relation.relation_type,
             "classification" => relation.classification,
             "confidence" => relation.confidence,
             "classifier_model" => relation.classifier_model,
             "classifier_version" => relation.classifier_version,
             "input_revision" => relation.input_revision,
             "evidence" =>
               Enum.map(evidence, fn item ->
                 %{"role" => item.role, "evidence_id" => item.evidence_id}
               end),
             "result" => result
           }
  end
end
