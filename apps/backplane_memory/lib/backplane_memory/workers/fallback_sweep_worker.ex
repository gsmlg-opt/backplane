defmodule BackplaneMemory.Workers.FallbackSweepWorker do
  @moduledoc "Oban cron worker: picks up orphaned sessions that closed without triggering SessionEnd consolidation."

  use Oban.Worker, queue: :memory, max_attempts: 2

  import Ecto.Query
  alias BackplaneMemory.Observations.Session
  alias BackplaneMemory.Workers.SummaryWorker

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

    orphaned =
      repo().all(
        from(s in Session,
          where:
            not is_nil(s.ended_at) and
              is_nil(s.consolidated_at) and
              s.ended_at < ^one_hour_ago
        )
      )

    Enum.each(orphaned, fn session ->
      SummaryWorker.enqueue(session.session_id)
    end)

    {:ok, %{swept: length(orphaned)}}
  end
end
