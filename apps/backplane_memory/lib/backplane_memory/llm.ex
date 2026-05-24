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

  defp model, do: Backplane.Settings.get("memory.llm_model")
end
