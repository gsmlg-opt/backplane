defmodule Backplane.Diagnostics.Detectors do
  @moduledoc "Versioned, side-effect-free classifiers over bounded diagnostic observations."

  alias Backplane.Diagnostics.Events.Event
  alias Backplane.Diagnostics.Runs.Run

  @version 1
  @expected_outcomes ~w(cancelled rejected waiting)
  @transient_codes ~w(429 http_429 rate_limited connection_reset transport_timeout timeout)
  @legitimate_waits ~w(approval input manual scheduled normal child_agent)
  @protected_exits ~w(normal shutdown cancelled canceled killed_by_request approval_required)
  @environment_codes ~w(emfile enfile enospc disk_full oom oom_killed out_of_memory)
  @category_values ~w(software_defect upstream_failure environment_failure configuration_or_compatibility expected_control_flow agent_quality unknown)

  def defaults do
    %{
      restart_count: 3,
      restart_window_seconds: 600,
      stall_grace_seconds: 60,
      retry_count: 3,
      handoff_grace_seconds: 60,
      release_min_runs: 10,
      release_failure_delta_bps: 2_000,
      release_window_seconds: 86_400
    }
  end

  @doc "Evaluates independently versioned findings. The first supported finding is the most specific."
  def evaluate(%{event: %Event{} = event} = facts, policy \\ %{}) do
    policy = Map.merge(defaults(), policy)

    if get_in(event.body, ["quality", "origin"]) == "diagnostics" do
      []
    else
      Enum.reject(
        [
          contract(facts),
          environment(facts),
          restart(facts, policy),
          retry(facts, policy),
          handoff(facts, policy),
          regression(facts, policy),
          stall(facts, policy),
          exception(facts)
        ],
        &is_nil/1
      )
    end
  end

  def expected?(%Event{} = event) do
    result(event)["error_class"] == "expected_control_flow" or
      result(event)["outcome"] in @expected_outcomes or
      code(event) in @protected_exits
  end

  defp exception(%{event: %Event{event_type: type} = event})
       when type in ~w(exception handled_error worker_exit) do
    evidence = get_in(event.body, ["evidence", "exception"]) || %{}

    if not expected?(event) and not transient?(event) and
         (nonempty?(evidence["type"]) or nonempty?(code(event))) do
      fallback = if type == "handled_error", do: "unknown", else: "software_defect"
      category = if event.error_class in @category_values, do: event.error_class, else: fallback

      status =
        if result(event)["certainty"] in ~w(unknown insufficient_evidence),
          do: "candidate",
          else: "observed"

      severity =
        if category == "software_defect" and type != "handled_error", do: "high", else: "medium"

      finding(event, "program_exception", status, category, severity, %{
        "exception_type" => evidence["type"],
        "error_code" => code(event)
      })
    end
  end

  defp exception(_facts), do: nil

  defp contract(%{event: %Event{event_type: "contract_check"} = event} = facts) do
    contract = get_in(event.body, ["evidence", "contract"]) || %{}
    run = Map.get(facts, :run)
    terminal_event = Map.get(facts, :terminal_event)
    quality = get_in(event.body, ["quality"]) || %{}
    required = ~w(rule revision expected actual)

    cond do
      expected?(event) ->
        nil

      not Enum.all?(required, &plain_summary?(contract[&1])) or not terminal?(run) or
        run.outcome == "unknown_outcome" or not complete?(facts) or quality["truncated"] == true or
          result(event)["certainty"] != "observed" ->
        finding(
          event,
          "contract_violation",
          "insufficient_evidence",
          "agent_quality",
          "low",
          Map.put(
            Map.take(contract, required),
            "reason",
            "incomplete_contract_or_terminal_facts"
          ),
          [terminal_event]
        )

      contract["expected"] != contract["actual"] ->
        finding(
          event,
          "contract_violation",
          "observed",
          "agent_quality",
          "high",
          Map.take(contract, required),
          [terminal_event]
        )

      true ->
        nil
    end
  end

  defp contract(_facts), do: nil

  defp restart(%{event: %Event{event_type: "service_restart"} = event} = facts, policy) do
    service = event.body["service_instance"]

    if nonempty?(service) and not expected?(event) do
      previous = DateTime.add(event.occurred_at, -policy.restart_window_seconds, :second)

      matching =
        [event | related(facts)]
        |> Enum.filter(fn observation ->
          observation.source_id == event.source_id and observation.event_type == "service_restart" and
            observation.body["service_instance"] == service and not expected?(observation) and
            in_window?(observation.occurred_at, previous, event.occurred_at)
        end)
        |> Enum.uniq_by(&restart_identity/1)

      if length(matching) >= policy.restart_count do
        finding(
          event,
          "restart_burst",
          "observed",
          "unknown",
          "medium",
          %{
            "service" => service,
            "restarts" => length(matching),
            "window_seconds" => policy.restart_window_seconds
          },
          matching
        )
      end
    end
  end

  defp restart(_facts, _policy), do: nil

  defp restart_identity(event),
    do: get_in(event.body, ["correlation", "process_instance"]) || event.id

  defp stall(%{event: %Event{event_type: type} = event, run: %Run{} = run} = facts, policy)
       when type in ~w(run_progress run_waiting) do
    now = Map.get(facts, :now, event.received_at)

    cond do
      terminal?(run) or run.wait_kind in @legitimate_waits ->
        nil

      run.deadline_at && DateTime.compare(now, run.deadline_at) != :gt ->
        nil

      Map.get(facts, :health) == :disconnected or not complete?(facts) ->
        details = %{
          "reason" =>
            if(Map.get(facts, :health) == :disconnected,
              do: "disconnected",
              else: "observation_gap"
            )
        }

        finding(event, "suspected_stall", "insufficient_evidence", "unknown", "low", details)

      (nonempty?(run.phase) and run.deadline_at) && run.last_progress_at &&
        nonempty?(run.wait_kind) &&
        Map.get(facts, :health) == :healthy &&
          DateTime.diff(now, run.last_progress_at) >= policy.stall_grace_seconds ->
        finding(event, "suspected_stall", "candidate", "unknown", "low", %{
          "phase" => run.phase,
          "deadline_at" => DateTime.to_iso8601(run.deadline_at),
          "last_progress_at" => DateTime.to_iso8601(run.last_progress_at),
          "wait_kind" => run.wait_kind
        })

      true ->
        nil
    end
  end

  defp stall(_facts, _policy), do: nil

  defp retry(%{event: %Event{event_type: type} = event} = facts, policy)
       when type in ~w(provider_attempt tool_attempt handled_error) do
    operation = operation(event)
    marker = progress_checkpoint(event)
    error_code = code(event)

    if nonempty?(operation) && nonempty?(error_code) && not is_nil(marker) &&
         retry_failure?(event) &&
         not terminal?(Map.get(facts, :run)) do
      matching =
        [event | related(facts)]
        |> Enum.filter(fn observation ->
          observation.source_id == event.source_id and observation.run_id == event.run_id and
            operation(observation) == operation and progress_checkpoint(observation) == marker and
            code(observation) == error_code and retry_failure?(observation) and
            nonempty?(observation.attempt_id)
        end)
        |> Enum.uniq_by(& &1.attempt_id)

      if complete?(facts) and length(matching) >= policy.retry_count do
        finding(
          event,
          "retry_without_progress",
          "candidate",
          "upstream_failure",
          "medium",
          %{"error_code" => error_code, "attempts" => length(matching), "checkpoint" => marker},
          matching
        )
      end
    end
  end

  defp retry(_facts, _policy), do: nil

  defp handoff(%{event: %Event{event_type: type} = event, run: %Run{} = parent} = facts, policy)
       when type in ~w(handoff run_waiting) do
    child = Map.get(facts, :child_run)
    child_event = Map.get(facts, :child_terminal_event)
    now = Map.get(facts, :now, event.received_at)

    if parent.wait_kind == "child_agent" and is_nil(parent.outcome) do
      cond do
        not complete?(facts) ->
          finding(event, "handoff_anomaly", "insufficient_evidence", "unknown", "low", %{
            "reason" => "observation_gap"
          })

        terminal?(child) and child.parent_run_id == parent.run_id and not is_nil(child_event) and
            DateTime.diff(now, child_event.occurred_at) >= policy.handoff_grace_seconds ->
          finding(
            event,
            "handoff_anomaly",
            "candidate",
            "agent_quality",
            "medium",
            %{"child_outcome" => child.outcome, "parent_phase" => parent.phase},
            [child_event]
          )

        true ->
          nil
      end
    end
  end

  defp handoff(_facts, _policy), do: nil

  defp environment(%{event: %Event{} = event} = facts) do
    failure_code = normalize_environment(code(event))

    if failure_code && not expected?(event) do
      correlated = Enum.filter(related(facts), &environment_evidence?(&1, event, failure_code))

      if correlated != [] do
        finding(
          event,
          "environment_correlated_failure",
          "observed",
          "environment_failure",
          "high",
          %{"condition" => failure_code},
          correlated
        )
      end
    end
  end

  defp environment_evidence?(observation, event, condition) do
    same_process = nonempty?(process_id(event)) and process_id(observation) == process_id(event)

    same_service =
      nonempty?(event.body["service_instance"]) and
        event.source_id == observation.source_id and
        event.body["service_instance"] == observation.body["service_instance"]

    observation.event_type in ~w(process_exit resource_sample crash_artifact) and
      (same_process or same_service) and not expected?(observation) and
      normalize_environment(code(observation)) == condition and
      abs(DateTime.diff(event.occurred_at, observation.occurred_at)) <= 120
  end

  defp regression(
         %{event: %Event{event_type: "run_finished"} = event, run: %Run{} = run} = facts,
         policy
       ) do
    if run.outcome in ~w(success failure) and nonempty?(run.release) and nonempty?(run.workload) and
         complete?(facts) do
      cohorts = Map.get(facts, :release_runs, [])
      {current, prior} = Enum.split_with(cohorts, &(&1.release == run.release))
      baseline_release = Enum.find_value(prior, & &1.release)
      baseline = Enum.filter(prior, &(&1.release == baseline_release))

      if cohort?(current, run, policy) and cohort?(baseline, run, policy) do
        current_failed = failures(current)
        baseline_failed = failures(baseline)

        delta =
          div(current_failed * 10_000, length(current)) -
            div(baseline_failed * 10_000, length(baseline))

        if delta >= policy.release_failure_delta_bps do
          finding(
            event,
            "release_regression",
            "candidate",
            "unknown",
            "medium",
            %{
              "release" => run.release,
              "baseline_release" => baseline_release,
              "workload" => run.workload,
              "run_count" => length(current),
              "failures" => current_failed,
              "baseline_run_count" => length(baseline),
              "baseline_failures" => baseline_failed,
              "failure_delta_bps" => delta
            },
            Enum.map(current ++ baseline, & &1.state_event_key)
          )
        end
      end
    end
  end

  defp regression(_facts, _policy), do: nil

  defp cohort?(runs, expected, policy) do
    length(runs) >= policy.release_min_runs and
      length(Enum.uniq_by(runs, & &1.run_id)) == length(runs) and
      Enum.all?(runs, fn run ->
        run.source_id == expected.source_id and run.workload == expected.workload and
          run.outcome in ~w(success failure) and not quality_gap?(run)
      end)
  end

  defp failures(runs), do: Enum.count(runs, &(&1.outcome == "failure"))

  defp finding(event, rule, status, category, severity, details, related \\ []) do
    ids =
      [event | related]
      |> Enum.map(&event_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(100)

    %{
      rule: rule,
      version: @version,
      status: status,
      category: category,
      severity: severity,
      details: details,
      evidence_event_ids: ids
    }
  end

  defp related(facts), do: Map.get(facts, :related, [])
  defp event_id(%Event{id: id}), do: id
  defp event_id(id) when is_integer(id), do: id
  defp event_id(_), do: nil
  defp result(event), do: event.body["result"] || %{}
  defp operation(event), do: get_in(event.body, ["subject", "operation_id"])

  defp progress_checkpoint(event),
    do: result(event)["last_progress_at"] || get_in(event.body, ["subject", "revision"])

  defp code(event),
    do: result(event)["reason_code"] || get_in(event.body, ["evidence", "exception", "code"])

  defp process_id(event), do: get_in(event.body, ["correlation", "process_instance"])
  defp terminal?(%Run{outcome: outcome}), do: nonempty?(outcome)
  defp terminal?(_), do: false

  defp transient?(event),
    do: result(event)["retryable"] == true and code(event) in @transient_codes

  defp retry_failure?(event),
    do:
      not expected?(event) and result(event)["outcome"] == "failure" and
        result(event)["retryable"] == true

  defp in_window?(time, from, to),
    do: not DateTime.before?(time, from) and not DateTime.after?(time, to)

  defp quality_gap?(%Run{} = run),
    do: run.source_gap or run.sampled or run.truncated or run.clock_skew

  defp quality_gap?(_), do: false

  defp complete?(facts) do
    event_quality = facts.event.body["quality"] || %{}

    not Map.get(facts, :gap, false) and not quality_gap?(Map.get(facts, :run)) and
      not is_integer(event_quality["source_gap"]) and event_quality["sampled"] != true
  end

  defp normalize_environment(code) when is_binary(code) do
    case String.downcase(code) do
      value when value in @environment_codes and value in ~w(oom oom_killed out_of_memory) ->
        "oom"

      value when value in @environment_codes and value in ~w(enospc disk_full) ->
        "enospc"

      value when value in @environment_codes ->
        value

      _ ->
        nil
    end
  end

  defp normalize_environment(_), do: nil
  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0

  defp plain_summary?(value),
    do: nonempty?(value) and value not in ["[REDACTED]", "[TRUNCATED]", "[UNAVAILABLE]"]
end
