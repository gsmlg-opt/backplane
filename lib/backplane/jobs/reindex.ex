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
    case Ingestion.run(project_id) do
      {:ok, _stats} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
