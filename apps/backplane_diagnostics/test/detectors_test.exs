defmodule Backplane.Diagnostics.DetectorsTest do
  use ExUnit.Case, async: true

  alias Backplane.Diagnostics.Detectors
  alias Backplane.Diagnostics.Events.Event
  alias Backplane.Diagnostics.Runs.Run

  @now ~U[2026-11-28 12:00:00Z]

  test "expected worker exits and rate limits do not become program exceptions" do
    for {outcome, code} <- [
          {"cancelled", "error"},
          {"failure", "normal"},
          {"waiting", "approval_required"}
        ] do
      event = event(1, "worker_exit", %{"outcome" => outcome, "reason_code" => code})
      assert Detectors.evaluate(%{event: event}) == []
    end

    transient =
      event(1, "handled_error", %{
        "outcome" => "failure",
        "reason_code" => "429",
        "retryable" => true
      })

    assert Detectors.evaluate(%{event: transient}) == []
  end

  test "a confirmed program exception attaches its evidence and ignores diagnostics-origin failures" do
    event = event(1, "exception", %{"outcome" => "failure", "reason_code" => "badarg"})

    assert [
             %{
               rule: "program_exception",
               version: 1,
               status: "observed",
               category: "software_defect",
               evidence_event_ids: [1]
             }
           ] =
             Detectors.evaluate(%{event: event})

    recursive = %{event | body: put_in(event.body, ["quality", "origin"], "diagnostics")}
    assert Detectors.evaluate(%{event: recursive}) == []
  end

  test "only explicit comparable service incarnations count toward a restart burst" do
    event = service(8, "service-a", "proc-3")

    related = [
      service(5, "service-a", "proc-1"),
      service(6, "service-a", "proc-2"),
      service(7, "service-a", "proc-1"),
      service(9, "service-b", "proc-9")
    ]

    assert [
             %{
               rule: "restart_burst",
               status: "observed",
               category: "unknown",
               details: %{"restarts" => 3}
             }
           ] =
             Detectors.evaluate(%{event: event, related: related})

    assert Detectors.evaluate(%{event: event, related: [service(6, "service-b", "proc-2")]}) == []
  end

  test "tracks collection disconnection and never converts a legitimate wait to a stall" do
    progress = event(1, "run_progress", %{})

    overdue = %Run{
      phase: "moving",
      wait_kind: "upstream",
      deadline_at: DateTime.add(@now, -120),
      last_progress_at: DateTime.add(@now, -130)
    }

    assert [%{rule: "suspected_stall", status: "candidate"}] =
             Detectors.evaluate(%{event: progress, run: overdue, health: :healthy})

    assert [
             %{
               rule: "suspected_stall",
               status: "insufficient_evidence",
               details: %{"reason" => "disconnected"}
             }
           ] =
             Detectors.evaluate(%{event: progress, run: overdue, health: :disconnected})

    assert [
             %{
               rule: "suspected_stall",
               status: "insufficient_evidence",
               details: %{"reason" => "observation_gap"}
             }
           ] =
             Detectors.evaluate(%{event: progress, run: overdue, health: :healthy, gap: true})

    assert Detectors.evaluate(%{
             event: progress,
             run: %{overdue | wait_kind: "approval"},
             health: :healthy
           }) == []

    assert Detectors.evaluate(%{
             event: progress,
             run: %{overdue | deadline_at: DateTime.add(@now, 5)},
             health: :disconnected
           }) == []
  end

  test "requires distinct attempt IDs with one operation, stable failure and no progress" do
    current = attempt(4, "three")
    related = [attempt(1, "one"), attempt(2, "two"), attempt(3, "two")]

    assert [%{rule: "retry_without_progress", status: "candidate", details: %{"attempts" => 3}}] =
             Detectors.evaluate(%{event: current, related: related})

    assert Detectors.evaluate(%{event: current, related: [attempt(2, "two"), attempt(3, "two")]}) ==
             []

    assert Detectors.evaluate(%{event: current, related: related, run: %Run{outcome: "success"}}) ==
             []
  end

  test "handoff inference requires the confirmed child's terminal facts and a still-waiting parent" do
    event = event(2, "run_waiting", %{"outcome" => "waiting"})

    child_event = %{
      event(1, "run_finished", %{"outcome" => "success"})
      | occurred_at: DateTime.add(@now, -300)
    }

    parent = %Run{run_id: "parent", phase: "wait", wait_kind: "child_agent"}
    child = %Run{run_id: "child", parent_run_id: "parent", outcome: "success"}
    facts = %{event: event, run: parent, child_run: child, child_terminal_event: child_event}

    assert [%{rule: "handoff_anomaly", status: "candidate", evidence_event_ids: [2, 1]}] =
             Detectors.evaluate(facts)

    assert [%{status: "insufficient_evidence"}] = Detectors.evaluate(Map.put(facts, :gap, true))
    assert Detectors.evaluate(%{facts | child_run: %{child | parent_run_id: "unrelated"}}) == []
  end

  test "an environment classification needs matching host evidence, not merely a failure code" do
    failure =
      event(1, "handled_error", %{"outcome" => "failure", "reason_code" => "oom"}, %{
        "correlation" => %{"process_instance" => "a"}
      })

    unrelated =
      event(2, "process_exit", %{"reason_code" => "oom_killed"}, %{
        "correlation" => %{"process_instance" => "b"}
      })

    supporting =
      event(3, "process_exit", %{"reason_code" => "oom_killed"}, %{
        "correlation" => %{"process_instance" => "a"}
      })

    assert [%{rule: "program_exception", category: "unknown"}] =
             Detectors.evaluate(%{event: failure, related: [unrelated]})

    assert [
             %{
               rule: "environment_correlated_failure",
               category: "environment_failure",
               details: %{"condition" => "oom"}
             }
             | _
           ] =
             Detectors.evaluate(%{event: failure, related: [supporting]})
  end

  test "release comparisons require comparable coverage and report separate denominators" do
    event = event(20, "run_finished", %{"outcome" => "failure"})

    current = %Run{
      source_id: "source",
      workload: "math",
      release: "new",
      outcome: "failure",
      run_id: "a",
      state_event_key: 20
    }

    comparison = [
      current,
      %{current | run_id: "b", state_event_key: 19},
      %{current | run_id: "c", release: "previous", outcome: "success", state_event_key: 18},
      %{current | run_id: "d", release: "previous", outcome: "success", state_event_key: 17}
    ]

    facts = %{event: event, run: current, release_runs: comparison}
    policy = %{release_min_runs: 2}

    assert [
             %{
               rule: "release_regression",
               status: "candidate",
               details: %{
                 "run_count" => 2,
                 "failures" => 2,
                 "baseline_run_count" => 2,
                 "baseline_failures" => 0
               }
             }
           ] =
             Detectors.evaluate(facts, policy)

    assert Detectors.evaluate(
             %{facts | release_runs: [%{current | sampled: true} | tl(comparison)]},
             policy
           ) == []

    assert Detectors.evaluate(facts) == []
  end

  defp event(id, type, result, extra \\ %{}) do
    %Event{
      id: id,
      source_id: "source",
      event_type: type,
      occurred_at: @now,
      received_at: @now,
      run_id: "run",
      attempt_id: extra["attempt_id"],
      body: Map.merge(%{"result" => result, "quality" => %{}}, extra)
    }
  end

  defp service(id, service, process) do
    event(id, "service_restart", %{}, %{
      "service_instance" => service,
      "correlation" => %{"process_instance" => process}
    })
  end

  defp attempt(id, attempt) do
    event(
      id,
      "provider_attempt",
      %{"outcome" => "failure", "reason_code" => "429", "retryable" => true},
      %{"attempt_id" => attempt, "subject" => %{"operation_id" => "retry", "revision" => 1}}
    )
  end
end
