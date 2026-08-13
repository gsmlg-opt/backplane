defmodule Backplane.Memory.Workers.LessonCandidateWorker do
  @moduledoc "Extracts one bounded lesson candidate from a durable projected event."

  use Oban.Worker,
    queue: :memory_lessons,
    max_attempts: 3,
    unique: [period: :infinity, states: :all, keys: [:event_id, :processing_version]]

  import Ecto.Query

  alias Backplane.Memory.Config
  alias Backplane.Memory.Lessons
  alias Backplane.Memory.Projections.ProjectedObservation

  @processing_version "lesson-candidate-v1"
  @tool_terminal_event_types ~w(agent.tool.failed tool.call.failed agent.tool.completed tool.call.completed)

  def enqueue(event_id) when is_binary(event_id) do
    if Config.lesson_auto_extract?() do
      %{"event_id" => event_id, "processing_version" => @processing_version}
      |> new()
      |> Oban.insert()
    else
      {:ok, :disabled}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"event_id" => event_id, "processing_version" => @processing_version} = args
      })
      when is_binary(event_id) do
    Backplane.Memory.PipelineTelemetry.span("lesson.candidate", args, fn ->
      if Config.lesson_auto_extract?(), do: extract(event_id), else: :ok
    end)
  end

  def perform(%Oban.Job{args: args}) do
    Backplane.Memory.PipelineTelemetry.span("lesson.candidate", args, fn ->
      {:cancel, :invalid_arguments}
    end)
  end

  defp extract(event_id) do
    case repo().get(ProjectedObservation, event_id) do
      %ProjectedObservation{} = observation -> extract_observation(observation)
      nil -> :ok
    end
  end

  defp extract_observation(%ProjectedObservation{event_type: "agent.prompt.submitted"} = row) do
    case correction_rule(row.content || row.message) do
      nil -> :ok
      rule -> create_correction(row, rule)
    end
  end

  defp extract_observation(%ProjectedObservation{event_type: type} = row)
       when type in ["agent.tool.completed", "tool.call.completed"] do
    case preceding_same_tool_terminal(row) do
      %ProjectedObservation{is_error: true} = failure -> create_remediation(row, failure)
      _not_failure -> :ok
    end
  end

  defp extract_observation(_row), do: :ok

  defp create_correction(row, rule) do
    evidence = [event_evidence(row, "supports")]

    create_candidate(
      row,
      rule,
      "correction",
      "Correction captured in session #{row.session_id}",
      evidence
    )
  end

  defp create_remediation(row, failure) do
    rule = "After #{failure.message || failure.content}, use #{row.message || row.content}"
    context = "Verified remediation for #{row.tool_name} in session #{row.session_id}"
    evidence = [event_evidence(failure, "derives"), event_evidence(row, "supports")]
    create_candidate(row, rule, "repeated_failure_remediation", context, evidence)
  end

  defp create_candidate(row, rule, source_kind, context, evidence) do
    attrs = %{
      rule: rule,
      context: context,
      project: row.project || "unknown",
      session_id: row.session_id,
      idempotency_key: "#{@processing_version}:#{row.event_id}",
      source_kind: source_kind,
      confidence: 0.85,
      evidence: evidence
    }

    partition = %{
      host_id: row.host_id,
      client_id: row.client_id,
      scope: row.scope,
      namespace: row.namespace
    }

    audit = %{
      actor: row.agent_id || "system:lesson-extraction",
      request_id: "lesson-event:#{row.event_id}",
      correlation_id: "lesson-event:#{row.event_id}"
    }

    case Lessons.create_candidate(attrs, partition, audit) do
      {:ok, _lesson} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp event_evidence(row, evidence_kind) do
    %{
      source_event_id: row.event_id,
      session_id: row.session_id,
      agent_id: row.agent_id,
      host_id: row.host_id,
      evidence_kind: evidence_kind,
      support_score: 1.0,
      excerpt: String.slice(row.message || row.content || row.event_type, 0, 500)
    }
  end

  defp preceding_same_tool_terminal(row) do
    repo().one(
      from(previous in ProjectedObservation,
        where:
          previous.host_id == ^row.host_id and previous.client_id == ^row.client_id and
            previous.scope == ^row.scope and previous.namespace == ^row.namespace and
            previous.session_id == ^row.session_id and previous.tool_name == ^row.tool_name and
            previous.source_sequence < ^row.source_sequence and
            previous.event_type in ^@tool_terminal_event_types,
        order_by: [desc: previous.source_sequence],
        limit: 1
      )
    )
  end

  defp correction_rule(value) when is_binary(value) do
    case Regex.run(~r/^\s*correction\s*:\s*(.+)$/is, value, capture: :all_but_first) do
      [rule] -> non_empty(String.trim(rule))
      _no_match -> nil
    end
  end

  defp correction_rule(_value), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value), do: value
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
