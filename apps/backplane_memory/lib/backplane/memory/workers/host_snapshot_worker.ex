defmodule Backplane.Memory.Workers.HostSnapshotWorker do
  @moduledoc "Applies one accepted `host.snapshot.collected` event as `host_collector` facts."

  use Styx.Worker,
    queue: :memory,
    max_attempts: 5

  require Logger

  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.HostSnapshots

  @invalid_payload [
    :unknown_collector,
    :invalid_unit,
    :invalid_complete,
    :invalid_items,
    :invalid_item,
    :invalid_host_label,
    :invalid_unscanned
  ]

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"event_id" => event_id}}) when is_binary(event_id) do
    case repo().get(Event, event_id) do
      nil -> :ok
      %Event{} = event -> apply_snapshot(event)
    end
  end

  def perform(%Styx.Job{}), do: {:cancel, :invalid_arguments}

  @spec enqueue(String.t()) :: {:ok, Styx.Job.t()} | {:error, term()}
  def enqueue(event_id) when is_binary(event_id) do
    %{event_id: event_id}
    |> new(unique: [period: :infinity, keys: [:event_id]])
    |> Styx.insert()
  end

  defp apply_snapshot(%Event{} = event) do
    case HostSnapshots.apply(event) do
      {:ok, _result} ->
        :ok

      {:error, reason} when reason in @invalid_payload ->
        Logger.warning("host snapshot #{event.id} rejected: #{reason}")
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
