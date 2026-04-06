defmodule Backplane.Embeddings do
  @moduledoc """
  Behaviour and configuration for embedding providers.

  When `[embeddings]` config is absent, the entire pipeline is inert —
  no columns populated, no jobs enqueued, search behaves as today.
  """

  @type vector :: [float()]
  @type text :: String.t()

  @callback embed(text()) :: {:ok, vector()} | {:error, term()}
  @callback embed_batch([text()]) :: {:ok, [vector()]} | {:error, term()}
  @callback dimensions() :: pos_integer()

  @doc "Returns the configured embedding provider module, or nil if not configured."
  @spec provider() :: module() | nil
  def provider do
    case Application.get_env(:backplane, :embeddings) do
      nil -> nil
      config -> resolve_provider(config[:provider])
    end
  end

  @doc "Returns the configured embedding settings, or nil."
  @spec config() :: map() | nil
  def config do
    Application.get_env(:backplane, :embeddings)
  end

  @doc "Returns true if embeddings are configured."
  @spec configured?() :: boolean()
  def configured? do
    provider() != nil
  end

  @doc "Embed a single text using the configured provider."
  @spec embed(text()) :: {:ok, vector()} | {:error, term()}
  def embed(text) do
    case provider() do
      nil -> {:error, :embeddings_not_configured}
      mod when is_atom(mod) -> apply(mod, :embed, [text])
    end
  end

  @doc "Embed a batch of texts using the configured provider."
  @spec embed_batch([text()]) :: {:ok, [vector()]} | {:error, term()}
  def embed_batch(texts) do
    case provider() do
      nil -> {:error, :embeddings_not_configured}
      mod when is_atom(mod) -> apply(mod, :embed_batch, [texts])
    end
  end

  @doc "Returns the configured vector dimensions."
  @spec dimensions() :: pos_integer() | nil
  def dimensions do
    case config() do
      nil -> nil
      c -> c[:dimensions]
    end
  end

  defp resolve_provider("ollama"), do: Backplane.Embeddings.Ollama
  defp resolve_provider("openai"), do: Backplane.Embeddings.OpenAI
  defp resolve_provider("anthropic"), do: Backplane.Embeddings.Anthropic
  defp resolve_provider(_), do: nil
end
