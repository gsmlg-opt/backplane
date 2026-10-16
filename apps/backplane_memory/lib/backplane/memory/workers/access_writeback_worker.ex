defmodule Backplane.Memory.Workers.AccessWritebackWorker do
  @moduledoc "Styx worker: batch-increment access_count and accessed_at for recalled memories."
  use Styx.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query
  alias Backplane.Memory.Memories.Memory

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Styx.Worker
  def perform(%Styx.Job{} = job) do
    Backplane.Memory.PipelineTelemetry.span("access.writeback", job.args, fn ->
      do_perform(job)
    end)
  end

  defp do_perform(%Styx.Job{args: %{"memory_ids" => ids}}) when is_list(ids) do
    repo().update_all(
      from(m in Memory, where: m.id in ^ids),
      inc: [access_count: 1],
      set: [accessed_at: DateTime.utc_now()]
    )

    :ok
  end

  defp do_perform(%Styx.Job{}), do: {:cancel, :invalid_arguments}

  @doc "Enqueue a batch access writeback for a list of memory IDs."
  def enqueue(memory_ids) when is_list(memory_ids) and memory_ids != [] do
    %{memory_ids: memory_ids}
    |> new()
    |> Styx.insert()
  end

  def enqueue([]), do: {:ok, :noop}
end
