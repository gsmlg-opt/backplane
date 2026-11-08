defmodule Backplane.Memory.Workers.ProjectionRepairWorker do
  @moduledoc "Durably repairs one captured-session projection from a canonical event identity."

  use Styx.Worker,
    queue: :memory,
    max_attempts: 5

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.{Rebuild, RepairFrontier, Source}

  @impl Styx.Worker
  def perform(%Styx.Job{} = job) do
    Backplane.Memory.PipelineTelemetry.span("projection.repair", job.args, fn ->
      rebuild =
        if host_session_args?(job.args),
          do: &Rebuild.session_locked/2,
          else: &Rebuild.session/2

      case perform(job, rebuild) do
        {:ok, :already_complete} -> :ok
        {:ok, :successor_scheduled} -> :ok
        other -> other
      end
    end)
  end

  @doc false
  def perform(%Styx.Job{args: %{"event_id" => event_id}}, rebuild)
      when is_binary(event_id) and is_function(rebuild, 2) do
    case Ecto.UUID.cast(event_id) do
      {:ok, event_id} -> load_and_repair(event_id, rebuild)
      :error -> {:cancel, :invalid_arguments}
    end
  end

  def perform(%Styx.Job{args: %{"host_id" => host_id, "session_id" => session_id}}, rebuild)
      when is_binary(host_id) and is_binary(session_id) and is_function(rebuild, 2) do
    if non_empty_binary?(host_id) and non_empty_binary?(session_id) do
      repair_frontier(host_id, session_id, rebuild)
    else
      {:cancel, :invalid_arguments}
    end
  end

  def perform(%Styx.Job{}, _rebuild), do: {:cancel, :invalid_arguments}

  def enqueue(event_id) when is_binary(event_id) do
    %{event_id: event_id}
    |> new()
    |> Styx.insert()
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
    |> Styx.insert()
  end

  defp repair_frontier(host_id, session_id, rebuild) do
    case repo().transaction(fn ->
           Source.lock_streams(host_id, session_id)

           case RepairFrontier.lock(repo(), host_id, session_id) do
             nil ->
               {:ok, :already_complete}

             frontier ->
               repair_claimed_frontier(frontier, rebuild)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp repair_claimed_frontier(frontier, rebuild) do
    frontier = initialize_migrated_frontier(frontier)

    if frontier.completed_generation >= frontier.requested_generation do
      {:ok, :already_complete}
    else
      repair_pending_frontier(frontier, rebuild)
    end
  end

  defp initialize_migrated_frontier(%RepairFrontier{requested_generation: 0} = frontier) do
    {:ok, %{input_revision: revision}} =
      Rebuild.authoritative_revision(frontier.host_id, frontier.session_id)

    RepairFrontier.advance(repo(), frontier.host_id, frontier.session_id, revision)
  end

  defp initialize_migrated_frontier(frontier), do: frontier

  defp repair_pending_frontier(frontier, rebuild) do
    {:ok, %{input_revision: authoritative_revision}} =
      Rebuild.authoritative_revision(frontier.host_id, frontier.session_id)

    if frontier.requested_revision == authoritative_revision do
      frontier = RepairFrontier.mark_inflight(repo(), frontier)

      case rebuild.(frontier.host_id, frontier.session_id) do
        {:ok, %{input_revision: ^authoritative_revision} = result} ->
          audit_frontier_repair(frontier, result)

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
      {:ok, %Styx.Job{state: state}}
      when state in ["available", "scheduled", "retryable", "suspended"] ->
        {:ok, :successor_scheduled}

      {:ok, %Styx.Job{conflict?: true}} ->
        {:ok, :successor_scheduled}

      {:ok, %Styx.Job{} = job} ->
        repo().rollback({:successor_job_not_durable, job.state})

      {:error, reason} ->
        repo().rollback(reason)
    end
  end

  defp load_and_repair(event_id, rebuild) do
    case repo().get(Event, event_id) do
      %Event{} = event -> repair(event, rebuild)
      nil -> :ok
    end
  end

  defp repair(%Event{} = event, rebuild) do
    if canonical_subject?(event) do
      case rebuild_and_audit(event, rebuild) do
        {:ok, _result} -> :ok
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
                 host_id: event.host_id,
                 client_id: event.client_id,
                 source_client_id: event.source_client_id,
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

  defp audit_frontier_repair(frontier, result) do
    Audit.log_once(
      "projection.repair",
      "system",
      [],
      "#{frontier.host_id}:#{frontier.session_id}:#{frontier.inflight_generation}",
      %{
        host_id: frontier.host_id,
        client_id: result.client_id,
        source_client_id: result.source_client_id,
        session_id: frontier.session_id,
        input_revision: frontier.inflight_revision,
        result: "repaired"
      }
    )
  end

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

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
