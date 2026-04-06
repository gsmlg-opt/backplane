defmodule Backplane.Jobs.EmbedChunks do
  @moduledoc """
  Oban worker that embeds doc chunks missing vector embeddings.

  Runs after reindex completes. Batches chunks by configured batch_size,
  calls embed_batch/1, writes vectors back to doc_chunks.embedding.

  Idempotent: skips rows where embedding IS NOT NULL.
  The embedding column is accessed via raw fragments since it's not in the Ecto schema.
  """

  use Oban.Worker,
    queue: :embeddings,
    unique: [fields: [:args], keys: [:project_id], period: 120]

  require Logger

  import Ecto.Query

  alias Backplane.Docs.DocChunk
  alias Backplane.Embeddings
  alias Backplane.Repo

  @impl true
  def perform(%Oban.Job{args: args}) do
    unless Embeddings.configured?() do
      Logger.debug("Embeddings not configured, skipping embed_chunks job")
      :ok
    else
      project_id = args["project_id"]
      batch_size = Embeddings.config()[:batch_size] || 32

      chunks =
        DocChunk
        |> where([c], fragment("? IS NULL", c.embedding))
        |> maybe_filter_project(project_id)
        |> select([c], %{id: c.id, content: c.content})
        |> Repo.all()

      if chunks == [] do
        Logger.debug("No chunks to embed#{if project_id, do: " for #{project_id}", else: ""}")
        :ok
      else
        Logger.info("Embedding #{length(chunks)} doc chunks")
        embed_in_batches(chunks, batch_size)
      end
    end
  end

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, project_id), do: where(query, [c], c.project_id == ^project_id)

  defp embed_in_batches(chunks, batch_size) do
    chunks
    |> Enum.chunk_every(batch_size)
    |> Enum.each(fn batch ->
      texts = Enum.map(batch, & &1.content)

      case Embeddings.embed_batch(texts) do
        {:ok, vectors} ->
          Enum.zip(batch, vectors)
          |> Enum.each(fn {chunk, vector} ->
            json_vec = Jason.encode!(vector)

            Repo.query!(
              "UPDATE doc_chunks SET embedding = $1::vector WHERE id = $2",
              [json_vec, chunk.id]
            )
          end)

        {:error, reason} ->
          Logger.warning("Failed to embed batch of #{length(batch)} chunks: #{inspect(reason)}")
      end
    end)

    :ok
  end
end
