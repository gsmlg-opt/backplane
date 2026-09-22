defmodule Backplane.Memory.Projections.ProjectionRepairWorkerTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query
  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Events.{Event, Store}
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Ingest.{EventValidator, Upcaster}
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.Evidence
  alias Backplane.Memory.Replay.Event, as: ReplayEvent

  alias Backplane.Memory.Projections.{
    ProjectedObservation,
    ProjectedSession,
    Rebuild,
    RepairFrontier,
    Snapshot,
    Source,
    State
  }

  alias Backplane.Memory.Workers.{LessonCandidateWorker, ProjectionRepairWorker}

  test "enqueues a revisioned canonical summary for closed projections after grace" do
    %{"server_event_id" => event_id} =
      accepted(captured_event("summary-host", "summary-session", 1, "agent.session.started"))

    owner = self()

    enqueue = fn host_id, session_id, input_revision ->
      send(owner, {:summary_enqueued, host_id, session_id, input_revision})
      {:ok, %Oban.Job{state: "available"}}
    end

    complete = fn _host_id, _session_id ->
      {:ok,
       %{
         input_revision: "revision-1",
         gaps: [],
         session_status: "completed",
         last_event_at: ~U[2026-08-04 01:00:00.000000Z],
         states: %{"session" => %{status: "complete"}}
       }}
    end

    job = %Oban.Job{args: %{"event_id" => event_id}}
    assert :ok = ProjectionRepairWorker.perform(job, complete, enqueue)
    assert_received {:summary_enqueued, "summary-host", "summary-session", "revision-1"}

    assert %{metadata: metadata} =
             Enum.find(Audit.list(operation: "projection.repair"), fn audit ->
               audit.target_ids == [event_id]
             end)

    assert metadata["host_id"] == "summary-host"
    assert metadata["memory_space_id"] == memory_space_id("summary-host")
    assert metadata["client_id"] == "host:summary-host"
    assert metadata["source_client_id"] == "codex-cli"
    assert metadata["scope"] == "project:backplane"
    assert metadata["namespace"] == "private"
    assert metadata["session_id"] == "summary-session"

    expired_gap = %{
      input_revision: "gap-revision",
      gaps: [%{"from" => 2, "to" => 2}],
      session_status: "completed",
      last_event_at: ~U[2026-08-04 01:00:00.000000Z],
      states: %{"session" => %{status: "pending"}}
    }

    assert :ok =
             ProjectionRepairWorker.perform(job, fn _, _ -> {:ok, expired_gap} end, enqueue)

    assert_received {:summary_enqueued, "summary-host", "summary-session", "gap-revision"}

    for result <- [
          %{
            input_revision: "r",
            gaps: [%{"from" => 2, "to" => 2}],
            session_status: "completed",
            last_event_at: DateTime.utc_now(),
            states: %{"session" => %{status: "pending"}}
          },
          %{
            input_revision: "r",
            gaps: [],
            session_status: "active",
            states: %{"session" => %{status: "complete"}}
          }
        ] do
      assert :ok = ProjectionRepairWorker.perform(job, fn _, _ -> {:ok, result} end, enqueue)
      refute_received {:summary_enqueued, _, _, _}
    end

    assert {:error, :oban_unavailable} =
             ProjectionRepairWorker.perform(job, complete, fn _, _, _ ->
               {:error, :oban_unavailable}
             end)
  end

  setup do
    previous_enabled = Application.get_env(:backplane_memory, :projection_repair_enabled)
    previous_enqueue = Application.get_env(:backplane_memory, :projection_repair_enqueue)

    previous_lesson_enqueue =
      Application.get_env(:backplane_memory, :projection_repair_lesson_enqueue)

    Application.put_env(:backplane_memory, :projection_repair_enabled, true)

    on_exit(fn ->
      restore_env(:projection_repair_enabled, previous_enabled)
      restore_env(:projection_repair_enqueue, previous_enqueue)
      restore_env(:projection_repair_lesson_enqueue, previous_lesson_enqueue)
    end)

    :ok
  end

  test "a late canonical event automatically repairs only its captured session" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      repaired_session = unique("repaired")
      unrelated_session = unique("unrelated")

      first = captured_event("host-repair", repaired_session, 1, "agent.session.started")
      third = captured_event("host-repair", repaired_session, 3, "agent.session.ended")

      assert accepted(first)
      assert accepted(third)

      assert [repair_job] = Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

      assert repair_job.args == %{
               "host_id" => "host-repair",
               "session_id" => repaired_session
             }

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :memory)

      repaired_subject = Source.subject_id!("host-repair", repaired_session)

      assert %{
               "session" => %{read_model: %{"gaps" => [%{"from" => 2, "to" => 2}]}},
               "observations" => %{read_model: %{"observations" => observations}}
             } = snapshots(repaired_subject)

      assert [_first, _third] = observations

      assert [_, _, _, _, _] = pending_states = states(repaired_subject)

      assert Enum.all?(pending_states, fn state ->
               state.status == "pending"
             end)

      # The expired gap is now a terminal deadline, so its durable summary job
      # runs separately and records an explicitly incomplete revision.
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :memory)

      assert accepted(captured_event("host-other", unrelated_session, 1, "agent.session.started"))

      # One projection repair plus the episodic successor of the incomplete summary.
      assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :memory)

      unrelated_subject = Source.subject_id!("host-other", unrelated_session)
      unrelated_before = projection_rows(unrelated_subject)

      late =
        captured_event("host-repair", repaired_session, 2, "agent.tool.completed", %{
          "source" => %{"tool_name" => "Read", "tool_response" => "ok"}
        })

      assert accepted(late)
      assert [_late_job] = Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :memory)

      assert %{
               "session" => %{read_model: %{"gaps" => [], "counts" => %{"events" => 3}}},
               "observations" => %{read_model: %{"observations" => repaired_observations}}
             } = snapshots(repaired_subject)

      assert [_first, _second, _third] = repaired_observations

      assert [_, _, _, _, _, _, _] = repaired_states = states(repaired_subject)

      assert Enum.all?(repaired_states, fn
               %{projector: "crystal", status: "enqueued", attempt_count: 0} ->
                 true

               %{projector: "summary", status: "pending", attempt_count: 1} ->
                 true

               %{projector: "episodic", status: "skipped_no_model", last_error: "no_model"} ->
                 true

               %{projector: projector, status: "complete"}
               when projector in ["activity", "observations", "replay", "session"] ->
                 true

               _state ->
                 false
             end)

      assert projection_rows(unrelated_subject) == unrelated_before

      repaired_before_duplicate = projection_rows(repaired_subject)
      assert duplicate(late)
      assert [] = Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)
      assert projection_rows(repaired_subject) == repaired_before_duplicate
    end)
  end

  test "legacy events do not enqueue projection repair" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:error, :incomplete_partition} =
               Store.append(%{
                 stream_id: "legacy-#{Ecto.UUID.generate()}",
                 event_type: "conversation.user_message",
                 host_id: "legacy-host",
                 session_id: "legacy-session",
                 content: "legacy"
               })

      assert [] = Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)
    end)
  end

  test "a converted legacy pending job prevents a second host session job after a new event" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      host_id = unique("upgraded-host")
      session_id = unique("upgraded-session")

      assert %{"server_event_id" => first_event_id} =
               accepted(captured_event(host_id, session_id, 1, "agent.session.started"))

      repo().delete_all(
        from(job in Oban.Job,
          where: job.worker == "Backplane.Memory.Workers.ProjectionRepairWorker"
        )
      )

      assert {:ok, %Oban.Job{id: legacy_job_id}} =
               %{event_id: first_event_id, host_id: host_id, session_id: session_id}
               |> ProjectionRepairWorker.new(unique: nil)
               |> Oban.insert()

      assert accepted(captured_event(host_id, session_id, 2, "agent.prompt.submitted"))

      assert [%Oban.Job{id: ^legacy_job_id, args: args}] =
               Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

      assert args == %{
               "event_id" => first_event_id,
               "host_id" => host_id,
               "session_id" => session_id
             }

      assert :ok = ProjectionRepairWorker.perform(%Oban.Job{args: args})

      assert %RepairFrontier{requested_generation: 2, completed_generation: 2} =
               RepairFrontier.get(repo(), host_id, session_id)

      repo().update_all(from(job in Oban.Job, where: job.id == ^legacy_job_id),
        set: [state: "completed", completed_at: DateTime.utc_now()]
      )

      assert [] = Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)
    end)
  end

  test "an event arriving during repair creates one successor and both executions converge" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      host_id = unique("concurrent-host")
      session_id = unique("concurrent-session")

      assert accepted(captured_event(host_id, session_id, 1, "agent.session.started"))

      assert [%Oban.Job{id: running_job_id, args: running_args}] =
               Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

      repo().update_all(from(job in Oban.Job, where: job.id == ^running_job_id),
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
                %Oban.Job{args: running_args},
                fn ^host_id, ^session_id ->
                  send(parent, :repair_running)

                  receive do
                    :release_repair ->
                      {:ok,
                       %{
                         input_revision: first_revision,
                         memory_space_id: memory_space_id(host_id),
                         client_id: "host:#{host_id}",
                         source_client_id: "codex-cli",
                         scope: "project:backplane",
                         namespace: "private"
                       }}
                  end
                end,
                fn _, _, _ -> {:ok, :not_needed} end
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
              Oban.Testing.with_testing_mode(:manual, fn ->
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

      assert [%Oban.Job{id: successor_id, args: successor_args}] =
               Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

      refute successor_id == running_job_id

      assert [["available"], ["executing"]] =
               repo().query!(
                 """
                 SELECT state FROM oban_jobs
                 WHERE id IN ($1, $2)
                 ORDER BY state
                 """,
                 [running_job_id, successor_id]
               ).rows

      repo().update_all(from(job in Oban.Job, where: job.id == ^running_job_id),
        set: [state: "completed", completed_at: DateTime.utc_now()]
      )

      assert :ok = ProjectionRepairWorker.perform(%Oban.Job{args: successor_args})

      repo().update_all(from(job in Oban.Job, where: job.id == ^successor_id),
        set: [state: "completed", completed_at: DateTime.utc_now()]
      )

      assert %RepairFrontier{requested_generation: 2, completed_generation: 2} =
               RepairFrontier.get(repo(), host_id, session_id)

      assert [] = Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)
    end)
  end

  @tag timeout: 180_000
  test "Scenario J: 10,000 accepted events coalesce to one pending projection repair job" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      host_id = "scale-host-#{Ecto.UUID.generate()}"
      session_id = "scale-session-#{Ecto.UUID.generate()}"
      auth = ingest_auth_context(host_id, %{partition: %{scope: "project:backplane"}})

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

      assert [%Oban.Job{args: %{"host_id" => ^host_id, "session_id" => ^session_id}}] =
               Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

      assert %RepairFrontier{
               requested_generation: 101,
               completed_generation: 0,
               requested_revision: revision
             } = RepairFrontier.get(repo(), host_id, session_id)

      assert revision =~ ~r/^[0-9a-f]{64}$/

      job = %Oban.Job{args: %{"host_id" => host_id, "session_id" => session_id}}

      assert :ok =
               ProjectionRepairWorker.perform(
                 job,
                 &Rebuild.session_locked/2,
                 fn _, _, _ -> {:ok, :not_needed} end
               )

      subject_id = Source.subject_id!(host_id, session_id)
      projected = repo().get!(ProjectedSession, subject_id)
      assert projected.input_revision == revision
      assert projected.source_sequence_max == 10_000

      stable_rows = persisted_row_fingerprints(subject_id)
      assert length(stable_rows.observations) == 10_000
      assert length(stable_rows.replay) == 10_000

      stable_projection =
        Map.take(projected, [:input_revision, :source_sequence_max, :status, :scope, :namespace])

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

      assert [%Oban.Job{args: %{"host_id" => ^host_id, "session_id" => ^session_id}}] =
               Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

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
    Oban.Testing.with_testing_mode(:manual, fn ->
      host_id = unique("batch-frontier-host")
      session_id = unique("batch-frontier-session")
      auth = ingest_auth_context(host_id, %{partition: %{scope: "project:backplane"}})

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

      assert [_job] = Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)
    end)
  end

  test "a revision mismatch marks work stale and a later attempt repairs the authoritative revision" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      :ets.insert(:backplane_settings, {"memory.lesson_auto_extract", true})
      on_exit(fn -> :ets.delete(:backplane_settings, "memory.lesson_auto_extract") end)

      host_id = unique("stale-host")
      session_id = unique("stale-session")

      assert accepted(captured_event(host_id, session_id, 1, "agent.session.started"))
      frontier = RepairFrontier.get(repo(), host_id, session_id)
      RepairFrontier.replace_requested_revision(repo(), frontier, String.duplicate("f", 64))

      job = %Oban.Job{args: %{"host_id" => host_id, "session_id" => session_id}}

      assert :ok = ProjectionRepairWorker.perform(job)

      assert [_successor] =
               Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

      assert [] = Oban.Testing.all_enqueued(repo(), worker: LessonCandidateWorker)

      assert %RepairFrontier{
               requested_generation: 1,
               completed_generation: 0,
               requested_revision: authoritative_revision
             } = RepairFrontier.get(repo(), host_id, session_id)

      refute authoritative_revision == String.duplicate("f", 64)

      assert :ok =
               ProjectionRepairWorker.perform(
                 job,
                 &Backplane.Memory.Projections.Rebuild.session_locked/2,
                 fn _, _, _ -> {:ok, :not_needed} end
               )

      assert %RepairFrontier{
               completed_generation: 1,
               completed_revision: ^authoritative_revision
             } = RepairFrontier.get(repo(), host_id, session_id)

      assert {:ok, :already_complete} =
               ProjectionRepairWorker.perform(
                 job,
                 fn _, _ -> flunk("a completed successor must not rebuild") end,
                 fn _, _, _ -> flunk("a completed successor must not summarize") end
               )
    end)
  end

  test "lesson scheduling failure rolls back completion and succeeds on retry" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Application.put_env(:backplane_memory, :projection_repair_lesson_enqueue, fn _event_id ->
        case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
          0 -> {:error, :lesson_unavailable}
          _ -> {:ok, :disabled}
        end
      end)

      host_id = unique("lesson-retry-host")
      session_id = unique("lesson-retry-session")

      assert accepted(captured_event(host_id, session_id, 1, "agent.session.started"))
      job = %Oban.Job{args: %{"host_id" => host_id, "session_id" => session_id}}

      assert {:error, :lesson_unavailable} = ProjectionRepairWorker.perform(job)

      assert %RepairFrontier{requested_generation: 1, completed_generation: 0} =
               RepairFrontier.get(repo(), host_id, session_id)

      assert :ok = ProjectionRepairWorker.perform(job)

      assert %RepairFrontier{requested_generation: 1, completed_generation: 1} =
               RepairFrontier.get(repo(), host_id, session_id)

      assert Agent.get(attempts, & &1) == 2
    end)
  end

  test "summary scheduling failure rolls back completion and succeeds on retry" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      host_id = unique("summary-retry-host")
      session_id = unique("summary-retry-session")

      assert accepted(captured_event(host_id, session_id, 1, "agent.session.ended"))

      %RepairFrontier{requested_revision: revision} =
        RepairFrontier.get(repo(), host_id, session_id)

      result = %{
        input_revision: revision,
        memory_space_id: memory_space_id(host_id),
        client_id: "host:#{host_id}",
        source_client_id: "codex-cli",
        scope: "project:backplane",
        namespace: "private",
        gaps: [],
        session_status: "completed",
        last_event_at: ~U[2026-08-04 01:00:00Z],
        states: %{"session" => %{status: "complete"}}
      }

      job = %Oban.Job{args: %{"host_id" => host_id, "session_id" => session_id}}

      assert {:error, :summary_unavailable} =
               ProjectionRepairWorker.perform(
                 job,
                 fn _, _ -> {:ok, result} end,
                 fn _, _, _ -> {:error, :summary_unavailable} end
               )

      assert %RepairFrontier{requested_generation: 1, completed_generation: 0} =
               RepairFrontier.get(repo(), host_id, session_id)

      assert :ok =
               ProjectionRepairWorker.perform(
                 job,
                 fn _, _ -> {:ok, result} end,
                 fn _, _, _ -> {:ok, %Oban.Job{state: "available"}} end
               )

      assert %RepairFrontier{requested_generation: 1, completed_generation: 1} =
               RepairFrontier.get(repo(), host_id, session_id)
    end)
  end

  test "normal canonical projection automatically extracts a correction candidate" do
    previous_llm = Application.get_env(:backplane_memory, :llm_client)
    Application.put_env(:backplane_memory, :llm_client, Backplane.Memory.TestLLMClient)
    :ets.insert(:backplane_settings, {"memory.lesson_auto_extract", true})

    on_exit(fn ->
      restore_env(:llm_client, previous_llm)
      :ets.delete(:backplane_settings, "memory.lesson_auto_extract")
    end)

    Oban.Testing.with_testing_mode(:manual, fn ->
      session_id = unique("lesson-correction")

      event =
        captured_event("lesson-host", session_id, 1, "agent.prompt.submitted", %{
          "message" => "Correction: always validate the canonical event before projecting it"
        })

      assert %{"server_event_id" => event_id} = accepted(event)
      assert [_repair] = Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :memory)

      assert [%Oban.Job{args: args}] =
               Oban.Testing.all_enqueued(repo(), worker: LessonCandidateWorker)

      assert args == %{"event_id" => event_id, "processing_version" => "lesson-candidate-v1"}
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :memory_lessons)

      assert %Lesson{status: "candidate", source_kind: "correction", memory_id: memory_id} =
               repo().one(Lesson)

      assert [%Evidence{source_event_id: ^event_id, evidence_kind: "supports"}] =
               repo().all(
                 from(e in Evidence,
                   where: e.memory_id == ^memory_id and not is_nil(e.source_event_id)
                 )
               )
    end)
  end

  test "normal canonical failure then successful remediation creates one idempotent candidate" do
    previous_llm = Application.get_env(:backplane_memory, :llm_client)
    Application.put_env(:backplane_memory, :llm_client, Backplane.Memory.TestLLMClient)
    :ets.insert(:backplane_settings, {"memory.lesson_auto_extract", true})

    on_exit(fn ->
      restore_env(:llm_client, previous_llm)
      :ets.delete(:backplane_settings, "memory.lesson_auto_extract")
    end)

    Oban.Testing.with_testing_mode(:manual, fn ->
      session_id = unique("lesson-remediation")

      failed =
        captured_event("remediation-host", session_id, 1, "agent.tool.failed", %{
          "source" => %{"tool_name" => "Build", "error" => "missing lock"}
        })

      fixed =
        captured_event("remediation-host", session_id, 2, "agent.tool.completed", %{
          "source" => %{"tool_name" => "Build", "tool_response" => "regenerate lock then build"}
        })

      assert %{"server_event_id" => failed_event_id} = accepted(failed)
      assert %{"server_event_id" => fixed_event_id} = accepted(fixed)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :memory)
      assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :memory_lessons)

      assert :ok =
               LessonCandidateWorker.perform(%Oban.Job{
                 args: %{
                   "event_id" => fixed_event_id,
                   "processing_version" => "lesson-candidate-v1"
                 }
               })

      assert [
               %Lesson{status: "candidate", source_kind: "correction", memory_id: memory_id} =
                 lesson
             ] =
               repo().all(Lesson)

      assert lesson.context =~ "Verified remediation"

      assert typed_evidence =
               repo().all(
                 from(e in Evidence,
                   where: e.memory_id == ^memory_id and not is_nil(e.source_event_id),
                   order_by: [asc: e.source_event_id]
                 )
               )

      assert MapSet.new(Enum.map(typed_evidence, &{&1.source_event_id, &1.evidence_kind})) ==
               MapSet.new([{failed_event_id, "derives"}, {fixed_event_id, "supports"}])

      assert length(typed_evidence) == 2
    end)
  end

  test "only the first same-tool success after a failure creates a remediation candidate" do
    previous_llm = Application.get_env(:backplane_memory, :llm_client)
    Application.put_env(:backplane_memory, :llm_client, Backplane.Memory.TestLLMClient)
    :ets.insert(:backplane_settings, {"memory.lesson_auto_extract", true})

    on_exit(fn ->
      restore_env(:llm_client, previous_llm)
      :ets.delete(:backplane_settings, "memory.lesson_auto_extract")
    end)

    Oban.Testing.with_testing_mode(:manual, fn ->
      session_id = unique("lesson-terminal-order")

      events = [
        captured_event("terminal-host", session_id, 1, "agent.tool.failed", %{
          "source" => %{"tool_name" => "Build", "error" => "missing lock"}
        }),
        captured_event("terminal-host", session_id, 2, "agent.tool.completed", %{
          "source" => %{"tool_name" => "Lint", "tool_response" => "lint clean"}
        }),
        captured_event("terminal-host", session_id, 3, "agent.tool.completed", %{
          "source" => %{"tool_name" => "Build", "tool_response" => "regenerate lock then build"}
        }),
        captured_event("terminal-host", session_id, 4, "agent.tool.completed", %{
          "source" => %{"tool_name" => "Build", "tool_response" => "build remains green"}
        })
      ]

      [failed_event_id, _lint_event_id, fixed_event_id, _repeat_event_id] =
        Enum.map(events, &accepted(&1)["server_event_id"])

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :memory)
      assert %{success: 4, failure: 0} = Oban.drain_queue(queue: :memory_lessons)

      assert [%Lesson{memory_id: memory_id}] = repo().all(Lesson)

      assert repo().all(
               from(e in Evidence,
                 where: e.memory_id == ^memory_id and not is_nil(e.source_event_id),
                 select: {e.source_event_id, e.evidence_kind}
               )
             )
             |> MapSet.new() ==
               MapSet.new([{failed_event_id, "derives"}, {fixed_event_id, "supports"}])
    end)
  end

  test "worker trusts the durable event identity and surfaces failures for retry" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      event =
        captured_event("trusted-host", unique("trusted-session"), 1, "agent.session.started")

      assert %{"server_event_id" => event_id} = accepted(event)

      job = %Oban.Job{
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
             ProjectionRepairWorker.perform(%Oban.Job{
               args: %{"event_id" => Ecto.UUID.generate()}
             })

    assert {:cancel, :invalid_arguments} =
             ProjectionRepairWorker.perform(%Oban.Job{args: %{}})

    assert {:cancel, :invalid_arguments} =
             ProjectionRepairWorker.perform(%Oban.Job{args: %{"event_id" => "  "}})
  end

  test "locked rebuild entrypoint rejects callers without a transaction" do
    assert {:error, :transaction_required} =
             Backplane.Memory.Projections.Rebuild.session_locked("host", "session")
  end

  test "a retryable inline worker result cannot masquerade as a durable repair job" do
    Application.put_env(:backplane_memory, :projection_repair_enqueue, fn _event_id ->
      {:ok, %Oban.Job{state: "retryable"}}
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
      ingest_auth_context(event["host_id"], %{partition: %{scope: event["scope"]}}),
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
        |> Enum.map(&semantic_row/1),
      replay:
        repo().all(
          from(row in ReplayEvent,
            where: row.subject_id == ^subject_id,
            order_by: [asc: row.position]
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
end
