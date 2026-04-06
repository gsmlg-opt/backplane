defmodule Backplane.Embeddings.OllamaTest do
  use ExUnit.Case, async: false

  alias Backplane.Embeddings.Ollama

  setup do
    original = Application.get_env(:backplane, :embeddings)

    Application.put_env(:backplane, :embeddings, %{
      provider: "ollama",
      model: "nomic-embed-text",
      api_url: "http://127.0.0.1:19999",
      dimensions: 768,
      batch_size: 2
    })

    on_exit(fn ->
      if original do
        Application.put_env(:backplane, :embeddings, original)
      else
        Application.delete_env(:backplane, :embeddings)
      end
    end)

    :ok
  end

  describe "embed/1" do
    test "returns error on connection failure" do
      assert {:error, msg} = Ollama.embed("test text")
      assert is_binary(msg)
      assert msg =~ "connection failed" or msg =~ "Ollama"
    end

    test "returns error when server is unreachable" do
      Application.put_env(:backplane, :embeddings, %{
        provider: "ollama",
        model: "nonexistent-model",
        api_url: "http://127.0.0.1:19999",
        dimensions: 768,
        batch_size: 2
      })

      assert {:error, msg} = Ollama.embed("hello world")
      assert is_binary(msg)
    end
  end

  describe "embed_batch/1" do
    test "returns error on connection failure for batch" do
      assert {:error, msg} = Ollama.embed_batch(["text one", "text two", "text three"])
      assert is_binary(msg)
      assert msg =~ "connection failed" or msg =~ "Ollama"
    end
  end
end
