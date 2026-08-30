defmodule Backplane.Memory.LessonGovernanceTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Lessons
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.{Evidence, Memory}
  alias Backplane.Memory.Observations.Observation
  alias Backplane.Memory.Projections.Rebuild

  @partition %{
    host_id: "governance-host",
    client_id: "host:governance-host",
    scope: "personal",
    namespace: "private"
  }
  @trace %{
    actor: "operator",
    request_id: "request-governance",
    correlation_id: "correlation-governance"
  }

  test "automatic extraction stays candidate by default and promotion requires evidence" do
    assert {:ok, candidate} =
             Lessons.create_candidate(
               %{
                 rule: "Verify remediation",
                 context: "failure",
                 project: "backplane",
                 source_kind: "correction",
                 confidence: 0.99,
                 idempotency_key: "candidate-1"
               },
               @partition,
               @trace
             )

    assert candidate.status == "candidate"
    assert repo().get!(Memory, candidate.memory_id).lifecycle_state == "candidate"

    repo().query!("SET CONSTRAINTS ALL IMMEDIATE")
    repo().query!("ALTER TABLE bpm_memory_evidence DISABLE TRIGGER USER")
    repo().delete_all(from(e in Evidence, where: e.memory_id == ^candidate.memory_id))
    repo().query!("ALTER TABLE bpm_memory_evidence ENABLE TRIGGER USER")

    assert {:error, :promotion_requires_evidence} =
             Lessons.promote(candidate.memory_id, "reviewed", "promotion-1", @partition, @trace)
  end

  test "legal lifecycle transitions update lesson and memory together and reject invalid moves" do
    assert {:ok, candidate} = candidate("transition")

    assert {:ok, active} =
             Lessons.promote(candidate.memory_id, "reviewed", "promote", @partition, @trace)

    assert {:ok, disputed} =
             Lessons.transition(
               active.memory_id,
               "disputed",
               "conflict",
               "dispute",
               @partition,
               @trace
             )

    assert disputed.status == "disputed"

    assert {:ok, archived} =
             Lessons.transition(
               active.memory_id,
               "archived",
               "stale",
               "archive",
               @partition,
               @trace
             )

    assert archived.status == "archived"

    assert {:ok, reactivated} =
             Lessons.transition(
               active.memory_id,
               "active",
               "reviewed again",
               "reactivate",
               @partition,
               @trace
             )

    assert reactivated.status == "active"
    assert repo().get!(Memory, active.memory_id).lifecycle_state == "active"

    assert {:error, :invalid_transition} =
             Lessons.transition(
               active.memory_id,
               "candidate",
               "invalid",
               "invalid",
               @partition,
               @trace
             )

    assert length(Backplane.Memory.Audit.list(@partition, operation: "lesson.transition")) == 4
  end

  test "verified application strengthens atomically once and recall does not strengthen" do
    assert {:ok, candidate} = candidate("strengthen")

    assert {:ok, lesson} =
             Lessons.promote(
               candidate.memory_id,
               "reviewed",
               "promote-strengthen",
               @partition,
               @trace
             )

    {_event_id, session_id} = canonical_event!("session-apply")
    lesson |> Ecto.Changeset.change(decay_rate: 0.7) |> repo().update!()

    assert {:ok, %{applied: true, lesson: first}} =
             Lessons.strengthen(
               lesson.memory_id,
               "verified_application",
               "application-1",
               %{"source_session_id" => session_id},
               @partition,
               @trace
             )

    assert first.reinforcement_count == 1
    assert first.last_reinforced_at
    assert first.last_applied_at
    assert first.decay_rate == 0.0
    assert repo().get!(Memory, lesson.memory_id).application_count == 1

    assert {:ok, %{applied: false, lesson: retry}} =
             Lessons.strengthen(
               lesson.memory_id,
               "verified_application",
               "application-1",
               %{"source_session_id" => session_id},
               @partition,
               @trace
             )

    assert retry.reinforcement_count == 1

    assert {:error, :invalid_strengthening} =
             Lessons.strengthen(
               lesson.memory_id,
               "recall",
               "recall-1",
               %{"source_event_id" => Ecto.UUID.generate()},
               @partition,
               @trace
             )

    assert {:ok, [_]} = Lessons.recall("Rule strengthen", @partition)
    assert repo().get!(Lesson, lesson.memory_id).reinforcement_count == 1
  end

  test "decay is deterministic and idempotent, archives by explicit policy, and preserves evidence" do
    assert {:ok, candidate} = candidate("decay")

    evidence_count =
      repo().aggregate(from(e in Evidence, where: e.memory_id == ^candidate.memory_id), :count)

    now = DateTime.add(candidate.created_at, 2, :day)

    assert {:ok, %{decayed: 1, archived: 1}} =
             Lessons.decay(@partition, now, rate: 0.2, archive_days: 1)

    assert {:ok, %{decayed: 0, archived: 0}} =
             Lessons.decay(@partition, now, rate: 0.2, archive_days: 1)

    assert %Lesson{status: "archived", decay_rate: 0.2, last_decayed_at: decayed_at} =
             repo().get!(Lesson, candidate.memory_id)

    assert DateTime.compare(decayed_at, now) == :eq

    assert repo().aggregate(
             from(e in Evidence, where: e.memory_id == ^candidate.memory_id),
             :count
           ) == evidence_count

    assert {:ok, []} = Lessons.recall("Rule decay", @partition)

    assert {:ok, %Lesson{status: "active"}} =
             Lessons.transition(
               candidate.memory_id,
               "active",
               "reviewed",
               "reactivate-decay",
               @partition,
               @trace
             )
  end

  test "auto-promotion requires enabled flag, confidence, evidence count, and source diversity" do
    keys =
      ~w(memory.lesson_auto_promote memory.lesson_promote_confidence memory.lesson_promote_sources)

    snapshot = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})

    on_exit(fn ->
      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)
    end)

    set("memory.lesson_auto_promote", false)
    assert {:ok, candidate} = candidate("threshold")

    {source_event_id, _session_id} = canonical_event!("independent-session")

    assert {:ok, %{applied: true}} =
             Lessons.strengthen(
               candidate.memory_id,
               "explicit_confirmation",
               "confirm-threshold",
               %{"source_event_id" => source_event_id},
               @partition,
               @trace
             )

    set("memory.lesson_promote_confidence", 0.85)
    set("memory.lesson_promote_sources", 2)
    set("memory.lesson_auto_promote", false)

    assert {:ok, %Lesson{status: "candidate"}} =
             Lessons.auto_promote(candidate.memory_id, "flag-off", @partition, @trace)

    set("memory.lesson_auto_promote", true)
    set("memory.lesson_promote_confidence", 0.95)

    assert {:ok, %Lesson{status: "candidate"}} =
             Lessons.auto_promote(candidate.memory_id, "confidence-low", @partition, @trace)

    set("memory.lesson_promote_confidence", 0.85)
    set("memory.lesson_promote_sources", 3)

    assert {:ok, %Lesson{status: "candidate"}} =
             Lessons.auto_promote(candidate.memory_id, "sources-low", @partition, @trace)

    set("memory.lesson_promote_sources", 2)

    assert {:ok, %Lesson{status: "active"}} =
             Lessons.auto_promote(candidate.memory_id, "all-thresholds", @partition, @trace)
  end

  test "independent strengthening immediately reevaluates automatic promotion" do
    keys =
      ~w(memory.lesson_auto_promote memory.lesson_promote_confidence memory.lesson_promote_sources)

    snapshot = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})

    on_exit(fn ->
      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)
    end)

    set("memory.lesson_auto_promote", false)
    set("memory.lesson_promote_confidence", 0.85)
    set("memory.lesson_promote_sources", 3)

    {first_event_id, _session_id} = canonical_event!("independent-first-session")
    {source_event_id, _session_id} = canonical_event!("independent-second-session")

    assert {:ok, %Lesson{status: "candidate"} = candidate} =
             Lessons.create_candidate(
               %{
                 rule: "Rule strengthen-promotes",
                 context: "test",
                 project: "backplane",
                 source_kind: "correction",
                 confidence: 0.9,
                 idempotency_key: "strengthen-promotes",
                 evidence: [
                   %{
                     source_event_id: first_event_id,
                     evidence_kind: "supports",
                     support_score: 1.0
                   }
                 ]
               },
               @partition,
               @trace
             )

    set("memory.lesson_auto_promote", true)

    assert {:ok, %{applied: true, lesson: %Lesson{status: "active"}}} =
             Lessons.strengthen(
               candidate.memory_id,
               "independent_evidence",
               "second-source-promotes",
               %{"source_event_id" => source_event_id},
               @partition,
               @trace
             )
  end

  test "strengthening rejects invented and foreign-partition typed sources" do
    assert {:ok, candidate} = candidate("typed-source-validation")

    assert {:error, :strengthening_source_not_found} =
             Lessons.strengthen(
               candidate.memory_id,
               "independent_evidence",
               "invented",
               %{"source_event_id" => Ecto.UUID.generate()},
               @partition,
               @trace
             )

    {foreign_event_id, _session_id} = canonical_event!("foreign", host_id: "foreign-host")

    assert {:error, :strengthening_source_not_found} =
             Lessons.strengthen(
               candidate.memory_id,
               "independent_evidence",
               "foreign",
               %{"source_event_id" => foreign_event_id},
               @partition,
               @trace
             )
  end

  test "strengthening rejects legacy observations that cannot prove exact partition ownership" do
    assert {:ok, candidate} = candidate("unverifiable-observation")
    {_event_id, session_id} = canonical_event!("shared-session")

    observation =
      %Observation{}
      |> Observation.changeset(%{
        session_id: session_id,
        tool_name: "test",
        content: "unverifiable legacy evidence"
      })
      |> repo().insert!()

    assert {:error, :strengthening_source_not_found} =
             Lessons.strengthen(
               candidate.memory_id,
               "independent_evidence",
               "unverifiable-observation",
               %{"source_observation_id" => observation.id},
               @partition,
               @trace
             )
  end

  test "lesson recall ranks otherwise equal matches by remaining strength" do
    assert {:ok, strong} =
             Lessons.save(
               %{
                 rule: "validate canonical payload strong",
                 context: "strong",
                 project: "backplane",
                 idempotency_key: "rank-strong"
               },
               @partition,
               @trace
             )

    assert {:ok, weak} =
             Lessons.save(
               %{
                 rule: "validate canonical payload weak",
                 context: "weak",
                 project: "backplane",
                 idempotency_key: "rank-weak"
               },
               @partition,
               @trace
             )

    weak |> Ecto.Changeset.change(decay_rate: 0.8) |> repo().update!()
    strong |> Ecto.Changeset.change(decay_rate: 0.1) |> repo().update!()

    assert {:ok, [first, second]} =
             Lessons.recall("validate canonical payload", @partition, limit: 2)

    assert [first.id, second.id] == [strong.memory_id, weak.memory_id]
  end

  defp candidate(key) do
    Lessons.create_candidate(
      %{
        rule: "Rule #{key}",
        context: "test",
        project: "backplane",
        source_kind: "correction",
        confidence: 0.9,
        idempotency_key: key
      },
      @partition,
      @trace
    )
  end

  defp set(key, value), do: :ets.insert(:backplane_settings, {key, value})

  defp canonical_event!(session_id, overrides \\ []) do
    host_id = Keyword.get(overrides, :host_id, @partition.host_id)

    event =
      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "host_id" => host_id,
        "client_id" => @partition.client_id,
        "scope" => @partition.scope,
        "session_id" => session_id,
        "idempotency_key" => "lesson-governance:#{host_id}:#{session_id}",
        "payload" => %{"message" => "independent verified evidence"}
      })

    assert {:ok, %{"results" => [%{"status" => "accepted", "server_event_id" => event_id}]}} =
             Ingest.ingest_batch(
               ingest_auth_context(host_id, %{
                 auth_token_id: "lesson-token",
                 partition: %{scope: @partition.scope}
               }),
               %{"batch_id" => Ecto.UUID.generate(), "host_id" => host_id, "events" => [event]}
             )

    assert {:ok, _projection} = Rebuild.session(host_id, session_id)
    {event_id, session_id}
  end
end
