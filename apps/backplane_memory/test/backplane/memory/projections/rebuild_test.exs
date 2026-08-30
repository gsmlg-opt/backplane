defmodule Backplane.Memory.Projections.RebuildTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Observations.{Observation, Session}
  alias Backplane.Memory.Replay.Event, as: ReplayEvent

  alias Backplane.Memory.Projections.{
    ProjectedObservation,
    ProjectedSession,
    Rebuild,
    Revision,
    Snapshot,
    Source,
    State
  }

  import Backplane.Memory.IngestFixtures

  test "session lifecycle transitions are idempotently audit-visible" do
    session_id = unique("audit-lifecycle")
    ingest!(captured_event("host-audit", session_id, 1, "agent.session.started"))
    assert {:ok, %{session_status: "active"}} = Rebuild.session("host-audit", session_id)

    [active] = lifecycle_entries(session_id)
    assert active.metadata["from"] == nil
    assert active.metadata["to"] == "active"

    ingest!(captured_event("host-audit", session_id, 2, "agent.session.ended"))
    assert {:ok, %{session_status: "completed"}} = Rebuild.session("host-audit", session_id)

    assert [_completed, _active] = lifecycle_entries(session_id)

    assert {:ok, %{session_status: "completed"}} = Rebuild.session("host-audit", session_id)
    assert length(lifecycle_entries(session_id)) == 2
  end

  test "targeted rebuild writes four production read-model projections" do
    session_id = unique("target")

    repo().insert!(%Session{
      session_id: session_id,
      project: "/legacy/project",
      started_at: ~U[2026-08-04 00:59:00.000000Z],
      ended_at: ~U[2026-08-04 01:10:00.000000Z],
      observation_count: 7
    })

    repo().insert!(%Observation{session_id: session_id, content: "legacy one"})
    repo().insert!(%Observation{session_id: session_id, content: "legacy two"})

    first = captured_event("host-target", session_id, 1, "agent.session.started")

    third =
      captured_event("host-target", session_id, 3, "agent.tool.failed", %{
        "source" => %{"tool_name" => "Bash", "error" => "exit 1"}
      })

    ingest!(first)
    ingest!(third)

    raw_before = raw_events("host-target", session_id)
    legacy_before = legacy_rows(session_id)

    assert {:ok, result} = Rebuild.session("host-target", session_id)
    assert result.production_read_models
    refute Map.has_key?(result, :validation_only)
    refute Map.has_key?(result, :comparison)
    assert result.subject_type == "captured_session"
    assert result.subject_id == Source.subject_id!("host-target", session_id)
    assert result.gaps == [%{"from" => 2, "to" => 2}]
    assert Map.keys(result.output_revisions) == ~w(activity observations replay session)
    assert Enum.all?(result.states, fn {_projector, state} -> state.status == "pending" end)
    assert processing_versions(result.states) == expected_processing_versions()

    subject_id = result.subject_id
    assert 4 == count_subject_rows(State, subject_id)
    assert 4 == count_subject_rows(Snapshot, subject_id)
    assert 2 == count_subject_rows(ProjectedObservation, subject_id)

    assert %ProjectedSession{
             host_id: "host-target",
             session_id: ^session_id,
             status: "active",
             source_sequence_max: 3,
             gap_count: 1,
             input_revision: input_revision
           } = repo().get!(ProjectedSession, subject_id)

    assert input_revision == result.input_revision

    snapshots = snapshots(subject_id)

    assert %{
             "observations" => %{
               read_model: %{
                 "host_id" => "host-target",
                 "session_id" => ^session_id,
                 "observations" => [first_observation, third_observation]
               }
             },
             "session" => %{
               read_model: %{
                 "status" => "active",
                 "gaps" => [%{"from" => 2, "to" => 2}],
                 "counts" => %{"events" => 2, "errors" => 1}
               }
             },
             "activity" => %{read_model: %{"activity" => activity}},
             "replay" => %{read_model: %{"events" => replay_events}}
           } = snapshots

    assert first_observation["event_id"] == first["event_id"]
    assert third_observation["event_id"] == third["event_id"]
    assert third_observation["is_error"]
    assert Enum.map(replay_events, & &1["kind"]) == ["session_boundary", "error"]
    assert Enum.map(activity, &{&1["event_count"], &1["session_count"]}) == [{1, 1}, {1, 1}]

    assert raw_events("host-target", session_id) == raw_before
    assert legacy_rows(session_id) == legacy_before
  end

  test "a late event replaces only its subject snapshots, clears gaps, and completes states" do
    repaired_session = unique("repaired")
    unrelated_session = unique("unrelated")

    ingest!(captured_event("host-repair", repaired_session, 1, "agent.session.started"))
    ingest!(captured_event("host-repair", repaired_session, 3, "agent.session.ended"))
    ingest!(captured_event("host-other", unrelated_session, 1, "agent.session.started"))

    assert {:ok, first} = Rebuild.session("host-repair", repaired_session)
    assert {:ok, unrelated} = Rebuild.session("host-other", unrelated_session)
    assert first.gaps == [%{"from" => 2, "to" => 2}]
    assert 2 == count_subject_rows(ReplayEvent, first.subject_id)

    unrelated_before = projection_rows(unrelated.subject_id)

    ingest!(
      captured_event("host-repair", repaired_session, 2, "agent.tool.completed", %{
        "source" => %{"tool_name" => "Read", "tool_response" => "ok"}
      })
    )

    assert {:ok, repaired} = Rebuild.session("host-repair", repaired_session)
    assert repaired.gaps == []
    assert repaired.input_revision != first.input_revision
    assert 5 == count_subject_rows(ReplayEvent, repaired.subject_id)
    assert 2 == replay_revision_count(repaired.subject_id)
    assert Enum.all?(repaired.states, fn {_projector, state} -> state.status == "complete" end)
    assert processing_versions(repaired.states) == expected_processing_versions()

    assert %{
             "session" => %{read_model: %{"gaps" => [], "counts" => %{"events" => 3}}},
             "observations" => %{read_model: %{"observations" => observations}}
           } = snapshots(repaired.subject_id)

    assert length(observations) == 3
    assert projection_rows(unrelated.subject_id) == unrelated_before
  end

  test "replaying the same subject is revision and row idempotent" do
    session_id = unique("replay")
    ingest!(captured_event("host-replay", session_id, 1, "agent.session.started"))
    ingest!(captured_event("host-replay", session_id, 2, "agent.session.ended"))

    assert {:ok, first} = Rebuild.session("host-replay", session_id)
    first_snapshots = snapshots(first.subject_id)

    assert {:ok, second} = Rebuild.session("host-replay", session_id)
    second_snapshots = snapshots(second.subject_id)

    assert second.input_revision == first.input_revision
    assert second.output_revisions == first.output_revisions

    assert Map.new(second_snapshots, fn {name, snapshot} ->
             {name, Map.take(snapshot, [:input_revision, :output_revision, :read_model])}
           end) ==
             Map.new(first_snapshots, fn {name, snapshot} ->
               {name, Map.take(snapshot, [:input_revision, :output_revision, :read_model])}
             end)

    assert 4 == count_subject_rows(State, first.subject_id)
    assert 4 == count_subject_rows(Snapshot, first.subject_id)
    assert 2 == count_subject_rows(ProjectedObservation, first.subject_id)
    assert 1 == count_subject_rows(ProjectedSession, first.subject_id)
    assert 2 == count_subject_rows(ReplayEvent, first.subject_id)
    assert 1 == replay_revision_count(first.subject_id)

    assert Enum.all?(second.states, fn {_name, state} ->
             state.status == "complete" and state.attempt_count == 2
           end)

    assert processing_versions(second.states) == expected_processing_versions()
  end

  test "persists both deterministic replay rows for a terminal agent run failure" do
    host_id = "host-run-failure"
    session_id = unique("run-failure")

    failed =
      captured_event(host_id, session_id, 1, "agent.run.failed", %{
        "source" => %{"error" => "terminal failure"}
      })

    ingest!(failed)

    assert {:ok, result} = Rebuild.session(host_id, session_id)

    assert %{
             "replay" => %{
               read_model: %{
                 "events" => [
                   %{"event_id" => event_id, "kind" => "error", "position" => 1},
                   %{"event_id" => event_id, "kind" => "session_boundary", "position" => 2}
                 ]
               }
             }
           } = snapshots(result.subject_id)

    assert event_id == failed["event_id"]

    assert repo().all(
             from(row in ReplayEvent,
               where: row.subject_id == ^result.subject_id,
               order_by: row.position,
               select: {row.event_id, row.kind, row.position}
             )
           ) == [
             {failed["event_id"], "error", 1},
             {failed["event_id"], "session_boundary", 2}
           ]
  end

  test "validates identifiers, reports missing captures, and rebuilds all subjects stably" do
    assert {:error, :invalid_host_id} = Rebuild.session("", "session")
    assert {:error, :invalid_session_id} = Rebuild.session("host", "")
    assert {:error, :not_found} = Rebuild.session("host", unique("missing"))

    session_a = unique("all-a")
    session_b = unique("all-b")
    ingest!(captured_event("host-b", session_b, 1, "agent.session.started"))
    ingest!(captured_event("host-a", session_a, 1, "agent.session.started"))

    parent = self()
    callback_ref = make_ref()
    assert {:ok, expected_subjects} = Source.subjects()

    assert {:ok, %{rebuilt: rebuilt_count}} =
             Rebuild.all(
               page_size: 1,
               on_result: &send(parent, {callback_ref, :rebuilt, &1})
             )

    callbacks =
      Enum.map(expected_subjects, fn _subject ->
        assert_receive {^callback_ref, :rebuilt, result}
        result
      end)

    assert rebuilt_count == length(expected_subjects)
    assert rebuilt_count == length(callbacks)

    assert Enum.map(callbacks, &{&1.host_id, &1.session_id, &1.subject_id}) ==
             Enum.map(expected_subjects, &{&1["host_id"], &1["session_id"], &1["subject_id"]})

    created_sessions = MapSet.new([session_a, session_b])

    assert Enum.filter(callbacks, &MapSet.member?(created_sessions, &1.session_id))
           |> Enum.map(&{&1.host_id, &1.session_id}) ==
             [{"host-a", session_a}, {"host-b", session_b}]

    refute_receive {^callback_ref, :rebuilt, _result}
  end

  defp replay_revision_count(subject_id) do
    repo().aggregate(
      from(row in ReplayEvent,
        where: row.subject_id == ^subject_id,
        distinct: row.input_revision
      ),
      :count,
      :input_revision
    )
  end

  test "concurrent first rebuilds serialize without failed-state corruption" do
    session_id = unique("concurrent")
    ingest!(captured_event("host-concurrent", session_id, 1, "agent.session.started"))
    ingest!(captured_event("host-concurrent", session_id, 2, "agent.session.ended"))

    results =
      1..4
      |> Enum.map(fn _index ->
        Task.async(fn -> Rebuild.session("host-concurrent", session_id) end)
      end)
      |> Task.await_many(10_000)

    assert Enum.all?(results, &match?({:ok, %{gaps: []}}, &1))

    subject_id = Source.subject_id!("host-concurrent", session_id)
    assert 4 == count_subject_rows(State, subject_id)
    assert 4 == count_subject_rows(Snapshot, subject_id)

    assert Enum.all?(repo().all(from(s in State, where: s.subject_id == ^subject_id)), fn state ->
             state.status == "complete" and state.attempt_count == 4 and is_nil(state.last_error)
           end)
  end

  test "failure recording cannot clobber a successful or newer subject revision" do
    session_id = unique("failure-guard")
    host_id = "host-failure-guard"
    ingest!(captured_event(host_id, session_id, 1, "agent.session.started"))

    assert {:ok, successful} = Rebuild.session(host_id, session_id)
    rows_after_success = projection_rows(successful.subject_id)

    assert :ok =
             Rebuild.record_failed(
               host_id,
               session_id,
               successful.subject_id,
               successful.input_revision,
               RuntimeError.exception("older attempt failed")
             )

    assert projection_rows(successful.subject_id) == rows_after_success

    ingest!(captured_event(host_id, session_id, 2, "agent.session.ended"))

    assert :ok =
             Rebuild.record_failed(
               host_id,
               session_id,
               successful.subject_id,
               successful.input_revision,
               RuntimeError.exception("stale attempt failed")
             )

    assert projection_rows(successful.subject_id) == rows_after_success

    assert {:ok, events} = Source.events(host_id, session_id)
    current_revision = Revision.input_revision(events)
    refute current_revision == successful.input_revision

    assert :ok =
             Rebuild.record_failed(
               host_id,
               session_id,
               successful.subject_id,
               current_revision,
               RuntimeError.exception("current revision failed")
             )

    failed_rows = projection_rows(successful.subject_id)
    assert failed_rows.snapshots == rows_after_success.snapshots

    assert Enum.all?(failed_rows.states, fn
             {_projector, _processing_version, "failed", 2, ^current_revision, nil,
              "current revision failed"} ->
               true

             _state ->
               false
           end)

    assert Map.new(failed_rows.states, fn {projector, version, _, _, _, _, _} ->
             {projector, version}
           end) == expected_processing_versions()
  end

  test "failed row replacement rolls back and preserves the prior subject rows" do
    host_id = "host-row-rollback"
    session_id = unique("row-rollback")
    ingest!(captured_event(host_id, session_id, 1, "agent.session.started"))
    assert {:ok, initial} = Rebuild.session(host_id, session_id)

    rows_before =
      repo().all(
        from(row in ProjectedObservation,
          where: row.subject_id == ^initial.subject_id,
          select: {row.event_id, row.input_revision}
        )
      )

    constraint = "bpm_projected_observations_test_reject_important"

    repo().query!(
      "ALTER TABLE bpm_projected_observations ADD CONSTRAINT #{constraint} CHECK (importance < 5)"
    )

    try do
      important =
        captured_event(host_id, session_id, 2, "agent.tool.completed")
        |> Map.put("importance", 9)

      ingest!(important)

      assert_raise Postgrex.Error, fn -> Rebuild.session(host_id, session_id) end

      assert repo().all(
               from(row in ProjectedObservation,
                 where: row.subject_id == ^initial.subject_id,
                 select: {row.event_id, row.input_revision}
               )
             ) == rows_before
    after
      repo().query!("ALTER TABLE bpm_projected_observations DROP CONSTRAINT #{constraint}")
    end
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

  defp ingest!(event) do
    auth = ingest_auth_context(event["host_id"], %{partition: %{scope: event["scope"]}})

    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(auth, %{
               "batch_id" => Ecto.UUID.generate(),
               "host_id" => event["host_id"],
               "events" => [event]
             })
  end

  defp raw_events(host_id, session_id) do
    repo().all(
      from(e in Event,
        where: e.host_id == ^host_id and e.session_id == ^session_id,
        order_by: [asc: e.source_sequence, asc: e.id],
        select: {e.id, e.source_sequence, e.payload_hash, e.payload, e.inserted_at}
      )
    )
  end

  defp legacy_rows(session_id) do
    %{
      observations:
        repo().all(
          from(o in Observation,
            where: o.session_id == ^session_id,
            order_by: [asc: o.id],
            select: {o.id, o.content, o.tool_name, o.is_error, o.files, o.created_at}
          )
        ),
      session: repo().get(Session, session_id)
    }
  end

  defp count_subject_rows(schema, subject_id) do
    repo().aggregate(from(row in schema, where: row.subject_id == ^subject_id), :count)
  end

  defp snapshots(subject_id) do
    repo().all(from(s in Snapshot, where: s.subject_id == ^subject_id))
    |> Map.new(&{&1.projector, &1})
  end

  defp projection_rows(subject_id) do
    %{
      states:
        repo().all(
          from(s in State,
            where: s.subject_id == ^subject_id,
            order_by: [asc: s.projector],
            select:
              {s.projector, s.processing_version, s.status, s.attempt_count, s.input_revision,
               s.output_revision, s.last_error}
          )
        ),
      snapshots:
        repo().all(
          from(s in Snapshot,
            where: s.subject_id == ^subject_id,
            order_by: [asc: s.projector],
            select: {s.projector, s.input_revision, s.output_revision, s.read_model}
          )
        )
    }
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp lifecycle_entries(session_id) do
    Backplane.Memory.Audit.list(operation: "session.lifecycle_transition", limit: 500)
    |> Enum.filter(&(&1.metadata["session_id"] == session_id))
  end

  defp processing_versions(states) do
    Map.new(states, fn {projector, state} -> {projector, state.processing_version} end)
  end

  defp expected_processing_versions do
    %{
      "observations" => "observations-v1",
      "session" => "session-v1",
      "activity" => "activity-v1",
      "replay" => "replay-v1"
    }
  end
end
