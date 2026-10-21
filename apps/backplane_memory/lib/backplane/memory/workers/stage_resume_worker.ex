defmodule Backplane.Memory.Workers.StageResumeWorker do
  @moduledoc "Bounded reconciliation of enabled stages against current canonical session revisions."

  use Styx.Worker, queue: :memory, max_attempts: 3
  import Ecto.Query

  alias Backplane.Memory.Config
  alias Backplane.Memory.Projections.{ProjectedSession, Source, State}
  alias Backplane.Memory.Summaries.Summary

  alias Backplane.Memory.Workers.{
    CrystalWorker,
    EpisodicWorker,
    GraphExtractWorker,
    ProceduralWorker,
    SummaryWorker,
    WindowSummaryWorker
  }

  @page_size 100

  def enqueue do
    %{} |> new(unique: [period: :infinity, states: :incomplete, keys: [:cursor]]) |> Styx.insert()
  end

  @impl Styx.Worker
  def perform(%Styx.Job{args: args}) when is_map(args) do
    cursor = args["cursor"]

    cond do
      not is_nil(cursor) and not is_binary(cursor) ->
        {:cancel, :invalid_arguments}

      not Config.pipeline_enabled?() ->
        {:ok, %{sessions: 0, jobs: 0}}

      true ->
        sessions = session_page(cursor)

        with {:ok, jobs} <- reconcile_page(sessions),
             :ok <- continue(sessions) do
          {:ok, %{sessions: length(sessions), jobs: jobs}}
        end
    end
  end

  def perform(%Styx.Job{}), do: {:cancel, :invalid_arguments}

  @doc false
  def complete?(attrs) do
    repo().exists?(
      from(s in State,
        where:
          s.projector == ^attrs.projector and s.subject_type == ^attrs.subject_type and
            s.subject_id == ^attrs.subject_id and s.input_revision == ^attrs.input_revision and
            s.status == "complete"
      )
    )
  end

  @doc false
  def eligible?(attrs, opts \\ []) do
    terminal = if opts[:retry_failed], do: ["complete"], else: ~w(complete failed dead_letter)

    not repo().exists?(
      from(s in State,
        where:
          s.projector == ^attrs.projector and s.subject_type == ^attrs.subject_type and
            s.subject_id == ^attrs.subject_id and s.input_revision == ^attrs.input_revision and
            s.status in ^terminal
      )
    )
  end

  @doc false
  def reconcile_session(%ProjectedSession{} = session, opts \\ []) do
    if Config.pipeline_enabled?(), do: do_reconcile_session(session, opts), else: {:ok, []}
  end

  defp do_reconcile_session(session, opts) do
    case repo().transaction(fn ->
           Source.lock_streams(session.host_id, session.session_id)
           current = repo().get!(ProjectedSession, session.subject_id)
           partition = partition(current)

           work =
             if Config.window_summaries_enabled?(),
               do: [
                 fn ->
                   WindowSummaryWorker.enqueue(
                     current.host_id,
                     current.session_id,
                     current.input_revision,
                     partition,
                     opts
                   )
                 end
               ],
               else: []

           work = work ++ session_work(current, partition, opts)

           Enum.reduce(work, [], fn enqueue, jobs ->
             case enqueue.() do
               {:ok, %Styx.Job{} = job} -> [job | jobs]
               {:ok, _already_complete_or_ineligible} -> jobs
               {:error, reason} -> repo().rollback(reason)
             end
           end)
         end) do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp session_work(session, partition, opts) do
    ready? =
      session.status in ~w(completed stopped abandoned) and
        not is_nil(session.last_event_at) and
        DateTime.diff(DateTime.utc_now(), session.last_event_at) >=
          Config.event_gap_grace_seconds()

    cond do
      not ready? ->
        []

      not complete?(attrs(session, "summary")) ->
        if Config.session_summary_v2_enabled?() and eligible?(attrs(session, "summary"), opts),
          do: [
            fn ->
              SummaryWorker.enqueue(
                session.host_id,
                session.session_id,
                session.input_revision,
                partition
              )
            end
          ],
          else: []

      true ->
        summary =
          repo().one(
            from(s in Summary,
              where:
                s.subject_id == ^session.subject_id and
                  s.processing_version == "summary-v1" and
                  s.input_revision == ^session.input_revision
            )
          )

        if summary do
          downstream_work(session, summary, partition, opts)
        else
          []
        end
    end
  end

  defp downstream_work(session, summary, partition, opts) do
    facts =
      if Config.fact_extraction_v2_enabled?() and eligible?(attrs(session, "episodic"), opts),
        do: [fn -> EpisodicWorker.enqueue_summary(summary.id) end],
        else: []

    crystals =
      if Config.crystal_session_enabled?() and eligible?(attrs(session, "crystal"), opts),
        do: [
          fn ->
            CrystalWorker.enqueue(
              session.host_id,
              session.session_id,
              session.input_revision,
              partition
            )
          end
        ],
        else: []

    enrichment =
      if complete?(attrs(session, "episodic")) do
        {:ok, procedure_attrs} =
          ProceduralWorker.processing_identity(partition, session.project || "")

        procedures =
          if Config.procedure_extraction_v2_enabled?() and eligible?(procedure_attrs, opts),
            do: [fn -> ProceduralWorker.enqueue(partition, session.project || "") end],
            else: []

        graph =
          if Config.relation_classifier_enabled?() and eligible?(attrs(session, "graph"), opts),
            do: [fn -> GraphExtractWorker.enqueue(session.session_id, partition, opts) end],
            else: []

        procedures ++ graph
      else
        []
      end

    facts ++ crystals ++ enrichment
  end

  defp attrs(session, projector),
    do: %{
      projector: projector,
      subject_type: "captured_session",
      subject_id: session.subject_id,
      input_revision: session.input_revision
    }

  defp partition(session),
    do:
      Map.take(
        Map.from_struct(session),
        [:memory_space_id, :host_id, :client_id, :source_client_id, :scope, :namespace]
      )

  defp session_page(cursor) do
    query = from(s in ProjectedSession, order_by: [asc: s.subject_id], limit: ^@page_size)
    query = if cursor, do: where(query, [s], s.subject_id > ^cursor), else: query
    repo().all(query)
  end

  defp reconcile_page(sessions) do
    Enum.reduce_while(sessions, {:ok, 0}, fn session, {:ok, count} ->
      case reconcile_session(session) do
        {:ok, jobs} -> {:cont, {:ok, count + length(jobs)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp continue(sessions) when length(sessions) == @page_size do
    case %{"cursor" => List.last(sessions).subject_id} |> new() |> Styx.insert() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp continue(_sessions), do: :ok
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
