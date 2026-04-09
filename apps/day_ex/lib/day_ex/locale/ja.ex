defmodule DayEx.Locale.Ja do
  @moduledoc "Japanese locale for DayEx."
  @behaviour DayEx.Locale

  @impl true
  def months_full, do: ~w(1月 2月 3月 4月 5月 6月 7月 8月 9月 10月 11月 12月)

  @impl true
  def months_short, do: ~w(1月 2月 3月 4月 5月 6月 7月 8月 9月 10月 11月 12月)

  @impl true
  def weekdays_full, do: ~w(日曜日 月曜日 火曜日 水曜日 木曜日 金曜日 土曜日)

  @impl true
  def weekdays_short, do: ~w(日 月 火 水 木 金 土)

  @impl true
  def weekdays_min, do: ~w(日 月 火 水 木 金 土)

  @impl true
  def relative_time do
    %{
      s: "数秒",
      m: "1分",
      mm: "%d分",
      h: "1時間",
      hh: "%d時間",
      d: "1日",
      dd: "%d日",
      M: "1ヶ月",
      MM: "%dヶ月",
      y: "1年",
      yy: "%d年"
    }
  end

  @impl true
  def ordinal(n), do: "#{n}日"

  @impl true
  def week_start, do: 0

  @impl true
  def meridiem_upper, do: {"午前", "午後"}

  @impl true
  def meridiem_lower, do: {"午前", "午後"}
end
