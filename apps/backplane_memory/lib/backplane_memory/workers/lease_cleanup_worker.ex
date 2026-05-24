defmodule BackplaneMemory.Workers.LeaseCleanupWorker do
  @moduledoc "Oban worker: delete expired memory leases."
  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query
  alias BackplaneMemory.Coordination.Lease

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {count, _} =
      repo().delete_all(from(l in Lease, where: l.expires_at < ^DateTime.utc_now()))

    {:ok, %{deleted: count}}
  end
end
