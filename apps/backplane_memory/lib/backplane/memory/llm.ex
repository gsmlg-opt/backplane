defmodule Backplane.Memory.LLM do
  @moduledoc """
  LLM proxy client for memory operations. Reads the `memory.llm_model`
  system setting. Returns `{:skip, :no_llm}` when no model is configured.
  """

  @max_descriptor_content 2_000
  @max_descriptor_entities 20
  @max_descriptor_entity_scan 100
  @max_descriptor_entity_chars 100
  @max_descriptor_evidence 10
  @max_descriptor_evidence_scan 100
  @max_descriptor_field_chars 200
  @max_descriptor_claim_chars 500
  @max_rerank_candidates 500
  @max_rerank_prompt_bytes 40_000
  @max_crystal_prompt_bytes 80_000
  @capture_guard_key {__MODULE__, :capture_suppressed}

  alias Backplane.Memory.Privacy.Filter

  @doc "Returns strict structured crystal enrichment or a classified optional-intelligence failure."
  def crystallize(%{summary: summary, fallback: fallback})
      when is_map(summary) and is_map(fallback) do
    case model() do
      nil -> {:skip, :no_llm}
      configured_model -> do_crystallize(summary, fallback, configured_model)
    end
  end

  def crystallize(_input), do: {:error, :invalid_crystal_input}

  defp do_crystallize(summary, fallback, configured_model) do
    {:ok, safe_summary} = Filter.apply_bounded(Map.get(summary, :content, ""), 65_536)

    prompt =
      "Return only one JSON object with exactly title, narrative, key_outcomes, decisions, " <>
        "files_affected, unresolved_items. title and narrative are strings; all other fields " <>
        "are arrays of strings. Do not include secrets or raw private content.\nSummary: " <>
        Jason.encode!(safe_summary) <> "\nFallback: " <> Jason.encode!(fallback)

    if byte_size(prompt) <= @max_crystal_prompt_bytes do
      options =
        [
          json: %{
            model: configured_model,
            messages: [%{role: "user", content: prompt}],
            response_format: %{type: "json_object"}
          },
          receive_timeout: 10_000
        ]
        |> Keyword.merge(Application.get_env(:backplane_memory, :llm_req_options, []))

      provider_request("crystal", options)
      |> case do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}}
        when is_binary(text) ->
          with {:ok, structured} <- parse_crystal(text) do
            {:ok, structured, configured_model}
          end

        {:ok, %{status: status}} ->
          {:error, {:llm_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :crystal_payload_too_large}
    end
  end

  @doc false
  def capture_suppressed?, do: Process.get(@capture_guard_key, false)

  @doc false
  def with_capture_suppressed(fun) when is_function(fun, 0) do
    previous = Process.get(@capture_guard_key)
    Process.put(@capture_guard_key, true)

    try do
      fun.()
    after
      if is_nil(previous),
        do: Process.delete(@capture_guard_key),
        else: Process.put(@capture_guard_key, previous)
    end
  end

  defp provider_request(origin, options) do
    url = Application.get_env(:backplane_memory, :llm_proxy_url, "http://localhost:4220")

    headers =
      [
        {"x-backplane-memory-origin", origin},
        {"x-backplane-memory-capture", "skip"}
      ] ++ Keyword.get(options, :headers, [])

    options = Keyword.put(options, :headers, headers)
    with_capture_suppressed(fn -> Req.post("#{url}/v1/chat/completions", options) end)
  end

  defp parse_crystal(text) when byte_size(text) <= 100_000 do
    keys = ~w(title narrative key_outcomes decisions files_affected unresolved_items)

    with {:ok, decoded} when is_map(decoded) <- Jason.decode(text),
         true <- decoded |> Map.keys() |> Enum.sort() == Enum.sort(keys),
         true <- is_binary(decoded["title"]) and is_binary(decoded["narrative"]),
         true <- Enum.all?(keys -- ~w(title narrative), &string_list?(decoded[&1])) do
      {:ok, decoded}
    else
      _invalid -> {:error, :invalid_crystal_response}
    end
  end

  defp parse_crystal(_text), do: {:error, :crystal_response_too_large}

  defp string_list?(values),
    do: is_list(values) and length(values) <= 500 and Enum.all?(values, &is_binary/1)

  @doc "Extract graph nodes and edges from a list of observation strings."
  def extract_graph(observations) when is_list(observations) do
    case model() do
      nil -> {:skip, :no_llm}
      _model -> do_extract_graph(observations)
    end
  end

  defp do_extract_graph(_observations) do
    # Stub: real impl sends observations to LLM proxy and parses response
    {:ok, %{nodes: [], edges: []}}
  end

  @doc """
  Generate 3–5 alternative phrasings of the query for search expansion.
  Returns {:ok, [String.t()]} or {:skip, :no_llm}.
  """
  def expand_query(query) when is_binary(query) do
    case model() do
      nil -> {:skip, :no_llm}
      _model -> do_expand_query(query)
    end
  end

  defp do_expand_query(query) do
    # Stub: real impl calls LLM proxy with expansion prompt
    # Returns 3–5 alternative phrasings including the original
    {:ok, [query]}
  end

  @doc """
  Score candidates for relevance to query. Returns reranked list.
  candidates is a list of %{id: _, content: _, ...} maps.
  Returns {:ok, [candidate]} reordered, or {:skip, :no_llm}.
  """
  def rerank(query, candidates) when is_binary(query) and is_list(candidates) do
    case model() do
      nil -> {:skip, :no_llm}
      _model -> do_rerank(query, candidates)
    end
  end

  defp do_rerank(query, candidates) when length(candidates) <= @max_rerank_candidates do
    prompt =
      "Rank these memory descriptors for relevance to the query. Return only one JSON object " <>
        "with exactly one field named rankings. rankings must contain each input token exactly " <>
        "once as objects with exactly token and score, where score is from 0 to 1.\n\n" <>
        "Query: #{Jason.encode!(query)}\nCandidates: #{Jason.encode!(candidates)}"

    if byte_size(prompt) <= @max_rerank_prompt_bytes do
      request_options =
        [
          json: %{
            model: model(),
            messages: [%{role: "user", content: prompt}]
          },
          receive_timeout: 10_000
        ]
        |> Keyword.merge(Application.get_env(:backplane_memory, :llm_req_options, []))

      case provider_request("rerank", request_options) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}}
        when is_binary(text) ->
          parse_rerank(text, candidates)

        {:ok, %{status: 200}} ->
          {:error, :invalid_reranker_response}

        {:ok, %{status: status}} ->
          {:error, {:llm_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :reranker_payload_too_large}
    end
  end

  defp do_rerank(_query, _candidates), do: {:error, :too_many_reranker_candidates}

  defp parse_rerank(text, candidates) do
    expected = candidates |> Enum.map(& &1.token) |> MapSet.new()

    with {:ok, %{"rankings" => rankings} = decoded} <- Jason.decode(text),
         true <- map_size(decoded) == 1 and is_list(rankings),
         {:ok, rows} <- parse_rerank_rows(rankings),
         tokens = Enum.map(rows, & &1.token),
         true <- length(tokens) == MapSet.size(expected),
         true <- length(tokens) == MapSet.size(MapSet.new(tokens)),
         true <- MapSet.new(tokens) == expected do
      {:ok, rows}
    else
      _invalid -> {:error, :invalid_reranker_response}
    end
  end

  defp parse_rerank_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      %{"token" => token, "score" => score} = row, {:ok, acc}
      when map_size(row) == 2 and is_integer(token) and is_number(score) and score >= 0 and
             score <= 1 ->
        {:cont, {:ok, [%{token: token, score: score / 1} | acc]}}

      _row, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  @doc "Classify the semantic relation between two bounded memory descriptors."
  def classify_relation(source, target) when is_map(source) and is_map(target) do
    case model() do
      nil -> {:skip, :no_llm}
      configured_model -> do_classify_relation(source, target, configured_model)
    end
  end

  defp do_classify_relation(source, target, configured_model) do
    prompt = """
    Classify the relation between these two memory descriptors. Return only one JSON object with exactly two fields: "classification" and "confidence". Classification must be one of: duplicate, extension, temporal_replacement, contradiction, unrelated. Confidence must be a number from 0 to 1.

    Source: #{bounded_json(source)}
    Target: #{bounded_json(target)}
    """

    request_options =
      [
        json: %{
          model: configured_model,
          messages: [%{role: "user", content: prompt}]
        },
        receive_timeout: 10_000
      ]
      |> Keyword.merge(Application.get_env(:backplane_memory, :llm_req_options, []))

    case provider_request("relation", request_options) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}}
      when is_binary(text) ->
        parse_relation_classification(text)

      {:ok, %{status: 200}} ->
        {:error, :invalid_classifier_response}

      {:ok, %{status: status}} ->
        {:error, {:llm_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bounded_json(value) do
    value
    |> bound_descriptor()
    |> Jason.encode!()
  end

  defp bound_descriptor(descriptor) do
    %{
      "content" => bound_string(descriptor["content"], @max_descriptor_content),
      "claim" => bound_claim(descriptor["claim"]),
      "entities" => bound_entities(descriptor["entities"]),
      "valid_from" => bound_string(descriptor["valid_from"], @max_descriptor_field_chars),
      "valid_to" => bound_string(descriptor["valid_to"], @max_descriptor_field_chars),
      "evidence" => bound_evidence(descriptor["evidence"])
    }
  end

  defp bound_claim(claim) when is_map(claim) do
    Map.new(~w(subject predicate value cardinality), fn key ->
      {key, bound_string(claim[key], @max_descriptor_claim_chars)}
    end)
  end

  defp bound_claim(_claim), do: nil

  defp bound_entities(entities) when is_list(entities) do
    entities
    |> Enum.take(@max_descriptor_entity_scan)
    |> Enum.filter(&is_binary/1)
    |> Enum.take(@max_descriptor_entities)
    |> Enum.map(&bound_string(&1, @max_descriptor_entity_chars))
  end

  defp bound_entities(_entities), do: []

  defp bound_evidence(evidence) when is_list(evidence) do
    evidence
    |> Enum.take(@max_descriptor_evidence_scan)
    |> Enum.filter(&is_map/1)
    |> Enum.take(@max_descriptor_evidence)
    |> Enum.map(fn item ->
      Map.new(
        ~w(evidence_kind support_score),
        fn key -> {key, bound_evidence_value(item[key])} end
      )
    end)
  end

  defp bound_evidence(_evidence), do: []

  defp bound_evidence_value(value) when is_binary(value),
    do: bound_string(value, @max_descriptor_field_chars)

  defp bound_evidence_value(value) when is_number(value), do: value
  defp bound_evidence_value(_value), do: nil

  defp bound_string(value, max_chars) when is_binary(value) do
    {:ok, filtered} = Filter.apply_bounded(value, max_chars)
    filtered
  end

  defp bound_string(_value, _max_chars), do: nil

  defp parse_relation_classification(text) do
    with {:ok, %{"classification" => classification, "confidence" => confidence} = result} <-
           Jason.decode(text),
         true <- map_size(result) == 2,
         true <-
           classification in ~w(duplicate extension temporal_replacement contradiction unrelated),
         true <- is_number(confidence) and confidence >= 0 and confidence <= 1 do
      {:ok, result}
    else
      _ -> {:error, :invalid_classifier_response}
    end
  end

  @doc "Extract durable semantic facts from a session summary. Returns {:ok, [string]} or {:skip, :no_llm}."
  @spec extract_facts(String.t()) :: {:ok, [String.t()]} | {:skip, :no_llm} | {:error, String.t()}
  def extract_facts(summary) when is_binary(summary) do
    case model() do
      nil -> {:skip, :no_llm}
      m -> do_extract_facts(summary, m)
    end
  end

  defp do_extract_facts(summary, model) do
    prompt = """
    Extract 3-7 durable, reusable facts from this session summary. Output one fact per line. Only include facts that would be useful in future sessions. Do not include session-specific details.

    Session summary:
    #{summary}
    """

    do_llm_call(prompt, model, "fact")
  end

  @doc "Extract reusable workflows/procedures from semantic memories. Returns {:ok, [string]} or {:skip, :no_llm}."
  @spec extract_procedures(String.t()) ::
          {:ok, [String.t()]} | {:skip, :no_llm} | {:error, String.t()}
  def extract_procedures(content) when is_binary(content) do
    case model() do
      nil -> {:skip, :no_llm}
      m -> do_extract_procedures(content, m)
    end
  end

  defp do_extract_procedures(content, model) do
    prompt = """
    Extract 3-7 reusable workflows or procedures from these semantic memories. Output one procedure per line. Only include patterns that represent repeatable steps or processes useful across sessions.

    Memories:
    #{content}
    """

    do_llm_call(prompt, model, "procedure")
  end

  defp do_llm_call(prompt, model, origin) do
    options =
      [
        json: %{model: model, messages: [%{role: "user", content: prompt}]},
        receive_timeout: 10_000
      ]
      |> Keyword.merge(Application.get_env(:backplane_memory, :llm_req_options, []))

    case provider_request(origin, options) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
        items =
          text
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&Regex.replace(~r/^[-*\d.]+\s*/, &1, ""))
          |> Enum.reject(&(&1 == ""))

        {:ok, items}

      {:ok, %{status: 200, body: body}} ->
        {:error, "unexpected LLM response shape: #{inspect(body)}"}

      {:ok, %{status: status}} ->
        {:error, "LLM proxy returned status #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp model, do: Backplane.Settings.get("memory.llm_model")
end
