defmodule Backplane.Memory.Embedding.ClientTest do
  use ExUnit.Case, async: true

  alias Backplane.HTTPClient
  alias Backplane.Memory.Embedding.Client

  @model "test-embedding-model"
  @http_options [adapter: {HTTP.Test, __MODULE__}]

  setup do
    HTTP.Test.verify_on_exit!()
    :ok
  end

  describe "query_instruction/0" do
    test "returns non-empty string starting with 'Instruct:'" do
      assert String.starts_with?(Client.query_instruction(), "Instruct:")
    end
  end

  describe "embed/3" do
    test "rejects empty, malformed and oversized input before contacting a provider" do
      HTTP.Test.stub(__MODULE__, fn _request -> flunk("invalid input reached provider") end)

      for texts <- [
            [],
            [""],
            ["  "],
            [<<255>>],
            [nil],
            "text",
            List.duplicate("text", 51),
            [String.duplicate("x", 80_001)]
          ] do
        assert {:error, :invalid_embedding_input} =
                 Client.embed(texts, :document, model: @model, http_options: @http_options)
      end

      assert {:error, :invalid_embedding_input} =
               Client.embed([String.duplicate("x", 80_000)], :query,
                 model: @model,
                 http_options: @http_options
               )
    end

    test "requests the schema dimension and rejects malformed successful vectors" do
      for data <- [
            [%{"index" => 0, "embedding" => [0.1, 0.2]}],
            [%{"index" => 0, "embedding" => List.duplicate("bad", 2560)}],
            [%{"index" => 1, "embedding" => List.duplicate(0.1, 2560)}],
            [],
            "invalid"
          ] do
        HTTP.Test.stub(__MODULE__, fn request ->
          assert Jason.decode!(IO.iodata_to_binary(request.body))["dimensions"] == 2560
          HTTP.Test.json(%{"data" => data})
        end)

        assert {:error, :invalid_embedding_response} =
                 Client.embed(["text"], :document, model: @model, http_options: @http_options)
      end
    end

    test "rejects duplicate indices and incomplete batches without returning partial success" do
      vector = List.duplicate(0.1, 2560)

      for data <- [
            [%{"index" => 0, "embedding" => vector}],
            [%{"index" => 0, "embedding" => vector}, %{"index" => 0, "embedding" => vector}]
          ] do
        HTTP.Test.stub(__MODULE__, fn _request -> HTTP.Test.json(%{"data" => data}) end)

        assert {:error, :invalid_embedding_response} =
                 Client.embed(["first", "second"], :document,
                   model: @model,
                   http_options: @http_options
                 )
      end
    end

    test "returns {:error, _} on non-200 response" do
      HTTP.Test.stub(__MODULE__, fn _request -> HTTP.Test.json(%{"error" => "oops"}, 500) end)

      assert {:error, {:llm_proxy_error, 500}} =
               Client.embed(["text"], :document, model: @model, http_options: @http_options)
    end

    test "returns {:ok, vectors} on success with 2560-dim vector" do
      vector = Enum.map(1..2560, fn _ -> 0.001 end)

      HTTP.Test.stub(__MODULE__, fn request ->
        assert HTTP.Headers.get_all(request.headers, "x-backplane-memory-origin") == ["embedding"]
        assert HTTP.Headers.get_all(request.headers, "x-backplane-memory-capture") == ["skip"]
        HTTP.Test.json(%{"data" => [%{"embedding" => vector, "index" => 0}]})
      end)

      assert {:ok, [result_vec]} =
               Client.embed(["hello"], :document, model: @model, http_options: @http_options)

      assert length(result_vec) == 2560
    end

    test "sorts results by index when multiple texts embedded" do
      v1 = Enum.map(1..2560, fn _ -> 0.1 end)
      v2 = Enum.map(1..2560, fn _ -> 0.2 end)

      HTTP.Test.stub(__MODULE__, fn _request ->
        HTTP.Test.json(%{
          "data" => [%{"embedding" => v2, "index" => 1}, %{"embedding" => v1, "index" => 0}]
        })
      end)

      assert {:ok, [first, second]} =
               Client.embed(["a", "b"], :document, model: @model, http_options: @http_options)

      assert hd(first) == 0.1
      assert hd(second) == 0.2
    end

    test "query mode prepends instruction prefix to each input" do
      pid = self()

      HTTP.Test.stub(__MODULE__, fn request ->
        %{"input" => inputs} = Jason.decode!(IO.iodata_to_binary(request.body))
        send(pid, {:input, inputs})

        HTTP.Test.json(%{
          "data" => [%{"embedding" => Enum.map(1..2560, fn _ -> 0.0 end), "index" => 0}]
        })
      end)

      Client.embed(["my query"], :query, model: @model, http_options: @http_options)

      assert_receive {:input, [prefixed]}
      assert String.starts_with?(prefixed, "Instruct:")
    end

    test "returns {:error, _} on network failure" do
      HTTP.Test.stub(__MODULE__, fn _request -> HTTP.Test.transport_error(:econnrefused) end)

      assert {:error, {:http_error, %HTTPClient.Error{reason: :econnrefused}}} =
               Client.embed(["text"], :document, model: @model, http_options: @http_options)
    end

    test "returns not configured without sending a request when no model is configured" do
      owner = self()

      HTTP.Test.stub(__MODULE__, fn _request ->
        send(owner, :unexpected_request)
        HTTP.Test.json(%{"data" => []})
      end)

      assert {:error, :embedding_model_not_configured} =
               Client.embed(["text"], :document, http_options: @http_options)

      refute_received :unexpected_request
    end
  end
end
