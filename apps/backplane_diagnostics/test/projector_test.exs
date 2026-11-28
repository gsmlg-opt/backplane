defmodule Backplane.Diagnostics.ProjectorTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Backplane.Diagnostics.{
    Events,
    Findings,
    Issues,
    Occurrences,
    Outbox,
    Projector,
    Queries,
    Resolutions,
    Runs,
    Sources
  }

  alias Backplane.DiagnosticsClient.{Envelope, Receipt}
  alias Backplane.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup tags do
    unless tags[:unboxed], do: BackplaneDataCase.setup_sandbox(Repo, tags)
    :ok
  end

  test "corroborates three observations, groups independent attempts, and ignores replay" do
    ctx = register_source()

    events = [
      received(ctx, 1, crash("attempt-1", "occurrence-1", "phoenix")),
      received(ctx, 2, crash("attempt-1", "occurrence-1", "logger")),
      received(
        ctx,
        3,
        Map.put(crash("attempt-1", "occurrence-1", "task"), "event_type", "worker_exit")
      ),
      received(ctx, 4, crash("attempt-2", "occurrence-2", "phoenix"))
    ]

    for event <- events, do: assert({:ok, :processed} = Projector.project(event.id))

    issue = lookup_issue(ctx.source)

    assert %Issues.Issue{category: "software_defect", severity: "high", occurrence_count: 2} =
             issue

    assert Issues.counts(issue.id) == %{events: 4, occurrences: 2, runs: 1}
    assert length(Issues.events(issue.id)) == 4

    for event <- Enum.reverse(events),
        do: assert({:ok, :already_processed} = Projector.project(event.id))

    assert Issues.get(issue.id).occurrence_count == 2
    assert Issues.counts(issue.id) == %{events: 4, occurrences: 2, runs: 1}
    assert pending_count(ctx.source) == 0
    assert %Issues.Change{kind: "opened"} = Repo.get!(Issues.Change, issue.id)
  end

  test "keeps an unsuccessful retry and expected control flow in the source's successful run" do
    ctx = register_source()

    for {seq, attrs} <- [
          {1, state("run_started", 1, %{"phase" => "planning"})},
          {2,
           %{
             "event_type" => "provider_attempt",
             "subject" => %{"run_id" => "run", "attempt_id" => "failing"},
             "result" => %{"outcome" => "failure", "reason_code" => "429", "retryable" => true}
           }},
          {3,
           state("run_waiting", 2, %{
             "phase" => "waiting",
             "outcome" => "waiting",
             "wait_kind" => "approval"
           })},
          {4, state("run_finished", 3, %{"phase" => "finished", "outcome" => "success"})}
        ] do
      row = received(ctx, seq, attrs)
      assert {:ok, :processed} = Projector.project(row.id)
    end

    assert %Runs.Run{outcome: "success", native_revision: 3} = Runs.get(ctx.source, "run")

    assert Enum.any?(
             Runs.events(ctx.source, "run"),
             &(&1.event.attempt_id == "failing" and &1.disposition == "context")
           )

    refute lookup_issue(ctx.source)
  end

  test "keeps late and conflicting observations without rewinding the native revision or hiding gaps" do
    ctx = register_source()

    newer =
      received(ctx, 3, state("run_finished", 3, %{"phase" => "finished", "outcome" => "success"}))

    assert {:ok, :processed} = Projector.project(newer.id)
    assert %{missing: 2} = Projector.source_epoch(ctx.source, "epoch")

    older = received(ctx, 1, state("run_started", 1, %{"phase" => "planning"}))
    assert {:ok, :processed} = Projector.project(older.id)
    assert %{missing: 1} = Projector.source_epoch(ctx.source, "epoch")

    middle = received(ctx, 2, state("run_progress", 2, %{"phase" => "running"}))
    assert {:ok, :processed} = Projector.project(middle.id)

    assert %{highest_sequence: 3, observed: 3, missing: 0} =
             Projector.source_epoch(ctx.source, "epoch")

    conflict =
      received(ctx, 4, state("run_finished", 3, %{"phase" => "finished", "outcome" => "failure"}))

    assert {:ok, :processed} = Projector.project(conflict.id)

    assert %Runs.Run{phase: "finished", outcome: "success", native_revision: 3} =
             Runs.get(ctx.source, "run")

    dispositions = Map.new(Runs.events(ctx.source, "run"), &{&1.event.id, &1.disposition})

    assert dispositions == %{
             newer.id => "applied",
             older.id => "late",
             middle.id => "late",
             conflict.id => "conflict"
           }
  end

  test "promotes an early contract check only when confirmed terminal evidence arrives" do
    ctx = register_source()

    check =
      received(ctx, 1, %{
        "event_type" => "contract_check",
        "subject" => %{"run_id" => "run"},
        "result" => %{"certainty" => "observed"},
        "evidence" => %{
          "contract" => %{
            "rule" => "tool_output",
            "revision" => "v1",
            "expected" => "structured",
            "actual" => "text"
          }
        }
      })

    assert {:ok, :processed} = Projector.project(check.id)
    assert [%Findings.Finding{status: "insufficient_evidence"}] = Findings.for_event(check.id)
    refute lookup_issue(ctx.source)

    terminal =
      received(ctx, 2, state("run_finished", 2, %{"phase" => "done", "outcome" => "success"}))

    assert {:ok, :processed} = Projector.project(terminal.id)

    assert [
             %Findings.Finding{
               rule: "contract_violation",
               rule_version: 1,
               status: "observed",
               details: details,
               evidence_event_ids: evidence
             }
           ] = Findings.for_event(check.id)

    assert %{"expected" => "structured", "actual" => "text", "revision" => "v1"} = details
    assert evidence == [check.id, terminal.id]

    assert %Issues.Issue{category: "agent_quality", occurrence_count: 1} =
             lookup_issue(ctx.source)

    assert %Runs.Run{outcome: "success"} = Runs.get(ctx.source, "run")
  end

  test "rolls back claims, counts, and issue changes together before retry" do
    ctx = register_source()
    row = received(ctx, 1, crash("attempt-1", "one", "phoenix"))

    assert {:error, :interrupted_projection} =
             Repo.transact(fn ->
               assert {:ok, :processed} = Projector.project(row.id)
               assert %Issues.Issue{occurrence_count: 1} = lookup_issue(ctx.source)
               Repo.rollback(:interrupted_projection)
             end)

    refute lookup_issue(ctx.source)
    assert %Outbox.Entry{} = Repo.get(Outbox.Entry, row.id)
    assert Projector.source_epoch(ctx.source, "epoch") == nil
    assert {:ok, :processed} = Projector.project(row.id)
    assert %Issues.Issue{occurrence_count: 1} = lookup_issue(ctx.source)
  end

  test "correlates a handoff to an explicit native child without interpreting causation as a run ID" do
    ctx = register_source()

    child =
      received(ctx, 1, %{
        "event_type" => "run_finished",
        "subject" => %{"run_id" => "child", "parent_run_id" => "parent", "revision" => 1},
        "result" => %{"outcome" => "success"}
      })

    parent =
      received(ctx, 2, %{
        "event_type" => "run_waiting",
        "subject" => %{"run_id" => "parent", "child_run_id" => "child", "revision" => 1},
        "correlation" => %{"causation_id" => "other-event"},
        "result" => %{"outcome" => "waiting", "phase" => "running", "wait_kind" => "child_agent"}
      })

    assert {:ok, :processed} = Projector.project(child.id)
    assert {:ok, :processed} = Projector.project(parent.id)

    assert [
             %Findings.Finding{
               rule: "handoff_anomaly",
               status: "candidate",
               evidence_event_ids: ids
             }
           ] = Findings.for_event(parent.id)

    assert ids == [parent.id, child.id]
    assert %Runs.Run{outcome: nil} = Runs.get(ctx.source, "parent")
  end

  test "can split and merge selected memberships with typed audit records and stable counts" do
    ctx = register_source()

    for {sequence, hint} <- [{1, "one"}, {2, "two"}] do
      row = received(ctx, sequence, crash("attempt-#{sequence}", hint, "phoenix"))
      assert {:ok, :processed} = Projector.project(row.id)
    end

    original = lookup_issue(ctx.source)
    [moved, _remaining] = Issues.occurrences(original.id)

    assert {:ok, %Issues.Issue{occurrence_count: 1} = split} =
             Issues.split(original.id, [moved.id], "operator")

    assert Issues.counts(original.id) == %{occurrences: 1, runs: 1, events: 1}
    assert Issues.counts(split.id) == %{occurrences: 1, runs: 1, events: 1}
    assert %Issues.Change{kind: "manual"} = Repo.get!(Issues.Change, split.id)

    assert {:ok, 1} = Issues.reassign(split.id, original.id, [moved.id], "operator")
    assert %Issues.Issue{occurrence_count: 2} = Issues.get(original.id)
    assert %Issues.Issue{occurrence_count: 0} = Issues.get(split.id)

    assert [
             %Issues.GroupingAction{actor: "operator", inserted_at: %DateTime{}},
             %Issues.GroupingAction{actor: "operator"}
           ] =
             Repo.all(
               from row in Issues.GroupingAction,
                 where: row.occurrence_id == ^moved.id,
                 order_by: row.id
             )
  end

  test "merges every membership and routes subsequent matching fingerprints to the canonical issue" do
    ctx = register_source()
    source_event = received(ctx, 1, crash("source-attempt", "source-fault", "phoenix"))
    target_event = received(ctx, 2, distinct_crash("target-attempt", "target-fault"))

    for event <- [source_event, target_event],
        do: assert({:ok, :processed} = Projector.project(event.id))

    source = issue_for_event(source_event)
    target = issue_for_event(target_event)
    assert source.id != target.id
    assert {:ok, source_id} = Queries.parse_id(Integer.to_string(source.id))
    assert {:ok, target_id} = Queries.parse_id(Integer.to_string(target.id))

    assert {:error, :invalid_grouping_action} =
             Issues.merge(9_223_372_036_854_775_808, target_id, "operator")

    assert {:error, :invalid_occurrences} =
             Issues.split(source_id, [9_223_372_036_854_775_808], "operator")

    assert {:ok, %Issues.Issue{id: ^target_id, occurrence_count: 2}} =
             Issues.merge(source_id, target_id, "operator")

    assert %Issues.Issue{status: "duplicate", occurrence_count: 0, fingerprint: fingerprint} =
             Issues.get(source_id)

    assert fingerprint == source.fingerprint
    assert Issues.merged_into(source_id) == target_id
    assert Issues.counts(source_id) == %{events: 0, occurrences: 0, runs: 0}
    assert Issues.counts(target_id) == %{events: 2, occurrences: 2, runs: 1}
    assert {:error, :already_merged} = Issues.merge(target_id, source_id, "operator")

    assert [%Issues.GroupingAction{actor: "operator", to_issue_id: ^target_id}] =
             Repo.all(from row in Issues.GroupingAction, where: row.from_issue_id == ^source_id)

    assert %Resolutions.ManagementAction{
             issue_id: ^source_id,
             entity_id: ^target_id,
             actor: "operator"
           } =
             Repo.get_by!(Resolutions.ManagementAction,
               issue_id: source_id,
               action: "issue_merged_into"
             )

    later = received(ctx, 3, crash("source-second-attempt", "source-second-fault", "phoenix"))
    assert {:ok, :processed} = Projector.project(later.id)
    assert issue_for_event(later).id == target_id
    assert Issues.counts(target_id) == %{events: 3, occurrences: 3, runs: 1}
    assert Issues.get(source_id).occurrence_count == 0
  end

  test "leaves verified resolution evidence and memberships intact when regrouping is rejected" do
    ctx = register_source()
    original = received(ctx, 1, crash("source-attempt", "source-fault", "phoenix"))
    second = received(ctx, 2, crash("source-second-attempt", "source-second-fault", "phoenix"))
    unrelated = received(ctx, 3, distinct_crash("target-attempt", "target-fault"))

    for event <- [original, second, unrelated],
        do: assert({:ok, :processed} = Projector.project(event.id))

    source = issue_for_event(original)
    target = issue_for_event(unrelated)
    [occurrence | _] = Issues.occurrences(source.id)

    assert {:ok, resolution} =
             Resolutions.propose(
               source.id,
               %{
                 "repository" => "gsmlg-opt/backplane",
                 "fix_sha" => String.duplicate("a", 40),
                 "releases" => ["fixed"],
                 "source_ids" => [ctx.source],
                 "workload" => "fixture"
               },
               "operator"
             )

    assert {:ok, verified} =
             Resolutions.record_check(
               resolution.id,
               "fixed_in_test",
               "fixture runner",
               "operator"
             )

    assert verified.test_state == "fixed_in_test"
    assert {:error, :resolution_history} = Issues.merge(source.id, target.id, "operator")
    assert {:error, :resolution_history} = Issues.merge(target.id, source.id, "operator")
    assert {:error, :resolution_history} = Issues.split(source.id, [occurrence.id], "operator")

    assert {:error, :resolution_history} =
             Issues.reassign(source.id, target.id, [occurrence.id], "operator")

    assert Resolutions.get(resolution.id) == verified
    assert Repo.get_by!(Resolutions.Check, resolution_id: resolution.id).state == "fixed_in_test"
    assert Issues.counts(source.id) == %{events: 2, occurrences: 2, runs: 1}
    assert Issues.counts(target.id) == %{events: 1, occurrences: 1, runs: 1}
    assert Issues.merged_into(source.id) == nil

    refute Repo.exists?(
             from row in Issues.GroupingAction,
               where: row.from_issue_id in ^[source.id, target.id]
           )
  end

  @tag :unboxed
  test "separate PostgreSQL connections cannot double-count concurrent identities" do
    ctx = Sandbox.unboxed_run(Repo, &register_source/0)
    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> clean_source(ctx) end) end)
    supervisor = start_supervised!(Task.Supervisor)

    Sandbox.unboxed_run(Repo, fn ->
      first = received(ctx, 1, crash("attempt-1", "one", "phoenix"))
      corroboration = received(ctx, 2, crash("attempt-1", "one", "logger"))
      second = received(ctx, 3, crash("attempt-2", "two", "phoenix"))
      parent = self()

      tasks =
        for event <- [first, first, corroboration, second] do
          Task.Supervisor.async_nolink(supervisor, fn ->
            Sandbox.unboxed_run(Repo, fn ->
              %{rows: [[connection]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:ready, connection})

              receive do
                :start -> Projector.project(event.id)
              after
                5_000 -> exit(:timed_out)
              end
            end)
          end)
        end

      connections =
        for _ <- tasks do
          assert_receive {:ready, connection}, 5_000
          connection
        end

      assert length(Enum.uniq(connections)) == 4
      for task <- tasks, do: send(task.pid, :start)

      assert Enum.frequencies(Task.await_many(tasks, 10_000)) == %{
               {:ok, :processed} => 3,
               {:ok, :already_processed} => 1
             }

      issue = lookup_issue(ctx.source)
      assert issue.occurrence_count == 2
      assert Issues.counts(issue.id) == %{events: 3, occurrences: 2, runs: 1}
    end)
  end

  defp register_source do
    suffix = Ecto.UUID.generate()
    source = "projector-#{suffix}"

    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO skill_hosts (name, inserted_at, updated_at) VALUES ($1, NOW(), NOW()) RETURNING id",
        [source]
      )

    host = Ecto.UUID.load!(id)
    assert {:ok, _} = Sources.register(host, %{id: source, application: source})
    %{source: source, host: host}
  end

  defp received(ctx, seq, attrs) do
    body =
      Map.merge(
        %{
          "schema_version" => 1,
          "application" => ctx.source,
          "source_id" => ctx.source,
          "producer_epoch" => "epoch",
          "source_sequence" => seq,
          "event_id" => "event-#{seq}",
          "occurred_at" =>
            DateTime.utc_now() |> DateTime.add(seq - 1_000) |> DateTime.to_iso8601(),
          "quality" => %{"redaction_policy_version" => 1}
        },
        attrs
      )

    {:ok, _, digest} = Envelope.seal(body)

    assert %{"receipts" => [%{"status" => "stored"}]} =
             Events.ingest(ctx.host, "batch-#{seq}", [Receipt.entry(body, digest)])

    Repo.get_by!(Events.Event, source_id: ctx.source, event_id: body["event_id"])
  end

  defp state(type, revision, result) do
    %{
      "event_type" => type,
      "subject" => %{"run_id" => "run", "revision" => revision},
      "result" => result
    }
  end

  defp crash(attempt, hint, phase) do
    %{
      "event_type" => "exception",
      "subject" => %{"run_id" => "run", "attempt_id" => attempt},
      "result" => %{"outcome" => "failure", "error_class" => "software_defect", "phase" => phase},
      "correlation" => %{"occurrence_hint" => hint},
      "evidence" => %{
        "exception" => %{
          "type" => "RuntimeError",
          "code" => "error",
          "stack" => [%{"module" => "Example", "function" => "call", "arity" => 1, "line" => 25}]
        }
      }
    }
  end

  defp distinct_crash(attempt, hint) do
    put_in(
      crash(attempt, hint, "phoenix"),
      ["evidence", "exception", "type"],
      "MergeDestinationFault"
    )
  end

  defp issue_for_event(event) do
    [%Findings.Finding{occurrence_id: id}] = Findings.for_event(event.id)
    Issues.get(Issues.issue_for_occurrence(id))
  end

  defp lookup_issue(source) do
    Repo.one(
      from issue in Issues.Issue,
        join: membership in Issues.Membership,
        on: membership.issue_id == issue.id,
        join: occurrence in Occurrences.Occurrence,
        on: occurrence.id == membership.occurrence_id,
        where: occurrence.source_id == ^source,
        distinct: true
    )
  end

  defp pending_count(source) do
    Repo.aggregate(
      from(row in Outbox.Entry,
        join: event in Events.Event,
        on: event.id == row.event_key,
        where: event.source_id == ^source
      ),
      :count
    )
  end

  defp clean_source(ctx) do
    source = ctx.source

    event_ids =
      Repo.all(from row in Events.Event, where: row.source_id == ^source, select: row.id)

    occurrence_ids =
      Repo.all(
        from row in Occurrences.Occurrence, where: row.source_id == ^source, select: row.id
      )

    issue_ids =
      Repo.all(
        from row in Issues.Membership,
          where: row.occurrence_id in ^occurrence_ids,
          select: row.issue_id,
          distinct: true
      )

    Repo.delete_all(from row in Findings.Finding, where: row.event_key in ^event_ids)
    Repo.delete_all(from row in Issues.Change, where: row.issue_id in ^issue_ids)

    Repo.delete_all(
      from row in "diagnostics_issue_evidence_kinds", where: field(row, :issue_id) in ^issue_ids
    )

    Repo.delete_all(from row in Issues.Membership, where: row.occurrence_id in ^occurrence_ids)
    Repo.delete_all(from row in Issues.Issue, where: row.id in ^issue_ids)
    Repo.delete_all(from row in Occurrences.Evidence, where: row.occurrence_id in ^occurrence_ids)
    Repo.delete_all(from row in Occurrences.Occurrence, where: row.id in ^occurrence_ids)
    Repo.delete_all(from row in Runs.Observation, where: row.event_key in ^event_ids)
    Repo.delete_all(from row in Runs.Run, where: row.source_id == ^source)
    Repo.delete_all(from row in Projector.SourceEpoch, where: row.source_id == ^source)
    Repo.delete_all(from row in Projector.Claim, where: row.source_id == ^source)
    Repo.delete_all(from row in Outbox.Entry, where: row.event_key in ^event_ids)
    Repo.delete_all(from row in Events.Event, where: row.id in ^event_ids)
    Repo.delete_all(from row in Events.Received, where: row.source_id == ^source)
    Repo.delete!(Repo.get!(Sources.Source, source))
    Repo.query!("DELETE FROM skill_hosts WHERE id = $1", [Ecto.UUID.dump!(ctx.host)])
  end
end
