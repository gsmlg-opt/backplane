defmodule DayEx.Locale.Zh do
  @moduledoc "Chinese locale for DayEx."
  @behaviour DayEx.Locale

  @impl true
  def months_full, do: ~w(一月 二月 三月 四月 五月 六月 七月 八月 九月 十月 十一月 十二月)

  @impl true
  def months_short, do: ~w(1月 2月 3月 4月 5月 6月 7月 8月 9月 10月 11月 12月)

  @impl true
  def weekdays_full, do: ~w(星期日 星期一 星期二 星期三 星期四 星期五 星期六)

  @impl true
  def weekdays_short, do: ~w(周日 周一 周二 周三 周四 周五 周六)

  @impl true
  def weekdays_min, do: ~w(日 一 二 三 四 五 六)

  @impl true
  def relative_time do
    %{
      s: "几秒",
      m: "1 分钟",
      mm: "%d 分钟",
      h: "1 小时",
      hh: "%d 小时",
      d: "1 天",
      dd: "%d 天",
      M: "1 个月",
      MM: "%d 个月",
      y: "1 年",
      yy: "%d 年"
    }
  end

  @impl true
  def ordinal(n), do: "#{n}日"

  @impl true
  def week_start, do: 1

  @impl true
  def meridiem_upper, do: {"上午", "下午"}

  @impl true
  def meridiem_lower, do: {"上午", "下午"}
end
