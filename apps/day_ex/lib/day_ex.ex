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

  def compare(%DayEx{datetime: dt1}, %DayEx{datetime: dt2}) do
    case {dt1, dt2} do
      {%DateTime{}, %DateTime{}} -> DateTime.compare(dt1, dt2)
      {%NaiveDateTime{}, %NaiveDateTime{}} -> NaiveDateTime.compare(dt1, dt2)
      {%DateTime{} = a, %NaiveDateTime{} = b} -> NaiveDateTime.compare(DateTime.to_naive(a), b)
      {%NaiveDateTime{} = a, %DateTime{} = b} -> NaiveDateTime.compare(a, DateTime.to_naive(b))
    end
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
