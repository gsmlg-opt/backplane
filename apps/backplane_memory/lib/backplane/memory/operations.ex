defmodule Backplane.Memory.Operations do
  @moduledoc false

  alias Backplane.Memory.{EventNotifier, Events}
  alias Backplane.Memory.Operations.{Params, Query, Rollout}

  @notification_fields %{
    stream: :stream_id,
    project: :project,
    agent: :agent_id,
    session: :session_id,
    run: :run_id,
    type: :event_type,
    tool: :tool_name,
    status: :status
  }

  @notification_summary_fields [
    :agent_id,
    :event_type,
    :id,
    :occurred_at,
    :project,
    :run_id,
    :session_id,
    :status,
    :stream_id,
    :tool_name
  ]

  def timeline(raw_filters) do
    with {:ok, normalized} <- Params.timeline(raw_filters),
         {:ok, page} <- safe_read(fn -> Events.timeline(normalized.values) end) do
      {:ok, Map.merge(page, %{filters: normalized.query})}
    else
      {:error, :invalid_cursor} ->
        canonical = raw_filters |> canonical_timeline_query() |> Map.delete("cursor")
        {:error, {:invalid_param, :cursor, canonical}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_event(id), do: safe_read(fn -> Query.get_event(id) end)
  def subscribe_events, do: EventNotifier.subscribe()
  def rollout_state, do: Rollout.state()
  def set_gate(gate, value), do: Rollout.set_gate(gate, value)
  def subscribe_rollout, do: Rollout.subscribe()
  def normalize_timeline_params(raw), do: Params.timeline(raw)
  def normalize_stream_params(raw), do: Params.streams(raw)
  def normalize_sequence_params(raw), do: Params.sequence(raw)

  def overview do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    collect_regions(%{
      pipeline: &rollout_state/0,
      persisted_counts: fn -> Query.persisted_counts(now) end,
      event_volume: fn -> Query.event_volume(now) end,
      runtime_metrics: &runtime_metrics/0,
      recent_events: fn -> Query.recent_events(8) end,
      active_streams: fn -> Query.active_streams(8) end
    })
  end

  @doc false
  def collect_regions(region_functions) do
    Map.new(region_functions, fn {region, loader} ->
      result =
        try do
          {:ok, loader.()}
        rescue
          error -> {:error, error}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      {region, result}
    end)
  end

  def list_streams(raw_filters) do
    with {:ok, normalized} <- Params.streams(raw_filters),
         {:ok, page} <- safe_read(fn -> Query.list_streams(normalized.values) end) do
      {:ok, Map.put(page, :filters, normalized.query)}
    else
      {:error, :invalid_cursor} ->
        canonical = raw_filters |> canonical_stream_query() |> Map.delete("cursor")
        {:error, {:invalid_param, :cursor, canonical}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_stream(stream_id) when is_binary(stream_id) do
    if String.trim(stream_id) == "" do
      {:error, :not_found}
    else
      safe_read(fn -> Query.get_stream(stream_id) end)
    end
  end

  def get_stream(_stream_id), do: {:error, :not_found}

  def stream_events(stream_id, raw_options) do
    with {:ok, normalized} <- Params.sequence(raw_options),
         {:ok, stream} <- get_stream(stream_id),
         {:ok, page} <-
           safe_read(fn -> Query.stream_events(stream, normalized.values) end) do
      {:ok, Map.put(page, :params, normalized.query)}
    end
  end

  def notification_matches?(summary, raw_filters) when is_map(summary) do
    with true <- valid_notification_summary?(summary),
         {:ok, normalized} <- Params.timeline(raw_filters) do
      normalized.values
      |> Map.drop([:cursor, :limit])
      |> Enum.all?(fn
        {:from, from} ->
          DateTime.compare(summary.occurred_at, from) in [:eq, :gt]

        {:to, to} ->
          DateTime.compare(summary.occurred_at, to) in [:eq, :lt]

        {filter, value} ->
          case Map.fetch(@notification_fields, filter) do
            {:ok, summary_field} -> Map.get(summary, summary_field) == value
            :error -> false
          end
      end)
    else
      _error -> false
    end
  end

  def notification_matches?(_summary, _raw_filters), do: false

  defp valid_notification_summary?(summary) do
    Enum.sort(Map.keys(summary)) == Enum.sort(@notification_summary_fields) and
      is_binary(summary.id) and summary.id != "" and
      is_binary(summary.stream_id) and summary.stream_id != "" and
      is_binary(summary.event_type) and summary.event_type != "" and
      match?(%DateTime{}, summary.occurred_at) and
      Enum.all?(
        [:project, :agent_id, :session_id, :run_id, :tool_name, :status],
        fn field ->
          value = Map.get(summary, field)
          is_nil(value) or (is_binary(value) and String.valid?(value))
        end
      )
  end

  defp canonical_timeline_query(raw_filters) do
    case Params.timeline(raw_filters) do
      {:ok, %{query: query}} -> query
      {:error, {:invalid_param, _key, canonical_query}} -> canonical_query
    end
  end

  defp canonical_stream_query(raw_filters) do
    case Params.streams(raw_filters) do
      {:ok, %{query: query}} -> query
      {:error, {:invalid_param, _key, canonical_query}} -> canonical_query
    end
  end

  defp runtime_metrics do
    snapshot = Backplane.Metrics.snapshot()
    counters = Map.get(snapshot, :counters, %{})

    %{
      appended: Map.get(counters, "memory_events_appended", 0),
      duplicates: Map.get(counters, "memory_events_duplicates", 0),
      errors: Map.get(counters, "memory_events_errors", 0),
      scope: :since_process_start
    }
  end

  defp safe_read(loader) do
    try do
      loader.()
    rescue
      error -> {:error, error}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end
end
