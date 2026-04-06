defmodule Backplane.Embeddings.OpenAITest do
  use ExUnit.Case, async: false

  alias Backplane.Embeddings.OpenAI

  setup do
    original = Application.get_env(:backplane, :embeddings)

    Application.put_env(:backplane, :embeddings, %{
      provider: "openai",
      model: "text-embedding-3-small",
      api_url: "http://127.0.0.1:19998/v1/embeddings",
      api_key: "sk-test-invalid",
      dimensions: 1536,
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
      assert {:error, msg} = OpenAI.embed("test text")
      assert is_binary(msg)
      assert msg =~ "connection failed" or msg =~ "OpenAI"
    end

    test "returns error when server is unreachable" do
      assert {:error, msg} = OpenAI.embed("hello world")
      assert is_binary(msg)
    end
  end

  describe "embed_batch/1" do
    test "batches correctly and returns error on connection failure" do
      # With batch_size: 2, three texts should be split into two batches.
      # The first batch will fail, so the overall result is an error.
      texts = ["alpha", "beta", "gamma"]
      assert {:error, msg} = OpenAI.embed_batch(texts)
      assert is_binary(msg)
      assert msg =~ "connection failed" or msg =~ "OpenAI"
    end

    test "handles connection error for single batch" do
      assert {:error, msg} = OpenAI.embed_batch(["single text"])
      assert is_binary(msg)
    end
  end
end
