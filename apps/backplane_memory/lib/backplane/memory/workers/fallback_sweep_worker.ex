defmodule Backplane.Memory.Sessions.FallbackSweep do
  @moduledoc """
  Closes stale canonical sessions and starts final processing from bounded indexed candidates.

  The worker never scans legacy `memory_sessions`. Every candidate is rebuilt while its
  canonical stream is locked, so concurrent capture and multiple sweep nodes cannot create
  false or duplicate abandonment effects.
  """

  import Ecto.Query

  alias Backplane.Memory.{Audit, Config}
  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Ingest.EventValidator

  alias Backplane.Memory.Projections.{
    ProjectedSession,
    Rebuild,
    Source,
    State
  }

  alias Backplane.Memory.Workers.SummaryWorker

  @subject_type "captured_session"

  def run(now \\ now(), opts \\ [])

  def run(%DateTime{} = now, opts) when is_list(opts) do
    candidates = candidates(now)
    Keyword.get(opts, :after_candidates, fn _candidates -> :ok end).(candidates)

    candidates
    |> Enum.map(&process_candidate(&1, now))
    |> summarize(length(candidates))
  end

  @doc false
  def candidate_query(now, limit)
      when is_struct(now, DateTime) and is_integer(limit) and limit > 0 do
    stale_before = DateTime.add(now, -Config.session_stale_after_seconds(), :second)
    grace_before = DateTime.add(now, -Config.event_gap_grace_seconds(), :second)

    from(session in ProjectedSession,
      left_join: summary_state in State,
      on:
        summary_state.projector == "summary" and
          summary_state.subject_type == ^@subject_type and
          summary_state.subject_id == session.subject_id and
          summary_state.input_revision == session.input_revision,
      where:
        (session.status == "active" and session.last_event_at <= ^stale_before) or
          (session.status in ["stopped", "completed", "abandoned"] and
             session.last_event_at <= ^grace_before and
             (is_nil(summary_state.id) or summary_state.status == "failed")),
      order_by: [asc: session.last_event_at, asc: session.subject_id],
      limit: ^limit,
      select: {session.host_id, session.session_id}
    )
  end

  defp candidates(now) do
    now
    |> candidate_query(Config.fallback_sweep_batch_size())
    |> repo().all()
  end

  defp process_candidate({host_id, session_id}, now) do
    case repo().transaction(fn -> process_locked(host_id, session_id, now) end) do
      {:ok, outcome} -> outcome
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp process_locked(host_id, session_id, now) do
    Source.lock_streams(host_id, session_id)

    with {:ok, _result} <- Rebuild.session(host_id, session_id),
         %ProjectedSession{} = session <- locked_session(host_id, session_id) do
      cond do
        stale_active?(session, now) -> abandon(session, now)
        summary_ready?(session, now) -> enqueue_summary(session)
        true -> :skipped
      end
    else
      nil -> :skipped
      {:error, :not_found} -> :skipped
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp locked_session(host_id, session_id) do
    repo().one(
      from(session in ProjectedSession,
        where: session.host_id == ^host_id and session.session_id == ^session_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp stale_active?(%ProjectedSession{status: "active", last_event_at: last_event_at}, now) do
    DateTime.diff(now, last_event_at, :second) >= Config.session_stale_after_seconds()
  end

  defp stale_active?(_session, _now), do: false

  defp summary_ready?(
         %ProjectedSession{
           status: status,
           last_event_at: last_event_at
         },
         now
       )
       when status in ["stopped", "completed", "abandoned"] do
    DateTime.diff(now, last_event_at, :second) >= Config.event_gap_grace_seconds()
  end

  defp summary_ready?(_session, _now), do: false

  defp abandon(session, now) do
    {:ok, events} = Source.events(session.host_id, session.session_id)
    source = List.first(events)
    correlation_id = Ecto.UUID.generate()

    payload = %{
      "reason" => "session_stale_timeout",
      "stale_after_seconds" => Config.session_stale_after_seconds(),
      "source_input_revision" => session.input_revision,
      "last_event_at" => DateTime.to_iso8601(session.last_event_at)
    }

    attrs = %{
      id: Ecto.UUID.generate(),
      stream_id: source.stream_id,
      project: session.project,
      namespace: source.namespace,
      agent_id: session.agent_id,
      host_id: session.host_id,
      client_id: source.client_id,
      session_id: session.session_id,
      event_type: "agent.session.abandoned",
      actor_type: "system",
      status: "abandoned",
      correlation_id: correlation_id,
      idempotency_key: "server:session-abandonment:#{session.subject_id}",
      importance: 0,
      payload: payload,
      occurred_at: now,
      schema_version: 1,
      integration: "backplane",
      scope: source.scope,
      source_sequence: (session.source_sequence_max || 0) + 1,
      captured_at: now,
      payload_hash: EventValidator.payload_hash(payload),
      privacy: %{"filtered" => true, "filter_version" => "server-v1"},
      trace: %{"correlation_id" => correlation_id},
      raw_envelope: %{
        "server_generated" => true,
        "reason" => "session_stale_timeout",
        "correlation_id" => correlation_id
      }
    }

    case Store.append_tagged(attrs, repo: repo()) do
      {:ok, {:inserted, event}} ->
        Audit.log(
          "session.abandoned",
          "system:fallback_sweep",
          %{
            "subject_id" => session.subject_id,
            "event_id" => event.id,
            "host_id" => session.host_id,
            "session_id" => session.session_id
          },
          %{
            "correlation_id" => correlation_id,
            "input_revision" => session.input_revision,
            "stale_after_seconds" => Config.session_stale_after_seconds()
          }
        )

        {:ok, _rebuilt} = Rebuild.session(session.host_id, session.session_id)
        :abandoned

      {:ok, {:duplicate, _event}} ->
        {:ok, _rebuilt} = Rebuild.session(session.host_id, session.session_id)
        :skipped

      {:error, reason} ->
        repo().rollback(reason)
    end
  end

  defp enqueue_summary(session) do
    case SummaryWorker.enqueue(session.host_id, session.session_id, session.input_revision) do
      {:ok, %Oban.Job{state: state}} when state in ["available", "scheduled"] ->
        Audit.log(
          "session.summary_enqueued",
          "system:fallback_sweep",
          %{
            "subject_id" => session.subject_id,
            "host_id" => session.host_id,
            "session_id" => session.session_id
          },
          %{"input_revision" => session.input_revision}
        )

        :enqueued

      {:ok, %Oban.Job{conflict?: true}} ->
        :skipped

      {:ok, %Oban.Job{} = job} ->
        repo().rollback({:summary_job_not_durable, job.state})

      {:error, reason} ->
        repo().rollback(reason)
    end
  end

  defp summarize(results, candidate_count) do
    case Enum.find(results, &match?({:error, _reason}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        abandoned = Enum.count(results, &(&1 == :abandoned))
        enqueued = Enum.count(results, &(&1 == :enqueued))

        {:ok,
         %{
           candidates: candidate_count,
           abandoned: abandoned,
           enqueued: enqueued,
           skipped: Enum.count(results, &(&1 == :skipped)),
           swept: abandoned + enqueued
         }}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end

defmodule Backplane.Memory.Workers.FallbackSweepWorker do
  @moduledoc "Oban entry point for bounded canonical stale-session closure and processing."

  use Oban.Worker, queue: :memory, max_attempts: 2

  alias Backplane.Memory.Sessions.FallbackSweep

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    Backplane.Memory.PipelineTelemetry.span("fallback.sweep", job.args, fn ->
      FallbackSweep.run()
    end)
  end
end
