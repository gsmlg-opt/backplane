defmodule Backplane.AgentTraces do
  @moduledoc """
  Context for trace events synced from host agents.
  """

  import Ecto.Query

  alias Backplane.AgentTraces.Event
  alias Backplane.Repo

  @type ingest_result :: {integer() | nil, :ok | {:error, String.t()}}

  @doc """
  Ingests host-agent trace items, returning one result per input item.

  Re-delivery of an already stored `{host_id, seq}` pair is treated as `:ok`.
  Invalid items do not abort the rest of the batch.
  """
  @spec ingest(Ecto.UUID.t(), [map()]) :: [ingest_result()]
  def ingest(host_id, items) when is_binary(host_id) and is_list(items) do
    Enum.map(items, &ingest_item(host_id, &1))
  end

  @doc "Lists trace events for a trace ID in occurrence order."
  @spec list_by_trace(String.t()) :: [Event.t()]
  def list_by_trace(trace_id) when is_binary(trace_id) do
    Event
    |> where([event], event.trace_id == ^trace_id)
    |> order_by([event], asc: event.occurred_at, asc: event.agent_seq)
    |> Repo.all()
  end

  @doc "Lists recent trace events for a host in reverse occurrence order."
  @spec recent(Ecto.UUID.t(), pos_integer()) :: [Event.t()]
  def recent(host_id, limit) when is_binary(host_id) and is_integer(limit) and limit > 0 do
    Event
    |> where([event], event.host_id == ^host_id)
    |> order_by([event], desc: event.occurred_at, desc: event.agent_seq)
    |> limit(^limit)
    |> Repo.all()
  end

  defp ingest_item(host_id, %{"seq" => seq} = item) when is_integer(seq) do
    attrs = %{
      host_id: host_id,
      agent_seq: seq,
      trace_id: item["trace_id"],
      span_id: item["span_id"],
      parent_id: item["parent_id"],
      event: item["event"],
      measurements: item["measurements"],
      metadata: item["metadata"],
      occurred_at: parse_occurred_at(item["occurred_at"])
    }

    changeset = Event.changeset(%Event{}, attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:host_id, :agent_seq]
         ) do
      {:ok, _event} -> {seq, :ok}
      {:error, changeset} -> {seq, {:error, changeset_error(changeset)}}
    end
  end

  defp ingest_item(_host_id, %{"seq" => seq}) do
    {seq, {:error, "seq must be an integer"}}
  end

  defp ingest_item(_host_id, _item) do
    {nil, {:error, "seq is required"}}
  end

  defp parse_occurred_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_occurred_at(_value), do: nil

  defp changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end
end
