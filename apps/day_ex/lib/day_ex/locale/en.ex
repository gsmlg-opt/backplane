defmodule DayEx.Locale.En do
  @moduledoc "English locale for DayEx."
  @behaviour DayEx.Locale

  @impl true
  def months_full,
    do: ~w(January February March April May June July August September October November December)

  @impl true
  def months_short, do: ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @impl true
  def weekdays_full, do: ~w(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)

  @impl true
  def weekdays_short, do: ~w(Sun Mon Tue Wed Thu Fri Sat)

  @impl true
  def weekdays_min, do: ~w(Su Mo Tu We Th Fr Sa)

  @impl true
  def relative_time do
    %{
      s: "a few seconds",
      m: "a minute",
      mm: "%d minutes",
      h: "an hour",
      hh: "%d hours",
      d: "a day",
      dd: "%d days",
      M: "a month",
      MM: "%d months",
      y: "a year",
      yy: "%d years"
    }
  end

  @impl true
  def ordinal(n) do
    suffix =
      cond do
        rem(div(n, 10), 10) == 1 -> "th"
        rem(n, 10) == 1 -> "st"
        rem(n, 10) == 2 -> "nd"
        rem(n, 10) == 3 -> "rd"
        true -> "th"
      end

    "#{n}#{suffix}"
  end

  @impl true
  def week_start, do: 0

  @impl true
  def meridiem_upper, do: {"AM", "PM"}

  @impl true
  def meridiem_lower, do: {"am", "pm"}
end
