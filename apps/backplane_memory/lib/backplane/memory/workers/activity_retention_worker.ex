defmodule Backplane.Memory.Workers.ActivityRetentionWorker do
  @moduledoc "Bounded retention purge for durable daily activity projections."

  use Oban.Worker, queue: :memory, max_attempts: 3

  alias Backplane.Memory.{Audit, Config}

  @default_batch_size 100
  @max_batch_size 1_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    Backplane.Memory.PipelineTelemetry.span("activity.retention", args, fn ->
      with {:ok, today} <- parse_today(args["today"]),
           {:ok, batch_size} <- parse_batch_size(args["batch_size"]) do
        cutoff = Date.add(today, -Config.activity_retention_days())

        case repo().transaction(fn -> purge_batch(cutoff, batch_size, today) end) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  defp purge_batch(cutoff, batch_size, today) do
    contributions_deleted =
      delete_batch("memory_activity_subject_contributions", cutoff, batch_size)

    daily_deleted = delete_batch("memory_activity_daily", cutoff, batch_size)
    continued = contributions_deleted == batch_size or daily_deleted == batch_size

    Audit.log("memory.activity.purge", "system", [Date.to_iso8601(cutoff)], %{
      cutoff: Date.to_iso8601(cutoff),
      contributions_deleted: contributions_deleted,
      daily_deleted: daily_deleted,
      bounded: true
    })

    if continued do
      %{"today" => Date.to_iso8601(today), "batch_size" => batch_size}
      |> new()
      |> Oban.insert!()
    end

    %{
      contributions_deleted: contributions_deleted,
      daily_deleted: daily_deleted,
      continued: continued
    }
  end

  defp delete_batch(table, cutoff, batch_size) do
    %{num_rows: deleted} =
      repo().query!(
        """
        WITH doomed AS (
          SELECT ctid
          FROM #{table}
          WHERE date < $1
          ORDER BY date
          LIMIT $2
          FOR UPDATE SKIP LOCKED
        )
        DELETE FROM #{table} AS target
        USING doomed
        WHERE target.ctid = doomed.ctid
        """,
        [cutoff, batch_size]
      )

    deleted
  end

  defp parse_today(nil), do: {:ok, Date.utc_today()}
  defp parse_today(%Date{} = today), do: {:ok, today}
  defp parse_today(today) when is_binary(today), do: Date.from_iso8601(today)
  defp parse_today(_today), do: {:error, :invalid_today}

  defp parse_batch_size(nil), do: {:ok, @default_batch_size}

  defp parse_batch_size(value) when is_integer(value) and value in 1..@max_batch_size,
    do: {:ok, value}

  defp parse_batch_size(_value), do: {:error, :invalid_batch_size}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
