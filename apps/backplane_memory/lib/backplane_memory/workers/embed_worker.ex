defmodule BackplaneMemory.Workers.EmbedWorker do
  @moduledoc "Oban worker: embed a bpm_memories row via the LLM proxy. Fails gracefully — memory stays unembedded on error."

  use Oban.Worker, queue: :memory, max_attempts: 5

  alias BackplaneMemory.Embedding.Client
  alias BackplaneMemory.Memories.Memory

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    perform_with_client(job, &Client.embed/3)
  end

  @doc false
  def perform_with_client(%Oban.Job{args: %{"id" => id}}, embed_fn) do
    case repo().get(Memory, id) do
      nil ->
        :ok

      %Memory{} = mem ->
        case embed_fn.([mem.content], :document, []) do
          {:ok, [vector]} ->
            mem |> Memory.embed_changeset(vector) |> repo().update!()
            :ok

          {:error, reason} ->
            {:error, reason}
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
