defmodule DayEx.Locale.Ko do
  @moduledoc "Korean locale for DayEx."
  @behaviour DayEx.Locale

  @impl true
  def months_full, do: ~w(1월 2월 3월 4월 5월 6월 7월 8월 9월 10월 11월 12월)

  @impl true
  def months_short, do: ~w(1월 2월 3월 4월 5월 6월 7월 8월 9월 10월 11월 12월)

  @impl true
  def weekdays_full, do: ~w(일요일 월요일 화요일 수요일 목요일 금요일 토요일)

  @impl true
  def weekdays_short, do: ~w(일 월 화 수 목 금 토)

  @impl true
  def weekdays_min, do: ~w(일 월 화 수 목 금 토)

  @impl true
  def relative_time do
    %{
      s: "몇 초",
      m: "1분",
      mm: "%d분",
      h: "한 시간",
      hh: "%d시간",
      d: "하루",
      dd: "%d일",
      M: "한 달",
      MM: "%d달",
      y: "일 년",
      yy: "%d년"
    }
  end

  @impl true
  def ordinal(n), do: "#{n}일"

  @impl true
  def week_start, do: 0

  @impl true
  def meridiem_upper, do: {"오전", "오후"}

  @impl true
  def meridiem_lower, do: {"오전", "오후"}
end
