defmodule Backplane.Memory.Workers.EmbedRecordsWorker do
  @moduledoc """
  Embeds active records whose `embedding` is still null, 50 at a time.

  Does nothing when no embedding model is configured. Errors never fail the job: they
  log a warning and leave the column null so full-text recall keeps working.
  """

  use Styx.Worker, queue: :embeddings, max_attempts: 1, unique: [period: 60]

  import Ecto.Query

  alias Backplane.Memory.Embedding.{CircuitBreaker, Client}
  alias Backplane.Memory.Record

  require Logger

  @batch 50
  # 50 texts must stay within the client's 80_000 byte input cap.
  @max_text_bytes 1_600

  @impl Styx.Worker
  def perform(%Styx.Job{}) do
    if Client.configured?() and CircuitBreaker.allow_request?(), do: embed_pending()
    :ok
  end

  defp embed_pending do
    case pending() do
      [] -> :ok
      records -> embed(records)
    end
  end

  defp pending do
    Record
    |> where([r], r.status == "active" and is_nil(r.embedding))
    |> order_by([r], asc: r.inserted_at, asc: r.id)
    |> limit(@batch)
    |> select([r], {r.id, r.title, r.content})
    |> repo().all()
  end

  defp embed(rows) do
    texts = Enum.map(rows, fn {_id, title, content} -> text(title, content) end)
    opts = [req_options: Application.get_env(:backplane_memory, :embedding_req_options, [])]

    case Client.embed(texts, :document, opts) do
      {:ok, vectors} ->
        CircuitBreaker.record_success()

        rows
        |> Enum.zip(vectors)
        |> Enum.each(fn {{id, _, _}, vector} -> store(id, vector) end)

      {:error, reason} ->
        CircuitBreaker.record_failure()

        Logger.warning(
          "memory embedding failed; #{length(rows)} records left without embeddings: #{inspect(reason)}"
        )
    end
  end

  defp store(id, vector) do
    Record
    |> where([r], r.id == ^id)
    |> repo().update_all(set: [embedding: Pgvector.new(vector)])
  end

  defp text(title, content) do
    [title, content]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> truncate()
  end

  defp truncate(text) when byte_size(text) <= @max_text_bytes, do: text

  defp truncate(text) do
    case :unicode.characters_to_binary(binary_part(text, 0, @max_text_bytes)) do
      {:incomplete, valid, _rest} -> valid
      valid when is_binary(valid) -> valid
    end
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
