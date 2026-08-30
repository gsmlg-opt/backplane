defmodule Backplane.Memory.Projections.ProjectionRepairWorkerTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Events.{Event, Store}
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.Evidence
  alias Backplane.Memory.Projections.{Snapshot, Source, State}
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

    assert [%{operation: "projection.repair", target_ids: [^event_id], metadata: metadata}] =
             Audit.list(operation: "projection.repair")

    assert metadata["host_id"] == "summary-host"
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
    Application.put_env(:backplane_memory, :projection_repair_enabled, true)

    on_exit(fn ->
      restore_env(:projection_repair_enabled, previous_enabled)
      restore_env(:projection_repair_enqueue, previous_enqueue)
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

      assert [first_job, third_job] =
               Oban.Testing.all_enqueued(repo(), worker: ProjectionRepairWorker)

      assert Enum.map([first_job, third_job], &Map.keys(&1.args)) == [["event_id"], ["event_id"]]
      assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :memory)

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

      assert [_, _, _, _, _, _] = repaired_states = states(repaired_subject)

      assert Enum.all?(repaired_states, fn
               %{projector: "crystal", status: "enqueued", attempt_count: 0} ->
                 true

               %{projector: "summary", status: "pending", attempt_count: 1} ->
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
      assert {:ok, _legacy} =
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
      assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :memory)
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

      assert %{success: 4, failure: 0} = Oban.drain_queue(queue: :memory)
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
    assert result["status"] == "accepted"
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

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp restore_env(key, nil), do: Application.delete_env(:backplane_memory, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_memory, key, value)
end
