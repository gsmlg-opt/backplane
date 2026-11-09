defmodule Backplane.Memory.Distill do
  @moduledoc """
  Runs background distillation for one claimed session.

  Loads the session's projected observations in `source_sequence` order, runs the
  memory agent over each chunk sequentially, and records completion or the first
  failure on the `Backplane.Memory.Distillation` row. A session without
  observations completes with zero records and no LLM call.
  """

  import Ecto.Query

  alias Backplane.Memory.{Distillation, Distillations}
  alias Backplane.Memory.Distill.{Agent, Chunker}
  alias Backplane.Memory.Projections.ProjectedObservation

  @spec run(String.t(), keyword()) :: :ok
  def run(subject_id, opts \\ []) when is_binary(subject_id) do
    case repo().get(Distillation, subject_id) do
      nil -> :ok
      %Distillation{} = row -> distill(row, opts)
    end
  end

  defp distill(row, opts) do
    case row.subject_id |> observations() |> Chunker.chunks() do
      [] -> Distillations.complete(row.subject_id, 0)
      chunks -> run_chunks(row, chunks, opts)
    end
  end

  defp run_chunks(row, chunks, opts) do
    total = length(chunks)

    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, 0}, fn {chunk, index}, {:ok, written} ->
      agent_opts = Keyword.put(opts, :chunk_index, index)

      case Agent.run_chunk(session(row), chunk, row.mode, agent_opts) do
        {:ok, %{records_written: count}} ->
          {:cont, {:ok, written + count}}

        {:error, reason} ->
          {:halt, {:error, "chunk #{index + 1}/#{total}: #{reason}"}}
      end
    end)
    |> finish(row.subject_id)
  end

  defp finish({:ok, written}, subject_id), do: Distillations.complete(subject_id, written)

  defp finish({:error, message}, subject_id), do: Distillations.fail(subject_id, message)

  defp session(row) do
    Map.take(row, [:subject_id, :host_id, :session_id, :agent_id, :integration, :mode])
  end

  defp observations(subject_id) do
    repo().all(
      from(o in ProjectedObservation,
        where: o.subject_id == ^subject_id,
        order_by: [asc: o.source_sequence, asc: o.event_id]
      )
    )
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
