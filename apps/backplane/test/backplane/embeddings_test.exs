defmodule Backplane.EmbeddingsTest do
  use ExUnit.Case, async: false

  alias Backplane.Embeddings

  setup do
    original = Application.get_env(:backplane, :embeddings)

    on_exit(fn ->
      if original do
        Application.put_env(:backplane, :embeddings, original)
      else
        Application.delete_env(:backplane, :embeddings)
      end
    end)

    :ok
  end

  describe "configuration" do
    test "returns nil provider when [embeddings] config absent" do
      Application.delete_env(:backplane, :embeddings)

      assert Embeddings.provider() == nil
      refute Embeddings.configured?()
      assert Embeddings.config() == nil
      assert Embeddings.dimensions() == nil
    end

    test "resolves Ollama provider from config" do
      Application.put_env(:backplane, :embeddings, %{
        provider: "ollama",
        model: "nomic-embed-text",
        api_url: "http://localhost:11434",
        dimensions: 768
      })

      assert Embeddings.provider() == Backplane.Embeddings.Ollama
      assert Embeddings.configured?()
      assert Embeddings.dimensions() == 768
    end

    test "resolves OpenAI provider from config" do
      Application.put_env(:backplane, :embeddings, %{
        provider: "openai",
        model: "text-embedding-3-small",
        api_key: "sk-test",
        dimensions: 1536
      })

      assert Embeddings.provider() == Backplane.Embeddings.OpenAI
      assert Embeddings.configured?()
      assert Embeddings.dimensions() == 1536
    end

    test "returns nil for unknown provider name" do
      Application.put_env(:backplane, :embeddings, %{
        provider: "unknown_provider",
        dimensions: 256
      })

      assert Embeddings.provider() == nil
      refute Embeddings.configured?()
      assert Embeddings.dimensions() == 256
    end
  end
end
