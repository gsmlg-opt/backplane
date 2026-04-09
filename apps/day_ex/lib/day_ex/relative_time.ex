defmodule DayEx.RelativeTime do
  @moduledoc "Relative time formatting for DayEx."

  def from(%DayEx{} = d, %DayEx{} = reference, without_suffix \\ false) do
    diff_ms = DayEx.diff(d, reference)
    abs_ms = abs(diff_ms)
    future? = diff_ms > 0
    locale_mod = DayEx.Locale.get(d.locale)
    rt = locale_mod.relative_time()
    raw = relative_string(abs_ms, rt)
    if without_suffix, do: raw, else: if(future?, do: "in #{raw}", else: "#{raw} ago")
  end

  def to(%DayEx{} = d, %DayEx{} = reference, without_suffix \\ false) do
    from(reference, d, without_suffix)
  end

  defp relative_string(abs_ms, rt) do
    seconds = div(abs_ms, 1_000)
    minutes = div(abs_ms, 60_000)
    hours = div(abs_ms, 3_600_000)
    days = div(abs_ms, 86_400_000)
    months = div(abs_ms, 2_629_746_000)

    cond do
      seconds < 45 -> rt.s
      seconds < 90 -> rt.m
      minutes < 45 -> String.replace(rt.mm, "%d", Integer.to_string(minutes))
      minutes < 90 -> rt.h
      hours < 22 -> String.replace(rt.hh, "%d", Integer.to_string(hours))
      hours < 36 -> rt.d
      days < 26 -> String.replace(rt.dd, "%d", Integer.to_string(days))
      days < 46 -> rt[:M]
      months < 11 -> String.replace(rt[:MM], "%d", Integer.to_string(months))
      months < 18 -> rt.y
      true -> String.replace(rt.yy, "%d", Integer.to_string(div(months, 12)))
    end
  end
end
