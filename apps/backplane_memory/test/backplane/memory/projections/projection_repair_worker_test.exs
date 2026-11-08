defmodule Backplane.Memory.Projections.ProjectionRepairWorkerTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query
  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Events.{Event, Store}
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Ingest.{EventValidator, Upcaster}

  alias Backplane.Memory.Projections.{
    ProjectedObservation,
    ProjectedSession,
    Rebuild,
    RepairFrontier,
    Snapshot,
    Source,
    State
  }

  alias Backplane.Memory.Workers.ProjectionRepairWorker

  test "a captured session closes on SessionEnd and audits provenance without summary jobs" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      host_id = unique("closed-host")
      session_id = unique("closed-session")

      assert accepted(captured_event(host_id, session_id, 1, "agent.session.started"))

      %{"server_event_id" => end_event_id} =
        accepted(captured_event(host_id, session_id, 2, "agent.session.ended"))

      assert :ok = ProjectionRepairWorker.perform(%Styx.Job{args: %{"event_id" => end_event_id}})

      assert %ProjectedSession{status: "completed"} =
               repo().get_by!(ProjectedSession, host_id: host_id, session_id: session_id)

      assert %{metadata: metadata} =
               Enum.find(Audit.list(operation: "projection.repair"), fn audit ->
                 audit.target_ids == [end_event_id]
               end)

      assert metadata["host_id"] == host_id
      assert metadata["client_id"] == "codex-cli"
      assert metadata["source_client_id"] == "codex-cli"
      assert metadata["session_id"] == session_id

      for key <- ~w(memory_space_id scope namespace) do
        refute Map.has_key?(metadata, key)
      end

      assert %{success: 1, failure: 0} = Styx.drain_queue(queue: :memory)

      assert [] = Styx.Testing.all_enqueued(repo(), [])

      assert Enum.all?(states(Source.subject_id!(host_id, session_id)), fn state ->
               state.projector in ["observations", "session"] and state.status == "complete"
             end)
    end)
  end

  setup do
    previous_enabled = Application.get_env(:backplane_memory, :projection_repair_enabled)
    previous_enqueue = Application.get_env(:backplane_memory, :projection_repair_enqueue)

    Application.put_env(:backplane_memory, :projection_repair_enabled, true)

    on_exit(fn ->
      restore_env(:projection_repair_enabled, previous_enabled)
      restore_env(:projection_repair_enqueue, previous_enqueue)
    end)

    :ok
  end

  test "a late canonical event automatically repairs only its captured session" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      repaired_session = unique("repaired")
      unrelated_session = unique("unrelated")

      first = captured_event("host-repair", repaired_session, 1, "agent.session.started")
      third = captured_event("host-repair", repaired_session, 3, "agent.session.ended")

      assert accepted(first)
      assert accepted(third)

      assert [repair_job] = Styx.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

      assert repair_job.args == %{
               "host_id" => "host-repair",
               "session_id" => repaired_session
             }

      assert %{success: 1, failure: 0} = Styx.drain_queue(queue: :memory)

      repaired_subject = Source.subject_id!("host-repair", repaired_session)

      assert %{
               "session" => %{read_model: %{"gaps" => [%{"from" => 2, "to" => 2}]}},
               "observations" => %{read_model: %{"observations" => observations}}
             } = snapshots(repaired_subject)

      assert [_first, _third] = observations

      assert [_, _] = pending_states = states(repaired_subject)
      initial_revision = hd(pending_states).input_revision

      assert Enum.all?(pending_states, fn state ->
               state.status == "pending"
             end)

      # Repair is the only durable successor of capture; nothing summarizes.
      assert_memory_jobs([])

      assert accepted(captured_event("host-other", unrelated_session, 1, "agent.session.started"))
      assert_memory_jobs([ProjectionRepairWorker])
      assert %{success: 1, failure: 0} = Styx.drain_queue(queue: :memory)

      unrelated_subject = Source.subject_id!("host-other", unrelated_session)
      unrelated_before = projection_rows(unrelated_subject)

      late =
        captured_event("host-repair", repaired_session, 2, "agent.tool.completed", %{
          "source" => %{"tool_name" => "Read", "tool_response" => "ok"}
        })

      assert accepted(late)
      assert [_late_job] = Styx.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)
      assert_memory_jobs([ProjectionRepairWorker])
      assert %{success: 1, failure: 0} = Styx.drain_queue(queue: :memory)

      assert %{
               "session" => %{read_model: %{"gaps" => [], "counts" => %{"events" => 3}}},
               "observations" => %{read_model: %{"observations" => repaired_observations}}
             } = snapshots(repaired_subject)

      assert [_first, _second, _third] = repaired_observations

      assert [_, _] = repaired_states = states(repaired_subject)

      assert {:ok, %{input_revision: repaired_revision}} =
               Source.input_revision("host-repair", repaired_session)

      refute repaired_revision == initial_revision
      assert Enum.all?(repaired_states, &(&1.input_revision == repaired_revision))

      assert Enum.all?(repaired_states, fn
               %{projector: projector, status: "complete"}
               when projector in ["observations", "session"] ->
                 true

               _state ->
                 false
             end)

      assert projection_rows(unrelated_subject) == unrelated_before

      repaired_before_duplicate = projection_rows(repaired_subject)
      assert duplicate(late)
      assert [] = Styx.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)
      assert projection_rows(repaired_subject) == repaired_before_duplicate
    end)
  end

  test "legacy events do not enqueue projection repair" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _legacy} =
               Store.append(%{
                 stream_id: "legacy-#{Ecto.UUID.generate()}",
                 event_type: "conversation.user_message",
                 host_id: "legacy-host",
                 session_id: "legacy-session",
                 content: "legacy"
               })

      assert [] = Styx.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)
    end)
  end

  test "an event arriving during repair creates one successor and both executions converge" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      host_id = unique("concurrent-host")
      session_id = unique("concurrent-session")

      assert accepted(captured_event(host_id, session_id, 1, "agent.session.started"))

      assert [%Styx.Job{id: running_job_id, args: running_args}] =
               Styx.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

      repo().update_all(from(job in Styx.Job, where: job.id == ^running_job_id),
        set: [state: "executing", attempted_at: DateTime.utc_now(), attempt: 1]
      )

      %RepairFrontier{requested_revision: first_revision} =
        RepairFrontier.get(repo(), host_id, session_id)

      parent = self()

      repair_task =
        Task.async(fn ->
          receive do
            :run ->
              ProjectionRepairWorker.perform(
                %Styx.Job{args: running_args},
                fn ^host_id, ^session_id ->
                  send(parent, :repair_running)

                  receive do
                    :release_repair ->
                      {:ok, %{input_revision: ^first_revision}} =
                        Rebuild.session_locked(host_id, session_id)
                  end
                end
              )
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(repo(), self(), repair_task.pid)
      send(repair_task.pid, :run)
      assert_receive :repair_running, 5_000

      ingest_task =
        Task.async(fn ->
          receive do
            :run ->
              Styx.Testing.with_testing_mode(:manual, fn ->
                accepted(captured_event(host_id, session_id, 2, "agent.prompt.submitted"))
              end)
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(repo(), self(), ingest_task.pid)
      send(ingest_task.pid, :run)
      assert Task.yield(ingest_task, 100) == nil

      send(repair_task.pid, :release_repair)
      assert :ok = Task.await(repair_task, 5_000)
      assert %{"status" => "accepted"} = Task.await(ingest_task, 5_000)

      assert [%Styx.Job{id: successor_id, args: successor_args}] =
               Styx.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

      refute successor_id == running_job_id

      assert [["available"], ["executing"]] =
               repo().query!(
                 """
                 SELECT state FROM styx_jobs
                 WHERE id IN ($1, $2)
                 ORDER BY state
                 """,
                 [running_job_id, successor_id]
               ).rows

      repo().update_all(from(job in Styx.Job, where: job.id == ^running_job_id),
        set: [state: "completed", completed_at: DateTime.utc_now()]
      )

      assert :ok = ProjectionRepairWorker.perform(%Styx.Job{args: successor_args})

      repo().update_all(from(job in Styx.Job, where: job.id == ^successor_id),
        set: [state: "completed", completed_at: DateTime.utc_now()]
      )

      assert %RepairFrontier{requested_generation: 2, completed_generation: 2} =
               RepairFrontier.get(repo(), host_id, session_id)

      assert [] = Styx.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)
    end)
  end

  @tag timeout: 180_000
  test "Scenario J: 10,000 accepted events coalesce to one pending projection repair job" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      host_id = "scale-host-#{Ecto.UUID.generate()}"
      session_id = "scale-session-#{Ecto.UUID.generate()}"
      auth = ingest_auth_context(host_id)

      assert accepted(captured_event(host_id, session_id, 1, "agent.session.started"))

      2..10_000
      |> Enum.chunk_every(100)
      |> Enum.with_index(2)
      |> Enum.each(fn {sequences, batch_generation} ->
        events =
          Enum.map(sequences, fn sequence ->
            occurred_at = DateTime.add(~U[2026-08-04 01:00:00Z], sequence, :second)

            valid_event(%{
              "event_id" => Ecto.UUID.generate(),
              "host_id" => host_id,
              "session_id" => session_id,
              "sequence" => sequence,
              "occurred_at" => DateTime.to_iso8601(occurred_at),
              "captured_at" => DateTime.to_iso8601(occurred_at),
              "idempotency_key" => "#{host_id}:#{session_id}:#{sequence}"
            })
          end)

        assert {:ok, %{"results" => results}} =
                 Ingest.ingest_batch(auth, %{
                   "batch_id" => Ecto.UUID.generate(),
                   "host_id" => host_id,
                   "events" => events
                 })

        assert length(results) == length(sequences)
        assert Enum.all?(results, &(&1["status"] == "accepted"))

        assert %RepairFrontier{requested_generation: ^batch_generation} =
                 RepairFrontier.get(repo(), host_id, session_id)
      end)

      assert [%Styx.Job{args: %{"host_id" => ^host_id, "session_id" => ^session_id}}] =
               Styx.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

      assert %RepairFrontier{
               requested_generation: 101,
               completed_generation: 0,
               requested_revision: revision
             } = RepairFrontier.get(repo(), host_id, session_id)

      assert revision =~ ~r/^[0-9a-f]{64}$/

      job = %Styx.Job{args: %{"host_id" => host_id, "session_id" => session_id}}

      assert :ok = ProjectionRepairWorker.perform(job, &Rebuild.session_locked/2)

      subject_id = Source.subject_id!(host_id, session_id)
      projected = repo().get!(ProjectedSession, subject_id)
      assert projected.input_revision == revision
      assert projected.source_sequence_max == 10_000

      stable_rows = persisted_row_fingerprints(subject_id)
      assert length(stable_rows.observations) == 10_000

      stable_projection =
        Map.take(projected, [:input_revision, :source_sequence_max, :status, :client_id])

      assert {:ok, %{input_revision: ^revision}} = Rebuild.session(host_id, session_id)

      assert Map.take(repo().get!(ProjectedSession, subject_id), Map.keys(stable_projection)) ==
               stable_projection

      assert persisted_row_fingerprints(subject_id) == stable_rows

      assert %RepairFrontier{
               requested_generation: 101,
               inflight_generation: 101,
               completed_generation: 101,
               requested_revision: ^revision,
               completed_revision: ^revision
             } = RepairFrontier.get(repo(), host_id, session_id)

      assert [%Styx.Job{args: %{"host_id" => ^host_id, "session_id" => ^session_id}}] =
               Styx.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

      IO.puts(
        "Scenario J projection scheduling: events=10000 generations=101 pending_jobs=1 completed_generation=101"
      )
    end)
  end

  test "frontier generations order work without ordering opaque revision hashes" do
    host_id = unique("opaque-host")
    session_id = unique("opaque-session")

    assert %RepairFrontier{requested_generation: 1, requested_revision: "ffff"} =
             RepairFrontier.advance(repo(), host_id, session_id, "ffff")

    assert %RepairFrontier{requested_generation: 2, requested_revision: "0000"} =
             RepairFrontier.advance(repo(), host_id, session_id, "0000")
  end

  test "one accepted store batch advances a session frontier exactly once" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      host_id = unique("batch-frontier-host")
      session_id = unique("batch-frontier-session")
      auth = ingest_auth_context(host_id)

      attrs =
        Enum.map(1..2, fn sequence ->
          raw = captured_event(host_id, session_id, sequence, "agent.prompt.submitted")
          {:ok, validated} = EventValidator.validate(raw)
          {:ok, attrs} = Upcaster.V1.upcast(validated, auth)
          attrs
        end)

      assert {:ok, [{:inserted, _}, {:inserted, _}]} = Store.append_batch_tagged(attrs)

      assert %RepairFrontier{requested_generation: 1} =
               RepairFrontier.get(repo(), host_id, session_id)

      assert [_job] = Styx.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)
    end)
  end

  test "a revision mismatch marks work stale and a later attempt repairs the authoritative revision" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      host_id = unique("stale-host")
      session_id = unique("stale-session")

      assert accepted(captured_event(host_id, session_id, 1, "agent.session.started"))
      frontier = RepairFrontier.get(repo(), host_id, session_id)
      RepairFrontier.replace_requested_revision(repo(), frontier, String.duplicate("f", 64))

      job = %Styx.Job{args: %{"host_id" => host_id, "session_id" => session_id}}

      assert :ok = ProjectionRepairWorker.perform(job)

      assert [_successor] =
               Styx.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

      assert %RepairFrontier{
               requested_generation: 1,
               completed_generation: 0,
               requested_revision: authoritative_revision
             } = RepairFrontier.get(repo(), host_id, session_id)

      refute authoritative_revision == String.duplicate("f", 64)

      assert :ok =
               ProjectionRepairWorker.perform(
                 job,
                 &Backplane.Memory.Projections.Rebuild.session_locked/2
               )

      assert %RepairFrontier{
               completed_generation: 1,
               completed_revision: ^authoritative_revision
             } = RepairFrontier.get(repo(), host_id, session_id)

      assert {:ok, :already_complete} =
               ProjectionRepairWorker.perform(
                 job,
                 fn _, _ -> flunk("a completed successor must not rebuild") end
               )
    end)
  end

  test "worker trusts the durable event identity and surfaces failures for retry" do
    Styx.Testing.with_testing_mode(:manual, fn ->
      event =
        captured_event("trusted-host", unique("trusted-session"), 1, "agent.session.started")

      assert %{"server_event_id" => event_id} = accepted(event)

      job = %Styx.Job{
        args: %{
          "event_id" => event_id,
          "host_id" => "attacker-host",
          "session_id" => "attacker-session"
        }
      }

      owner = self()

      rebuild = fn host_id, session_id ->
        send(owner, {:rebuild_subject, host_id, session_id})
        {:error, :database_unavailable}
      end

      assert {:error, :database_unavailable} = ProjectionRepairWorker.perform(job, rebuild)
      assert_received {:rebuild_subject, "trusted-host", trusted_session}
      assert trusted_session == event["session_id"]

      assert {:error, :not_found} =
               ProjectionRepairWorker.perform(job, fn _host_id, _session_id ->
                 {:error, :not_found}
               end)

      assert_raise RuntimeError, "projection crashed", fn ->
        ProjectionRepairWorker.perform(job, fn _host_id, _session_id ->
          raise "projection crashed"
        end)
      end
    end)
  end

  test "worker treats missing events as successful no-ops and cancels malformed args" do
    assert :ok =
             ProjectionRepairWorker.perform(%Styx.Job{
               args: %{"event_id" => Ecto.UUID.generate()}
             })

    assert {:cancel, :invalid_arguments} =
             ProjectionRepairWorker.perform(%Styx.Job{args: %{}})

    assert {:cancel, :invalid_arguments} =
             ProjectionRepairWorker.perform(%Styx.Job{args: %{"event_id" => "  "}})
  end

  test "locked rebuild entrypoint rejects callers without a transaction" do
    assert {:error, :transaction_required} =
             Backplane.Memory.Projections.Rebuild.session_locked("host", "session")
  end

  test "a retryable inline worker result cannot masquerade as a durable repair job" do
    Application.put_env(:backplane_memory, :projection_repair_enqueue, fn _event_id ->
      {:ok, %Styx.Job{state: "retryable"}}
    end)

    event = captured_event("host-inline", unique("inline"), 1, "agent.session.started")

    assert {:ok,
            %{
              "results" => [
                %{
                  "status" => "failed",
                  "retryable" => true,
                  "reason" => "transaction_rolled_back"
                }
              ]
            }} = ingest(event)

    refute repo().get(Event, event["event_id"])
    refute RepairFrontier.get(repo(), event["host_id"], event["session_id"])

    refute repo().exists?(
             from(job in Styx.Job,
               where:
                 job.worker == "Backplane.Memory.Workers.ProjectionRepairWorker" and
                   fragment("?->>'host_id'", job.args) == ^event["host_id"] and
                   fragment("?->>'session_id'", job.args) == ^event["session_id"]
             )
           )
  end

  defp captured_event(host_id, session_id, sequence, event_type, payload \\ %{}) do
    valid_event(%{
      "event_id" => Ecto.UUID.generate(),
      "host_id" => host_id,
      "session_id" => session_id,
      "sequence" => sequence,
      "event_type" => event_type,
      "occurred_at" => "2026-08-04T01:0#{sequence}:00.000Z",
      "idempotency_key" => "#{host_id}:#{session_id}:#{sequence}:#{event_type}",
      "payload" => payload
    })
  end

  defp accepted(event) do
    assert {:ok, %{"results" => [result]}} = ingest(event)
    assert result["status"] == "accepted", inspect(result)
    result
  end

  defp duplicate(event) do
    assert {:ok, %{"results" => [result]}} = ingest(event)
    assert result["status"] == "duplicate"
    result
  end

  defp ingest(event) do
    Ingest.ingest_batch(
      ingest_auth_context(event["host_id"]),
      %{
        "batch_id" => Ecto.UUID.generate(),
        "host_id" => event["host_id"],
        "events" => [event]
      }
    )
  end

  defp snapshots(subject_id) do
    repo().all(from(snapshot in Snapshot, where: snapshot.subject_id == ^subject_id))
    |> Map.new(&{&1.projector, &1})
  end

  defp states(subject_id) do
    repo().all(from(state in State, where: state.subject_id == ^subject_id))
  end

  defp projection_rows(subject_id) do
    %{
      states:
        repo().all(
          from(state in State,
            where: state.subject_id == ^subject_id,
            order_by: [asc: state.projector],
            select: {
              state.projector,
              state.processing_version,
              state.status,
              state.attempt_count,
              state.input_revision,
              state.output_revision,
              state.last_error
            }
          )
        ),
      snapshots:
        repo().all(
          from(snapshot in Snapshot,
            where: snapshot.subject_id == ^subject_id,
            order_by: [asc: snapshot.projector],
            select: {
              snapshot.projector,
              snapshot.input_revision,
              snapshot.output_revision,
              snapshot.read_model
            }
          )
        )
    }
  end

  defp persisted_row_fingerprints(subject_id) do
    %{
      observations:
        repo().all(
          from(row in ProjectedObservation,
            where: row.subject_id == ^subject_id,
            order_by: [asc: row.source_sequence, asc: row.event_id]
          )
        )
        |> Enum.map(&semantic_row/1)
    }
  end

  defp semantic_row(row) do
    row
    |> Map.from_struct()
    |> Map.drop([:__meta__, :inserted_at, :updated_at])
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp restore_env(key, nil), do: Application.delete_env(:backplane_memory, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_memory, key, value)

  defp assert_memory_jobs(workers) do
    actual = Styx.Testing.all_enqueued(repo(), queue: :memory)
    assert Enum.sort(Enum.map(actual, & &1.worker)) == Enum.sort(Enum.map(workers, &inspect/1))
  end
end

defmodule Backplane.Memory.Projections.ProjectionRepairCommitTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.Events.{Event, Stream}
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Projections.RepairFrontier
  alias Ecto.Adapters.SQL.Sandbox

  test "a caller crash after commit but before ACK retains one event and durable repair on retry" do
    host_id = "committed-capture-#{Ecto.UUID.generate()}"
    session_id = "session-#{Ecto.UUID.generate()}"

    event =
      valid_event(%{
        "host_id" => host_id,
        "session_id" => session_id,
        "idempotency_key" => "#{host_id}:#{session_id}:1"
      })

    batch = %{"batch_id" => Ecto.UUID.generate(), "host_id" => host_id, "events" => [event]}
    previous_enabled = Application.get_env(:backplane_memory, :projection_repair_enabled)
    previous_enqueue = Application.get_env(:backplane_memory, :projection_repair_enqueue)
    Application.put_env(:backplane_memory, :projection_repair_enabled, true)
    Application.delete_env(:backplane_memory, :projection_repair_enqueue)

    on_exit(fn ->
      for {key, value} <- [
            projection_repair_enabled: previous_enabled,
            projection_repair_enqueue: previous_enqueue
          ] do
        if is_nil(value),
          do: Application.delete_env(:backplane_memory, key),
          else: Application.put_env(:backplane_memory, key, value)
      end

      # These connections really commit; remove only this test's generated rows.
      Sandbox.unboxed_run(repo(), fn ->
        repo().transaction(fn ->
          # Captured events are immutable; match the existing committed-event test cleanup.
          repo().query!("SET LOCAL session_replication_role = replica")
          repo().delete_all(repair_jobs(host_id, session_id))

          repo().delete_all(
            from(row in RepairFrontier,
              where: row.host_id == ^host_id and row.session_id == ^session_id
            )
          )

          repo().delete_all(
            from(row in Event, where: row.id == ^event["event_id"] and row.host_id == ^host_id)
          )

          repo().delete_all(from(row in Stream, where: row.host_id == ^host_id))
        end)
      end)
    end)

    owner = self()
    barrier = make_ref()

    {caller, monitor} =
      spawn_monitor(fn ->
        Sandbox.unboxed_run(repo(), fn ->
          auth = ingest_auth_context(host_id)

          Styx.Testing.with_testing_mode(:manual, fn ->
            assert {:ok,
                    %{
                      "results" => [
                        %{"status" => "accepted", "server_event_id" => event_id}
                      ]
                    }} = Ingest.ingest_batch(auth, batch)

            refute repo().in_transaction?()
            [[backend]] = repo().query!("SELECT pg_backend_pid()").rows
            send(owner, {:committed_without_ack, barrier, event_id, backend})

            receive do
              {:release_ack, ^barrier} -> send(owner, {:ack_delivered, barrier})
            after
              10_000 -> exit(:ack_barrier_timeout)
            end
          end)
        end)
      end)

    on_exit(fn ->
      shutdown = Process.monitor(caller)
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      assert_receive {:DOWN, ^shutdown, :process, ^caller, _}, 5_000
    end)

    assert_receive {:committed_without_ack, ^barrier, event_id, writer_backend}, 5_000
    assert event_id == event["event_id"]

    {frontier, job_id} =
      Sandbox.unboxed_run(repo(), fn ->
        [[reader_backend]] = repo().query!("SELECT pg_backend_pid()").rows
        refute reader_backend == writer_backend
        assert %Event{id: ^event_id} = repo().get(Event, event_id)

        assert %RepairFrontier{requested_generation: 1, completed_generation: 0} =
                 frontier =
                 RepairFrontier.get(repo(), host_id, session_id)

        assert [%Styx.Job{id: job_id, state: "available"}] =
                 repo().all(repair_jobs(host_id, session_id))

        {frontier, job_id}
      end)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 5_000
    refute_received {:ack_delivered, ^barrier}

    Sandbox.unboxed_run(repo(), fn ->
      Styx.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{"results" => [%{"status" => "duplicate", "server_event_id" => ^event_id}]}} =
                 Ingest.ingest_batch(ingest_auth_context(host_id), batch)
      end)

      assert repo().aggregate(from(row in Event, where: row.host_id == ^host_id), :count) == 1
      assert RepairFrontier.get(repo(), host_id, session_id) == frontier

      assert [%Styx.Job{id: ^job_id, state: "available"}] =
               repo().all(repair_jobs(host_id, session_id))
    end)
  end

  defp repair_jobs(host_id, session_id) do
    from(job in Styx.Job,
      where:
        job.worker == "Backplane.Memory.Workers.ProjectionRepairWorker" and
          fragment("?->>'host_id'", job.args) == ^host_id and
          fragment("?->>'session_id'", job.args) == ^session_id
    )
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
