defmodule Backplane.Memory.Workers.RecallTracePurgeWorker do
  @moduledoc "Daily bounded retention purge for privacy-filtered recall traces."

  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Recall.Run

  @batch_size 100
  @telemetry_event [:backplane, :memory, :recall_trace, :purge]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    started_at = System.monotonic_time()

    result =
      repo().transaction(fn ->
        ids =
          repo().all(
            from(run in Run,
              where: run.expires_at <= ^now(),
              order_by: [asc: run.expires_at, asc: run.id],
              limit: @batch_size,
              lock: "FOR UPDATE SKIP LOCKED",
              select: run.id
            )
          )

        {deleted, deleted_ids} =
          if ids == [] do
            {0, []}
          else
            repo().delete_all(from(run in Run, where: run.id in ^ids, select: run.id))
          end

        if deleted > 0 do
          Audit.log("memory.recall_trace.purge", "system", deleted_ids, %{
            count: deleted,
            result: "expired"
          })
        end

        deleted
      end)

    case result do
      {:ok, deleted} ->
        emit(started_at, deleted, :ok)
        {:ok, %{deleted: deleted}}

      {:error, reason} ->
        emit(started_at, 0, :error)
        {:error, reason}
    end
  end

  defp emit(started_at, deleted, status) do
    :telemetry.execute(
      @telemetry_event,
      %{deleted: deleted, duration: System.monotonic_time() - started_at},
      %{status: status}
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
