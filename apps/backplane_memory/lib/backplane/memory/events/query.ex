defmodule Backplane.Memory.Events.Query do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Memory.Events.Event

  @default_limit 100
  @maximum_limit 500
  @maximum_sequence 9_223_372_036_854_775_807
  @equality_filters [:stream, :project, :agent, :session, :run, :type, :tool, :status]

  @filter_aliases %{
    :stream => :stream,
    "stream" => :stream,
    :project => :project,
    "project" => :project,
    :agent => :agent,
    "agent" => :agent,
    :session => :session,
    "session" => :session,
    :run => :run,
    "run" => :run,
    :type => :type,
    "type" => :type,
    :tool => :tool,
    "tool" => :tool,
    :status => :status,
    "status" => :status,
    :from => :from,
    "from" => :from,
    :to => :to,
    "to" => :to,
    :limit => :limit,
    "limit" => :limit,
    :cursor => :cursor,
    "cursor" => :cursor
  }

  def range(stream_id, %Range{first: first, last: last, step: 1})
      when is_binary(stream_id) and byte_size(stream_id) > 0 and is_integer(first) and
             is_integer(last) and first > 0 and last >= first and
             first <= @maximum_sequence and last <= @maximum_sequence do
    events =
      Event
      |> where([e], e.stream_id == ^stream_id)
      |> where([e], e.sequence >= ^first and e.sequence <= ^last)
      |> order_by([e], asc: e.sequence)
      |> repo().all()

    {:ok, events}
  end

  def range(stream_id, _range) when not is_binary(stream_id) or byte_size(stream_id) == 0,
    do: {:error, :invalid_stream_id}

  def range(_stream_id, _range), do: {:error, :invalid_range}

  def timeline(filters) do
    with {:ok, filters} <- normalize_filters(filters),
         {:ok, limit} <- normalize_limit(Map.get(filters, :limit)),
         {:ok, from} <- normalize_time(Map.get(filters, :from)),
         {:ok, to} <- normalize_time(Map.get(filters, :to)),
         {:ok, cursor} <- decode_cursor(Map.get(filters, :cursor)) do
      query =
        Event
        |> apply_equality_filters(filters)
        |> apply_time_filter(:from, from)
        |> apply_time_filter(:to, to)
        |> apply_cursor(cursor)
        |> order_by([e], desc: e.occurred_at, desc: e.id)
        |> limit(^(limit + 1))

      rows = repo().all(query)
      {events, remaining} = Enum.split(rows, limit)

      next_cursor =
        if remaining == [] do
          nil
        else
          events |> List.last() |> encode_cursor()
        end

      {:ok, %{events: events, next_cursor: next_cursor}}
    end
  end

  defp normalize_filters(filters) when is_list(filters) do
    if Keyword.keyword?(filters),
      do: normalize_filter_pairs(filters),
      else: {:error, :invalid_filters}
  end

  defp normalize_filters(filters) when is_map(filters),
    do: filters |> Map.to_list() |> normalize_filter_pairs()

  defp normalize_filters(_filters), do: {:error, :invalid_filters}

  defp normalize_filter_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      case Map.fetch(@filter_aliases, key) do
        {:ok, normalized_key} ->
          case put_filter(normalized, normalized_key, value) do
            {:ok, normalized} -> {:cont, {:ok, normalized}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        :error ->
          {:halt, {:error, :invalid_filters}}
      end
    end)
  end

  defp put_filter(filters, _key, nil), do: {:ok, filters}

  defp put_filter(filters, key, value) when key in @equality_filters do
    if is_binary(value) and String.valid?(value),
      do: {:ok, Map.put(filters, key, value)},
      else: {:error, :invalid_filters}
  end

  defp put_filter(filters, key, value), do: {:ok, Map.put(filters, key, value)}

  defp normalize_limit(nil), do: {:ok, @default_limit}

  defp normalize_limit(limit) when is_integer(limit) and limit > 0,
    do: {:ok, min(limit, @maximum_limit)}

  defp normalize_limit(_limit), do: {:error, :invalid_limit}

  defp normalize_time(nil), do: {:ok, nil}

  defp normalize_time(%DateTime{} = value) do
    value
    |> DateTime.to_unix(:microsecond)
    |> DateTime.from_unix!(:microsecond)
    |> then(&{:ok, &1})
  end

  defp normalize_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> normalize_time(datetime)
      _ -> {:error, :invalid_time}
    end
  end

  defp normalize_time(_value), do: {:error, :invalid_time}

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"occurred_at" => occurred_at, "id" => id}} <- Jason.decode(json),
         {:ok, occurred_at} <- normalize_time(occurred_at),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {occurred_at, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_cursor), do: {:error, :invalid_cursor}

  defp encode_cursor(%Event{} = event) do
    %{
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "id" => event.id
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp apply_equality_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:stream, value}, query -> where(query, [e], e.stream_id == ^value)
      {:project, value}, query -> where(query, [e], e.project == ^value)
      {:agent, value}, query -> where(query, [e], e.agent_id == ^value)
      {:session, value}, query -> where(query, [e], e.session_id == ^value)
      {:run, value}, query -> where(query, [e], e.run_id == ^value)
      {:type, value}, query -> where(query, [e], e.event_type == ^value)
      {:tool, value}, query -> where(query, [e], e.tool_name == ^value)
      {:status, value}, query -> where(query, [e], e.status == ^value)
      {_option, _value}, query -> query
    end)
  end

  defp apply_time_filter(query, _direction, nil), do: query
  defp apply_time_filter(query, :from, value), do: where(query, [e], e.occurred_at >= ^value)
  defp apply_time_filter(query, :to, value), do: where(query, [e], e.occurred_at <= ^value)

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, {occurred_at, id}) do
    where(
      query,
      [e],
      e.occurred_at < ^occurred_at or (e.occurred_at == ^occurred_at and e.id < ^id)
    )
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
