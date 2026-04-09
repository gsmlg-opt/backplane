defmodule DayEx.Format do
  @moduledoc """
  Recursive descent tokenizer and renderer for DayEx format strings.

  Parses format strings left-to-right, greedily matching the longest token first.
  Handles `[escaped]` text in square brackets as literals.
  """

  # Tokens ordered for greedy matching — longest first within same prefix
  @tokens ~w(
    YYYY YY
    MMMM MMM MM M
    DDDD DD Do D
    dddd ddd dd d
    HH H hh h
    mm m
    ss s
    SSS
    A a
    ZZ Z
    X x
    Q
    kk k
    GGGG GG
    WW W
    ww wo w
  )

  @doc """
  Tokenize a format string into a list of `{:token, string}` or `{:literal, string}` tuples.
  Adjacent literal characters are kept as individual literals (not merged).
  Escaped text in `[...]` is emitted as individual `{:literal, content}` per character? No —
  the spec says merge adjacent literal chars. Looking at test: `[Year:] YYYY` → `[{:literal, "Year:"}, {:literal, " "}, ...]`.
  So the escaped block becomes one literal, and each non-token char outside brackets becomes its own literal.
  """
  def tokenize(str), do: do_tokenize(str, [])

  defp do_tokenize("", acc), do: Enum.reverse(acc)

  defp do_tokenize("[" <> rest, acc) do
    case String.split(rest, "]", parts: 2) do
      [escaped, remainder] ->
        do_tokenize(remainder, [{:literal, escaped} | acc])

      [_no_close] ->
        # No closing bracket — treat [ as literal
        do_tokenize(rest, [{:literal, "["} | acc])
    end
  end

  defp do_tokenize(str, acc) do
    case match_token(str) do
      {token, rest} ->
        do_tokenize(rest, [{:token, token} | acc])

      nil ->
        # Consume one character as literal
        {char, rest} = String.split_at(str, 1)
        do_tokenize(rest, [{:literal, char} | acc])
    end
  end

  defp match_token(str) do
    Enum.find_value(@tokens, fn token ->
      if String.starts_with?(str, token) do
        {token, String.slice(str, String.length(token)..-1//1)}
      end
    end)
  end

  @doc """
  Format a `%DayEx{}` struct using the given format string.
  """
  def format(%DayEx{} = d, template) do
    tokens = tokenize(template)
    locale_mod = DayEx.Locale.get(d.locale)

    tokens
    |> Enum.map(fn
      {:literal, text} -> text
      {:token, token} -> render_token(d, token, locale_mod)
    end)
    |> Enum.join()
  end

  defp render_token(d, "YYYY", _locale), do: String.pad_leading(to_string(DayEx.year(d)), 4, "0")
  defp render_token(d, "YY", _locale) do
    year = DayEx.year(d)
    two = rem(year, 100)
    String.pad_leading(to_string(two), 2, "0")
  end

  defp render_token(d, "MMMM", locale), do: Enum.at(locale.months_full(), DayEx.month(d) - 1)
  defp render_token(d, "MMM", locale), do: Enum.at(locale.months_short(), DayEx.month(d) - 1)
  defp render_token(d, "MM", _locale), do: String.pad_leading(to_string(DayEx.month(d)), 2, "0")
  defp render_token(d, "M", _locale), do: to_string(DayEx.month(d))

  defp render_token(d, "DDDD", _locale) do
    date = to_date_struct(d)
    doy = Date.day_of_year(date)
    String.pad_leading(to_string(doy), 3, "0")
  end

  defp render_token(d, "DD", _locale), do: String.pad_leading(to_string(DayEx.date(d)), 2, "0")
  defp render_token(d, "Do", locale), do: locale.ordinal(DayEx.date(d))
  defp render_token(d, "D", _locale), do: to_string(DayEx.date(d))

  defp render_token(d, "dddd", locale) do
    dow = DayEx.day(d)
    Enum.at(locale.weekdays_full(), dow)
  end

  defp render_token(d, "ddd", locale) do
    dow = DayEx.day(d)
    Enum.at(locale.weekdays_short(), dow)
  end

  defp render_token(d, "dd", locale) do
    dow = DayEx.day(d)
    Enum.at(locale.weekdays_min(), dow)
  end

  defp render_token(d, "d", _locale), do: to_string(DayEx.day(d))

  defp render_token(d, "HH", _locale), do: String.pad_leading(to_string(DayEx.hour(d)), 2, "0")
  defp render_token(d, "H", _locale), do: to_string(DayEx.hour(d))

  defp render_token(d, "hh", _locale) do
    h = hour_12(DayEx.hour(d))
    String.pad_leading(to_string(h), 2, "0")
  end

  defp render_token(d, "h", _locale), do: to_string(hour_12(DayEx.hour(d)))

  defp render_token(d, "kk", _locale) do
    h = hour_1_24(DayEx.hour(d))
    String.pad_leading(to_string(h), 2, "0")
  end

  defp render_token(d, "k", _locale), do: to_string(hour_1_24(DayEx.hour(d)))

  defp render_token(d, "mm", _locale), do: String.pad_leading(to_string(DayEx.minute(d)), 2, "0")
  defp render_token(d, "m", _locale), do: to_string(DayEx.minute(d))

  defp render_token(d, "ss", _locale), do: String.pad_leading(to_string(DayEx.second(d)), 2, "0")
  defp render_token(d, "s", _locale), do: to_string(DayEx.second(d))

  defp render_token(d, "SSS", _locale) do
    ms = DayEx.millisecond(d)
    String.pad_leading(to_string(ms), 3, "0")
  end

  defp render_token(d, "A", locale) do
    {am, pm} = locale.meridiem_upper()
    if DayEx.hour(d) < 12, do: am, else: pm
  end

  defp render_token(d, "a", locale) do
    {am, pm} = locale.meridiem_lower()
    if DayEx.hour(d) < 12, do: am, else: pm
  end

  defp render_token(%DayEx{datetime: %DateTime{} = dt}, "Z", _locale) do
    offset_seconds = dt.utc_offset + dt.std_offset
    format_offset_colon(offset_seconds)
  end

  defp render_token(%DayEx{datetime: %NaiveDateTime{}}, "Z", _locale), do: "+00:00"

  defp render_token(%DayEx{datetime: %DateTime{} = dt}, "ZZ", _locale) do
    offset_seconds = dt.utc_offset + dt.std_offset
    format_offset_compact(offset_seconds)
  end

  defp render_token(%DayEx{datetime: %NaiveDateTime{}}, "ZZ", _locale), do: "+0000"

  defp render_token(%DayEx{datetime: %DateTime{} = dt}, "X", _locale) do
    to_string(DateTime.to_unix(dt))
  end

  defp render_token(%DayEx{datetime: %NaiveDateTime{} = ndt}, "X", _locale) do
    dt = DateTime.from_naive!(ndt, "Etc/UTC")
    to_string(DateTime.to_unix(dt))
  end

  defp render_token(%DayEx{datetime: %DateTime{} = dt}, "x", _locale) do
    unix_ms = DateTime.to_unix(dt, :millisecond)
    to_string(unix_ms)
  end

  defp render_token(%DayEx{datetime: %NaiveDateTime{} = ndt}, "x", _locale) do
    dt = DateTime.from_naive!(ndt, "Etc/UTC")
    unix_ms = DateTime.to_unix(dt, :millisecond)
    to_string(unix_ms)
  end

  defp render_token(d, "Q", _locale) do
    quarter = ceil(DayEx.month(d) / 3)
    to_string(quarter)
  end

  defp render_token(d, "GGGG", _locale) do
    {iso_year, _week} = iso_week_number(d)
    to_string(iso_year)
  end

  defp render_token(d, "GG", _locale) do
    {iso_year, _week} = iso_week_number(d)
    two = rem(iso_year, 100)
    String.pad_leading(to_string(two), 2, "0")
  end

  defp render_token(d, "WW", _locale) do
    {_iso_year, week} = iso_week_number(d)
    String.pad_leading(to_string(week), 2, "0")
  end

  defp render_token(d, "W", _locale) do
    {_iso_year, week} = iso_week_number(d)
    to_string(week)
  end

  defp render_token(d, "ww", locale) do
    week = locale_week(d, locale)
    String.pad_leading(to_string(week), 2, "0")
  end

  defp render_token(d, "wo", locale) do
    week = locale_week(d, locale)
    locale.ordinal(week)
  end

  defp render_token(d, "w", locale) do
    week = locale_week(d, locale)
    to_string(week)
  end

  # --- Helpers ---

  defp hour_12(0), do: 12
  defp hour_12(h) when h <= 12, do: h
  defp hour_12(h), do: h - 12

  defp hour_1_24(0), do: 24
  defp hour_1_24(h), do: h

  defp to_date_struct(%DayEx{datetime: %DateTime{} = dt}), do: DateTime.to_date(dt)
  defp to_date_struct(%DayEx{datetime: %NaiveDateTime{} = ndt}), do: NaiveDateTime.to_date(ndt)

  defp iso_week_number(d) do
    date = to_date_struct(d)
    :calendar.iso_week_number({date.year, date.month, date.day})
  end

  defp locale_week(d, locale) do
    week_start = locale.week_start()
    date = to_date_struct(d)
    # Day of week 0 = Sunday, 6 = Saturday
    jan1 = Date.new!(date.year, 1, 1)
    jan1_dow = day_of_week_0indexed(jan1)
    # Adjust jan1_dow relative to week_start
    offset = rem(jan1_dow - week_start + 7, 7)
    doy = Date.day_of_year(date)
    div(doy + offset - 1, 7) + 1
  end

  defp day_of_week_0indexed(date) do
    case Date.day_of_week(date) do
      7 -> 0
      n -> n
    end
  end

  defp format_offset_colon(seconds) do
    sign = if seconds >= 0, do: "+", else: "-"
    abs_seconds = abs(seconds)
    hours = div(abs_seconds, 3600)
    minutes = div(rem(abs_seconds, 3600), 60)
    "#{sign}#{String.pad_leading(to_string(hours), 2, "0")}:#{String.pad_leading(to_string(minutes), 2, "0")}"
  end

  defp format_offset_compact(seconds) do
    sign = if seconds >= 0, do: "+", else: "-"
    abs_seconds = abs(seconds)
    hours = div(abs_seconds, 3600)
    minutes = div(rem(abs_seconds, 3600), 60)
    "#{sign}#{String.pad_leading(to_string(hours), 2, "0")}#{String.pad_leading(to_string(minutes), 2, "0")}"
  end
end
