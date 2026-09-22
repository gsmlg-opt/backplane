defmodule Backplane.Memory.Workers.EdgeSyncRetentionWorker do
  @moduledoc "Scheduled bounded retention for recoverable host edge synchronization state."

  use Oban.Worker, queue: :memory, max_attempts: 3

  alias Backplane.Memory.EdgeSync.Retention

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    opts = [
      max_changes_per_partition: positive(args["max_changes_per_partition"], 10_000),
      max_snapshots_per_partition: positive(args["max_snapshots_per_partition"], 2),
      delivery_retention_days: positive(args["delivery_retention_days"], 7),
      max_partitions: positive(args["max_partitions"], 100),
      max_deletes: positive(args["max_deletes"], 1_000)
    ]

    with {:ok, result} <- Retention.prune(opts),
         :ok <- schedule_continuation(result, args) do
      {:ok, result}
    end
  end

  defp schedule_continuation(%{continued: true}, args) do
    case args |> __MODULE__.new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_continuation(_result, _args), do: :ok

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
