defmodule BackplaneMemory.LLM do
  @moduledoc """
  LLM proxy client for memory operations. Reads the `memory.llm_model`
  system setting. Returns `{:skip, :no_llm}` when no model is configured.
  """

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

  defp do_rerank(_query, candidates) do
    # Stub: real impl calls LLM proxy for relevance scoring
    {:ok, candidates}
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

    do_llm_call(prompt, model)
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

    do_llm_call(prompt, model)
  end

  defp do_llm_call(prompt, model) do
    url = Application.get_env(:backplane_memory, :llm_proxy_url, "http://localhost:4220")

    case Req.post("#{url}/api/llm/v1/chat/completions",
           json: %{model: model, messages: [%{role: "user", content: prompt}]}
         ) do
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
