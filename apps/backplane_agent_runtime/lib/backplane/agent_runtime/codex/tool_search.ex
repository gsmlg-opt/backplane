defmodule Backplane.AgentRuntime.Codex.ToolSearch do
  @moduledoc false
  # Codex 46fdd5ef metadata text; bm25 2.3.2 English tokenizer and f32 scorer.
  # Modified Elixir adaptation for Backplane contracts and schema keys.
  # Codex attribution and Apache-2.0 terms: priv/codex/tool_search/{NOTICE,LICENSE}-codex.
  import Bitwise
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Codex.ToolSearchStemmer

  @data Path.expand("../../../../priv/codex/tool_search", __DIR__)
  @external_resource Path.join(@data, "deunicode-pointers.bin")
  @external_resource Path.join(@data, "deunicode-mapping.txt")
  @external_resource Path.join(@data, "english-stopwords.txt")
  @pointers File.read!(Path.join(@data, "deunicode-pointers.bin"))
  @mapping File.read!(Path.join(@data, "deunicode-mapping.txt"))
  @stopwords @data
             |> Path.join("english-stopwords.txt")
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Map.new(&{&1, true})

  def query(value) when is_binary(value) do
    if String.valid?(value) and String.trim(value) != "",
      do: {:ok, String.trim(value)},
      else: invalid("query must be a nonempty UTF-8 string")
  end

  def query(_), do: invalid("query must be a nonempty UTF-8 string")

  def text(contract) do
    with {:ok, namespace} <- namespace_parts(contract),
         {:ok, body} <- body_parts(contract) do
      parts(namespace ++ body)
    end
  end

  defp namespace_parts(%{namespace: nil}), do: {:ok, []}

  defp namespace_parts(contract) do
    description = field(contract.metadata, :namespace_description)

    with {:ok, description} <- optional_text(description) do
      description =
        if is_nil(description) or String.trim(description) == "",
          do:
            if(contract.namespace == "functions",
              do: "",
              else: "Tools in the #{contract.namespace} namespace."
            ),
          else: description

      {:ok, [contract.namespace, description]}
    end
  end

  defp body_parts(%{input_kind: :custom} = contract) do
    with {:ok, syntax} <- optional_text(field(contract.format, :syntax)) do
      {:ok, [contract.name, contract.description, syntax]}
    end
  end

  defp body_parts(contract) do
    with {:ok, schema} <- schema_parts(contract.schema) do
      {:ok,
       [contract.name, String.replace(contract.name, "_", " "), contract.description | schema]}
    end
  end

  defp schema_parts(nil), do: {:ok, []}
  defp schema_parts(schema) when is_boolean(schema), do: {:ok, []}

  defp schema_parts(schema) when is_map(schema) do
    properties =
      (field(schema, :properties) || %{})
      |> Enum.map(fn {name, child} ->
        {if(is_atom(name), do: Atom.to_string(name), else: name), child}
      end)
      |> Enum.sort_by(fn {name, _} -> name end)

    any_of = field(schema, :anyOf) || []

    with {:ok, properties} <-
           collect(properties, fn {name, child} ->
             with {:ok, child} <- schema_parts(child), do: {:ok, [name | child]}
           end),
         {:ok, items} <- schema_parts(field(schema, :items)),
         {:ok, variants} <- collect(any_of, &schema_parts/1) do
      {:ok, [field(schema, :description) | properties ++ items ++ variants]}
    end
  end

  defp schema_parts(_), do: invalid("search schema metadata must be an object")

  defp collect(items, callback) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case callback.(item) do
        {:ok, parts} -> {:cont, {:ok, acc ++ parts}}
        error -> {:halt, error}
      end
    end)
  end

  defp parts(values) do
    with {:ok, strings} <-
           collect(values, fn value ->
             with {:ok, value} <- optional_text(value),
                  do: {:ok, if(is_nil(value), do: [], else: [String.trim(value)])}
           end) do
      {:ok, strings |> Enum.reject(&(&1 == "")) |> Enum.join(" ")}
    end
  end

  defp optional_text(nil), do: {:ok, nil}

  defp optional_text(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: invalid("search metadata must be UTF-8 text")
  end

  defp optional_text(_), do: invalid("search metadata must be text")
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_, _), do: nil

  def tokens(text) do
    text
    |> transliterate()
    |> String.downcase()
    |> ascii_words()
    |> Enum.reject(&Map.has_key?(@stopwords, &1))
    |> Enum.map(&ToolSearchStemmer.stem/1)
  end

  def transliterate(text) do
    {ascii, rest} = split_ascii(text, text, 0)
    mapped = rest |> String.to_charlist() |> Enum.map(&mapping/1)
    IO.iodata_to_binary([ascii | transliterated_parts(mapped, [])])
  end

  defp transliterated_parts([], acc), do: Enum.reverse(acc)

  defp transliterated_parts([value | rest], acc) do
    next_space? =
      case rest do
        [] -> true
        [<<" ", _::binary>> | _] -> true
        _ -> false
      end

    value =
      if byte_size(value) > 1 and String.ends_with?(value, " ") and next_space?,
        do: binary_part(value, 0, byte_size(value) - 1),
        else: value

    transliterated_parts(rest, [value | acc])
  end

  defp split_ascii(text, <<c, rest::binary>>, n) when c < 127,
    do: split_ascii(text, rest, n + 1)

  defp split_ascii(text, rest, n), do: {binary_part(text, 0, n), rest}

  defp mapping(codepoint) when codepoint * 3 + 3 <= byte_size(@pointers) do
    <<a, b, size>> = binary_part(@pointers, codepoint * 3, 3)
    offset = a + b * 256

    cond do
      size <= 2 -> binary_part(<<a, b>>, 0, size)
      offset + size <= byte_size(@mapping) -> binary_part(@mapping, offset, size)
      true -> "[?]"
    end
  end

  defp mapping(_), do: "[?]"

  defp letter?(c), do: c in ?a..?z
  defp number?(c), do: c in ?0..?9
  defp word?(c), do: letter?(c) or number?(c) or c == ?_

  defp bridge?(c, left, right) do
    (c in ~c"':." and letter?(left) and letter?(right)) or
      (c in ~c"',;." and number?(left) and number?(right))
  end

  defp ascii_words(text), do: ascii_words(text, 0, [], [])

  defp ascii_words(<<c, rest::binary>>, left, words, current) do
    right =
      case rest do
        <<next, _::binary>> -> next
        <<>> -> 0
      end

    if word?(c) or bridge?(c, left, right),
      do: ascii_words(rest, c, words, [c | current]),
      else: ascii_words(rest, c, finish_word(words, current), [])
  end

  defp ascii_words(<<>>, _left, words, current),
    do: words |> finish_word(current) |> Enum.reverse()

  defp finish_word(words, chars) do
    if Enum.any?(chars, &(letter?(&1) or number?(&1))),
      do: [chars |> Enum.reverse() |> :erlang.list_to_binary() | words],
      else: words
  end

  def hash(token), do: token |> hash_bytes(0) |> hash_word(255)

  defp hash_bytes(<<word::little-unsigned-32, rest::binary>>, hash),
    do: hash_bytes(rest, hash_word(hash, word))

  defp hash_bytes(<<byte, rest::binary>>, hash), do: hash_bytes(rest, hash_word(hash, byte))
  defp hash_bytes(<<>>, hash), do: hash

  defp hash_word(hash, word),
    do:
      band(bxor(band(bsl(hash, 5) ||| bsr(hash, 27), 0xFFFFFFFF), word) * 0x27220A95, 0xFFFFFFFF)

  def rank(documents, query) do
    documents =
      Enum.map(documents, fn {name, text} -> {name, Enum.map(tokens(text), &hash/1)} end)

    query = query |> tokens() |> Enum.map(&hash/1)
    n = length(documents)

    avg =
      if n == 0,
        do: 256.0,
        else: f32(Enum.sum(Enum.map(documents, fn {_, ts} -> length(ts) end)) / n)

    avg = if avg <= 0, do: 256.0, else: avg

    df =
      Enum.reduce(documents, %{}, fn {_, ts}, acc ->
        Enum.reduce(Enum.uniq(ts), acc, &Map.update(&2, &1, 1, fn count -> count + 1 end))
      end)

    documents
    |> Enum.map(fn {name, ts} ->
      counts = Enum.frequencies(ts)
      normalization = mul(f32(1.2), add(sub(1.0, 0.75), mul(0.75, divide(f32(length(ts)), avg))))

      score =
        Enum.reduce(query, 0.0, fn token, acc ->
          frequency = f32(Map.get(counts, token, 0))
          document_frequency = f32(Map.get(df, token, 0))

          idf =
            f32(
              :math.log(
                add(
                  1.0,
                  divide(add(sub(f32(n), document_frequency), 0.5), add(document_frequency, 0.5))
                )
              )
            )

          weight = divide(mul(frequency, add(f32(1.2), 1.0)), add(frequency, normalization))
          add(acc, mul(idf, weight))
        end)

      {name, score}
    end)
    |> Enum.filter(fn {_, score} -> score > 0 end)
    |> Enum.sort_by(fn {name, score} -> {-score, name} end)
  end

  defp f32(value) do
    <<rounded::float-32>> = <<value / 1::float-32>>
    rounded
  end

  defp add(a, b), do: f32(a + b)
  defp sub(a, b), do: f32(a - b)
  defp mul(a, b), do: f32(a * b)
  defp divide(a, b), do: f32(a / b)
  defp invalid(message), do: {:error, Error.new(:validation, message)}
end
