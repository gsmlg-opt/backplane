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

  @unit_aliases %{
    :year => :year,
    :years => :year,
    :y => :year,
    "year" => :year,
    "years" => :year,
    "y" => :year,
    :quarter => :quarter,
    :quarters => :quarter,
    :Q => :quarter,
    "quarter" => :quarter,
    "quarters" => :quarter,
    "Q" => :quarter,
    :month => :month,
    :months => :month,
    :M => :month,
    "month" => :month,
    "months" => :month,
    "M" => :month,
    :week => :week,
    :weeks => :week,
    :w => :week,
    "week" => :week,
    "weeks" => :week,
    "w" => :week,
    :day => :day,
    :days => :day,
    :d => :day,
    "day" => :day,
    "days" => :day,
    "d" => :day,
    :date => :date,
    :dates => :date,
    :D => :date,
    "date" => :date,
    "dates" => :date,
    "D" => :date,
    :hour => :hour,
    :hours => :hour,
    :h => :hour,
    "hour" => :hour,
    "hours" => :hour,
    "h" => :hour,
    :minute => :minute,
    :minutes => :minute,
    :m => :minute,
    "minute" => :minute,
    "minutes" => :minute,
    "m" => :minute,
    :second => :second,
    :seconds => :second,
    :s => :second,
    "second" => :second,
    "seconds" => :second,
    "s" => :second,
    :millisecond => :millisecond,
    :milliseconds => :millisecond,
    :ms => :millisecond,
    "millisecond" => :millisecond,
    "milliseconds" => :millisecond,
    "ms" => :millisecond
  }

  def now, do: %DayEx{datetime: DateTime.utc_now()}
  def now(locale) when is_atom(locale), do: %DayEx{datetime: DateTime.utc_now(), locale: locale}

  def parse(%DayEx{} = d), do: {:ok, %DayEx{datetime: d.datetime, locale: d.locale}}
  def parse(%DateTime{} = dt), do: {:ok, %DayEx{datetime: dt}}
  def parse(%NaiveDateTime{} = ndt), do: {:ok, %DayEx{datetime: ndt}}
  def parse(%Date{} = date), do: {:ok, %DayEx{datetime: NaiveDateTime.new!(date, ~T[00:00:00])}}
  def parse(fields) when is_map(fields), do: parse_map(fields)
  def parse(fields) when is_list(fields), do: parse_list(fields)

  def parse(ts) when is_integer(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> {:ok, %DayEx{datetime: dt}}
      {:error, reason} -> {:error, "invalid unix timestamp: #{inspect(reason)}"}
    end
  end

  def parse(ts) when is_float(ts) do
    microseconds = round(ts * 1_000_000)

    case DateTime.from_unix(microseconds, :microsecond) do
      {:ok, dt} -> {:ok, %DayEx{datetime: dt}}
      {:error, reason} -> {:error, "invalid unix timestamp: #{inspect(reason)}"}
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

  def parse(input, format) when is_binary(input) and is_binary(format) do
    DayEx.Parse.parse(input, format)
  end

  def parse(input, format, locale)
      when is_binary(input) and is_binary(format) and is_atom(locale) do
    DayEx.Parse.parse(input, format, locale)
  end

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

  def parse!(input, format) when is_binary(input) and is_binary(format) do
    case parse(input, format) do
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

  def month(%DayEx{datetime: dt} = d, value),
    do: %{d | datetime: update_datetime(dt, month: value)}

  def date(%DayEx{datetime: dt} = d, value), do: %{d | datetime: update_datetime(dt, day: value)}
  def hour(%DayEx{datetime: dt} = d, value), do: %{d | datetime: update_datetime(dt, hour: value)}

  def minute(%DayEx{datetime: dt} = d, value),
    do: %{d | datetime: update_datetime(dt, minute: value)}

  def second(%DayEx{datetime: dt} = d, value),
    do: %{d | datetime: update_datetime(dt, second: value)}

  def millisecond(%DayEx{datetime: dt} = d, value),
    do: %{d | datetime: update_datetime(dt, microsecond: {value * 1000, 3})}

  def set(%DayEx{} = d, unit, value), do: do_set(d, normalize_unit(unit), value)

  def add(%DayEx{} = d, n, unit), do: do_add(d, n, normalize_unit(unit))

  defp do_add(%DayEx{} = d, n, :year) do
    new_year = year(d) + n
    max_day = Calendar.ISO.days_in_month(new_year, month(d))
    clamped_day = min(date(d), max_day)
    %{d | datetime: update_datetime(d.datetime, year: new_year, day: clamped_day)}
  end

  defp do_add(%DayEx{} = d, n, :quarter), do: do_add(d, n * 3, :month)

  defp do_add(%DayEx{} = d, n, :month) do
    total_months = (year(d) - 1) * 12 + (month(d) - 1) + n
    new_year = div(total_months, 12) + 1
    new_month = rem(total_months, 12) + 1
    max_day = Calendar.ISO.days_in_month(new_year, new_month)
    clamped_day = min(date(d), max_day)

    %{
      d
      | datetime: update_datetime(d.datetime, year: new_year, month: new_month, day: clamped_day)
    }
  end

  defp do_add(%DayEx{} = d, n, :week), do: do_add(d, n * 7, :day)
  defp do_add(%DayEx{} = d, n, :date), do: do_add(d, n, :day)

  defp do_add(%DayEx{datetime: %DateTime{} = dt} = d, n, :day) do
    %{d | datetime: shift_datetime_date(dt, n)}
  end

  defp do_add(%DayEx{datetime: %DateTime{} = dt} = d, n, unit)
       when unit in [:hour, :minute, :second, :millisecond] do
    new_dt =
      case unit do
        :millisecond -> DateTime.add(dt, n, :millisecond)
        :second -> DateTime.add(dt, n, :second)
        :minute -> DateTime.add(dt, n * 60, :second)
        :hour -> DateTime.add(dt, n * 3_600, :second)
      end

    %{d | datetime: new_dt}
  end

  defp do_add(%DayEx{datetime: %NaiveDateTime{} = ndt} = d, n, unit)
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

  def start_of(%DayEx{} = d, unit), do: do_start_of(d, normalize_unit(unit))

  defp do_start_of(%DayEx{} = d, :year),
    do: %{
      d
      | datetime:
          update_datetime(d.datetime,
            month: 1,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0,
            microsecond: {0, 0}
          )
    }

  defp do_start_of(%DayEx{} = d, :quarter) do
    quarter_start_month = (quarter(d) - 1) * 3 + 1

    d
    |> month(quarter_start_month)
    |> date(1)
    |> do_start_of(:day)
  end

  defp do_start_of(%DayEx{} = d, :month),
    do: %{
      d
      | datetime:
          update_datetime(d.datetime, day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0})
    }

  defp do_start_of(%DayEx{} = d, :week) do
    days_since_sunday = day(d)
    d |> subtract(days_since_sunday, :day) |> start_of(:day)
  end

  defp do_start_of(%DayEx{} = d, :date), do: do_start_of(d, :day)

  defp do_start_of(%DayEx{} = d, :day),
    do: %{
      d
      | datetime: update_datetime(d.datetime, hour: 0, minute: 0, second: 0, microsecond: {0, 0})
    }

  defp do_start_of(%DayEx{} = d, :hour),
    do: %{d | datetime: update_datetime(d.datetime, minute: 0, second: 0, microsecond: {0, 0})}

  defp do_start_of(%DayEx{} = d, :minute),
    do: %{d | datetime: update_datetime(d.datetime, second: 0, microsecond: {0, 0})}

  defp do_start_of(%DayEx{} = d, :second),
    do: %{d | datetime: update_datetime(d.datetime, microsecond: {0, 0})}

  def end_of(%DayEx{} = d, unit), do: do_end_of(d, normalize_unit(unit))

  defp do_end_of(%DayEx{} = d, :year),
    do: %{
      d
      | datetime:
          update_datetime(d.datetime,
            month: 12,
            day: 31,
            hour: 23,
            minute: 59,
            second: 59,
            microsecond: {999_000, 3}
          )
    }

  defp do_end_of(%DayEx{} = d, :quarter) do
    d
    |> do_start_of(:quarter)
    |> do_add(3, :month)
    |> do_add(-1, :millisecond)
  end

  defp do_end_of(%DayEx{} = d, :month) do
    max_day = Calendar.ISO.days_in_month(year(d), month(d))

    %{
      d
      | datetime:
          update_datetime(d.datetime,
            day: max_day,
            hour: 23,
            minute: 59,
            second: 59,
            microsecond: {999_000, 3}
          )
    }
  end

  defp do_end_of(%DayEx{} = d, :week) do
    days_until_saturday = 6 - day(d)
    d |> add(days_until_saturday, :day) |> end_of(:day)
  end

  defp do_end_of(%DayEx{} = d, :date), do: do_end_of(d, :day)

  defp do_end_of(%DayEx{} = d, :day),
    do: %{
      d
      | datetime:
          update_datetime(d.datetime, hour: 23, minute: 59, second: 59, microsecond: {999_000, 3})
    }

  defp do_end_of(%DayEx{} = d, :hour),
    do: %{
      d
      | datetime: update_datetime(d.datetime, minute: 59, second: 59, microsecond: {999_000, 3})
    }

  defp do_end_of(%DayEx{} = d, :minute),
    do: %{d | datetime: update_datetime(d.datetime, second: 59, microsecond: {999_000, 3})}

  defp do_end_of(%DayEx{} = d, :second),
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

  def to_iso_string(%DayEx{datetime: %NaiveDateTime{} = ndt}),
    do: NaiveDateTime.to_iso8601(ndt) <> "Z"

  def to_json(%DayEx{} = d), do: to_iso_string(d)

  def to_datetime(%DayEx{datetime: %DateTime{} = dt}), do: dt

  def to_datetime(%DayEx{datetime: %NaiveDateTime{} = ndt}),
    do: DateTime.from_naive!(ndt, "Etc/UTC")

  def to_naive_datetime(%DayEx{datetime: %DateTime{} = dt}), do: DateTime.to_naive(dt)
  def to_naive_datetime(%DayEx{datetime: %NaiveDateTime{} = ndt}), do: ndt

  def to_unix(%DayEx{datetime: %DateTime{} = dt}), do: DateTime.to_unix(dt)

  def to_unix(%DayEx{datetime: %NaiveDateTime{} = ndt}),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  def to_unix_millisecond(%DayEx{} = d), do: to_unix_ms(d)

  def to_list(%DayEx{} = d),
    do: [year(d), month(d), date(d), hour(d), minute(d), second(d), millisecond(d)]

  def to_map(%DayEx{} = d) do
    %{
      year: year(d),
      month: month(d),
      date: date(d),
      hour: hour(d),
      minute: minute(d),
      second: second(d),
      millisecond: millisecond(d)
    }
  end

  def to_date(%DayEx{datetime: %DateTime{} = dt}), do: DateTime.to_date(dt)
  def to_date(%DayEx{datetime: %NaiveDateTime{} = ndt}), do: NaiveDateTime.to_date(ndt)

  # --- Comparison & Query ---

  def before?(%DayEx{} = a, %DayEx{} = b), do: compare(a, b) == :lt

  def before?(%DayEx{} = a, %DayEx{} = b, unit),
    do: compare(start_of(a, unit), start_of(b, unit)) == :lt

  def after?(%DayEx{} = a, %DayEx{} = b), do: compare(a, b) == :gt

  def after?(%DayEx{} = a, %DayEx{} = b, unit),
    do: compare(start_of(a, unit), start_of(b, unit)) == :gt

  def same?(%DayEx{} = a, %DayEx{} = b), do: compare(a, b) == :eq

  def same?(%DayEx{} = a, %DayEx{} = b, unit),
    do: compare(start_of(a, unit), start_of(b, unit)) == :eq

  def same_or_before?(%DayEx{} = a, %DayEx{} = b), do: compare(a, b) in [:lt, :eq]

  def same_or_before?(%DayEx{} = a, %DayEx{} = b, unit),
    do: compare(start_of(a, unit), start_of(b, unit)) in [:lt, :eq]

  def same_or_after?(%DayEx{} = a, %DayEx{} = b), do: compare(a, b) in [:gt, :eq]

  def same_or_after?(%DayEx{} = a, %DayEx{} = b, unit),
    do: compare(start_of(a, unit), start_of(b, unit)) in [:gt, :eq]

  def between?(%DayEx{} = d, %DayEx{} = a, %DayEx{} = b), do: between?(d, a, b, nil, "()")
  def between?(%DayEx{} = d, %DayEx{} = a, %DayEx{} = b, unit), do: between?(d, a, b, unit, "()")

  def between?(%DayEx{} = d, %DayEx{} = a, %DayEx{} = b, unit, inclusivity) do
    {left_inc, right_inc} =
      case inclusivity do
        "()" -> {false, false}
        "[]" -> {true, true}
        "[)" -> {true, false}
        "(]" -> {false, true}
      end

    left_ok =
      if unit,
        do: if(left_inc, do: same_or_after?(d, a, unit), else: after?(d, a, unit)),
        else: if(left_inc, do: same_or_after?(d, a), else: after?(d, a))

    right_ok =
      if unit,
        do: if(right_inc, do: same_or_before?(d, b, unit), else: before?(d, b, unit)),
        else: if(right_inc, do: same_or_before?(d, b), else: before?(d, b))

    left_ok and right_ok
  end

  def diff(%DayEx{} = a, %DayEx{} = b), do: to_unix_ms(a) - to_unix_ms(b)

  def diff(%DayEx{} = a, %DayEx{} = b, unit) do
    case normalize_unit(unit) do
      :year -> trunc(calendar_month_diff(a, b) / 12)
      :quarter -> trunc(calendar_month_diff(a, b) / 3)
      :month -> calendar_month_diff(a, b)
      unit when unit in [:week, :day, :date] -> trunc(calendar_day_ms(a, b) / unit_to_ms(unit))
      unit -> trunc(diff(a, b) / unit_to_ms(unit))
    end
  end

  def diff(%DayEx{} = a, %DayEx{} = b, unit, opts) do
    if Keyword.get(opts, :float, false),
      do: diff_float(a, b, normalize_unit(unit)),
      else: diff(a, b, unit)
  end

  def leap_year?(%DayEx{} = d), do: Calendar.ISO.leap_year?(year(d))
  def utc?(%DayEx{datetime: %DateTime{time_zone: "Etc/UTC"}}), do: true
  def utc?(%DayEx{}), do: false

  # --- Timezone ---

  def tz(input, timezone) when is_binary(input) and is_binary(timezone) do
    {:ok, d} = parse(input)

    case d.datetime do
      %NaiveDateTime{} = ndt ->
        case DateTime.from_naive(ndt, timezone) do
          {:ok, dt} -> %{d | datetime: dt}
          {:ambiguous, first, _} -> %{d | datetime: first}
          {:gap, _, just_after} -> %{d | datetime: just_after}
        end

      %DateTime{} = dt ->
        {:ok, shifted} = DateTime.shift_zone(dt, timezone)
        %{d | datetime: shifted}
    end
  end

  def tz(%DayEx{datetime: %DateTime{} = dt} = d, timezone) when is_binary(timezone) do
    {:ok, shifted} = DateTime.shift_zone(dt, timezone)
    %{d | datetime: shifted}
  end

  def tz(%DayEx{datetime: %NaiveDateTime{} = ndt} = d, timezone) when is_binary(timezone) do
    dt = DateTime.from_naive!(ndt, "Etc/UTC")
    {:ok, shifted} = DateTime.shift_zone(dt, timezone)
    %{d | datetime: shifted}
  end

  def tz_name(%DayEx{datetime: %DateTime{time_zone: tz}}), do: tz
  def tz_name(%DayEx{datetime: %NaiveDateTime{}}), do: nil

  def local(%DayEx{datetime: %DateTime{} = dt} = d), do: %{d | datetime: DateTime.to_naive(dt)}
  def local(%DayEx{datetime: %NaiveDateTime{}} = d), do: d

  def utc_offset(%DayEx{datetime: %DateTime{utc_offset: offset, std_offset: std}}),
    do: div(offset + std, 60)

  def utc_offset(%DayEx{datetime: %NaiveDateTime{}}), do: nil

  # --- Relative Time entry points ---

  def from_now(%DayEx{} = d), do: DayEx.RelativeTime.from(d, now())

  def from_now(%DayEx{} = d, without_suffix),
    do: DayEx.RelativeTime.from(d, now(), without_suffix)

  def from(%DayEx{} = d, %DayEx{} = ref), do: DayEx.RelativeTime.from(d, ref)

  def from(%DayEx{} = d, %DayEx{} = ref, without_suffix),
    do: DayEx.RelativeTime.from(d, ref, without_suffix)

  def to_now(%DayEx{} = d), do: DayEx.RelativeTime.to(d, now())
  def to_now(%DayEx{} = d, without_suffix), do: DayEx.RelativeTime.to(d, now(), without_suffix)
  def to(%DayEx{} = d, %DayEx{} = target), do: DayEx.RelativeTime.to(d, target)

  def to(%DayEx{} = d, %DayEx{} = target, without_suffix),
    do: DayEx.RelativeTime.to(d, target, without_suffix)

  # --- Week / Quarter / Calendar ---

  def week(%DayEx{} = d) do
    doy = day_of_year(d)
    div(doy - 1, 7) + 1
  end

  def week(%DayEx{} = d, n) do
    current = week(d)
    add(d, (n - current) * 7, :day)
  end

  def iso_week(%DayEx{datetime: dt}) do
    date = to_elixir_date(dt)
    {_year, week} = :calendar.iso_week_number({date.year, date.month, date.day})
    week
  end

  def iso_week(%DayEx{} = d, n) do
    current = iso_week(d)
    add(d, (n - current) * 7, :day)
  end

  def week_year(%DayEx{} = d), do: year(d)

  def iso_week_year(%DayEx{datetime: dt}) do
    date = to_elixir_date(dt)
    {year, _week} = :calendar.iso_week_number({date.year, date.month, date.day})
    year
  end

  def day_of_year(%DayEx{datetime: dt}), do: Date.day_of_year(to_elixir_date(dt))

  def day_of_year(%DayEx{} = d, n) do
    current = day_of_year(d)
    add(d, n - current, :day)
  end

  def quarter(%DayEx{} = d), do: div(month(d) - 1, 3) + 1

  def quarter(%DayEx{} = d, q) do
    current_q = quarter(d)
    month_offset = (q - current_q) * 3
    add(d, month_offset, :month)
  end

  def weekday(%DayEx{} = d) do
    locale_mod = DayEx.Locale.get(d.locale)
    ws = locale_mod.week_start()
    rem(day(d) - ws + 7, 7)
  end

  def weekday(%DayEx{} = d, n) do
    current = weekday(d)
    add(d, n - current, :day)
  end

  def weeks_in_year(%DayEx{} = d) do
    dec28 = Date.new!(year(d), 12, 28)
    {_year, week} = :calendar.iso_week_number({dec28.year, dec28.month, dec28.day})
    week
  end

  # --- Min / Max ---

  def min(list) when is_list(list), do: Enum.min_by(list, &to_unix_ms/1)
  def max(list) when is_list(list), do: Enum.max_by(list, &to_unix_ms/1)

  # --- Locale ---

  def locale(%DayEx{} = d, loc) when is_atom(loc), do: %{d | locale: loc}

  defp to_elixir_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_elixir_date(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt)

  # Private helpers
  defp parse_map(fields) do
    locale = map_get(fields, :locale, :en)
    timezone = map_get(fields, :time_zone, nil) || map_get(fields, :timezone, nil)

    with {:ok, ndt} <- build_naive_datetime(fields) do
      if is_binary(timezone) do
        case DateTime.from_naive(ndt, timezone) do
          {:ok, dt} -> {:ok, %DayEx{datetime: dt, locale: locale}}
          {:ambiguous, first, _second} -> {:ok, %DayEx{datetime: first, locale: locale}}
          {:gap, _before, after_gap} -> {:ok, %DayEx{datetime: after_gap, locale: locale}}
          {:error, reason} -> {:error, "invalid timezone: #{inspect(reason)}"}
        end
      else
        {:ok, %DayEx{datetime: ndt, locale: locale}}
      end
    end
  end

  defp parse_list(fields) when length(fields) in 2..7 do
    keys = [:year, :month, :date, :hour, :minute, :second, :millisecond]

    fields
    |> Enum.zip(keys)
    |> Map.new(fn {value, key} -> {key, value} end)
    |> parse_map()
  end

  defp parse_list(_fields), do: {:error, "expected list constructor with 2 to 7 values"}

  defp build_naive_datetime(fields) do
    year = map_get(fields, :year, 2000)
    month = map_get(fields, :month, 1)
    day = map_get(fields, :date, nil) || map_get(fields, :day, 1)
    hour = map_get(fields, :hour, 0)
    minute = map_get(fields, :minute, 0)
    second = map_get(fields, :second, 0)
    millisecond = map_get(fields, :millisecond, 0)

    with true <- Enum.all?([year, month, day, hour, minute, second, millisecond], &is_integer/1),
         {:ok, ndt} <-
           NaiveDateTime.new(year, month, day, hour, minute, second, {millisecond * 1000, 3}) do
      {:ok, ndt}
    else
      false -> {:error, "invalid date/time fields: :invalid_field"}
      {:error, reason} -> {:error, "invalid date/time fields: #{inspect(reason)}"}
    end
  end

  defp map_get(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp do_set(%DayEx{} = d, :year, value), do: year(d, value)
  defp do_set(%DayEx{} = d, :month, value), do: month(d, value)
  defp do_set(%DayEx{} = d, unit, value) when unit in [:date, :day], do: date(d, value)
  defp do_set(%DayEx{} = d, :hour, value), do: hour(d, value)
  defp do_set(%DayEx{} = d, :minute, value), do: minute(d, value)
  defp do_set(%DayEx{} = d, :second, value), do: second(d, value)
  defp do_set(%DayEx{} = d, :millisecond, value), do: millisecond(d, value)

  defp to_unix_ms(%DayEx{datetime: %DateTime{} = dt}), do: DateTime.to_unix(dt, :millisecond)

  defp to_unix_ms(%DayEx{datetime: %NaiveDateTime{} = ndt}),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp unit_to_ms(:millisecond), do: 1
  defp unit_to_ms(:second), do: 1_000
  defp unit_to_ms(:minute), do: 60_000
  defp unit_to_ms(:hour), do: 3_600_000
  defp unit_to_ms(:day), do: 86_400_000
  defp unit_to_ms(:date), do: unit_to_ms(:day)
  defp unit_to_ms(:week), do: 604_800_000
  defp unit_to_ms(:month), do: 2_629_746_000
  defp unit_to_ms(:year), do: 31_556_952_000

  def compare(%DayEx{datetime: dt1}, %DayEx{datetime: dt2}) do
    case {dt1, dt2} do
      {%DateTime{}, %DateTime{}} ->
        DateTime.compare(dt1, dt2)

      {%NaiveDateTime{}, %NaiveDateTime{}} ->
        NaiveDateTime.compare(dt1, dt2)

      {%DateTime{} = a, %NaiveDateTime{} = b} ->
        DateTime.compare(a, DateTime.from_naive!(b, "Etc/UTC"))

      {%NaiveDateTime{} = a, %DateTime{} = b} ->
        DateTime.compare(DateTime.from_naive!(a, "Etc/UTC"), b)
    end
  end

  defp diff_float(a, b, :year), do: calendar_month_diff_float(a, b) / 12
  defp diff_float(a, b, :quarter), do: calendar_month_diff_float(a, b) / 3
  defp diff_float(a, b, :month), do: calendar_month_diff_float(a, b)
  defp diff_float(a, b, :week), do: calendar_day_ms(a, b) / unit_to_ms(:week)
  defp diff_float(a, b, :day), do: calendar_day_ms(a, b) / unit_to_ms(:day)
  defp diff_float(a, b, :date), do: calendar_day_ms(a, b) / unit_to_ms(:day)
  defp diff_float(a, b, unit), do: diff(a, b) / unit_to_ms(unit)

  defp normalize_unit(unit) do
    case Map.fetch(@unit_aliases, unit) do
      {:ok, normalized} -> normalized
      :error -> raise ArgumentError, "unsupported unit: #{inspect(unit)}"
    end
  end

  defp calendar_month_diff(a, b) do
    months = (year(a) - year(b)) * 12 + (month(a) - month(b))

    cond do
      months > 0 and compare(a, add(b, months, :month)) == :lt -> months - 1
      months < 0 and compare(a, add(b, months, :month)) == :gt -> months + 1
      true -> months
    end
  end

  defp calendar_month_diff_float(a, b) do
    whole_months = calendar_month_diff(a, b)
    anchor = add(b, whole_months, :month)

    case compare(a, anchor) do
      :eq ->
        whole_months * 1.0

      comparison ->
        direction = if comparison == :gt, do: 1, else: -1
        next_anchor = add(b, whole_months + direction, :month)
        span = abs(diff(next_anchor, anchor))

        if span == 0 do
          whole_months * 1.0
        else
          whole_months + direction * (abs(diff(a, anchor)) / span)
        end
    end
  end

  defp calendar_day_ms(a, b), do: diff(a, b) + utc_offset_ms(a) - utc_offset_ms(b)

  defp utc_offset_ms(%DayEx{datetime: %DateTime{utc_offset: offset, std_offset: std}}),
    do: (offset + std) * 1_000

  defp utc_offset_ms(%DayEx{datetime: %NaiveDateTime{}}), do: 0

  defp shift_datetime_date(%DateTime{} = dt, days) do
    date = dt |> DateTime.to_date() |> Date.add(days)
    time = DateTime.to_time(dt)
    DateTime.new(date, time, dt.time_zone) |> resolve_datetime()
  end

  defp update_datetime(%DateTime{} = dt, updates) do
    {date_fields, time_fields} = split_date_time_fields(updates)
    date = update_date(dt, date_fields)
    time = update_time(dt, time_fields)
    DateTime.new(date, time, dt.time_zone) |> resolve_datetime()
  end

  defp update_datetime(%NaiveDateTime{} = ndt, updates) do
    {date_fields, time_fields} = split_date_time_fields(updates)
    date = update_date(ndt, date_fields)
    time = update_time(ndt, time_fields)
    NaiveDateTime.new!(date, time)
  end

  defp resolve_datetime({:ok, dt}), do: dt
  defp resolve_datetime({:ambiguous, first, _second}), do: first
  defp resolve_datetime({:gap, _just_before, just_after}), do: just_after

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
