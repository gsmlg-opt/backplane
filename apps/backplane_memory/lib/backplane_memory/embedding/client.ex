defmodule BackplaneMemory.Embedding.Client do
  @moduledoc """
  Embeds text via vLLM (Qwen3-Embedding-4B) through the Backplane LLM proxy.

  :document mode — plain text for storage
  :query mode — prepends retrieval instruction for asymmetric search quality
  """

  @model "Qwen/Qwen3-Embedding-4B"
  @query_instruction "Instruct: Retrieve semantically similar text: Query: "

  @doc "Retrieval instruction prefix used in query mode."
  def query_instruction, do: @query_instruction

  @spec embed([String.t()], :query | :document, keyword()) ::
          {:ok, [[float()]]} | {:error, String.t()}
  def embed(texts, mode, opts \\ []) when mode in [:query, :document] do
    inputs = prepare_inputs(texts, mode)
    base_url = Application.get_env(:backplane_memory, :llm_proxy_url, "http://localhost:4220")
    url = "#{base_url}/api/llm/v1/embeddings"
    req_options = Keyword.get(opts, :req_options, [])

    req_opts =
      [
        url: url,
        json: %{model: @model, input: inputs, encoding_format: "float"},
        headers: [{"content-type", "application/json"}]
      ] ++ req_options

    case Req.post(req_opts) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        vectors =
          data
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, vectors}

      {:ok, %{status: status, body: body}} ->
        {:error, "LLM proxy returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp prepare_inputs(texts, :document), do: texts
  defp prepare_inputs(texts, :query), do: Enum.map(texts, &(@query_instruction <> &1))
end
