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
