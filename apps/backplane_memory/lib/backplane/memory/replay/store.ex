defmodule Backplane.Memory.Replay.Store do
  @moduledoc false
  alias Backplane.Memory.Replay.Event
  @version "replay-v1"

  def put!(subject_id, input_revision, partition, session_id, rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    {:ok, partition} = Backplane.Memory.PartitionIdentity.validate(partition)

    entries =
      Enum.map(rows, fn row ->
        %{
          subject_id: subject_id,
          input_revision: input_revision,
          position: row["position"],
          event_id: row["event_id"],
          memory_space_id: partition.memory_space_id,
          host_id: partition.host_id,
          client_id: partition.client_id,
          source_client_id: partition[:source_client_id],
          scope: partition.scope,
          namespace: partition.namespace,
          session_id: session_id,
          source_sequence: row["source_sequence"],
          kind: row["kind"],
          event_type: row["event_type"],
          occurred_at: parse!(row["occurred_at"]),
          detail: row["detail"],
          processing_version: @version,
          inserted_at: now,
          updated_at: now
        }
      end)

    if entries != [], do: repo().insert_all(Event, entries, on_conflict: :nothing)

    Backplane.Memory.ReplayNotifier.enqueue(repo(), %{
      memory_space_id: partition.memory_space_id,
      host_id: partition.host_id,
      client_id: partition.client_id,
      scope: partition.scope,
      namespace: partition.namespace,
      session_id: session_id,
      input_revision: input_revision
    })

    :ok
  end

  defp parse!(value), do: elem(DateTime.from_iso8601(value), 1)
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
