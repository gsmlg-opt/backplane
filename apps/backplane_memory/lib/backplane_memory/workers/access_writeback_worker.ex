defmodule BackplaneMemory.Workers.AccessWritebackWorker do
  @moduledoc "Oban worker: batch-increment access_count and accessed_at for recalled memories."
  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query
  alias BackplaneMemory.Memories.Memory

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"memory_ids" => ids}}) when is_list(ids) do
    repo().update_all(
      from(m in Memory, where: m.id in ^ids),
      inc: [access_count: 1],
      set: [accessed_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc "Enqueue a batch access writeback for a list of memory IDs."
  def enqueue(memory_ids) when is_list(memory_ids) and memory_ids != [] do
    %{memory_ids: memory_ids}
    |> new()
    |> Oban.insert()
  end

  def enqueue([]), do: {:ok, :noop}
end
