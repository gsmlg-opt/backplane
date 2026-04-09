defmodule DayEx.Parse do
  @moduledoc """
  Custom format string parser for DayEx.

  Parses date strings using format tokens (the reverse of DayEx.Format).
  Reuses `DayEx.Format.tokenize/1` for tokenizing the format string, then
  walks the input string consuming characters that match each token.
  """

  @doc """
  Parse `input` according to `format` using the default (:en) locale.

  Returns `{:ok, %DayEx{}}` on success, `{:error, reason}` on failure.
  """
  def parse(input, format) when is_binary(input) and is_binary(format) do
    parse(input, format, :en)
  end

  @doc """
  Parse `input` according to `format` with the given `locale`.

  Returns `{:ok, %DayEx{}}` on success, `{:error, reason}` on failure.
  """
  def parse(input, format, locale) when is_binary(input) and is_binary(format) and is_atom(locale) do
    tokens = DayEx.Format.tokenize(format)
    locale_mod = DayEx.Locale.get(locale)

    case consume_tokens(input, tokens, %{}, locale_mod) do
      {:ok, fields, _rest} ->
        build_daytime(fields, locale)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Walk the input string consuming characters matching each token
  defp consume_tokens(rest, [], fields, _locale_mod), do: {:ok, fields, rest}

  defp consume_tokens(input, [{:literal, text} | tokens], fields, locale_mod) do
    len = String.length(text)

    case String.split_at(input, len) do
      {^text, rest} ->
        consume_tokens(rest, tokens, fields, locale_mod)

      {actual, _} ->
        {:error, "expected literal #{inspect(text)}, got #{inspect(actual)}"}
    end
  end

  defp consume_tokens(input, [{:token, token} | tokens], fields, locale_mod) do
    case consume_token(input, token, locale_mod) do
      {:ok, key, value, rest} ->
        consume_tokens(rest, tokens, Map.put(fields, key, value), locale_mod)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # YYYY — 4 digit year
  defp consume_token(input, "YYYY", _locale) do
    case take_digits(input, 4, 4) do
      {:ok, digits, rest} -> {:ok, :year, String.to_integer(digits), rest}
      :error -> {:error, "expected 4-digit year, got: #{inspect(String.slice(input, 0, 4))}"}
    end
  end

  # YY — 2 digit year (add 2000)
  defp consume_token(input, "YY", _locale) do
    case take_digits(input, 2, 2) do
      {:ok, digits, rest} -> {:ok, :year, 2000 + String.to_integer(digits), rest}
      :error -> {:error, "expected 2-digit year"}
    end
  end

  # MMMM — full month name
  defp consume_token(input, "MMMM", locale) do
    months = locale.months_full()
    case match_name_list(input, months) do
      {:ok, index, rest} -> {:ok, :month, index + 1, rest}
      :error -> {:error, "expected full month name, got: #{inspect(String.slice(input, 0, 10))}"}
    end
  end

  # MMM — short month name
  defp consume_token(input, "MMM", locale) do
    months = locale.months_short()
    case match_name_list(input, months) do
      {:ok, index, rest} -> {:ok, :month, index + 1, rest}
      :error -> {:error, "expected short month name, got: #{inspect(String.slice(input, 0, 5))}"}
    end
  end

  # MM — 2 digit month
  defp consume_token(input, "MM", _locale) do
    case take_digits(input, 2, 2) do
      {:ok, digits, rest} -> {:ok, :month, String.to_integer(digits), rest}
      :error -> {:error, "expected 2-digit month"}
    end
  end

  # M — 1-2 digit month
  defp consume_token(input, "M", _locale) do
    case take_digits(input, 1, 2) do
      {:ok, digits, rest} -> {:ok, :month, String.to_integer(digits), rest}
      :error -> {:error, "expected month digits"}
    end
  end

  # DD — 2 digit day
  defp consume_token(input, "DD", _locale) do
    case take_digits(input, 2, 2) do
      {:ok, digits, rest} -> {:ok, :day, String.to_integer(digits), rest}
      :error -> {:error, "expected 2-digit day"}
    end
  end

  # D — 1-2 digit day
  defp consume_token(input, "D", _locale) do
    case take_digits(input, 1, 2) do
      {:ok, digits, rest} -> {:ok, :day, String.to_integer(digits), rest}
      :error -> {:error, "expected day digits"}
    end
  end

  # HH — 2 digit hour (24h)
  defp consume_token(input, "HH", _locale) do
    case take_digits(input, 2, 2) do
      {:ok, digits, rest} -> {:ok, :hour, String.to_integer(digits), rest}
      :error -> {:error, "expected 2-digit hour"}
    end
  end

  # H — 1-2 digit hour (24h)
  defp consume_token(input, "H", _locale) do
    case take_digits(input, 1, 2) do
      {:ok, digits, rest} -> {:ok, :hour, String.to_integer(digits), rest}
      :error -> {:error, "expected hour digits"}
    end
  end

  # hh — 2 digit hour (12h)
  defp consume_token(input, "hh", _locale) do
    case take_digits(input, 2, 2) do
      {:ok, digits, rest} -> {:ok, :hour12, String.to_integer(digits), rest}
      :error -> {:error, "expected 2-digit 12h hour"}
    end
  end

  # h — 1-2 digit hour (12h)
  defp consume_token(input, "h", _locale) do
    case take_digits(input, 1, 2) do
      {:ok, digits, rest} -> {:ok, :hour12, String.to_integer(digits), rest}
      :error -> {:error, "expected 12h hour digits"}
    end
  end

  # mm — 2 digit minute
  defp consume_token(input, "mm", _locale) do
    case take_digits(input, 2, 2) do
      {:ok, digits, rest} -> {:ok, :minute, String.to_integer(digits), rest}
      :error -> {:error, "expected 2-digit minute"}
    end
  end

  # m — 1-2 digit minute
  defp consume_token(input, "m", _locale) do
    case take_digits(input, 1, 2) do
      {:ok, digits, rest} -> {:ok, :minute, String.to_integer(digits), rest}
      :error -> {:error, "expected minute digits"}
    end
  end

  # ss — 2 digit second
  defp consume_token(input, "ss", _locale) do
    case take_digits(input, 2, 2) do
      {:ok, digits, rest} -> {:ok, :second, String.to_integer(digits), rest}
      :error -> {:error, "expected 2-digit second"}
    end
  end

  # s — 1-2 digit second
  defp consume_token(input, "s", _locale) do
    case take_digits(input, 1, 2) do
      {:ok, digits, rest} -> {:ok, :second, String.to_integer(digits), rest}
      :error -> {:error, "expected second digits"}
    end
  end

  # SSS — 3 digit millisecond
  defp consume_token(input, "SSS", _locale) do
    case take_digits(input, 3, 3) do
      {:ok, digits, rest} -> {:ok, :millisecond, String.to_integer(digits), rest}
      :error -> {:error, "expected 3-digit millisecond"}
    end
  end

  # A — uppercase AM/PM
  defp consume_token(input, "A", locale) do
    {am, pm} = locale.meridiem_upper()
    cond do
      String.starts_with?(input, pm) ->
        {:ok, :meridiem, :pm, String.slice(input, String.length(pm)..-1//1)}
      String.starts_with?(input, am) ->
        {:ok, :meridiem, :am, String.slice(input, String.length(am)..-1//1)}
      true ->
        {:error, "expected AM or PM, got: #{inspect(String.slice(input, 0, 2))}"}
    end
  end

  # a — lowercase am/pm
  defp consume_token(input, "a", locale) do
    {am, pm} = locale.meridiem_lower()
    cond do
      String.starts_with?(input, pm) ->
        {:ok, :meridiem, :pm, String.slice(input, String.length(pm)..-1//1)}
      String.starts_with?(input, am) ->
        {:ok, :meridiem, :am, String.slice(input, String.length(am)..-1//1)}
      true ->
        {:error, "expected am or pm, got: #{inspect(String.slice(input, 0, 2))}"}
    end
  end

  # Unhandled tokens — skip (consume nothing, just ignore)
  defp consume_token(input, _token, _locale) do
    {:ok, :ignored, nil, input}
  end

  # Build the NaiveDateTime from parsed fields
  defp build_daytime(fields, locale) do
    year = Map.get(fields, :year, 2000)
    month = Map.get(fields, :month, 1)
    day = Map.get(fields, :day, 1)
    minute = Map.get(fields, :minute, 0)
    second = Map.get(fields, :second, 0)
    ms = Map.get(fields, :millisecond, 0)

    # Resolve hour: prefer explicit 24h, otherwise compute from 12h + meridiem
    hour =
      cond do
        Map.has_key?(fields, :hour) ->
          Map.get(fields, :hour)

        Map.has_key?(fields, :hour12) ->
          h12 = Map.get(fields, :hour12)
          meridiem = Map.get(fields, :meridiem, :am)
          convert_12h_to_24h(h12, meridiem)

        true ->
          0
      end

    case NaiveDateTime.new(year, month, day, hour, minute, second, {ms * 1000, 3}) do
      {:ok, ndt} ->
        {:ok, %DayEx{datetime: ndt, locale: locale}}

      {:error, reason} ->
        {:error, "invalid date/time fields: #{inspect(reason)}"}
    end
  end

  defp convert_12h_to_24h(12, :am), do: 0
  defp convert_12h_to_24h(h, :am), do: h
  defp convert_12h_to_24h(12, :pm), do: 12
  defp convert_12h_to_24h(h, :pm), do: h + 12

  # Take between min_digits and max_digits consecutive ASCII digits from the front of `str`.
  # Returns `{:ok, digits_string, rest}` or `:error`.
  defp take_digits(str, min_digits, max_digits) do
    {digits, rest} = take_while_digit(str, max_digits, "")
    if String.length(digits) >= min_digits do
      {:ok, digits, rest}
    else
      :error
    end
  end

  defp take_while_digit(str, 0, acc), do: {acc, str}
  defp take_while_digit("", _n, acc), do: {acc, ""}

  defp take_while_digit(str, n, acc) do
    {char, rest} = String.split_at(str, 1)
    if char >= "0" and char <= "9" do
      take_while_digit(rest, n - 1, acc <> char)
    else
      {acc, str}
    end
  end

  # Try to match the input against a list of names (case-insensitive prefix match).
  # Returns `{:ok, 0-based-index, rest}` or `:error`.
  defp match_name_list(input, names) do
    input_lower = String.downcase(input)

    result =
      names
      |> Enum.with_index()
      |> Enum.find(fn {name, _idx} ->
        String.starts_with?(input_lower, String.downcase(name))
      end)

    case result do
      {name, idx} ->
        rest = String.slice(input, String.length(name)..-1//1)
        {:ok, idx, rest}

      nil ->
        :error
    end
  end
end
