defmodule Backplane.Docs.Indexer do
  @moduledoc """
  Database operations for doc chunk indexing.

  Inserts new chunks, skips unchanged (same content_hash),
  deletes removed chunks, and updates reindex_state.
  """

  import Ecto.Query
  alias Backplane.Docs.{DocChunk, ReindexState}
  alias Backplane.Repo

  @doc """
  Index a set of processed chunks for a project.
  Returns {:ok, stats} with insert/delete/skip counts.
  """
  @spec index(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def index(project_id, chunks) do
    existing = load_existing_hashes(project_id)
    new_hashes = MapSet.new(chunks, & &1.content_hash)

    to_insert =
      Enum.reject(chunks, fn chunk ->
        MapSet.member?(existing, chunk.content_hash)
      end)

    to_delete_hashes = MapSet.difference(existing, new_hashes)
    skip_count = length(chunks) - length(to_insert)

    # Wrap delete + insert in a transaction so a crash between them
    # doesn't leave the index in an inconsistent state
    case Repo.transaction(fn ->
           deleted_count = delete_chunks(project_id, to_delete_hashes)
           inserted_count = insert_chunks(project_id, to_insert)

           %{
             inserted: inserted_count,
             deleted: deleted_count,
             skipped: skip_count,
             total: length(chunks)
           }
         end) do
      {:ok, stats} -> {:ok, stats}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Update the reindex state for a project.
  """
  @spec update_reindex_state(String.t(), map()) ::
          {:ok, ReindexState.t()} | {:error, Ecto.Changeset.t()}
  def update_reindex_state(project_id, attrs) do
    case Repo.get(ReindexState, project_id) do
      nil ->
        %ReindexState{}
        |> ReindexState.changeset(Map.put(attrs, :project_id, project_id))
        |> Repo.insert()

      state ->
        state
        |> ReindexState.changeset(attrs)
        |> Repo.update()
    end
  end

  defp load_existing_hashes(project_id) do
    DocChunk
    |> where([c], c.project_id == ^project_id)
    |> select([c], c.content_hash)
    |> Repo.all()
    |> MapSet.new()
  end

  defp delete_chunks(project_id, hashes) do
    hash_list = MapSet.to_list(hashes)

    case hash_list do
      [] ->
        0

      _ ->
        {count, _} =
          DocChunk
          |> where([c], c.project_id == ^project_id and c.content_hash in ^hash_list)
          |> Repo.delete_all()

        count
    end
  end

  defp insert_chunks(_project_id, []), do: 0

  defp insert_chunks(project_id, chunks) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    entries =
      Enum.map(chunks, fn chunk ->
        %{
          project_id: project_id,
          source_path: chunk.source_path,
          module: chunk[:module],
          function: chunk[:function],
          chunk_type: chunk.chunk_type,
          content: chunk.content,
          content_hash: chunk.content_hash,
          tokens: chunk[:tokens],
          inserted_at: now
        }
      end)

    # Insert in batches to avoid huge queries
    entries
    |> Enum.chunk_every(500)
    |> Enum.each(fn batch ->
      Repo.insert_all(DocChunk, batch)
    end)

    length(entries)
  end
end
