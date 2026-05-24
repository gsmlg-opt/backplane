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

  defp model, do: Backplane.Settings.get("memory.llm_model")
end
