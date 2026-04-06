defmodule Backplane.Embeddings.OpenAI do
  @moduledoc """
  OpenAI embedding provider. Calls OpenAI embeddings API.
  """

  @behaviour Backplane.Embeddings

  @default_url "https://api.openai.com/v1/embeddings"

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
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]

      case Req.post(url, json: body, headers: headers, retry: :transient, max_retries: 2) do
        {:ok, %{status: 200, body: %{"data" => data}}} ->
          vecs = data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])
          {:cont, {:ok, acc ++ vecs}}

        {:ok, %{status: 429} = resp} ->
          retry_after = Req.Response.get_header(resp, "retry-after") |> List.first()
          wait = if retry_after, do: String.to_integer(retry_after) * 1000, else: 5000
          Process.sleep(wait)
          # Retry this batch once
          case Req.post(url, json: body, headers: headers) do
            {:ok, %{status: 200, body: %{"data" => data}}} ->
              vecs = data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])
              {:cont, {:ok, acc ++ vecs}}

            _ ->
              {:halt, {:error, "OpenAI rate limited (429)"}}
          end

        {:ok, %{status: status, body: body}} ->
          {:halt, {:error, "OpenAI API error #{status}: #{inspect(body)}"}}

        {:error, reason} ->
          {:halt, {:error, "OpenAI connection failed: #{inspect(reason)}"}}
      end
    end)
  end

  @impl true
  def dimensions do
    config = Backplane.Embeddings.config()
    config[:dimensions] || 1536
  end
end
