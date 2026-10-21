defmodule Backplane.Memory.Workers.LessonDecayWorker do
  @moduledoc "Thin durable scheduler boundary for exact-partition lesson decay."

  use Styx.Worker, queue: :memory_lessons, max_attempts: 3

  alias Backplane.Memory.Lessons
  alias Backplane.Memory.PartitionIdentity

  @impl Styx.Worker
  def perform(%Styx.Job{args: args}) when is_map(args) do
    Backplane.Memory.PipelineTelemetry.span("lesson.decay", args, fn ->
      with {:ok, partition} <- PartitionIdentity.validate_generator(args),
           {:ok, now} <- parse_now(args["now"]),
           {:ok, counts} <- Lessons.decay(partition, now, limit: 100),
           :ok <- maybe_continue(counts, partition, now) do
        :ok
      else
        {:error, reason} when reason in [:incomplete_partition, :partition_mismatch] ->
          {:cancel, reason}

        result ->
          result
      end
    end)
  end

  def perform(%Styx.Job{}), do: {:cancel, :invalid_arguments}

  def enqueue(partition, %DateTime{} = now) do
    with {:ok, partition} <- PartitionIdentity.validate_generator(partition) do
      partition
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("now", DateTime.to_iso8601(now))
      |> new()
      |> Styx.insert()
    end
  end

  defp maybe_continue(%{decayed: 100}, partition, now) do
    case enqueue(partition, now) do
      {:ok, %Styx.Job{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_continue(_counts, _partition, _now), do: :ok

  defp parse_now(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, now, _offset} -> {:ok, now}
      {:error, _reason} -> {:cancel, :invalid_arguments}
    end
  end

  defp parse_now(_value), do: {:cancel, :invalid_arguments}
end
