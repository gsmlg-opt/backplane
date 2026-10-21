defmodule Backplane.Memory.Operations.RepairTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Memories}
  alias Backplane.Memory.Operations.{Health, Repair}
  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Projections.{ActivityDaily, Rebuild}

  setup do
    {:ok,
     partition:
       canonical_partition("repair-host", client_id: "repair-client", scope: "repair-scope")}
  end

  test "re-embed repair is exact-partition, idempotent, and audited without content", %{
    partition: partition
  } do
    assert {:ok, memory} =
             Memories.remember("repair content must stay out of operations telemetry and audit",
               agent_id: "repair-agent",
               memory_space_id: partition.memory_space_id,
               host_id: partition.host_id,
               client_id: partition.client_id,
               source_client_id: partition.source_client_id,
               scope: partition.scope,
               namespace: partition.namespace,
               idempotency_scope: "repair-test",
               idempotency_key: "memory-1"
             )

    args = %{
      "kind" => "reembed",
      "target_id" => memory.id,
      "idempotency_key" => "repair-reembed-1"
    }

    assert {:ok, %{status: "dispatched", kind: "reembed", affected: 1}} =
             Repair.run(args, partition, "repair-operator")

    assert {:ok, %{status: "already_applied", kind: "reembed", affected: 1}} =
             Repair.run(args, partition, "repair-operator")

    assert [%{actor: "repair-operator", metadata: metadata}] =
             Audit.list(operation: "memory.repair")

    assert metadata["kind"] == "reembed"
    assert metadata["result"] == "dispatched"
    assert metadata["host_id"] == partition.host_id
    refute inspect(metadata) =~ "repair content"
  end

  test "repair rejects a foreign target before dispatch or audit", %{partition: partition} do
    foreign =
      canonical_partition("foreign-host", client_id: partition.client_id, scope: partition.scope)

    assert {:ok, memory} =
             Memories.remember("foreign",
               agent_id: "repair-agent",
               memory_space_id: foreign.memory_space_id,
               host_id: foreign.host_id,
               client_id: foreign.client_id,
               source_client_id: foreign.source_client_id,
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
               partition,
               "repair-operator"
             )

    assert [%{metadata: %{"result" => "failed", "error_class" => "not_found"}}] =
             Audit.list(operation: "memory.repair")
  end

  test "repair requires an explicit stable idempotency key", %{partition: partition} do
    assert {:error, :invalid_arguments} =
             Repair.run(%{"kind" => "coordination"}, partition, "repair-operator")
  end

  test "repair rejects an incomplete canonical partition", %{partition: partition} do
    assert {:error, :unauthorized} =
             Repair.run(
               %{"kind" => "coordination", "idempotency_key" => "missing-space"},
               Map.delete(partition, :memory_space_id),
               "repair-operator"
             )
  end

  test "one caller key cannot be replayed for a different repair request", %{partition: partition} do
    first = %{"kind" => "coordination", "idempotency_key" => "shared-key"}

    assert {:ok, %{status: "dispatched", kind: "coordination"}} =
             Repair.run(first, partition, "repair-operator")

    assert {:error, :idempotency_conflict} =
             Repair.run(
               %{
                 "kind" => "activity",
                 "date_from" => "2026-05-01",
                 "date_to" => "2026-05-01",
                 "idempotency_key" => "shared-key"
               },
               partition,
               "repair-operator"
             )
  end

  test "a failed repair also prevents caller-key reuse for a different request", %{
    partition: partition
  } do
    missing_id = Ecto.UUID.generate()

    assert {:error, :not_found} =
             Repair.run(
               %{
                 "kind" => "reembed",
                 "target_id" => missing_id,
                 "idempotency_key" => "failed-shared-key"
               },
               partition,
               "repair-operator"
             )

    assert {:error, :idempotency_conflict} =
             Repair.run(
               %{"kind" => "coordination", "idempotency_key" => "failed-shared-key"},
               partition,
               "repair-operator"
             )

    assert {:error, :not_found} =
             Repair.run(
               %{
                 "kind" => "reembed",
                 "target_id" => missing_id,
                 "idempotency_key" => "failed-shared-key"
               },
               partition,
               "repair-operator"
             )
  end

  test "activity repair changes only the authenticated host in the exact partition", %{
    partition: partition
  } do
    owned_session = "repair-owned-#{System.unique_integer([:positive])}"
    foreign_session = "repair-foreign-#{System.unique_integer([:positive])}"

    append_activity_event!(partition, owned_session, "owned")

    foreign =
      canonical_partition("foreign-repair-host",
        client_id: partition.client_id,
        scope: partition.scope
      )

    append_activity_event!(foreign, foreign_session, "foreign")
    assert {:ok, _} = Rebuild.session(partition.host_id, owned_session)
    assert {:ok, _} = Rebuild.session("foreign-repair-host", foreign_session)

    repo().update_all(
      from(row in ActivityDaily,
        where:
          row.host_id in [^partition.host_id, "foreign-repair-host"] and
            row.client_id == ^partition.client_id and row.scope == ^partition.scope and
            row.namespace == ^partition.namespace
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
               partition,
               "repair-operator"
             )

    assert [%ActivityDaily{event_count: 1}] =
             repo().all(from(row in ActivityDaily, where: row.host_id == ^partition.host_id))

    assert [%ActivityDaily{event_count: 9}] =
             repo().all(from(row in ActivityDaily, where: row.host_id == "foreign-repair-host"))
  end

  test "processing diagnosis counts only the exact partition and exposes no content", %{
    partition: partition
  } do
    assert {:ok, _owned} =
             Memories.remember("owned diagnosis content",
               agent_id: "repair-agent",
               memory_space_id: partition.memory_space_id,
               host_id: partition.host_id,
               client_id: partition.client_id,
               source_client_id: partition.source_client_id,
               scope: partition.scope,
               namespace: partition.namespace,
               idempotency_scope: "repair-health",
               idempotency_key: "owned"
             )

    foreign =
      canonical_partition("foreign-health-host",
        client_id: partition.client_id,
        scope: partition.scope
      )

    assert {:ok, _foreign} =
             Memories.remember("foreign diagnosis content",
               agent_id: "repair-agent",
               memory_space_id: foreign.memory_space_id,
               host_id: foreign.host_id,
               client_id: foreign.client_id,
               source_client_id: foreign.source_client_id,
               scope: foreign.scope,
               namespace: foreign.namespace,
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
           } = Health.snapshot(partition)
  end

  test "dead-letter repair retries complete flat and nested identities once with bounded audit",
       %{
         partition: partition
       } do
    Styx.Testing.with_testing_mode(:manual, fn ->
      identity = job_partition(partition)

      jobs = [
        insert_dead_letter(Map.put(identity, "private_payload", "do-not-audit")),
        insert_dead_letter(%{"partition" => identity, "memory_id" => Ecto.UUID.generate()}),
        insert_dead_letter(%{"partition" => identity}, state: "cancelled")
      ]

      args = %{"kind" => "dead_letter", "idempotency_key" => "retry-exact-identities"}

      assert {:ok, %{status: "dispatched", affected: 3}} =
               Repair.run(args, partition, "operator")

      for job <- jobs do
        retried = repo().get!(Styx.Job, job.id)
        assert retried.state == "available"
        assert retried.args == job.args
        assert retried.max_attempts == 4
      end

      assert {:ok, %{status: "already_applied", affected: 3}} =
               Repair.run(args, partition, "operator")

      assert [%{metadata: metadata, target_ids: target_ids}] =
               Audit.list(operation: "memory.repair")

      assert metadata["memory_space_id"] == partition.memory_space_id
      assert metadata["bounded"] == true
      assert Enum.sort(target_ids) == Enum.sort(Enum.map(jobs, &to_string(&1.id)))
      refute inspect(metadata) =~ "do-not-audit"
    end)
  end

  test "dead-letter repair rejects partial, hybrid, conflicting and foreign partition jobs", %{
    partition: partition
  } do
    Styx.Testing.with_testing_mode(:manual, fn ->
      identity = job_partition(partition)

      invalid_identities =
        for key <- Map.keys(identity),
            invalid <- [nil, 123, "foreign", ""],
            do: Map.put(identity, key, invalid)

      invalid_identities =
        invalid_identities ++ Enum.map(Map.keys(identity), &Map.delete(identity, &1))

      invalid_args =
        Enum.flat_map(invalid_identities, &[&1, %{"partition" => &1}]) ++
          [
            %{"partition" => nil},
            %{"partition" => "invalid"},
            %{"partition" => [identity]},
            Map.put(identity, "partition", nil),
            Map.put(identity, "partition", identity),
            Map.put(identity, "partition", Map.put(identity, "host_id", "foreign")),
            %{"partition" => identity, "host_id" => identity["host_id"]},
            %{"partition" => identity, "memory_space_id" => Ecto.UUID.generate()},
            Map.put(Map.delete(identity, "memory_space_id"), "partition", %{
              "memory_space_id" => identity["memory_space_id"]
            })
          ]

      jobs = Enum.map(invalid_args, &insert_dead_letter/1)
      jobs = jobs ++ [insert_dead_letter(identity, queue: "default")]

      jobs =
        jobs ++
          Enum.map(~w(available executing completed scheduled retryable), fn state ->
            insert_dead_letter(identity, state: state)
          end)

      snapshots = Map.new(jobs, &{&1.id, repo().get!(Styx.Job, &1.id)})

      assert {:ok, %{status: "dispatched", affected: 0}} =
               Repair.run(
                 %{"kind" => "dead_letter", "idempotency_key" => "reject-ambiguous-partitions"},
                 partition,
                 "operator"
               )

      for {id, unchanged} <- snapshots, do: assert(repo().get!(Styx.Job, id) == unchanged)
    end)
  end

  test "dead-letter repair leaves governed memory jobs unchanged without interpreting unrelated IDs",
       %{
         partition: partition
       } do
    Styx.Testing.with_testing_mode(:manual, fn ->
      {:ok, memory} =
        Memories.remember(
          "Governed retry target",
          canonical_memory_opts(partition.host_id,
            client_id: partition.client_id,
            scope: partition.scope,
            agent_id: "repair-agent"
          )
        )

      assert :ok = Memories.tombstone(memory.id, partition)
      identity = job_partition(partition)

      embedding =
        insert_dead_letter(Map.put(identity, "id", memory.id),
          state: "cancelled",
          worker: Backplane.Memory.Workers.EmbedWorker
        )

      classifier = insert_dead_letter(%{"partition" => identity, "memory_id" => memory.id})

      unrelated =
        insert_dead_letter(Map.put(identity, "id", memory.id),
          worker: Backplane.Memory.Workers.SummaryWorker
        )

      assert {:ok, %{affected: 1}} =
               Repair.run(
                 %{"kind" => "dead_letter", "idempotency_key" => "governed-retries"},
                 partition,
                 "operator"
               )

      assert repo().get!(Styx.Job, embedding.id) == embedding
      assert repo().get!(Styx.Job, classifier.id) == classifier
      assert repo().get!(Styx.Job, unrelated.id).state == "available"
      assert [%{target_ids: ids}] = Audit.list(operation: "memory.repair")
      assert ids == [to_string(unrelated.id)]
    end)
  end

  test "dead-letter repair keeps the 100-job bound and deterministic target order", %{
    partition: partition
  } do
    Styx.Testing.with_testing_mode(:manual, fn ->
      jobs = for _ <- 1..102, do: insert_dead_letter(%{"partition" => job_partition(partition)})
      args = %{"kind" => "dead_letter", "idempotency_key" => "bounded-dead-letters"}

      assert {:ok, %{status: "dispatched", affected: 100}} =
               Repair.run(args, partition, "operator")

      for job <- Enum.take(jobs, 100),
          do: assert(repo().get!(Styx.Job, job.id).state == "available")

      for job <- Enum.drop(jobs, 100),
          do: assert(repo().get!(Styx.Job, job.id).state == "discarded")

      assert [%{target_ids: ids}] = Audit.list(operation: "memory.repair")
      assert ids == jobs |> Enum.take(100) |> Enum.map(&to_string(&1.id))

      assert {:ok, %{status: "already_applied", affected: 100}} =
               Repair.run(args, partition, "operator")

      for job <- Enum.drop(jobs, 100),
          do: assert(repo().get!(Styx.Job, job.id).state == "discarded")
    end)
  end

  test "explicit job IDs select newer jobs without touching older failures and replay as a set",
       %{partition: partition} do
    Styx.Testing.with_testing_mode(:manual, fn ->
      identity = job_partition(partition)
      older = for _ <- 1..101, do: insert_dead_letter(identity)
      selected = for _ <- 1..2, do: insert_dead_letter(%{"partition" => identity})
      ids = Enum.map(selected, & &1.id)

      args = %{
        "kind" => "dead_letter",
        "idempotency_key" => "selected-newer",
        "job_ids" => Enum.reverse(ids)
      }

      assert {:ok, %{status: "dispatched", affected: 2}} = Repair.run(args, partition, "operator")
      for job <- older, do: assert(repo().get!(Styx.Job, job.id) == job)

      for job <- selected do
        current = repo().get!(Styx.Job, job.id)
        assert current.state == "available"
        assert current.max_attempts == 4
        assert current.args == job.args
      end

      assert [%{target_ids: targets}] = Audit.list(operation: "memory.repair")
      assert targets == Enum.map(ids, &to_string/1)

      assert {:ok, %{status: "already_applied", affected: 2}} =
               Repair.run(Map.put(args, "job_ids", ids), partition, "operator")

      assert {:error, :idempotency_conflict} =
               Repair.run(Map.put(args, "job_ids", [hd(older).id]), partition, "operator")

      for job <- older, do: assert(repo().get!(Styx.Job, job.id) == job)
    end)
  end

  test "explicit selection rejects any ineligible job without partial retries", %{
    partition: partition
  } do
    Styx.Testing.with_testing_mode(:manual, fn ->
      identity = job_partition(partition)
      valid = insert_dead_letter(identity)

      {:ok, memory} =
        Memories.remember(
          "governed explicit retry",
          canonical_memory_opts(partition.host_id,
            client_id: partition.client_id,
            scope: partition.scope,
            agent_id: "repair-agent"
          )
        )

      assert :ok = Memories.tombstone(memory.id, partition)

      invalid = [
        insert_dead_letter(Map.put(identity, "memory_space_id", Ecto.UUID.generate())),
        insert_dead_letter(Map.delete(identity, "host_id")),
        insert_dead_letter(identity, queue: "default"),
        insert_dead_letter(identity, state: "executing"),
        insert_dead_letter(%{"partition" => identity, "memory_id" => memory.id}),
        insert_dead_letter(Map.put(identity, "id", memory.id),
          worker: Backplane.Memory.Workers.EmbedWorker
        )
      ]

      for {id, index} <-
            Enum.with_index(Enum.map(invalid, & &1.id) ++ [9_223_372_036_854_775_807]) do
        assert {:error, :target_mismatch} =
                 Repair.run(
                   %{
                     "kind" => "dead_letter",
                     "job_ids" => [valid.id, id],
                     "idempotency_key" => "reject-selected-#{index}"
                   },
                   partition,
                   "operator"
                 )

        for job <- [valid | invalid], do: assert(repo().get!(Styx.Job, job.id) == job)
      end

      assert Enum.all?(
               Audit.list(operation: "memory.repair"),
               &(&1.metadata["result"] == "failed")
             )
    end)
  end

  test "job ID selector rejects invalid shapes bounds duplicates kinds and ambiguity", %{
    partition: partition
  } do
    Styx.Testing.with_testing_mode(:manual, fn ->
      job = insert_dead_letter(job_partition(partition))
      base = %{"kind" => "dead_letter", "idempotency_key" => "invalid-selection"}

      values = [
        nil,
        [],
        "1",
        1,
        %{},
        [0],
        [-1],
        [1.0],
        [true],
        ["1"],
        [9_223_372_036_854_775_808],
        [job.id, job.id],
        Enum.to_list(1..101)
      ]

      for value <- values do
        assert {:error, :invalid_arguments} =
                 Repair.run(Map.put(base, "job_ids", value), partition, "operator")
      end

      assert {:error, :invalid_arguments} =
               Repair.run(
                 Map.merge(base, %{"job_ids" => [job.id], "kind" => "coordination"}),
                 partition,
                 "operator"
               )

      assert {:error, :invalid_arguments} =
               Repair.run(
                 Map.merge(base, %{"job_ids" => [job.id], "target_id" => "another-target"}),
                 partition,
                 "operator"
               )

      assert repo().get!(Styx.Job, job.id) == job
      assert Audit.list(operation: "memory.repair") == []
    end)
  end

  defp job_partition(partition) do
    Map.new(~w(memory_space_id host_id client_id scope namespace)a, fn key ->
      {Atom.to_string(key), Map.fetch!(partition, key)}
    end)
  end

  defp insert_dead_letter(args, opts \\ []) do
    args
    |> Backplane.Memory.Workers.RelationClassifierWorker.new()
    |> Ecto.Changeset.change(%{
      state: Keyword.get(opts, :state, "discarded"),
      queue: Keyword.get(opts, :queue, "memory_relation_classifier"),
      worker:
        inspect(Keyword.get(opts, :worker, Backplane.Memory.Workers.RelationClassifierWorker)),
      attempt: 3,
      max_attempts: 3
    })
    |> repo().insert!()
    |> repo().reload!()
  end

  defp append_activity_event!(partition, session_id, project) do
    suffix = System.unique_integer([:positive])

    assert {:ok, {:inserted, _event}} =
             Store.append_tagged(%{
               id: Ecto.UUID.generate(),
               stream_id: "capture:#{partition.host_id}:#{session_id}",
               memory_space_id: partition.memory_space_id,
               host_id: partition.host_id,
               client_id: partition.client_id,
               source_client_id: partition.source_client_id,
               scope: partition.scope,
               namespace: partition.namespace,
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
