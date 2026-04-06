defmodule Backplane.Embeddings.Ollama do
  @moduledoc """
  Ollama embedding provider. Calls local Ollama API.
  """

  @behaviour Backplane.Embeddings

  @impl true
  def embed(text) do
    config = Backplane.Embeddings.config()
    url = "#{config[:api_url]}/api/embeddings"

    case Req.post(url, json: %{model: config[:model], prompt: text}) do
      {:ok, %{status: 200, body: %{"embedding" => embedding}}} ->
        {:ok, embedding}

      {:ok, %{status: status, body: body}} ->
        {:error, "Ollama API error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Ollama connection failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def embed_batch(texts) do
    config = Backplane.Embeddings.config()
    batch_size = config[:batch_size] || 32

    results =
      texts
      |> Enum.chunk_every(batch_size)
      |> Enum.flat_map(fn batch ->
        Enum.map(batch, fn text ->
          case embed(text) do
            {:ok, vec} -> vec
            {:error, _} = err -> err
          end
        end)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, results}
      error -> error
    end
  end

  @impl true
  def dimensions do
    config = Backplane.Embeddings.config()
    config[:dimensions] || 768
  end
end
