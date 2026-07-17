defmodule Backplane.Memory.Operations.Query do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Memory.Events
  alias Backplane.Memory.Events.{Event, Stream}

  def list_streams(filters) do
    with {:ok, cursor} <- decode_stream_cursor(Map.get(filters, :cursor)) do
      limit = Map.fetch!(filters, :limit)

      query =
        Stream
        |> apply_stream_filters(filters)
        |> apply_stream_cursor(cursor)
        |> order_by([stream],
          desc_nulls_last: stream.last_event_at,
          desc: stream.stream_id
        )
        |> limit(^(limit + 1))

      rows = repo().all(query)
      {streams, remaining} = Enum.split(rows, limit)

      next_cursor =
        if remaining == [] do
          nil
        else
          streams |> List.last() |> encode_stream_cursor()
        end

      {:ok, %{streams: streams, next_cursor: next_cursor}}
    end
  end

  def get_event(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case repo().get(Event, uuid) do
          nil -> {:error, :not_found}
          event -> {:ok, event}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def get_stream(stream_id) do
    case repo().get(Stream, stream_id) do
      nil -> {:error, :not_found}
      stream -> {:ok, stream}
    end
  end

  def stream_events(%Stream{} = stream, options) do
    max_sequence = max(stream.next_sequence - 1, 0)
    {window, bounds} = sequence_bounds(max_sequence, options)

    case bounds do
      nil ->
        {:ok,
         %{
           events: [],
           older_before: nil,
           newer_after: nil,
           window: window
         }}

      {first_sequence, last_sequence} ->
        with {:ok, events} <-
               Events.range(stream.stream_id, first_sequence..last_sequence) do
          first = List.first(events)
          last = List.last(events)

          {:ok,
           %{
             events: events,
             older_before: if(first && first.sequence > 1, do: first.sequence, else: nil),
             newer_after: if(last && last.sequence < max_sequence, do: last.sequence, else: nil),
             window: window
           }}
        end
    end
  end

  defp apply_stream_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:state, "open"}, query -> where(query, [stream], is_nil(stream.closed_at))
      {:state, "closed"}, query -> where(query, [stream], not is_nil(stream.closed_at))
      {:project, value}, query -> where(query, [stream], stream.project == ^value)
      {:agent, value}, query -> where(query, [stream], stream.agent_id == ^value)
      {:host, value}, query -> where(query, [stream], stream.host_id == ^value)
      {:session, value}, query -> where(query, [stream], stream.session_id == ^value)
      {:run, value}, query -> where(query, [stream], stream.run_id == ^value)
      {_option, _value}, query -> query
    end)
  end

  defp apply_stream_cursor(query, nil), do: query

  defp apply_stream_cursor(query, {:dated, last_event_at, stream_id}) do
    where(
      query,
      [stream],
      stream.last_event_at < ^last_event_at or
        (stream.last_event_at == ^last_event_at and stream.stream_id < ^stream_id) or
        is_nil(stream.last_event_at)
    )
  end

  defp apply_stream_cursor(query, {:undated, stream_id}) do
    where(
      query,
      [stream],
      is_nil(stream.last_event_at) and stream.stream_id < ^stream_id
    )
  end

  defp decode_stream_cursor(nil), do: {:ok, nil}

  defp decode_stream_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, decoded} <- Jason.decode(json) do
      decode_stream_cursor_map(decoded)
    else
      _error -> {:error, :invalid_cursor}
    end
  end

  defp decode_stream_cursor(_cursor), do: {:error, :invalid_cursor}

  defp decode_stream_cursor_map(
         cursor = %{
           "branch" => "dated",
           "last_event_at" => last_event_at,
           "stream_id" => stream_id
         }
       )
       when map_size(cursor) == 3 and is_binary(last_event_at) and
              is_binary(stream_id) and byte_size(stream_id) > 0 do
    case DateTime.from_iso8601(last_event_at) do
      {:ok, datetime, _offset} -> {:ok, {:dated, datetime, stream_id}}
      _error -> {:error, :invalid_cursor}
    end
  end

  defp decode_stream_cursor_map(cursor = %{"branch" => "undated", "stream_id" => stream_id})
       when map_size(cursor) == 2 and is_binary(stream_id) and byte_size(stream_id) > 0 do
    {:ok, {:undated, stream_id}}
  end

  defp decode_stream_cursor_map(_cursor), do: {:error, :invalid_cursor}

  defp encode_stream_cursor(%Stream{last_event_at: nil, stream_id: stream_id}) do
    %{"branch" => "undated", "stream_id" => stream_id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp encode_stream_cursor(%Stream{} = stream) do
    %{
      "branch" => "dated",
      "last_event_at" => DateTime.to_iso8601(stream.last_event_at),
      "stream_id" => stream.stream_id
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp sequence_bounds(0, options), do: {sequence_window(options), nil}

  defp sequence_bounds(max_sequence, %{before: before_sequence, limit: limit}) do
    last_sequence = min(max_sequence, before_sequence - 1)

    if last_sequence < 1 do
      {:before, nil}
    else
      {:before, {max(1, last_sequence - limit + 1), last_sequence}}
    end
  end

  defp sequence_bounds(max_sequence, %{after: after_sequence, limit: limit}) do
    first_sequence = after_sequence + 1

    if first_sequence > max_sequence do
      {:after, nil}
    else
      {:after, {first_sequence, min(max_sequence, first_sequence + limit - 1)}}
    end
  end

  defp sequence_bounds(max_sequence, %{limit: limit}) do
    {:latest, {max(1, max_sequence - limit + 1), max_sequence}}
  end

  defp sequence_window(%{before: _sequence}), do: :before
  defp sequence_window(%{after: _sequence}), do: :after
  defp sequence_window(_options), do: :latest

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
