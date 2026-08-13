defmodule Backplane.Memory.Workers.LeaseCleanupWorker do
  @moduledoc "Oban worker: delete expired memory leases."
  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query
  alias Backplane.Memory.Audit
  alias Backplane.Memory.Coordination.Lease

  @batch_size 100

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    Backplane.Memory.PipelineTelemetry.span("lease.cleanup", job.args || %{}, fn ->
      do_perform()
    end)
  end

  defp do_perform do
    {:ok, count} =
      repo().transaction(fn ->
        ids =
          repo().all(
            from(l in Lease,
              where: l.expires_at < ^DateTime.utc_now(),
              order_by: [asc: l.expires_at, asc: l.id],
              limit: @batch_size,
              lock: "FOR UPDATE SKIP LOCKED",
              select: l.id
            )
          )

        {count, deleted_ids} =
          if ids == [] do
            {0, []}
          else
            repo().delete_all(from(l in Lease, where: l.id in ^ids, select: l.id))
          end

        if count > 0 do
          Audit.log("coordination.lease.cleanup", "system", deleted_ids, %{
            result: "expired",
            count: count
          })
        end

        count
      end)

    {:ok, %{deleted: count}}
  end
end
