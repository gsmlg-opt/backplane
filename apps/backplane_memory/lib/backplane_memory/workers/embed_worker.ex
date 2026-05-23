defmodule BackplaneMemory.Workers.EmbedWorker do
  @moduledoc "Oban worker: embed a bpm_memories row via the LLM proxy. Fails gracefully — memory stays unembedded on error."

  use Oban.Worker, queue: :memory, max_attempts: 5

  alias Backplane.Repo
  alias BackplaneMemory.Embedding.Client
  alias BackplaneMemory.Memories.Memory

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    perform_with_client(job, &Client.embed/3)
  end

  @doc "Testable entry-point: accepts an embed_fn instead of the real client."
  def perform_with_client(%Oban.Job{args: %{"id" => id}}, embed_fn) do
    case Repo.get(Memory, id) do
      nil ->
        :ok

      %Memory{} = mem ->
        case embed_fn.([mem.content], :document, []) do
          {:ok, [vector]} ->
            mem |> Memory.embed_changeset(vector) |> Repo.update!()
            :ok

          {:error, _reason} ->
            # Non-fatal: leave embedding nil; recall degrades to keyword-only
            :ok
        end
    end
  end

  @doc "Enqueue an embed job for the given memory id."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(id) do
    %{id: id}
    |> new()
    |> Oban.insert()
  end
end
