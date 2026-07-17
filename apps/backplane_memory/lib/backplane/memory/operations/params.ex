defmodule Backplane.Memory.Operations.Params do
  @moduledoc false

  @timeline_fields %{
    "stream" => {:stream, :string},
    "project" => {:project, :string},
    "agent" => {:agent, :string},
    "session" => {:session, :string},
    "run" => {:run, :string},
    "type" => {:type, :string},
    "tool" => {:tool, :string},
    "status" => {:status, :string},
    "from" => {:from, :time},
    "to" => {:to, :time},
    "cursor" => {:cursor, :cursor},
    "limit" => {:limit, :limit}
  }

  @stream_fields %{
    "state" => {:state, :state},
    "project" => {:project, :string},
    "agent" => {:agent, :string},
    "host" => {:host, :string},
    "session" => {:session, :string},
    "run" => {:run, :string},
    "cursor" => {:cursor, :cursor},
    "limit" => {:limit, :limit}
  }

  @sequence_fields %{
    "before" => {:before, :anchor},
    "after" => {:after, :anchor},
    "limit" => {:limit, :limit}
  }

  def timeline(raw), do: normalize(raw, @timeline_fields, 50, :standard)
  def streams(raw), do: normalize(raw, @stream_fields, 50, :standard)
  def sequence(raw), do: normalize(raw, @sequence_fields, 100, :sequence)

  defp normalize(raw, fields, default_limit, mode) do
    with {:ok, pairs} <- pairs(raw) do
      {values, query, invalid_key} =
        Enum.reduce(pairs, {%{}, %{}, nil}, fn {raw_key, raw_value},
                                               {values, query, invalid_key} ->
          case normalize_key(fields, raw_key) do
            {:ok, key, parser, query_key} ->
              case normalize_value(parser, raw_value) do
                :omit ->
                  {values, query, invalid_key}

                {:ok, value, canonical} ->
                  {
                    Map.put(values, key, value),
                    Map.put(query, query_key, canonical),
                    invalid_key
                  }

                :error ->
                  {values, query, invalid_key || key}
              end

            :error ->
              {values, query, invalid_key || raw_key}
          end
        end)

      {values, query, invalid_key} =
        enforce_mode(mode, values, query, invalid_key)

      values = Map.put_new(values, :limit, default_limit)

      query =
        if values.limit == default_limit,
          do: Map.delete(query, "limit"),
          else: query

      if invalid_key do
        {:error, {:invalid_param, invalid_key, query}}
      else
        {:ok, %{values: values, query: query}}
      end
    else
      :error -> {:error, {:invalid_param, :filters, %{}}}
    end
  end

  defp pairs(raw) when is_map(raw), do: {:ok, Map.to_list(raw)}

  defp pairs(raw) when is_list(raw) do
    if Keyword.keyword?(raw), do: {:ok, raw}, else: :error
  end

  defp pairs(_raw), do: :error

  defp normalize_key(fields, raw_key) when is_atom(raw_key) do
    normalize_key(fields, Atom.to_string(raw_key))
  end

  defp normalize_key(fields, raw_key) when is_binary(raw_key) do
    case Map.fetch(fields, raw_key) do
      {:ok, {key, parser}} -> {:ok, key, parser, raw_key}
      :error -> :error
    end
  end

  defp normalize_key(_fields, _raw_key), do: :error

  defp normalize_value(_parser, nil), do: :omit

  defp normalize_value(:limit, value) when is_integer(value) and value > 0 do
    capped = min(value, 100)
    {:ok, capped, Integer.to_string(capped)}
  end

  defp normalize_value(:anchor, value) when is_integer(value) and value > 0 do
    {:ok, value, Integer.to_string(value)}
  end

  defp normalize_value(parser, value) when is_binary(value) do
    if String.valid?(value) do
      value
      |> String.trim()
      |> normalize_trimmed(parser)
    else
      :error
    end
  end

  defp normalize_value(_parser, _value), do: :error

  defp normalize_trimmed("", _parser), do: :omit
  defp normalize_trimmed(value, :string), do: {:ok, value, value}
  defp normalize_trimmed(value, :cursor), do: {:ok, value, value}

  defp normalize_trimmed(value, :state) when value in ["open", "closed"] do
    {:ok, value, value}
  end

  defp normalize_trimmed(_value, :state), do: :error

  defp normalize_trimmed(value, parser) when parser in [:limit, :anchor] do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> normalize_value(parser, integer)
      _error -> :error
    end
  end

  defp normalize_trimmed(value, :time) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime, DateTime.to_iso8601(datetime)}

      {:error, _reason} ->
        local_value =
          if Regex.match?(
               ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/,
               value
             ),
             do: value <> ":00",
             else: value

        with {:ok, naive} <- NaiveDateTime.from_iso8601(local_value),
             {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, datetime, DateTime.to_iso8601(datetime)}
        else
          _error -> :error
        end
    end
  end

  defp enforce_mode(:standard, values, query, invalid_key) do
    {values, query, invalid_key}
  end

  defp enforce_mode(:sequence, values, query, invalid_key) do
    if Map.has_key?(values, :before) and Map.has_key?(values, :after) do
      {
        Map.delete(values, :after),
        Map.delete(query, "after"),
        invalid_key || :after
      }
    else
      {values, query, invalid_key}
    end
  end
end
