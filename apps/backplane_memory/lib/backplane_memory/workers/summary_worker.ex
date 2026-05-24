defmodule BackplaneMemory.Workers.SummaryWorker do
  @moduledoc "Oban worker: compress session observations into a summary row (working → episodic)."

  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query
  alias BackplaneMemory.Consolidation.Summary
  alias BackplaneMemory.Observations.{Observation, Session}
  alias BackplaneMemory.Workers.EpisodicWorker

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"session_id" => session_id}}) do
    case repo().one(from(s in Session, where: s.session_id == ^session_id)) do
      nil ->
        :ok

      %Session{} = session ->
        observations =
          repo().all(
            from(o in Observation,
              where: o.session_id == ^session_id and not o.is_error,
              order_by: [desc: fragment("length(?)", o.content)],
              limit: 20
            )
          )

        if observations == [] do
          mark_consolidated(session_id)
          :ok
        else
          content = build_summary(session, observations)

          result =
            %Summary{}
            |> Summary.changeset(%{
              session_id: session_id,
              project: session.project || "",
              content: content,
              observation_count: length(observations)
            })
            |> repo().insert(on_conflict: :nothing)

          case result do
            {:ok, _} ->
              mark_consolidated(session_id)
              EpisodicWorker.enqueue(session_id)
              :ok

            {:error, changeset} ->
              {:error, changeset}
          end
        end
    end
  end

  defp build_summary(%Session{} = session, observations) do
    header =
      "Session #{session.session_id} (project: #{session.project || "unknown"}) — #{length(observations)} observations"

    lines =
      observations
      |> Enum.take(20)
      |> Enum.map(&String.slice(&1.content, 0, 500))

    Enum.join([header | lines], "\n---\n")
  end

  defp mark_consolidated(session_id) do
    repo().update_all(
      from(s in Session, where: s.session_id == ^session_id),
      set: [consolidated_at: DateTime.utc_now()]
    )
  end

  @doc "Enqueue a summary job for the given session_id."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(session_id) do
    %{session_id: session_id}
    |> new()
    |> Oban.insert()
  end
end
