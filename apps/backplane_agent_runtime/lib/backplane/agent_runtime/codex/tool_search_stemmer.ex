defmodule Backplane.AgentRuntime.Codex.ToolSearchStemmer do
  @moduledoc false
  # English Snowball algorithm, matching rust-stemmers 1.2.0 (MIT license).
  @exceptions %{
    "skis" => "ski",
    "skies" => "sky",
    "dying" => "die",
    "lying" => "lie",
    "tying" => "tie",
    "idly" => "idl",
    "gently" => "gentl",
    "ugly" => "ugli",
    "early" => "earli",
    "only" => "onli",
    "singly" => "singl",
    "sky" => "sky",
    "news" => "news",
    "howe" => "howe",
    "atlas" => "atlas",
    "cosmos" => "cosmos",
    "bias" => "bias",
    "andes" => "andes"
  }
  @after_1a ~w(inning outing canning herring earring proceed exceed succeed)
  @step2 [
    {"ization", "ize"},
    {"ational", "ate"},
    {"fulness", "ful"},
    {"ousness", "ous"},
    {"iveness", "ive"},
    {"tional", "tion"},
    {"biliti", "ble"},
    {"lessli", "less"},
    {"entli", "ent"},
    {"ation", "ate"},
    {"alism", "al"},
    {"aliti", "al"},
    {"ousli", "ous"},
    {"iviti", "ive"},
    {"fulli", "ful"},
    {"enci", "ence"},
    {"anci", "ance"},
    {"abli", "able"},
    {"izer", "ize"},
    {"ator", "ate"},
    {"alli", "al"},
    {"bli", "ble"},
    {"ogi", "og"},
    {"li", ""}
  ]
  @step3 [
    {"ational", "ate"},
    {"tional", "tion"},
    {"alize", "al"},
    {"icate", "ic"},
    {"iciti", "ic"},
    {"ative", ""},
    {"ical", "ic"},
    {"ness", ""},
    {"ful", ""}
  ]
  @step4 ~w(ement ance ence able ible ment ant ent ism ate iti ous ive ize ion al er ic)

  def stem(word) when byte_size(word) <= 2, do: word

  def stem(word) do
    case Map.fetch(@exceptions, word) do
      {:ok, value} -> value
      :error -> run(word)
    end
  end

  defp run(word) do
    word = word |> String.trim_leading("'") |> mark_y()

    r1 =
      case Enum.find(~w(gener commun arsen), &String.starts_with?(word, &1)) do
        nil -> region(word, 0)
        prefix -> byte_size(prefix)
      end

    r2 = region(word, r1)
    word = replace_suffix(word, ["'s'", "'s", "'"], "") |> step1a()

    if word in @after_1a do
      String.replace(word, "Y", "y")
    else
      word
      |> step1b(r1)
      |> step1c()
      |> step2(r1)
      |> step3(r1, r2)
      |> step4(r2)
      |> step5(r1, r2)
      |> String.replace("Y", "y")
    end
  end

  defp mark_y(word) do
    word
    |> :binary.bin_to_list()
    |> Enum.reduce({[], nil}, fn char, {acc, prev} ->
      char = if char == ?y and (prev == nil or vowel?(prev)), do: ?Y, else: char
      {[char | acc], char}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> :erlang.list_to_binary()
  end

  defp vowel?(char), do: char in ~c"aeiouy"
  defp vowel_in?(word), do: Enum.any?(:binary.bin_to_list(word), &vowel?/1)

  defp region(word, from) do
    chars = :binary.bin_to_list(word)

    chars
    |> Enum.with_index()
    |> Enum.drop(from + 1)
    |> Enum.find_value(byte_size(word), fn {c, i} ->
      if not vowel?(c) and vowel?(Enum.at(chars, i - 1)), do: i + 1
    end)
  end

  defp cut(word, suffix), do: binary_part(word, 0, byte_size(word) - byte_size(suffix))
  defp suffix(word, choices), do: Enum.find(choices, &String.ends_with?(word, &1))

  defp replace_suffix(word, choices, replacement) do
    case suffix(word, choices) do
      nil -> word
      found -> cut(word, found) <> replacement
    end
  end

  defp in_region?(word, suffix, region), do: byte_size(word) - byte_size(suffix) >= region

  defp step1a(word) do
    case suffix(word, ~w(sses ied ies us ss s)) do
      "sses" ->
        cut(word, "sses") <> "ss"

      found when found in ["ied", "ies"] ->
        base = cut(word, found)
        base <> if(byte_size(base) > 1, do: "i", else: "ie")

      "s" ->
        if byte_size(word) > 2 and vowel_in?(binary_part(word, 0, byte_size(word) - 2)),
          do: cut(word, "s"),
          else: word

      _ ->
        word
    end
  end

  defp step1b(word, r1) do
    case suffix(word, ~w(eedly ingly edly eed ing ed)) do
      found when found in ["eed", "eedly"] ->
        if in_region?(word, found, r1), do: cut(word, found) <> "ee", else: word

      nil ->
        word

      found ->
        base = cut(word, found)

        if vowel_in?(base) do
          cond do
            suffix(base, ~w(at bl iz)) ->
              base <> "e"

            suffix(base, ~w(bb dd ff gg mm nn pp rr tt)) ->
              binary_part(base, 0, byte_size(base) - 1)

            r1 >= byte_size(base) and short_syllable?(base) ->
              base <> "e"

            true ->
              base
          end
        else
          word
        end
    end
  end

  defp step1c(word) do
    n = byte_size(word)

    if n > 2 and not is_nil(suffix(word, ["y", "Y"])) and not vowel?(:binary.at(word, n - 2)),
      do: binary_part(word, 0, n - 1) <> "i",
      else: word
  end

  defp step2(word, r1) do
    case Enum.find(@step2, fn {s, _} -> String.ends_with?(word, s) end) do
      nil ->
        word

      {s, replacement} ->
        base = cut(word, s)

        allowed =
          case s do
            "ogi" -> String.ends_with?(base, "l")
            "li" -> byte_size(base) > 0 and :binary.last(base) in ~c"cdeghkmnrt"
            _ -> true
          end

        if allowed and in_region?(word, s, r1), do: base <> replacement, else: word
    end
  end

  defp step3(word, r1, r2) do
    case Enum.find(@step3, fn {s, _} -> String.ends_with?(word, s) end) do
      nil ->
        word

      {s, replacement} ->
        if in_region?(word, s, if(s == "ative", do: r2, else: r1)),
          do: cut(word, s) <> replacement,
          else: word
    end
  end

  defp step4(word, r2) do
    case suffix(word, @step4) do
      nil ->
        word

      s ->
        base = cut(word, s)

        if in_region?(word, s, r2) and (s != "ion" or suffix(base, ["s", "t"])),
          do: base,
          else: word
    end
  end

  defp step5(word, r1, r2) do
    cond do
      String.ends_with?(word, "e") ->
        base = cut(word, "e")

        if byte_size(base) >= r2 or (byte_size(base) >= r1 and not short_syllable?(base)),
          do: base,
          else: word

      String.ends_with?(word, "ll") and in_region?(word, "l", r2) ->
        cut(word, "l")

      true ->
        word
    end
  end

  defp short_syllable?(word) do
    chars = :binary.bin_to_list(word)

    case Enum.take(chars, -3) do
      [a, b, c] -> not vowel?(a) and vowel?(b) and not vowel?(c) and c not in ~c"wxY"
      [a, b] -> vowel?(a) and not vowel?(b)
      _ -> false
    end
  end
end
