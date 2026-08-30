defmodule Backplane.Memory.Workers.SummaryWorkerTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Observations
  alias Backplane.Memory.Observations.Observation
  alias Backplane.Memory.Projections.{ReadModels, Rebuild, Source, State}
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}
  alias Backplane.Memory.Workers.{EpisodicWorker, SummaryWorker}

  test "canonical jobs keep same session ids on different hosts separate and exclude legacy decoys" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      session_id = unique("shared")
      first = canonical_session("host-a", session_id, "project-a", "host a observation")
      second = canonical_session("host-b", session_id, "project-b", "host b observation")

      repo().insert!(%Observation{session_id: session_id, content: "legacy decoy"})

      assert :ok = perform("host-a", session_id, first.input_revision)
      assert :ok = perform("host-b", session_id, second.input_revision)

      summaries = repo().all(from(s in Summary, order_by: [asc: s.host_id]))

      assert Enum.map(summaries, &{&1.host_id, &1.subject_id, &1.project}) == [
               {"host-a", Source.subject_id!("host-a", session_id), "project-a"},
               {"host-b", Source.subject_id!("host-b", session_id), "project-b"}
             ]

      assert Enum.all?(summaries, &(&1.processing_version == "summary-v1"))
      assert Enum.all?(summaries, &(not String.contains?(&1.content, "legacy decoy")))

      assert Enum.map(summaries, & &1.input_revision) |> Enum.sort() ==
               Enum.sort([first.input_revision, second.input_revision])

      assert Enum.sort(
               Enum.map(Oban.Testing.all_enqueued(repo(), worker: EpisodicWorker), & &1.args)
             ) ==
               Enum.sort(Enum.map(summaries, &%{"summary_id" => &1.id}))
    end)
  end

  test "retry is idempotent and a later input revision preserves and supersedes history" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      host_id = "host-evolve"
      session_id = unique("evolve")
      initial = canonical_session(host_id, session_id, "project-evolve", "initial useful fact")

      assert :ok = perform(host_id, session_id, initial.input_revision)
      current = current_summary(host_id, session_id)
      assert :ok = perform(host_id, session_id, initial.input_revision)
      assert current.id == current_summary(host_id, session_id).id
      assert repo().aggregate(Summary, :count) == 1

      ingest!(
        event(
          host_id,
          session_id,
          "project-evolve",
          4,
          "agent.tool.completed",
          "late revision content"
        )
      )

      assert {:ok, late} = Rebuild.session(host_id, session_id)
      refute late.input_revision == initial.input_revision

      assert :ok = perform(host_id, session_id, late.input_revision)
      replacement = current_summary(host_id, session_id)
      refute replacement.id == current.id
      assert replacement.input_revision == late.input_revision
      assert replacement.content =~ "late revision content"

      historical = repo().get!(Summary, current.id)
      assert historical.processing_version == "summary-v1@#{initial.input_revision}"
      assert historical.superseded_by_input_revision == late.input_revision
      assert historical.superseded_at
      assert repo().aggregate(Summary, :count) == 2

      # A reordered old job cannot replace the newer canonical revision.
      assert :ok = perform(host_id, session_id, initial.input_revision)
      assert current_summary(host_id, session_id).id == replacement.id
      assert repo().aggregate(Summary, :count) == 2
    end)
  end

  test "canonical missing, active, and pre-deadline gapped jobs are stable no-ops" do
    assert :ok = perform("missing-host", unique("missing"), String.duplicate("a", 64))

    active = unique("active")
    ingest!(event("host-active", active, "p", 1, "agent.session.started", "start"))
    assert {:ok, active_projection} = Rebuild.session("host-active", active)
    assert :ok = perform("host-active", active, active_projection.input_revision)

    gapped = unique("gapped")
    current = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ingest!(event_at("host-gap", gapped, "p", 1, "agent.session.started", "start", current))
    ingest!(event_at("host-gap", gapped, "p", 3, "agent.session.ended", "done", current))
    assert {:ok, gap_projection} = Rebuild.session("host-gap", gapped)
    assert :ok = perform("host-gap", gapped, gap_projection.input_revision)
    assert repo().aggregate(Summary, :count) == 0
  end

  test "expired gaps produce an explicitly incomplete summary that late repair supersedes" do
    host_id = "host-incomplete"
    session_id = unique("incomplete")

    ingest!(event(host_id, session_id, "p", 1, "agent.session.started", "start"))
    ingest!(event(host_id, session_id, "p", 3, "agent.session.ended", "done"))
    assert {:ok, incomplete_projection} = Rebuild.session(host_id, session_id)

    assert :ok = perform(host_id, session_id, incomplete_projection.input_revision)

    incomplete = current_summary(host_id, session_id)
    assert incomplete.source_complete == false
    assert incomplete.source_gap_count == 1
    assert incomplete.source_gaps == %{"ranges" => [%{"from" => 2, "to" => 2}]}
    assert incomplete.content =~ "source_complete=false"
    assert incomplete.content =~ "source_gaps=2-2"

    assert repo().aggregate(
             from(link in SourceEvent, where: link.summary_id == ^incomplete.id),
             :count
           ) == 2

    ingest!(event(host_id, session_id, "p", 2, "agent.tool.completed", "late fact"))
    assert {:ok, complete_projection} = Rebuild.session(host_id, session_id)
    refute complete_projection.input_revision == incomplete_projection.input_revision

    assert :ok = perform(host_id, session_id, complete_projection.input_revision)
    complete = current_summary(host_id, session_id)

    assert complete.id != incomplete.id
    assert complete.source_complete
    assert complete.source_gap_count == 0
    assert complete.source_gaps == %{"ranges" => []}
    assert complete.content =~ "source_complete=true"
    assert complete.content =~ "late fact"

    historical = repo().get!(Summary, incomplete.id)
    assert historical.superseded_by_input_revision == complete_projection.input_revision
    assert historical.superseded_at

    assert repo().aggregate(
             from(link in SourceEvent, where: link.summary_id == ^complete.id),
             :count
           ) == 3

    assert :ok = perform(host_id, session_id, complete_projection.input_revision)
    assert current_summary(host_id, session_id).id == complete.id
    assert repo().aggregate(Summary, :count) == 2
  end

  test "complete state is revisioned" do
    closed = canonical_session("host-state", unique("state"), "p", "fact")
    assert :ok = perform(closed.host_id, closed.session_id, closed.input_revision)

    assert %State{
             projector: "summary",
             processing_version: "summary-v1",
             status: "complete",
             input_revision: input_revision,
             output_revision: output_revision,
             attempt_count: 1,
             last_error: nil
           } = state(closed.subject_id)

    assert input_revision == closed.input_revision
    assert is_binary(output_revision) and byte_size(output_revision) == 64
  end

  test "fallback summary records important observations, errors, tools, files, commits, timestamps, and exact sources" do
    host_id = "host-summary-details"
    session_id = unique("details")
    project = "project-details"

    ingest!(event(host_id, session_id, project, 1, "agent.session.started", "start"))

    ingest!(
      event(host_id, session_id, project, 2, "agent.tool.completed", "important result")
      |> Map.put("importance", 9)
      |> Map.put("tool_name", "Read")
      |> Map.put("payload", %{
        "source" => %{
          "message" => "important result",
          "tool_name" => "Read",
          "file_paths" => ["lib/a.ex"],
          "commit_hash" => "abc123"
        }
      })
      |> refresh_payload_hash()
    )

    ingest!(
      event(host_id, session_id, project, 3, "agent.tool.failed", "permission denied")
      |> Map.put("importance", 8)
      |> Map.put("tool_name", "Read")
      |> Map.put("payload", %{
        "source" => %{
          "error" => "permission denied",
          "file_path" => "lib/a.ex",
          "tool_name" => "Read"
        }
      })
      |> refresh_payload_hash()
    )

    ingest!(event(host_id, session_id, project, 4, "agent.session.ended", "done"))
    assert {:ok, result} = Rebuild.session(host_id, session_id)
    assert :ok = perform(host_id, session_id, result.input_revision)

    summary = current_summary(host_id, session_id)
    assert summary.content =~ "started_at=2026-08-04T01:01:00.000000Z"
    assert summary.content =~ "ended_at=2026-08-04T01:04:00.000000Z"
    assert summary.content =~ "tool_counts=Read=2"
    assert summary.content =~ "file_counts=lib/a.ex=2"
    assert summary.content =~ "commits=abc123"
    assert summary.content =~ "[observation importance=9"
    assert summary.content =~ "important result"
    assert summary.content =~ "[error importance=8"
    assert summary.content =~ "permission denied"

    assert repo().aggregate(
             from(link in SourceEvent, where: link.summary_id == ^summary.id),
             :count
           ) == 4
  end

  test "legacy session-only jobs remain explicitly compatible" do
    Observations.register_session("legacy-summary", "legacy-project")
    {:ok, _} = Observations.record("legacy-summary", "legacy observation", [])

    assert :ok = SummaryWorker.perform(%Oban.Job{args: %{"session_id" => "legacy-summary"}})
    summary = repo().one!(from(s in Summary, where: s.session_id == "legacy-summary"))
    assert summary.subject_id == "legacy:legacy-summary"
    assert summary.host_id == "legacy"
    assert summary.processing_version == "legacy-v0"
  end

  test "canonical argument contract is exact" do
    assert {:cancel, :invalid_arguments} = SummaryWorker.perform(%Oban.Job{args: %{}})

    assert {:cancel, :invalid_arguments} =
             SummaryWorker.perform(%Oban.Job{
               args: %{
                 "host_id" => "h",
                 "session_id" => "s",
                 "processing_version" => "summary-v2"
               }
             })
  end

  test "canonical enqueue atomically records pending projection state and exact job args" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      result = canonical_session("host-pending", unique("pending"), "p", "fact")

      assert {:ok, job} =
               SummaryWorker.enqueue(result.host_id, result.session_id, result.input_revision)

      assert job.args == %{
               host_id: result.host_id,
               session_id: result.session_id,
               processing_version: "summary-v1",
               input_revision: result.input_revision
             }

      assert %State{
               status: "pending",
               processing_version: "summary-v1",
               input_revision: input_revision,
               output_revision: nil,
               attempt_count: 0
             } = state(result.subject_id)

      assert input_revision == result.input_revision
    end)
  end

  test "summary completion stays successful when crystal execution supervision is temporarily absent" do
    previous = Application.get_env(:backplane_memory, :crystal_task_supervisor)

    Application.put_env(
      :backplane_memory,
      :crystal_task_supervisor,
      :missing_crystal_task_supervisor
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane_memory, :crystal_task_supervisor, previous)
      else
        Application.delete_env(:backplane_memory, :crystal_task_supervisor)
      end
    end)

    result = canonical_session("host-supervisor-churn", unique("churn"), "p", "fact")

    assert :ok = perform(result.host_id, result.session_id, result.input_revision)
    assert %Summary{} = current_summary(result.host_id, result.session_id)

    assert %State{projector: "crystal", status: "enqueued", attempt_count: 0} =
             state(result.subject_id, "crystal")
  end

  test "concurrent retries serialize to one summary and one episodic job" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      result = canonical_session("host-concurrent-summary", unique("concurrent"), "p", "fact")

      outcomes =
        1..4
        |> Enum.map(fn _ ->
          Task.async(fn -> perform(result.host_id, result.session_id, result.input_revision) end)
        end)
        |> Task.await_many(10_000)

      assert outcomes == [:ok, :ok, :ok, :ok]
      assert repo().aggregate(Summary, :count) == 1
      assert state(result.subject_id).attempt_count == 4
    end)
  end

  test "transaction failure records a retryable failed projection state without a summary" do
    result = canonical_session("host-summary-failure", unique("failure"), "p", "fact")
    constraint = "memory_summaries_test_reject_canonical"

    repo().query!(
      "ALTER TABLE memory_summaries ADD CONSTRAINT #{constraint} CHECK (processing_version <> 'summary-v1')"
    )

    try do
      assert_raise Ecto.ConstraintError, fn ->
        perform(result.host_id, result.session_id, result.input_revision)
      end

      assert repo().aggregate(Summary, :count) == 0

      assert %State{
               status: "failed",
               processing_version: "summary-v1",
               input_revision: input_revision,
               output_revision: nil,
               attempt_count: 1,
               last_error: error
             } = state(result.subject_id)

      assert input_revision == result.input_revision
      assert error =~ constraint
    after
      repo().query!("ALTER TABLE memory_summaries DROP CONSTRAINT #{constraint}")
    end
  end

  test "a stale failed attempt cannot overwrite the state for a newer input revision" do
    host_id = "host-stale-failure"
    session_id = unique("stale-failure")
    first = canonical_session(host_id, session_id, "p", "first revision")
    assert {:ok, _job} = SummaryWorker.enqueue(host_id, session_id, first.input_revision)

    ingest!(event(host_id, session_id, "p", 4, "agent.tool.completed", "new revision"))
    assert {:ok, second} = Rebuild.session(host_id, session_id)
    assert {:ok, _job} = SummaryWorker.enqueue(host_id, session_id, second.input_revision)

    before = state(second.subject_id)

    assert :ok =
             SummaryWorker.record_failed(
               host_id,
               session_id,
               second.subject_id,
               first.input_revision,
               RuntimeError.exception("stale attempt failed")
             )

    assert state(second.subject_id) == before
  end

  test "large sessions keep summary input bounded while preserving every exact source in SQL" do
    host_id = "host-large-summary"
    session_id = unique("large")
    project = "large-project"

    events =
      Enum.map(1..105, fn sequence ->
        type =
          case sequence do
            1 -> "agent.session.started"
            105 -> "agent.session.ended"
            _ -> "agent.prompt.submitted"
          end

        large_event(host_id, session_id, project, sequence, type)
      end)

    events |> Enum.chunk_every(50) |> Enum.each(&ingest_batch!/1)
    assert {:ok, result} = Rebuild.session(host_id, session_id)
    assert {:ok, input} = ReadModels.summary_input(host_id, session_id, limit: 100)
    assert length(input.observations) == 100
    refute Map.has_key?(input, :source_event_ids)

    assert :ok = perform(host_id, session_id, result.input_revision)
    summary = current_summary(host_id, session_id)
    refute Map.has_key?(summary, :source_event_ids)
    assert summary.content =~ "events=105"

    assert repo().aggregate(
             from(link in SourceEvent, where: link.summary_id == ^summary.id),
             :count
           ) == 105
  end

  defp canonical_session(host_id, session_id, project, content) do
    ingest!(event(host_id, session_id, project, 1, "agent.session.started", "start"))
    ingest!(event(host_id, session_id, project, 2, "agent.prompt.submitted", content))
    ingest!(event(host_id, session_id, project, 3, "agent.session.ended", "done"))
    {:ok, result} = Rebuild.session(host_id, session_id)
    result
  end

  defp event(host, session, project, sequence, type, content) do
    valid_event(%{
      "event_id" => Ecto.UUID.generate(),
      "host_id" => host,
      "session_id" => session,
      "project" => project,
      "sequence" => sequence,
      "event_type" => type,
      "occurred_at" => "2026-08-04T01:0#{sequence}:00.000Z",
      "idempotency_key" => "#{host}:#{session}:#{sequence}:#{type}",
      "payload" => %{"message" => content}
    })
  end

  defp event_at(host, session, project, sequence, type, content, occurred_at) do
    event(host, session, project, sequence, type, content)
    |> Map.put("occurred_at", DateTime.to_iso8601(occurred_at))
    |> Map.put("captured_at", DateTime.to_iso8601(occurred_at))
  end

  defp ingest!(event) do
    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(
               ingest_auth_context(event["host_id"], %{partition: %{scope: event["scope"]}}),
               %{
                 "batch_id" => Ecto.UUID.generate(),
                 "host_id" => event["host_id"],
                 "events" => [event]
               }
             )
  end

  defp ingest_batch!(events) do
    host_id = hd(events)["host_id"]

    assert {:ok, %{"results" => results}} =
             Ingest.ingest_batch(
               ingest_auth_context(host_id, %{partition: %{scope: hd(events)["scope"]}}),
               %{
                 "batch_id" => Ecto.UUID.generate(),
                 "host_id" => host_id,
                 "events" => events
               }
             )

    assert Enum.all?(results, &(&1["status"] == "accepted"))
  end

  defp large_event(host, session, project, sequence, type) do
    occurred_at =
      ~U[2026-08-04 01:00:00.000Z]
      |> DateTime.add(sequence, :second)
      |> DateTime.to_iso8601()

    event(host, session, project, sequence, type, "event #{sequence}")
    |> Map.put("occurred_at", occurred_at)
  end

  defp refresh_payload_hash(event) do
    Map.put(
      event,
      "payload_hash",
      Backplane.Memory.Ingest.EventValidator.payload_hash(event["payload"])
    )
  end

  defp perform(host_id, session_id, input_revision) do
    SummaryWorker.perform(%Oban.Job{
      args: %{
        "host_id" => host_id,
        "session_id" => session_id,
        "processing_version" => "summary-v1",
        "input_revision" => input_revision
      }
    })
  end

  defp current_summary(host_id, session_id) do
    repo().one!(
      from(s in Summary,
        where:
          s.host_id == ^host_id and s.session_id == ^session_id and
            s.processing_version == "summary-v1"
      )
    )
  end

  defp state(subject_id, projector \\ "summary") do
    repo().one!(
      from(s in State, where: s.projector == ^projector and s.subject_id == ^subject_id)
    )
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
