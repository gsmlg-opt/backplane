defmodule Backplane.Memory.Workers.ProjectionRepairWorker do
  @moduledoc "Durably repairs one captured-session projection from a canonical event identity."

  use Oban.Worker,
    queue: :memory,
    max_attempts: 5

  import Ecto.Query

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Config
  alias Backplane.Memory.Projections.{Rebuild, RepairFrontier, Source}
  alias Backplane.Memory.Workers.{LessonCandidateWorker, SummaryWorker}

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    Backplane.Memory.PipelineTelemetry.span("projection.repair", job.args, fn ->
      rebuild =
        if host_session_args?(job.args),
          do: &Rebuild.session_locked/2,
          else: &Rebuild.session/2

      case perform(job, rebuild, &SummaryWorker.enqueue/3) do
        :ok -> maybe_enqueue_legacy_lesson_candidate(job)
        {:ok, :already_complete} -> :ok
        {:ok, :successor_scheduled} -> :ok
        other -> other
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
  def perform(
        %Oban.Job{
          args: %{
            "event_id" => legacy_event_id,
            "host_id" => host_id,
            "session_id" => session_id
          }
        },
        rebuild,
        enqueue_summary
      )
      when is_binary(legacy_event_id) and is_binary(host_id) and is_binary(session_id) and
             is_function(rebuild, 2) and is_function(enqueue_summary, 3) do
    perform(
      %Oban.Job{args: %{"host_id" => host_id, "session_id" => session_id}},
      rebuild,
      enqueue_summary
    )
  end

  def perform(%Oban.Job{args: %{"event_id" => event_id}}, rebuild, enqueue_summary)
      when is_binary(event_id) and is_function(rebuild, 2) and is_function(enqueue_summary, 3) do
    case Ecto.UUID.cast(event_id) do
      {:ok, event_id} -> load_and_repair(event_id, rebuild, enqueue_summary)
      :error -> {:cancel, :invalid_arguments}
    end
  end

  def perform(
        %Oban.Job{args: %{"host_id" => host_id, "session_id" => session_id}},
        rebuild,
        enqueue_summary
      )
      when is_binary(host_id) and is_binary(session_id) and is_function(rebuild, 2) and
             is_function(enqueue_summary, 3) do
    if non_empty_binary?(host_id) and non_empty_binary?(session_id) do
      repair_frontier(host_id, session_id, rebuild, enqueue_summary)
    else
      {:cancel, :invalid_arguments}
    end
  end

  def perform(%Oban.Job{}, _rebuild, _enqueue_summary), do: {:cancel, :invalid_arguments}

  def enqueue(event_id) when is_binary(event_id) do
    %{event_id: event_id}
    |> new()
    |> Oban.insert()
  end

  def enqueue(host_id, session_id) when is_binary(host_id) and is_binary(session_id) do
    %{host_id: host_id, session_id: session_id}
    |> new(
      unique: [
        period: :infinity,
        states: [:available, :scheduled, :retryable, :suspended],
        keys: [:host_id, :session_id]
      ]
    )
    |> Oban.insert()
  end

  defp repair_frontier(host_id, session_id, rebuild, enqueue_summary) do
    case repo().transaction(fn ->
           Source.lock_streams(host_id, session_id)

           case RepairFrontier.lock(repo(), host_id, session_id) do
             nil ->
               {:ok, :already_complete}

             frontier ->
               repair_claimed_frontier(frontier, rebuild, enqueue_summary)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp repair_claimed_frontier(frontier, rebuild, enqueue_summary) do
    frontier = initialize_migrated_frontier(frontier)

    if frontier.completed_generation >= frontier.requested_generation do
      {:ok, :already_complete}
    else
      repair_pending_frontier(frontier, rebuild, enqueue_summary)
    end
  end

  defp initialize_migrated_frontier(%RepairFrontier{requested_generation: 0} = frontier) do
    {:ok, %{input_revision: revision}} =
      Rebuild.authoritative_revision(frontier.host_id, frontier.session_id)

    RepairFrontier.advance(repo(), frontier.host_id, frontier.session_id, revision)
  end

  defp initialize_migrated_frontier(frontier), do: frontier

  defp repair_pending_frontier(frontier, rebuild, enqueue_summary) do
    {:ok, %{input_revision: authoritative_revision}} =
      Rebuild.authoritative_revision(frontier.host_id, frontier.session_id)

    if frontier.requested_revision == authoritative_revision do
      frontier = RepairFrontier.mark_inflight(repo(), frontier)

      case rebuild.(frontier.host_id, frontier.session_id) do
        {:ok, %{input_revision: ^authoritative_revision} = result} ->
          audit_frontier_repair(frontier, result)

          case maybe_enqueue_summary(frontier, result, enqueue_summary) do
            :ok -> :ok
            {:error, reason} -> repo().rollback(reason)
          end

          case enqueue_lesson_candidates_for_session(frontier.host_id, frontier.session_id) do
            :ok -> :ok
            {:error, reason} -> repo().rollback(reason)
          end

          RepairFrontier.complete(
            repo(),
            frontier,
            frontier.inflight_generation,
            authoritative_revision
          )

          :ok

        {:ok, _stale_result} ->
          ensure_successor(frontier)

        {:error, reason} ->
          repo().rollback(reason)

        other ->
          repo().rollback({:unexpected_rebuild_result, other})
      end
    else
      frontier =
        RepairFrontier.replace_requested_revision(repo(), frontier, authoritative_revision)

      ensure_successor(frontier)
    end
  end

  defp ensure_successor(frontier) do
    case enqueue(frontier.host_id, frontier.session_id) do
      {:ok, %Oban.Job{state: state}}
      when state in ["available", "scheduled", "retryable", "suspended"] ->
        {:ok, :successor_scheduled}

      {:ok, %Oban.Job{conflict?: true}} ->
        {:ok, :successor_scheduled}

      {:ok, %Oban.Job{} = job} ->
        repo().rollback({:successor_job_not_durable, job.state})

      {:error, reason} ->
        repo().rollback(reason)
    end
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
                 memory_space_id: event.memory_space_id,
                 host_id: event.host_id,
                 client_id: event.client_id,
                 source_client_id: event.source_client_id,
                 scope: event.scope,
                 namespace: event.namespace,
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

  defp audit_frontier_repair(frontier, result) do
    Audit.log_once(
      "projection.repair",
      "system",
      [],
      "#{frontier.host_id}:#{frontier.session_id}:#{frontier.inflight_generation}",
      %{
        memory_space_id: result.memory_space_id,
        host_id: frontier.host_id,
        client_id: result.client_id,
        source_client_id: result.source_client_id,
        scope: result.scope,
        namespace: result.namespace,
        session_id: frontier.session_id,
        input_revision: frontier.inflight_revision,
        result: "repaired"
      }
    )
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

  defp host_session_args?(%{"host_id" => host_id, "session_id" => session_id}),
    do: non_empty_binary?(host_id) and non_empty_binary?(session_id)

  defp host_session_args?(_args), do: false

  defp maybe_enqueue_legacy_lesson_candidate(%Oban.Job{args: %{"event_id" => event_id}}) do
    enqueue_lesson_candidate(event_id)
  end

  defp maybe_enqueue_legacy_lesson_candidate(_job), do: :ok

  defp enqueue_lesson_candidates_for_session(host_id, session_id) do
    Event
    |> where([event], event.host_id == ^host_id and event.session_id == ^session_id)
    |> where([event], not is_nil(event.schema_version))
    |> order_by([event], asc: event.source_sequence, asc: event.id)
    |> select([event], event.id)
    |> repo().all()
    |> Enum.reduce_while(:ok, fn event_id, :ok ->
      case enqueue_lesson_candidate(event_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp enqueue_lesson_candidate(event_id) do
    result =
      case Application.get_env(:backplane_memory, :projection_repair_lesson_enqueue) do
        enqueue when is_function(enqueue, 1) -> enqueue.(event_id)
        nil -> LessonCandidateWorker.enqueue(event_id)
      end

    case result do
      {:ok, :disabled} -> :ok
      {:ok, %Oban.Job{state: state}} when state in ["available", "scheduled"] -> :ok
      {:ok, %Oban.Job{conflict?: true}} -> :ok
      {:ok, %Oban.Job{} = job} -> {:error, {:lesson_candidate_job_not_durable, job.state}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
