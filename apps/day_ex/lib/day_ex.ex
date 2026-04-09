defmodule DayEx do
  @moduledoc """
  Lightweight Elixir port of dayjs.

  Pipe-friendly date/time parsing, formatting, manipulation, and querying.
  All functions accept `%DayEx{}` as the first argument.

  Months are 1-indexed (differs from dayjs 0-indexed).
  """

  @type t :: %__MODULE__{
          datetime: DateTime.t() | NaiveDateTime.t(),
          locale: atom()
        }

  defstruct [:datetime, locale: :en]

  def now, do: %DayEx{datetime: DateTime.utc_now()}
  def now(locale) when is_atom(locale), do: %DayEx{datetime: DateTime.utc_now(), locale: locale}

  def parse(%DayEx{} = d), do: {:ok, %DayEx{datetime: d.datetime, locale: d.locale}}
  def parse(%DateTime{} = dt), do: {:ok, %DayEx{datetime: dt}}
  def parse(%NaiveDateTime{} = ndt), do: {:ok, %DayEx{datetime: ndt}}
  def parse(%Date{} = date), do: {:ok, %DayEx{datetime: NaiveDateTime.new!(date, ~T[00:00:00])}}

  def parse(ts) when is_integer(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> {:ok, %DayEx{datetime: dt}}
      {:error, reason} -> {:error, "invalid unix timestamp: #{inspect(reason)}"}
    end
  end

  def parse(ts) when is_float(ts) do
    seconds = trunc(ts)
    microseconds = round((ts - seconds) * 1_000_000)

    case DateTime.from_unix(seconds) do
      {:ok, dt} ->
        dt = %{dt | microsecond: {microseconds, 6}}
        {:ok, %DayEx{datetime: dt}}

      {:error, reason} ->
        {:error, "invalid unix timestamp: #{inspect(reason)}"}
    end
  end

  def parse(str) when is_binary(str) do
    cond do
      String.contains?(str, "T") or String.contains?(str, "t") ->
        parse_iso8601_datetime(str)

      Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, str) ->
        case Date.from_iso8601(str) do
          {:ok, date} -> {:ok, %DayEx{datetime: NaiveDateTime.new!(date, ~T[00:00:00])}}
          {:error, reason} -> {:error, "invalid date: #{inspect(reason)}"}
        end

      true ->
        {:error, "unrecognized format: #{str}"}
    end
  end

  def parse(_), do: {:error, "unsupported input type"}

  defp parse_iso8601_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        {:ok, %DayEx{datetime: dt}}

      {:error, _} ->
        case NaiveDateTime.from_iso8601(str) do
          {:ok, ndt} -> {:ok, %DayEx{datetime: ndt}}
          {:error, reason} -> {:error, "invalid datetime: #{inspect(reason)}"}
        end
    end
  end

  def parse!(input) do
    case parse(input) do
      {:ok, d} -> d
      {:error, reason} -> raise ArgumentError, "failed to parse: #{reason}"
    end
  end

  def unix(ts) when is_integer(ts) do
    {:ok, dt} = DateTime.from_unix(ts)
    %DayEx{datetime: dt}
  end

  def utc, do: %DayEx{datetime: DateTime.utc_now()}

  def utc(input) do
    {:ok, d} = parse(input)

    case d.datetime do
      %DateTime{} = dt ->
        {:ok, utc_dt} = DateTime.shift_zone(dt, "Etc/UTC")
        %DayEx{datetime: utc_dt}

      %NaiveDateTime{} = ndt ->
        dt = DateTime.from_naive!(ndt, "Etc/UTC")
        %DayEx{datetime: dt}
    end
  end

  def year(%DayEx{datetime: dt}), do: dt.year
  def month(%DayEx{datetime: dt}), do: dt.month
  def date(%DayEx{datetime: dt}), do: dt.day

  def day(%DayEx{datetime: dt}) do
    case Date.day_of_week(dt) do
      7 -> 0
      n -> n
    end
  end

  def hour(%DayEx{datetime: dt}), do: dt.hour
  def minute(%DayEx{datetime: dt}), do: dt.minute
  def second(%DayEx{datetime: dt}), do: dt.second

  def millisecond(%DayEx{datetime: dt}) do
    {us, _precision} = dt.microsecond
    div(us, 1000)
  end

  def year(%DayEx{datetime: dt} = d, value), do: %{d | datetime: update_datetime(dt, year: value)}
  def month(%DayEx{datetime: dt} = d, value), do: %{d | datetime: update_datetime(dt, month: value)}
  def date(%DayEx{datetime: dt} = d, value), do: %{d | datetime: update_datetime(dt, day: value)}
  def hour(%DayEx{datetime: dt} = d, value), do: %{d | datetime: update_datetime(dt, hour: value)}
  def minute(%DayEx{datetime: dt} = d, value), do: %{d | datetime: update_datetime(dt, minute: value)}
  def second(%DayEx{datetime: dt} = d, value), do: %{d | datetime: update_datetime(dt, second: value)}
  def millisecond(%DayEx{datetime: dt} = d, value), do: %{d | datetime: update_datetime(dt, microsecond: {value * 1000, 3})}

  def set(d, :year, value), do: year(d, value)
  def set(d, :month, value), do: month(d, value)
  def set(d, :date, value), do: date(d, value)
  def set(d, :hour, value), do: hour(d, value)
  def set(d, :minute, value), do: minute(d, value)
  def set(d, :second, value), do: second(d, value)
  def set(d, :millisecond, value), do: millisecond(d, value)

  def compare(%DayEx{datetime: dt1}, %DayEx{datetime: dt2}) do
    case {dt1, dt2} do
      {%DateTime{}, %DateTime{}} -> DateTime.compare(dt1, dt2)
      {%NaiveDateTime{}, %NaiveDateTime{}} -> NaiveDateTime.compare(dt1, dt2)
      {%DateTime{} = a, %NaiveDateTime{} = b} -> NaiveDateTime.compare(DateTime.to_naive(a), b)
      {%NaiveDateTime{} = a, %DateTime{} = b} -> NaiveDateTime.compare(a, DateTime.to_naive(b))
    end
  end

  defp update_datetime(%DateTime{} = dt, updates) do
    {date_fields, time_fields} = split_date_time_fields(updates)
    date = update_date(dt, date_fields)
    time = update_time(dt, time_fields)
    case DateTime.new(date, time, dt.time_zone) do
      {:ok, new_dt} -> new_dt
      {:ambiguous, first, _second} -> first
      {:gap, _just_before, just_after} -> just_after
    end
  end

  defp update_datetime(%NaiveDateTime{} = ndt, updates) do
    {date_fields, time_fields} = split_date_time_fields(updates)
    date = update_date(ndt, date_fields)
    time = update_time(ndt, time_fields)
    NaiveDateTime.new!(date, time)
  end

  defp split_date_time_fields(updates) do
    date_keys = [:year, :month, :day]
    date_fields = Keyword.take(updates, date_keys)
    time_fields = Keyword.drop(updates, date_keys)
    {date_fields, time_fields}
  end

  defp update_date(dt, []), do: Date.new!(dt.year, dt.month, dt.day)
  defp update_date(dt, fields) do
    year = Keyword.get(fields, :year, dt.year)
    month = Keyword.get(fields, :month, dt.month)
    day = Keyword.get(fields, :day, dt.day)
    max_day = Calendar.ISO.days_in_month(year, month)
    Date.new!(year, month, min(day, max_day))
  end

  defp update_time(dt, []), do: Time.new!(dt.hour, dt.minute, dt.second, dt.microsecond)
  defp update_time(dt, fields) do
    hour = Keyword.get(fields, :hour, dt.hour)
    minute = Keyword.get(fields, :minute, dt.minute)
    second = Keyword.get(fields, :second, dt.second)
    microsecond = Keyword.get(fields, :microsecond, dt.microsecond)
    Time.new!(hour, minute, second, microsecond)
  end

  defimpl String.Chars do
    def to_string(%DayEx{datetime: %DateTime{} = dt}) do
      DateTime.to_iso8601(dt)
    end

    def to_string(%DayEx{datetime: %NaiveDateTime{} = ndt}) do
      NaiveDateTime.to_iso8601(ndt)
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%DayEx{datetime: dt, locale: locale}, _opts) do
      dt_str =
        case dt do
          %DateTime{} -> DateTime.to_iso8601(dt)
          %NaiveDateTime{} -> NaiveDateTime.to_iso8601(dt)
        end

      concat(["#DayEx<", dt_str, " ", Atom.to_string(locale), ">"])
    end
  end
end
