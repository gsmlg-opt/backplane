defmodule Backplane.Memory.Distill do
  @moduledoc """
  Runs background distillation for one claimed session.

  Loads the session's projected observations after the row's
  `distilled_through_sequence` watermark, in `source_sequence` order, joined with
  their captured event's `payload.source.tool_input`, and runs the memory agent
  over each chunk sequentially. After every completed chunk the watermark,
  heartbeat and accumulated `records_written` are stored, so a failed or
  interrupted run keeps its progress and a retry or a reopened session resumes
  after it. At most 20 chunks run per call; when more remain the row goes back
  to `pending` for the next scheduler tick. A session without new observations
  completes with no LLM call.
  """

  import Ecto.Query

  alias Backplane.Memory.{Distillation, Distillations}
  alias Backplane.Memory.Distill.{Agent, Chunker}
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.ProjectedObservation

  @max_chunks_per_run 20

  @spec run(String.t(), keyword()) :: :ok
  def run(subject_id, opts \\ []) when is_binary(subject_id) do
    case repo().get(Distillation, subject_id) do
      nil -> :ok
      %Distillation{} = row -> distill(row, opts)
    end
  end

  defp distill(row, opts) do
    observations = observations(row.subject_id, row.distilled_through_sequence || 0)

    case Chunker.chunks(observations) do
      [] -> Distillations.complete(row.subject_id)
      chunks -> run_chunks(row, chunks, sequences(observations), opts)
    end
  end

  defp run_chunks(row, chunks, sequences, opts) do
    total = length(chunks)
    {batch, rest} = Enum.split(chunks, @max_chunks_per_run)

    batch
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {chunk, index}, :ok ->
      agent_opts = Keyword.put(opts, :chunk_index, index)

      case Agent.run_chunk(session(row), chunk, row.mode, agent_opts) do
        {:ok, %{records_written: count}} ->
          Distillations.record_progress(row.subject_id, through(chunk, sequences), count)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "chunk #{index + 1}/#{total}: #{reason}"}}
      end
    end)
    |> finish(row.subject_id, rest)
  end

  defp finish(:ok, subject_id, []), do: Distillations.complete(subject_id)
  defp finish(:ok, subject_id, _remaining), do: Distillations.requeue(subject_id)

  defp finish({:error, message}, subject_id, _remaining),
    do: Distillations.fail(subject_id, message)

  defp through(chunk, sequences),
    do: chunk |> Enum.map(&Map.fetch!(sequences, &1["event_id"])) |> Enum.max()

  defp sequences(observations),
    do: Map.new(observations, fn {o, _input} -> {o.event_id, o.source_sequence} end)

  defp session(row) do
    Map.take(row, [:subject_id, :host_id, :session_id, :agent_id, :integration, :mode])
  end

  defp observations(subject_id, watermark) do
    repo().all(
      from(o in ProjectedObservation,
        left_join: e in Event,
        on: e.id == o.event_id,
        where: o.subject_id == ^subject_id and o.source_sequence > ^watermark,
        order_by: [asc: o.source_sequence, asc: o.event_id],
        select: {o, e.payload["source"]["tool_input"]}
      )
    )
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
