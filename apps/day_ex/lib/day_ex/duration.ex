defmodule DayEx.Duration do
  @moduledoc """
  Represents a duration of time with decomposed fields.

  Supports construction from milliseconds, maps, or ISO 8601 duration strings.
  """

  defstruct years: 0, months: 0, days: 0, hours: 0, minutes: 0, seconds: 0, milliseconds: 0

  @type t :: %__MODULE__{
          years: integer(),
          months: integer(),
          days: integer(),
          hours: integer(),
          minutes: integer(),
          seconds: integer(),
          milliseconds: integer()
        }

  @ms_per_second 1_000
  @ms_per_minute 60_000
  @ms_per_hour 3_600_000
  @ms_per_day 86_400_000
  @ms_per_week 604_800_000
  @ms_per_month 2_629_746_000
  @ms_per_year 31_556_952_000

  @doc """
  Create a Duration from milliseconds (integer), a map of fields, or an ISO 8601 duration string.

  From milliseconds: decomposes into hours/minutes/seconds/milliseconds only (no calendar days).
  From map: direct field assignment with defaults of 0.
  From ISO string: parses "P[nY][nM][nD][T[nH][nM][nS]]".
  """
  @spec new(integer() | map() | String.t()) :: t()
  def new(ms) when is_integer(ms) do
    total_ms = abs(ms)
    sign = if ms < 0, do: -1, else: 1

    hours = div(total_ms, @ms_per_hour)
    remaining = rem(total_ms, @ms_per_hour)
    minutes = div(remaining, @ms_per_minute)
    remaining = rem(remaining, @ms_per_minute)
    seconds = div(remaining, @ms_per_second)
    milliseconds = rem(remaining, @ms_per_second)

    %__MODULE__{
      hours: sign * hours,
      minutes: sign * minutes,
      seconds: sign * seconds,
      milliseconds: sign * milliseconds
    }
  end

  def new(map) when is_map(map) do
    %__MODULE__{
      years: Map.get(map, :years, 0),
      months: Map.get(map, :months, 0),
      days: Map.get(map, :days, 0),
      hours: Map.get(map, :hours, 0),
      minutes: Map.get(map, :minutes, 0),
      seconds: Map.get(map, :seconds, 0),
      milliseconds: Map.get(map, :milliseconds, 0)
    }
  end

  def new(str) when is_binary(str) do
    parse_iso8601!(str)
  end

  # --- Getters ---

  @spec years(t()) :: integer()
  def years(%__MODULE__{years: v}), do: v

  @spec months(t()) :: integer()
  def months(%__MODULE__{months: v}), do: v

  @spec days(t()) :: integer()
  def days(%__MODULE__{days: v}), do: v

  @spec hours(t()) :: integer()
  def hours(%__MODULE__{hours: v}), do: v

  @spec minutes(t()) :: integer()
  def minutes(%__MODULE__{minutes: v}), do: v

  @spec seconds(t()) :: integer()
  def seconds(%__MODULE__{seconds: v}), do: v

  @spec milliseconds(t()) :: integer()
  def milliseconds(%__MODULE__{milliseconds: v}), do: v

  # --- Total converters ---

  @doc "Returns total duration in milliseconds."
  @spec as_milliseconds(t()) :: number()
  def as_milliseconds(%__MODULE__{} = d) do
    d.years * @ms_per_year +
      d.months * @ms_per_month +
      d.days * @ms_per_day +
      d.hours * @ms_per_hour +
      d.minutes * @ms_per_minute +
      d.seconds * @ms_per_second +
      d.milliseconds
  end

  @doc "Returns total duration in seconds."
  @spec as_seconds(t()) :: float()
  def as_seconds(%__MODULE__{} = d), do: as_milliseconds(d) / @ms_per_second

  @doc "Returns total duration in minutes."
  @spec as_minutes(t()) :: float()
  def as_minutes(%__MODULE__{} = d), do: as_milliseconds(d) / @ms_per_minute

  @doc "Returns total duration in hours."
  @spec as_hours(t()) :: float()
  def as_hours(%__MODULE__{} = d), do: as_milliseconds(d) / @ms_per_hour

  @doc "Returns total duration in days."
  @spec as_days(t()) :: float()
  def as_days(%__MODULE__{} = d), do: as_milliseconds(d) / @ms_per_day

  @doc "Returns total duration in weeks."
  @spec as_weeks(t()) :: float()
  def as_weeks(%__MODULE__{} = d), do: as_milliseconds(d) / @ms_per_week

  @doc "Returns total duration in months."
  @spec as_months(t()) :: float()
  def as_months(%__MODULE__{} = d), do: as_milliseconds(d) / @ms_per_month

  @doc "Returns total duration in years."
  @spec as_years(t()) :: float()
  def as_years(%__MODULE__{} = d), do: as_milliseconds(d) / @ms_per_year

  # --- Humanize ---

  @doc """
  Returns a human-readable string for the duration.

  When `with_suffix` is true, prefixes positive durations with "in ".
  """
  @spec humanize(t(), boolean()) :: String.t()
  def humanize(%__MODULE__{} = d, with_suffix \\ false) do
    ms = as_milliseconds(d)
    abs_ms = abs(ms)
    future? = ms > 0

    raw = humanize_abs(abs_ms)

    if with_suffix do
      if future?, do: "in #{raw}", else: "#{raw} ago"
    else
      raw
    end
  end

  defp humanize_abs(abs_ms) do
    seconds = div(abs_ms, @ms_per_second)
    minutes = div(abs_ms, @ms_per_minute)
    hours = div(abs_ms, @ms_per_hour)
    days = div(abs_ms, @ms_per_day)
    months = div(abs_ms, @ms_per_month)

    cond do
      seconds < 45 -> "a few seconds"
      seconds < 90 -> "a minute"
      minutes < 45 -> "#{minutes} minutes"
      minutes < 90 -> "an hour"
      hours < 22 -> "#{hours} hours"
      hours < 36 -> "a day"
      days < 26 -> "#{days} days"
      days < 46 -> "a month"
      months < 11 -> "#{months} months"
      months < 18 -> "a year"
      true -> "#{div(months, 12)} years"
    end
  end

  # --- ISO 8601 ---

  @doc """
  Returns the duration as an ISO 8601 duration string.

  Zero duration returns "P0D".
  """
  @spec to_iso_string(t()) :: String.t()
  def to_iso_string(%__MODULE__{} = d) do
    date_part =
      [
        if(d.years != 0, do: "#{d.years}Y", else: ""),
        if(d.months != 0, do: "#{d.months}M", else: ""),
        if(d.days != 0, do: "#{d.days}D", else: "")
      ]
      |> Enum.join()

    time_part =
      [
        if(d.hours != 0, do: "#{d.hours}H", else: ""),
        if(d.minutes != 0, do: "#{d.minutes}M", else: ""),
        if(d.seconds != 0, do: "#{d.seconds}S", else: ""),
        if(d.milliseconds != 0, do: "#{d.milliseconds / 1000}S", else: "")
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join()

    time_section = if time_part != "", do: "T#{time_part}", else: ""
    body = date_part <> time_section

    if body == "", do: "P0D", else: "P#{body}"
  end

  # --- Arithmetic ---

  @doc "Adds two durations field-wise."
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      years: a.years + b.years,
      months: a.months + b.months,
      days: a.days + b.days,
      hours: a.hours + b.hours,
      minutes: a.minutes + b.minutes,
      seconds: a.seconds + b.seconds,
      milliseconds: a.milliseconds + b.milliseconds
    }
  end

  @doc "Subtracts two durations field-wise."
  @spec subtract(t(), t()) :: t()
  def subtract(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      years: a.years - b.years,
      months: a.months - b.months,
      days: a.days - b.days,
      hours: a.hours - b.hours,
      minutes: a.minutes - b.minutes,
      seconds: a.seconds - b.seconds,
      milliseconds: a.milliseconds - b.milliseconds
    }
  end

  # --- Private: ISO 8601 parser ---

  defp parse_iso8601!(str) do
    # Pattern: P[nY][nM][nD][T[nH][nM][nS]]
    case Regex.run(
           ~r/^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$/,
           str
         ) do
      nil ->
        raise ArgumentError, "invalid ISO 8601 duration: #{inspect(str)}"

      captures ->
        # captures[0] = full match, rest are groups (may be nil if not matched)
        [_full | groups] = captures

        [years_s, months_s, days_s, hours_s, minutes_s, seconds_s] =
          pad_nils(groups, 6)

        years = parse_int(years_s)
        months = parse_int(months_s)
        days = parse_int(days_s)
        hours = parse_int(hours_s)
        minutes = parse_int(minutes_s)
        {seconds, milliseconds} = parse_seconds(seconds_s)

        %__MODULE__{
          years: years,
          months: months,
          days: days,
          hours: hours,
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds
        }
    end
  end

  defp pad_nils(list, n) do
    len = length(list)
    if len >= n, do: Enum.take(list, n), else: list ++ List.duplicate(nil, n - len)
  end

  defp parse_int(nil), do: 0
  defp parse_int(""), do: 0
  defp parse_int(s), do: String.to_integer(s)

  defp parse_seconds(nil), do: {0, 0}
  defp parse_seconds(""), do: {0, 0}

  defp parse_seconds(s) do
    case String.split(s, ".") do
      [int_part] ->
        {String.to_integer(int_part), 0}

      [int_part, frac_part] ->
        sec = String.to_integer(int_part)
        # Convert fractional seconds to milliseconds (up to 3 digits)
        frac_padded = String.pad_trailing(frac_part, 3, "0") |> String.slice(0, 3)
        ms = String.to_integer(frac_padded)
        {sec, ms}
    end
  end
end
