defmodule Backplane.Memory.Workers.ProjectionRepairWorker do
  @moduledoc "Durably repairs one captured-session projection from a canonical event identity."

  use Oban.Worker,
    queue: :memory,
    max_attempts: 5,
    unique: [
      period: :infinity,
      states: :all,
      keys: [:event_id]
    ]

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Config
  alias Backplane.Memory.Projections.Rebuild
  alias Backplane.Memory.Workers.{LessonCandidateWorker, SummaryWorker}

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    Backplane.Memory.PipelineTelemetry.span("projection.repair", job.args, fn ->
      with :ok <- perform(job, &Rebuild.session/2, &SummaryWorker.enqueue/3) do
        enqueue_lesson_candidate(job)
      end
    end)
  end

  @doc false
  def perform(%Oban.Job{args: %{"event_id" => event_id}}, rebuild)
      when is_binary(event_id) and is_function(rebuild, 2) do
    perform(
      %Oban.Job{args: %{"event_id" => event_id}},
      rebuild,
      &SummaryWorker.enqueue/3
    )
  end

  def perform(%Oban.Job{}, _rebuild), do: {:cancel, :invalid_arguments}

  @doc false
  def perform(%Oban.Job{args: %{"event_id" => event_id}}, rebuild, enqueue_summary)
      when is_binary(event_id) and is_function(rebuild, 2) and is_function(enqueue_summary, 3) do
    case Ecto.UUID.cast(event_id) do
      {:ok, event_id} -> load_and_repair(event_id, rebuild, enqueue_summary)
      :error -> {:cancel, :invalid_arguments}
    end
  end

  def perform(%Oban.Job{}, _rebuild, _enqueue_summary), do: {:cancel, :invalid_arguments}

  def enqueue(event_id) when is_binary(event_id) do
    %{event_id: event_id}
    |> new()
    |> Oban.insert()
  end

  defp load_and_repair(event_id, rebuild, enqueue_summary) do
    case repo().get(Event, event_id) do
      %Event{} = event -> repair(event, rebuild, enqueue_summary)
      nil -> :ok
    end
  end

  defp repair(%Event{} = event, rebuild, enqueue_summary) do
    if canonical_subject?(event) do
      case rebuild_and_audit(event, rebuild) do
        {:ok, result} -> maybe_enqueue_summary(event, result, enqueue_summary)
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_rebuild_result, other}}
      end
    else
      :ok
    end
  end

  defp rebuild_and_audit(event, rebuild) do
    case repo().transaction(fn ->
           case rebuild.(event.host_id, event.session_id) do
             {:ok, result} ->
               Audit.log_once("projection.repair", "system", [event.id], event.id, %{
                 host_id: event.host_id,
                 session_id: event.session_id,
                 result: "repaired"
               })

               result

             {:error, reason} ->
               repo().rollback(reason)

             other ->
               repo().rollback({:unexpected_rebuild_result, other})
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_enqueue_summary(event, result, enqueue_summary) do
    if summary_eligible?(result) do
      case enqueue_summary.(event.host_id, event.session_id, result.input_revision) do
        {:ok, %Oban.Job{state: state}} when state in ["available", "scheduled"] -> :ok
        {:ok, %Oban.Job{conflict?: true}} -> :ok
        {:ok, %Oban.Job{} = job} -> {:error, {:summary_job_not_durable, job.state}}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_summary_enqueue_result, other}}
      end
    else
      :ok
    end
  end

  defp summary_eligible?(%{
         input_revision: input_revision,
         gaps: gaps,
         session_status: status,
         last_event_at: %DateTime{} = last_event_at,
         states: %{"session" => %{status: state_status}}
       })
       when is_binary(input_revision) and is_list(gaps) and
              status in ["completed", "stopped", "abandoned"] and
              state_status in ["complete", "pending"] do
    DateTime.diff(DateTime.utc_now(), last_event_at, :second) >= Config.event_gap_grace_seconds()
  end

  defp summary_eligible?(_result), do: false

  defp canonical_subject?(%Event{
         schema_version: schema_version,
         host_id: host_id,
         session_id: session_id
       }) do
    not is_nil(schema_version) and non_empty_binary?(host_id) and non_empty_binary?(session_id)
  end

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp enqueue_lesson_candidate(%Oban.Job{args: %{"event_id" => event_id}}) do
    case LessonCandidateWorker.enqueue(event_id) do
      {:ok, :disabled} -> :ok
      {:ok, %Oban.Job{state: state}} when state in ["available", "scheduled"] -> :ok
      {:ok, %Oban.Job{conflict?: true}} -> :ok
      {:ok, %Oban.Job{} = job} -> {:error, {:lesson_candidate_job_not_durable, job.state}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_lesson_candidate(_job), do: :ok

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
