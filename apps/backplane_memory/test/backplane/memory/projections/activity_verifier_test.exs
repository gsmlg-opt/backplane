defmodule Backplane.Memory.Projections.ActivityVerifierTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Events.Store

  alias Backplane.Memory.Projections.{
    ActivityContribution,
    ActivityDaily,
    ActivityVerifier,
    Rebuild
  }

  test "reports actionable direct-event drift and repairs it idempotently" do
    suffix = System.unique_integer([:positive])
    host = "verify-host-#{suffix}"
    session = "verify-session-#{suffix}"
    project = "verify-project-#{suffix}"

    assert {:ok, {:inserted, _event}} =
             Store.append_tagged(%{
               id: Ecto.UUID.generate(),
               stream_id: "capture:#{host}:#{session}",
               host_id: host,
               client_id: "verify-client",
               scope: "verify-scope",
               namespace: "private",
               session_id: session,
               project: project,
               agent_id: "verify-agent",
               source_sequence: 1,
               event_type: "memory.recalled",
               occurred_at: "2026-05-01T01:00:00.000000Z",
               idempotency_key: "verify:#{suffix}",
               payload: %{},
               payload_hash: "sha256:verify",
               schema_version: 1
             })

    assert {:ok, _result} = Rebuild.session(host, session)

    opts = [
      client_id: "verify-client",
      scope: "verify-scope",
      namespace: "private",
      date_from: ~D[2026-05-01],
      date_to: ~D[2026-05-01]
    ]

    assert {:ok, %{status: :consistent, drift_count: 0, drift: []}} =
             ActivityVerifier.verify(opts)

    repo().update_all(
      from(a in ActivityDaily,
        where: a.project == ^project and a.event_type == "memory.recalled"
      ),
      set: [event_count: 9]
    )

    assert {:ok, %{status: :drift, drift_count: 1, drift: [drift]}} =
             ActivityVerifier.verify(opts)

    assert drift.project == project
    assert drift.event_type == "memory.recalled"
    assert drift.expected.event_count == 1
    assert drift.actual.event_count == 9

    assert {:ok, %{repaired_subjects: 1, verification: %{status: :consistent}}} =
             ActivityVerifier.repair(opts)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    orphan_daily = %{
      date: ~D[2026-05-01],
      project: "orphan",
      agent_id: "verify-agent",
      host_id: host,
      client_id: "verify-client",
      scope: "verify-scope",
      namespace: "private",
      event_type: "orphan.event",
      event_count: 1,
      session_count: 1,
      memory_count: 0,
      lesson_count: 0,
      crystal_count: 0,
      recall_count: 0,
      action_count: 0,
      error_count: 0,
      inserted_at: now,
      updated_at: now
    }

    repo().insert_all(ActivityDaily, [orphan_daily])

    valid_contribution =
      repo().one!(
        from(c in ActivityContribution,
          where: c.project == ^project and c.event_type == "memory.recalled"
        )
      )

    repo().insert_all(ActivityContribution, [
      valid_contribution
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> Map.put(:subject_id, "orphan-subject-#{suffix}")
      |> Map.put(:input_revision, "orphan-revision")
    ])

    repo().update_all(
      from(a in ActivityDaily,
        where: a.project == ^project and a.event_type == "memory.recalled"
      ),
      set: [event_count: 2, session_count: 2, recall_count: 2]
    )

    assert {:ok, %{status: :drift, drift_count: 2}} = ActivityVerifier.verify(opts)

    assert {:ok,
            %{
              repaired_subjects: 1,
              orphan_contributions_removed: 1,
              orphan_daily_removed: 1,
              verification: %{status: :consistent}
            }} = ActivityVerifier.repair(opts)

    assert [%{metadata: metadata}] = Audit.list(operation: "activity.repair", limit: 1)
    assert metadata["orphan_contributions_removed"] == 1
    assert metadata["orphan_daily_removed"] == 1
    assert metadata["bounded"] == true

    assert repo().exists?(
             from(a in ActivityDaily,
               where: a.project == ^project and a.event_type == "memory.recalled"
             )
           )

    assert [%ActivityContribution{subject_id: valid_subject_id}] =
             repo().all(
               from(c in ActivityContribution,
                 where: c.project == ^project and c.event_type == "memory.recalled"
               )
             )

    refute valid_subject_id == "orphan-subject-#{suffix}"

    assert [%ActivityDaily{event_count: 1, session_count: 1, recall_count: 1}] =
             repo().all(
               from(a in ActivityDaily,
                 where: a.project == ^project and a.event_type == "memory.recalled"
               )
             )

    assert {:ok,
            %{
              repaired_subjects: 1,
              orphan_contributions_removed: 0,
              orphan_daily_removed: 0,
              verification: %{status: :consistent}
            }} = ActivityVerifier.repair(opts)
  end
end
