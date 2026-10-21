defmodule Backplane.Memory.Embedding.Client do
  @moduledoc """
  Embeds text through the Backplane LLM proxy.

  :document mode — plain text for storage
  :query mode — prepends retrieval instruction for asymmetric search quality
  """

  @query_instruction "Instruct: Retrieve semantically similar text: Query: "
  @dimensions 2560

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
    with :ok <- validate_inputs(texts, mode) do
      case model(opts) do
        nil -> {:error, :embedding_model_not_configured}
        model -> do_embed(texts, mode, model, opts)
      end
    end
  end

  defp validate_inputs(texts, mode) when is_list(texts) and length(texts) in 1..50 do
    valid? =
      Enum.all?(texts, fn text ->
        is_binary(text) and String.valid?(text) and String.trim(text) != ""
      end)

    if valid? and Enum.reduce(prepare_inputs(texts, mode), 0, &(byte_size(&1) + &2)) <= 80_000,
      do: :ok,
      else: {:error, :invalid_embedding_input}
  end

  defp validate_inputs(_texts, _mode), do: {:error, :invalid_embedding_input}

  defp do_embed(texts, mode, model, opts) do
    inputs = prepare_inputs(texts, mode)
    base_url = Application.get_env(:backplane_memory, :llm_proxy_url, "http://localhost:4220")
    url = "#{base_url}/v1/embeddings"
    req_options = Keyword.get(opts, :req_options, [])

    req_opts =
      [
        url: url,
        headers: [
          {"x-backplane-memory-origin", "embedding"},
          {"x-backplane-memory-capture", "skip"}
        ],
        json: %{model: model, input: inputs, encoding_format: "float", dimensions: @dimensions},
        receive_timeout: 10_000,
        retry: false
      ] ++ req_options

    with {:ok, req_opts} <- Backplane.Memory.ProxyAuth.authorize(req_opts) do
      request(req_opts, length(texts))
    end
  end

  defp request(req_opts, count) do
    case Backplane.Memory.LLM.with_capture_suppressed(fn -> Req.post(req_opts) end) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        validate_vectors(data, count)

      {:ok, %{status: 200}} ->
        {:error, :invalid_embedding_response}

      {:ok, %{status: status}} ->
        {:error, {:llm_proxy_error, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp validate_vectors(data, count) when is_list(data) and length(data) == count do
    if Enum.all?(data, &valid_vector_row?/1) and
         Enum.sort(Enum.map(data, & &1["index"])) == Enum.to_list(0..(count - 1)) do
      {:ok, data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])}
    else
      {:error, :invalid_embedding_response}
    end
  end

  defp validate_vectors(_data, _count), do: {:error, :invalid_embedding_response}

  defp valid_vector_row?(%{"index" => index, "embedding" => vector})
       when is_integer(index) and is_list(vector),
       do: length(vector) == @dimensions and Enum.all?(vector, &is_number/1)

  defp valid_vector_row?(_row), do: false

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
