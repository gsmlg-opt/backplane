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

  def add(%DayEx{} = d, n, :year) do
    new_year = year(d) + n
    max_day = Calendar.ISO.days_in_month(new_year, month(d))
    clamped_day = min(date(d), max_day)
    %{d | datetime: update_datetime(d.datetime, year: new_year, day: clamped_day)}
  end

  def add(%DayEx{} = d, n, :month) do
    total_months = (year(d) - 1) * 12 + (month(d) - 1) + n
    new_year = div(total_months, 12) + 1
    new_month = rem(total_months, 12) + 1
    max_day = Calendar.ISO.days_in_month(new_year, new_month)
    clamped_day = min(date(d), max_day)
    %{d | datetime: update_datetime(d.datetime, year: new_year, month: new_month, day: clamped_day)}
  end

  def add(%DayEx{} = d, n, :week), do: add(d, n * 7, :day)

  def add(%DayEx{datetime: %DateTime{} = dt} = d, n, unit)
      when unit in [:day, :hour, :minute, :second, :millisecond] do
    new_dt =
      case unit do
        :millisecond -> DateTime.add(dt, n, :millisecond)
        :second -> DateTime.add(dt, n, :second)
        :minute -> DateTime.add(dt, n * 60, :second)
        :hour -> DateTime.add(dt, n * 3_600, :second)
        :day -> DateTime.add(dt, n * 86_400, :second)
      end

    %{d | datetime: new_dt}
  end

  def add(%DayEx{datetime: %NaiveDateTime{} = ndt} = d, n, unit)
      when unit in [:day, :hour, :minute, :second, :millisecond] do
    new_ndt =
      case unit do
        :millisecond -> NaiveDateTime.add(ndt, n, :millisecond)
        :second -> NaiveDateTime.add(ndt, n, :second)
        :minute -> NaiveDateTime.add(ndt, n * 60, :second)
        :hour -> NaiveDateTime.add(ndt, n * 3_600, :second)
        :day -> NaiveDateTime.add(ndt, n * 86_400, :second)
      end

    %{d | datetime: new_ndt}
  end

  def subtract(%DayEx{} = d, n, unit), do: add(d, -n, unit)

  def start_of(%DayEx{} = d, :year),
    do: %{d | datetime: update_datetime(d.datetime, month: 1, day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0})}

  def start_of(%DayEx{} = d, :month),
    do: %{d | datetime: update_datetime(d.datetime, day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0})}

  def start_of(%DayEx{} = d, :week) do
    days_since_sunday = day(d)
    d |> subtract(days_since_sunday, :day) |> start_of(:day)
  end

  def start_of(%DayEx{} = d, :day),
    do: %{d | datetime: update_datetime(d.datetime, hour: 0, minute: 0, second: 0, microsecond: {0, 0})}

  def start_of(%DayEx{} = d, :hour),
    do: %{d | datetime: update_datetime(d.datetime, minute: 0, second: 0, microsecond: {0, 0})}

  def start_of(%DayEx{} = d, :minute),
    do: %{d | datetime: update_datetime(d.datetime, second: 0, microsecond: {0, 0})}

  def start_of(%DayEx{} = d, :second),
    do: %{d | datetime: update_datetime(d.datetime, microsecond: {0, 0})}

  def end_of(%DayEx{} = d, :year),
    do: %{d | datetime: update_datetime(d.datetime, month: 12, day: 31, hour: 23, minute: 59, second: 59, microsecond: {999_000, 3})}

  def end_of(%DayEx{} = d, :month) do
    max_day = Calendar.ISO.days_in_month(year(d), month(d))
    %{d | datetime: update_datetime(d.datetime, day: max_day, hour: 23, minute: 59, second: 59, microsecond: {999_000, 3})}
  end

  def end_of(%DayEx{} = d, :week) do
    days_until_saturday = 6 - day(d)
    d |> add(days_until_saturday, :day) |> end_of(:day)
  end

  def end_of(%DayEx{} = d, :day),
    do: %{d | datetime: update_datetime(d.datetime, hour: 23, minute: 59, second: 59, microsecond: {999_000, 3})}

  def end_of(%DayEx{} = d, :hour),
    do: %{d | datetime: update_datetime(d.datetime, minute: 59, second: 59, microsecond: {999_000, 3})}

  def end_of(%DayEx{} = d, :minute),
    do: %{d | datetime: update_datetime(d.datetime, second: 59, microsecond: {999_000, 3})}

  def end_of(%DayEx{} = d, :second),
    do: %{d | datetime: update_datetime(d.datetime, microsecond: {999_000, 3})}

  def valid?(%DayEx{datetime: nil}), do: false
  def valid?(%DayEx{datetime: %DateTime{}}), do: true
  def valid?(%DayEx{datetime: %NaiveDateTime{}}), do: true
  def valid?(_), do: false

  def format(%DayEx{} = d), do: to_string(d)
  def format(%DayEx{} = d, template), do: DayEx.Format.format(d, template)

  def to_iso_string(%DayEx{datetime: %DateTime{} = dt}) do
    {:ok, utc} = DateTime.shift_zone(dt, "Etc/UTC")
    DateTime.to_iso8601(utc)
  end
  def to_iso_string(%DayEx{datetime: %NaiveDateTime{} = ndt}), do: NaiveDateTime.to_iso8601(ndt) <> "Z"

  def to_json(%DayEx{} = d), do: to_iso_string(d)

  def to_unix(%DayEx{datetime: %DateTime{} = dt}), do: DateTime.to_unix(dt)
  def to_unix(%DayEx{datetime: %NaiveDateTime{} = ndt}), do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  def to_list(%DayEx{} = d), do: [year(d), month(d), date(d), hour(d), minute(d), second(d), millisecond(d)]

  def to_map(%DayEx{} = d) do
    %{year: year(d), month: month(d), date: date(d), hour: hour(d), minute: minute(d), second: second(d), millisecond: millisecond(d)}
  end

  def to_date(%DayEx{datetime: dt}), do: dt

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
