defmodule BackplaneMemory.Embedding.Client do
  @moduledoc """
  Embeds text through the Backplane LLM proxy.

  :document mode — plain text for storage
  :query mode — prepends retrieval instruction for asymmetric search quality
  """

  @query_instruction "Instruct: Retrieve semantically similar text: Query: "

  @doc "Retrieval instruction prefix used in query mode."
  def query_instruction, do: @query_instruction

  @doc "Returns true when an embedding model is configured."
  def configured?(opts \\ []), do: not is_nil(model(opts))

  @doc "Resolved embedding model, or nil when vector search is not configured."
  def model(opts \\ []) do
    opts
    |> Keyword.get(:model)
    |> Kernel.||(settings_model())
    |> Kernel.||(Application.get_env(:backplane_memory, :embed_model))
    |> normalize_model()
  end

  @spec embed([String.t()], :query | :document, keyword()) ::
          {:ok, [[float()]]} | {:error, term()}
  def embed(texts, mode, opts \\ []) when mode in [:query, :document] do
    case model(opts) do
      nil ->
        {:error, :embedding_model_not_configured}

      model ->
        do_embed(texts, mode, model, opts)
    end
  end

  defp do_embed(texts, mode, model, opts) do
    inputs = prepare_inputs(texts, mode)
    base_url = Application.get_env(:backplane_memory, :llm_proxy_url, "http://localhost:4220")
    url = "#{base_url}/api/llm/v1/embeddings"
    req_options = Keyword.get(opts, :req_options, [])

    req_opts =
      [
        url: url,
        json: %{model: model, input: inputs, encoding_format: "float"}
      ] ++ req_options

    case Req.post(req_opts) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        vectors =
          data
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, vectors}

      {:ok, %{status: status, body: body}} ->
        {:error, {:llm_proxy_error, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp settings_model do
    if Code.ensure_loaded?(Backplane.Settings) do
      Backplane.Settings.get("memory.embed_model")
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp normalize_model(model) when is_binary(model) do
    model = String.trim(model)
    if model == "", do: nil, else: model
  end

  defp normalize_model(_), do: nil

  defp prepare_inputs(texts, :document), do: texts
  defp prepare_inputs(texts, :query), do: Enum.map(texts, &(@query_instruction <> &1))
end
