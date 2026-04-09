defmodule DayEx.Locale.Fr do
  @moduledoc "French locale for DayEx."
  @behaviour DayEx.Locale

  @impl true
  def months_full,
    do:
      ~w(janvier février mars avril mai juin juillet août septembre octobre novembre décembre)

  @impl true
  def months_short,
    do: ~w(janv. févr. mars avr. mai juin juil. août sept. oct. nov. déc.)

  @impl true
  def weekdays_full, do: ~w(dimanche lundi mardi mercredi jeudi vendredi samedi)

  @impl true
  def weekdays_short, do: ~w(dim. lun. mar. mer. jeu. ven. sam.)

  @impl true
  def weekdays_min, do: ~w(di lu ma me je ve sa)

  @impl true
  def relative_time do
    %{
      s: "quelques secondes",
      m: "une minute",
      mm: "%d minutes",
      h: "une heure",
      hh: "%d heures",
      d: "un jour",
      dd: "%d jours",
      M: "un mois",
      MM: "%d mois",
      y: "un an",
      yy: "%d ans"
    }
  end

  @impl true
  def ordinal(n), do: if(n == 1, do: "#{n}er", else: "#{n}e")

  @impl true
  def week_start, do: 1

  @impl true
  def meridiem_upper, do: {"AM", "PM"}

  @impl true
  def meridiem_lower, do: {"am", "pm"}
end
