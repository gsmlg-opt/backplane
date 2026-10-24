defmodule Backplane.Memory.SourcesTest do
  use Backplane.Memory.DataCase, async: false
  alias Backplane.Memory.{Sources, Memories}
  alias Backplane.Memory.Sources.{Entry, Mutation}
  alias Backplane.MemorySourceContract, as: Contract

  setup do
    partition = canonical_partition("hermes-source-fixture")

    source = %{
      "integration" => "hermes",
      "installation_id" => Ecto.UUID.generate(),
      "profile_id" => "primary",
      "target" => "memory"
    }

    %{partition: partition, source: source, entry: Ecto.UUID.generate()}
  end

  defp mutation(c, revision, content, overrides \\ %{}) do
    Map.merge(
      %{
        "protocol" => "memory_sources.v1",
        "source" => c.source,
        "entry_id" => c.entry,
        "event_id" => Ecto.UUID.generate(),
        "revision" => revision,
        "operation" => "upsert",
        "content" => content,
        "type" => "semantic",
        "occurred_at" => "2026-10-24T01:00:00Z",
        "provenance" => %{"session_id" => "session-#{revision}", "role" => "assistant"}
      },
      overrides
    )
  end

  defp withdraw(c, revision),
    do: mutation(c, revision, nil, %{"operation" => "withdraw"}) |> Map.delete("content")

  defp current(c), do: Memories.list([current: true], c.partition)

  test "edge publication waits for source evidence and withdrawal emits one tombstone", c do
    repo().query!(
      "INSERT INTO bpm_memory_space_entitlements (memory_space_id,host_id,scope,namespace,status,inserted_at,updated_at) VALUES ($1,$2,$3,$4,'active',now(),now())",
      [
        Ecto.UUID.dump!(c.partition.memory_space_id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        c.partition.scope,
        c.partition.namespace
      ]
    )

    args = mutation(c, 1, "Publish only supported source context")

    assert {:ok, %{canonical_id: id, revision: revision}} =
             Sources.mutate(args, c.partition)

    assert [[^revision, "upsert", payload]] =
             repo().query!(
               "SELECT revision, op, payload FROM bpm_memory_changes WHERE memory_id=$1 ORDER BY revision",
               [Ecto.UUID.dump!(id)]
             ).rows

    assert payload["effective_support"]
    assert payload["support_complete"]
    refute payload["independent_support"]
    assert payload["trust"] == "candidate_inference"
    assert [%{"event_id" => event_id, "source_revision" => 1}] = payload["source_refs"]
    assert event_id == args["event_id"]

    assert {:ok, %{revision: withdrawn_revision}} =
             Sources.mutate(withdraw(c, 2), c.partition)

    assert withdrawn_revision > revision

    assert [[^revision, "upsert"], [^withdrawn_revision, "delete"]] =
             repo().query!(
               "SELECT revision, op FROM bpm_memory_changes WHERE memory_id=$1 ORDER BY revision",
               [Ecto.UUID.dump!(id)]
             ).rows
  end

  test "sole source correction and withdrawal retain history but stop current reads", c do
    assert {:ok, %{canonical_id: first}} =
             Sources.mutate(mutation(c, 1, "Hermes likes blue"), c.partition)

    assert Enum.map(current(c), & &1.id) == [first]

    assert {:ok, %{canonical_id: second}} =
             Sources.mutate(mutation(c, 2, "Hermes likes green"), c.partition)

    assert Enum.map(current(c), & &1.id) == [second]
    assert {:error, :not_found} = Memories.public_get(first, c.partition, %{})
    assert {:ok, %{outcome: "applied"}} = Sources.mutate(withdraw(c, 3), c.partition)
    assert current(c) == []
    assert length(Memories.list([], c.partition)) == 2
    assert repo().aggregate(Mutation, :count) == 3
    assert Enum.all?(repo().all(Entry), &(not &1.active))
  end

  test "independent profile and target retain memberships despite canonical content dedup", c do
    text = "One independently supported fact"
    assert {:ok, %{canonical_id: id}} = Sources.mutate(mutation(c, 1, text), c.partition)

    second = %{
      c
      | source: %{c.source | "profile_id" => "independent", "target" => "user"},
        entry: Ecto.UUID.generate()
    }

    assert {:ok, %{canonical_id: ^id}} = Sources.mutate(mutation(second, 1, text), c.partition)
    assert repo().aggregate(Entry, :count) == 2
    assert {:ok, _} = Sources.mutate(withdraw(c, 2), c.partition)
    assert Enum.map(current(c), & &1.id) == [id]
    assert {:ok, _} = Sources.mutate(withdraw(second, 2), c.partition)
    assert current(c) == []
  end

  test "immutable replay, conflict and delayed revisions cannot resurrect withdrawn state", c do
    original = mutation(c, 1, "Original fact")
    assert {:ok, receipt} = Sources.mutate(original, c.partition)
    assert {:ok, ^receipt} = Sources.mutate(original, c.partition)

    assert {:error, :idempotency_conflict} =
             Sources.mutate(Map.put(original, "content", "changed"), c.partition)

    assert {:ok, _} = Sources.mutate(withdraw(c, 5), c.partition)

    assert {:ok, %{outcome: "stale"}} =
             Sources.mutate(mutation(c, 2, "Late old state"), c.partition)

    assert current(c) == []
    assert repo().aggregate(Mutation, :count) == 3
  end

  test "generic direct support is independent and immutable remember semantics remain", c do
    opts =
      Map.to_list(c.partition) ++
        [agent_id: "generic", idempotency_scope: "generic", idempotency_key: "same"]

    assert {:ok, direct} = Memories.remember("Shared fact", opts)
    assert {:ok, %{canonical_id: id}} = Sources.mutate(mutation(c, 1, "Shared fact"), c.partition)
    assert direct.id == id
    assert {:ok, _} = Sources.mutate(withdraw(c, 2), c.partition)
    assert Enum.map(current(c), & &1.id) == [id]
    assert {:error, :idempotency_conflict} = Memories.remember("Changed fact", opts)
  end

  test "global forget suppresses future source revisions and reconciliation", c do
    assert {:ok, %{canonical_id: id}} =
             Sources.mutate(mutation(c, 1, "Forget this source"), c.partition)

    assert :ok = Memories.tombstone(id, c.partition)

    assert {:ok, %{outcome: "suppressed"}} =
             Sources.mutate(mutation(c, 2, "Changed source after global forget"), c.partition)

    assert current(c) == []
  end

  test "derived request receipts do not outlive their required source support", c do
    args = mutation(c, 1, "Primary source evidence")
    assert {:ok, %{canonical_id: source_id}} = Sources.mutate(args, c.partition)

    assert {:ok, output} =
             Memories.remember(
               "Derived output",
               Map.to_list(c.partition) ++
                 [
                   agent_id: "extractor",
                   evidence: [
                     %{
                       source_mutation_id: args["event_id"],
                       evidence_kind: "derives",
                       support_score: 0.8
                     }
                   ]
                 ]
             )

    assert MapSet.new(Enum.map(current(c), & &1.id)) == MapSet.new([source_id, output.id])
    assert {:ok, _} = Sources.mutate(withdraw(c, 2), c.partition)
    assert current(c) == []

    assert [
             %{
               source_type: "request",
               source_id: request_id,
               evidence_kind: "derives",
               support_score: +0.0
             },
             %{source_type: "source_mutation", source_id: mutation_id, support_score: 0.8}
           ] = Memories.list_evidence(output.id)

    assert mutation_id == args["event_id"]
    request = repo().get!(Backplane.Memory.Memories.RememberRequest, request_id)
    assert request.origin == "derived"
    refute request.independent_support
  end

  test "expired or archived roots stop derived reads and cannot create a new current output", c do
    args = mutation(c, 1, "Root with bounded eligibility")
    assert {:ok, %{canonical_id: root}} = Sources.mutate(args, c.partition)

    opts =
      Map.to_list(c.partition) ++
        [
          agent_id: "extractor",
          evidence: [
            %{source_mutation_id: args["event_id"], evidence_kind: "derives", support_score: 1.0}
          ]
        ]

    assert {:ok, derived} = Memories.remember("derived before expiry", opts)
    assert {:ok, _} = Memories.public_get(derived.id, c.partition, %{})

    repo().update_all(from(m in Backplane.Memory.Memories.Memory, where: m.id == ^root),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert {:error, :not_found} = Memories.public_get(derived.id, c.partition, %{})
    assert {:ok, later} = Memories.remember("must remain historical after root expiry", opts)
    assert {:error, :not_found} = Memories.public_get(later.id, c.partition, %{})
    assert current(c) == []
  end

  test "global forget refreshes dependent support and direct reinforcement preserves independence",
       c do
    args = mutation(c, 1, "Root for forget and independent support")
    assert {:ok, %{canonical_id: root}} = Sources.mutate(args, c.partition)

    opts =
      Map.to_list(c.partition) ++
        [
          agent_id: "extractor",
          evidence: [
            %{source_mutation_id: args["event_id"], evidence_kind: "derives", support_score: 1.0}
          ]
        ]

    assert {:ok, derived} = Memories.remember("dependent output", opts)
    assert :ok = Memories.tombstone(root, c.partition)
    assert {:error, :not_found} = Memories.public_get(derived.id, c.partition, %{})

    assert {:ok, reinforced} =
             Memories.remember(
               "dependent output",
               Map.to_list(c.partition) ++ [agent_id: "operator"]
             )

    assert reinforced.id == derived.id
    assert {:ok, visible} = Memories.public_get(derived.id, c.partition, %{})
    assert Backplane.Memory.CurrentContext.metadata(visible)["independent_support"] == true
  end

  test "legacy Hermes request defaults do not become independent support after source withdrawal",
       c do
    for source <- ["hermes.memory_write.add", "hermes.memory_write.update", "hermes.sync_turn"] do
      text = "Legacy native source #{source}"

      # Reproduce the old storage shape: the receipt has no per-request support
      # classification, and its canonical metadata is the only reliable evidence.
      memory =
        %Backplane.Memory.Memories.Memory{}
        |> Backplane.Memory.Memories.Memory.changeset(
          Map.merge(c.partition, %{
            content: text,
            memory_type: "semantic",
            agent_id: "legacy",
            metadata: %{"source" => source}
          })
        )
        |> repo().insert!()

      repo().insert!(%Backplane.Memory.Memories.RememberRequest{
        idempotency_scope: "legacy-hermes",
        idempotency_key: source,
        request_hash: :crypto.hash(:sha256, text),
        memory_id: memory.id,
        origin: "direct",
        independent_support: nil
      })

      fixture = %{c | entry: Ecto.UUID.generate()}
      assert {:ok, %{canonical_id: id}} = Sources.mutate(mutation(fixture, 1, text), c.partition)
      assert id == memory.id
      assert {:ok, visible} = Memories.public_get(id, c.partition, %{})
      refute Backplane.Memory.CurrentContext.metadata(visible)["independent_support"]
      assert {:ok, _} = Sources.mutate(withdraw(fixture, 2), c.partition)
      assert {:error, :not_found} = Memories.public_get(id, c.partition, %{})

      assert {:ok, reinforced} =
               Memories.remember(text, Map.to_list(c.partition) ++ [agent_id: "operator"])

      assert reinforced.id == id
      assert {:ok, visible} = Memories.public_get(id, c.partition, %{})
      assert Backplane.Memory.CurrentContext.metadata(visible)["independent_support"]
    end
  end

  test "edge payloads and snapshots synchronously suppress dependents when source roots expire or archive",
       c do
    alias Backplane.Memory.EdgeSync.{SnapshotBuilder, SnapshotChunk}

    repo().query!(
      "INSERT INTO bpm_memory_space_entitlements (memory_space_id,host_id,scope,namespace,status,inserted_at,updated_at) VALUES ($1,$2,$3,$4,'active',now(),now())",
      [
        Ecto.UUID.dump!(c.partition.memory_space_id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        c.partition.scope,
        c.partition.namespace
      ]
    )

    args = mutation(c, 1, "Root for current edge policy")
    assert {:ok, %{canonical_id: root}} = Sources.mutate(args, c.partition)

    assert {:ok, derived} =
             Memories.remember(
               "Derived for current edge policy",
               Map.to_list(c.partition) ++
                 [
                   agent_id: "extractor",
                   evidence: [
                     %{
                       source_mutation_id: args["event_id"],
                       evidence_kind: "derives",
                       support_score: 1.0
                     }
                   ]
                 ]
             )

    future = DateTime.add(DateTime.utc_now(), 3600)

    repo().update_all(from(m in Backplane.Memory.Memories.Memory, where: m.id == ^root),
      set: [expires_at: future]
    )

    assert %{rows: [[payload]]} =
             repo().query!(
               "SELECT bpm_memory_edge_payload(m) FROM bpm_memories m WHERE id=$1",
               [Ecto.UUID.dump!(derived.id)]
             )

    assert payload["policy_version"] == "current_context.v1"
    assert payload["effective_support"]
    assert payload["valid_until"]
    assert payload["metadata"]["current_context"]["valid_until"] == payload["valid_until"]
    assert [%{"entry_id" => entry}] = payload["source_refs"]
    assert entry == c.entry

    partition = Map.take(c.partition, [:memory_space_id, :scope, :namespace])

    assert {:ok, snapshot} =
             repo().transaction(fn ->
               SnapshotBuilder.build_locked(partition, %{
                 max_changes: 100,
                 max_frame_bytes: 524_288
               })
             end)

    assert snapshot.item_count == 2

    repo().update_all(from(m in Backplane.Memory.Memories.Memory, where: m.id == ^root),
      set: [lifecycle_state: "archived"]
    )

    refute repo().get!(Backplane.Memory.Memories.Memory, derived.id).effective_support

    assert %{rows: [["delete"]]} =
             repo().query!(
               "SELECT op FROM bpm_memory_changes WHERE memory_id=$1 ORDER BY revision DESC LIMIT 1",
               [Ecto.UUID.dump!(derived.id)]
             )

    assert {:ok, empty} =
             repo().transaction(fn ->
               SnapshotBuilder.build_locked(partition, %{
                 max_changes: 100,
                 max_frame_bytes: 524_288
               })
             end)

    assert empty.item_count == 0

    assert repo().one!(
             from(chunk in SnapshotChunk,
               where: chunk.snapshot_id == ^empty.id and chunk.chunk_index == 0
             )
           ).payload == %{"items" => []}
  end

  test "complete snapshots fence concurrent live changes and delayed unknown adds", c do
    assert {:ok, _} = Sources.mutate(mutation(c, 1, "Initial"), c.partition)
    rid = Ecto.UUID.generate()

    common = %{
      "protocol" => "memory_sources.v1",
      "source" => c.source,
      "reconciliation_id" => rid
    }

    begin =
      Map.merge(common, %{
        "phase" => "begin",
        "event_id" => Ecto.UUID.generate(),
        "revision" => 2,
        "page_count" => 0,
        "entry_count" => 0,
        "snapshot_hash" => Contract.digest([])
      })

    assert {:ok, _} = Sources.reconcile(begin, c.partition)

    assert {:ok, %{canonical_id: newer}} =
             Sources.mutate(mutation(c, 3, "Concurrent live"), c.partition)

    commit =
      Map.merge(common, %{
        "phase" => "commit",
        "event_id" => Ecto.UUID.generate(),
        "complete" => true
      })

    assert {:ok, _} = Sources.reconcile(commit, c.partition)
    assert {:ok, _} = Sources.reconcile(commit, c.partition)
    assert Enum.map(current(c), & &1.id) == [newer]
    unknown = %{c | entry: Ecto.UUID.generate()}

    assert {:ok, %{outcome: "stale"}} =
             Sources.mutate(mutation(unknown, 1, "Delayed unknown add"), c.partition)

    assert Enum.map(current(c), & &1.id) == [newer]
  end

  test "missing pages cannot imply an empty source", c do
    assert {:ok, %{canonical_id: id}} =
             Sources.mutate(mutation(c, 1, "Must survive partial read"), c.partition)

    common = %{
      "protocol" => "memory_sources.v1",
      "source" => c.source,
      "reconciliation_id" => Ecto.UUID.generate()
    }

    assert {:ok, _} =
             Sources.reconcile(
               Map.merge(common, %{
                 "phase" => "begin",
                 "event_id" => Ecto.UUID.generate(),
                 "revision" => 2,
                 "page_count" => 1,
                 "entry_count" => 1,
                 "snapshot_hash" => String.duplicate("0", 64)
               }),
               c.partition
             )

    assert {:error, :incomplete_snapshot} =
             Sources.reconcile(
               Map.merge(common, %{
                 "phase" => "commit",
                 "event_id" => Ecto.UUID.generate(),
                 "complete" => true
               }),
               c.partition
             )

    assert Enum.map(current(c), & &1.id) == [id]
  end
end
