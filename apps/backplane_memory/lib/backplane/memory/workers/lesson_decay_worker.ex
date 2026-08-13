defmodule Backplane.Memory.Workers.LessonDecayWorker do
  @moduledoc "Thin durable scheduler boundary for exact-partition lesson decay."

  use Oban.Worker, queue: :memory_lessons, max_attempts: 3

  alias Backplane.Memory.Lessons

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{
            "host_id" => host_id,
            "client_id" => client_id,
            "scope" => scope,
            "namespace" => namespace,
            "now" => now
          }
        } = job
      ) do
    Backplane.Memory.PipelineTelemetry.span("lesson.decay", job.args, fn ->
      with {:ok, now, 0} <- DateTime.from_iso8601(now),
           {:ok, counts} <-
             Lessons.decay(
               %{host_id: host_id, client_id: client_id, scope: scope, namespace: namespace},
               now,
               limit: 100
             ),
           :ok <-
             maybe_continue(
               counts,
               %{host_id: host_id, client_id: client_id, scope: scope, namespace: namespace},
               now
             ) do
        :ok
      end
    end)
  end

  def enqueue(partition, %DateTime{} = now) do
    partition
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("now", DateTime.to_iso8601(now))
    |> new()
    |> Oban.insert()
  end

  defp maybe_continue(%{decayed: 100}, partition, now) do
    case enqueue(partition, now) do
      {:ok, %Oban.Job{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_continue(_counts, _partition, _now), do: :ok
end
