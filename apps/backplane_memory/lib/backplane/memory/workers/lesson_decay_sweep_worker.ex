defmodule Backplane.Memory.Workers.LessonDecaySweepWorker do
  @moduledoc "Nightly bounded paginator that schedules exact-partition lesson decay."

  use Styx.Worker, queue: :memory_lessons, max_attempts: 3

  import Ecto.Query

  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.PartitionIdentity
  alias Backplane.Memory.Workers.LessonDecayWorker

  @page_size 100

  @impl Styx.Worker
  def perform(%Styx.Job{args: args}) when is_map(args) do
    Backplane.Memory.PipelineTelemetry.span("lesson.decay_sweep", args, fn ->
      now = parse_now(args["now"])

      with {:ok, cursor} <- parse_cursor(args["cursor"]),
           {:ok, now} <- now,
           partitions <- partitions(cursor),
           :ok <- enqueue_partitions(partitions, now),
           :ok <- maybe_enqueue_next(partitions, now) do
        :ok
      end
    end)
  end

  def perform(%Styx.Job{}), do: {:cancel, :invalid_arguments}

  defp partitions(cursor) do
    query =
      from(l in Lesson,
        join: m in Memory,
        on: m.id == l.memory_id,
        where: l.status in ["active", "candidate", "disputed"],
        group_by: [m.memory_space_id, m.host_id, m.client_id, m.scope, m.namespace],
        order_by: [
          asc: m.memory_space_id,
          asc: m.host_id,
          asc: m.client_id,
          asc: m.scope,
          asc: m.namespace
        ],
        limit: ^@page_size,
        select: %{
          memory_space_id: m.memory_space_id,
          host_id: m.host_id,
          client_id: m.client_id,
          scope: m.scope,
          namespace: m.namespace
        }
      )

    query =
      case cursor do
        nil ->
          query

        [memory_space_id, host_id, client_id, scope, namespace] ->
          where(
            query,
            [l, m],
            fragment(
              "ROW(?, ?, ?, ?, ?) > ROW(?, ?, ?, ?, ?)",
              m.memory_space_id,
              m.host_id,
              m.client_id,
              m.scope,
              m.namespace,
              type(^memory_space_id, :binary_id),
              ^host_id,
              ^client_id,
              ^scope,
              ^namespace
            )
          )
      end

    repo().all(query)
  end

  defp enqueue_partitions(partitions, now) do
    Enum.reduce_while(partitions, :ok, fn partition, :ok ->
      case LessonDecayWorker.enqueue(partition, now) do
        {:ok, %Styx.Job{}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_enqueue_next(partitions, now) when length(partitions) == @page_size do
    last = List.last(partitions)
    cursor = [last.memory_space_id, last.host_id, last.client_id, last.scope, last.namespace]

    case %{"cursor" => cursor, "now" => DateTime.to_iso8601(now)}
         |> new()
         |> Styx.insert() do
      {:ok, %Styx.Job{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_enqueue_next(_partitions, _now), do: :ok
  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor([memory_space_id, host_id, client_id, scope, namespace]) do
    case PartitionIdentity.validate_generator(%{
           memory_space_id: memory_space_id,
           host_id: host_id,
           client_id: client_id,
           scope: scope,
           namespace: namespace
         }) do
      {:ok, partition} ->
        {:ok,
         [
           partition.memory_space_id,
           partition.host_id,
           partition.client_id,
           partition.scope,
           partition.namespace
         ]}

      {:error, _reason} ->
        {:cancel, :invalid_arguments}
    end
  end

  defp parse_cursor(_value), do: {:cancel, :invalid_arguments}
  defp parse_now(nil), do: {:ok, DateTime.utc_now()}

  defp parse_now(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, now, _offset} -> {:ok, now}
      {:error, reason} -> {:cancel, reason}
    end
  end

  defp parse_now(_value), do: {:cancel, :invalid_arguments}
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
