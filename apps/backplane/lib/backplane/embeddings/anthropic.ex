defmodule Backplane.Embeddings.Anthropic do
  @moduledoc """
  Anthropic embedding provider. Placeholder for when Anthropic embeddings API is available.
  """

  @behaviour Backplane.Embeddings

  @default_url "https://api.anthropic.com/v1/embeddings"

  @impl true
  def embed(text) do
    case embed_batch([text]) do
      {:ok, [vec]} -> {:ok, vec}
      {:error, _} = err -> err
    end
  end

  @impl true
  def embed_batch(texts) do
    config = Backplane.Embeddings.config()
    url = config[:api_url] || @default_url
    api_key = config[:api_key]
    model = config[:model]
    batch_size = config[:batch_size] || 32

    texts
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      body = %{model: model, input: batch}

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ]

      case Req.post(url, json: body, headers: headers) do
        {:ok, %{status: 200, body: %{"data" => data}}} ->
          vecs = data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])
          {:cont, {:ok, acc ++ vecs}}

        {:ok, %{status: status, body: resp_body}} ->
          {:halt, {:error, "Anthropic API error #{status}: #{inspect(resp_body)}"}}

        {:error, reason} ->
          {:halt, {:error, "Anthropic connection failed: #{inspect(reason)}"}}
      end
    end)
  end

  @impl true
  def dimensions do
    config = Backplane.Embeddings.config()
    config[:dimensions] || 1024
  end
end
