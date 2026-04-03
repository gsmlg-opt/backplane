defmodule Backplane.Jobs.Reindex do
  @moduledoc """
  Oban worker for reindexing documentation.
  Unique per project_id to avoid duplicate jobs.
  """

  use Oban.Worker,
    queue: :indexing,
    unique: [fields: [:args], keys: [:project_id], period: 60]

  alias Backplane.Docs.Ingestion

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => project_id}}) do
    Backplane.PubSubBroadcaster.broadcast_docs_reindex(:started, %{project_id: project_id})

    case Ingestion.run(project_id) do
      {:ok, stats} ->
        Backplane.Notifications.resources_changed()

        Backplane.PubSubBroadcaster.broadcast_docs_reindex(:completed, %{
          project_id: project_id,
          stats: stats
        })

        :ok

      {:error, reason} ->
        Backplane.PubSubBroadcaster.broadcast_docs_reindex(:failed, %{
          project_id: project_id,
          reason: reason
        })

        {:error, reason}
    end
  end
end
