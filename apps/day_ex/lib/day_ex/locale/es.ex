defmodule DayEx.Locale.Es do
  @moduledoc "Spanish locale for DayEx."
  @behaviour DayEx.Locale

  @impl true
  def months_full,
    do:
      ~w(enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre)

  @impl true
  def months_short, do: ~w(ene feb mar abr may jun jul ago sep oct nov dic)

  @impl true
  def weekdays_full, do: ~w(domingo lunes martes miércoles jueves viernes sábado)

  @impl true
  def weekdays_short, do: ~w(dom lun mar mié jue vie sáb)

  @impl true
  def weekdays_min, do: ~w(do lu ma mi ju vi sá)

  @impl true
  def relative_time do
    %{
      s: "unos segundos",
      m: "un minuto",
      mm: "%d minutos",
      h: "una hora",
      hh: "%d horas",
      d: "un día",
      dd: "%d días",
      M: "un mes",
      MM: "%d meses",
      y: "un año",
      yy: "%d años"
    }
  end

  @impl true
  def ordinal(n), do: "#{n}º"

  @impl true
  def week_start, do: 1

  @impl true
  def meridiem_upper, do: {"AM", "PM"}

  @impl true
  def meridiem_lower, do: {"am", "pm"}
end
