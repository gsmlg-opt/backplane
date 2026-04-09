defmodule DayEx.Locale.De do
  @moduledoc "German locale for DayEx."
  @behaviour DayEx.Locale

  @impl true
  def months_full,
    do:
      ~w(Januar Februar März April Mai Juni Juli August September Oktober November Dezember)

  @impl true
  def months_short, do: ~w(Jan. Feb. März Apr. Mai Juni Juli Aug. Sep. Okt. Nov. Dez.)

  @impl true
  def weekdays_full, do: ~w(Sonntag Montag Dienstag Mittwoch Donnerstag Freitag Samstag)

  @impl true
  def weekdays_short, do: ~w(So. Mo. Di. Mi. Do. Fr. Sa.)

  @impl true
  def weekdays_min, do: ~w(So Mo Di Mi Do Fr Sa)

  @impl true
  def relative_time do
    %{
      s: "ein paar Sekunden",
      m: "einer Minute",
      mm: "%d Minuten",
      h: "einer Stunde",
      hh: "%d Stunden",
      d: "einem Tag",
      dd: "%d Tagen",
      M: "einem Monat",
      MM: "%d Monaten",
      y: "einem Jahr",
      yy: "%d Jahren"
    }
  end

  @impl true
  def ordinal(n), do: "#{n}."

  @impl true
  def week_start, do: 1

  @impl true
  def meridiem_upper, do: {"AM", "PM"}

  @impl true
  def meridiem_lower, do: {"am", "pm"}
end
