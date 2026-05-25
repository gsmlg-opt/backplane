defmodule BackplaneMemory.Embedding.ClientTest do
  use ExUnit.Case, async: true

  alias BackplaneMemory.Embedding.Client

  @model "test-embedding-model"

  describe "query_instruction/0" do
    test "returns non-empty string starting with 'Instruct:'" do
      assert String.starts_with?(Client.query_instruction(), "Instruct:")
    end
  end

  describe "embed/3" do
    test "returns {:error, _} on non-200 response" do
      mock = fn req ->
        {req, Req.Response.new(status: 500, body: %{"error" => "oops"})}
      end

      assert {:error, {:llm_proxy_error, 500, %{"error" => "oops"}}} =
               Client.embed(["text"], :document, model: @model, req_options: [adapter: mock])
    end

    test "returns {:ok, vectors} on success with 2560-dim vector" do
      vector = Enum.map(1..2560, fn _ -> 0.001 end)

      mock = fn req ->
        body = %{"data" => [%{"embedding" => vector, "index" => 0}]}
        {req, Req.Response.new(status: 200, body: body)}
      end

      assert {:ok, [result_vec]} =
               Client.embed(["hello"], :document, model: @model, req_options: [adapter: mock])

      assert length(result_vec) == 2560
    end

    test "sorts results by index when multiple texts embedded" do
      v1 = Enum.map(1..2560, fn _ -> 0.1 end)
      v2 = Enum.map(1..2560, fn _ -> 0.2 end)

      mock = fn req ->
        body = %{
          "data" => [%{"embedding" => v2, "index" => 1}, %{"embedding" => v1, "index" => 0}]
        }

        {req, Req.Response.new(status: 200, body: body)}
      end

      assert {:ok, [first, second]} =
               Client.embed(["a", "b"], :document, model: @model, req_options: [adapter: mock])

      assert hd(first) == 0.1
      assert hd(second) == 0.2
    end

    test "query mode prepends instruction prefix to each input" do
      pid = self()

      mock = fn req ->
        %{"input" => inputs} = Jason.decode!(req.body)
        send(pid, {:input, inputs})
        body = %{"data" => [%{"embedding" => Enum.map(1..2560, fn _ -> 0.0 end), "index" => 0}]}
        {req, Req.Response.new(status: 200, body: body)}
      end

      Client.embed(["my query"], :query, model: @model, req_options: [adapter: mock])

      assert_receive {:input, [prefixed]}
      assert String.starts_with?(prefixed, "Instruct:")
    end

    test "returns {:error, _} on network failure" do
      mock = fn req -> {req, %Req.TransportError{reason: :econnrefused}} end

      assert {:error, {:http_error, %Req.TransportError{reason: :econnrefused}}} =
               Client.embed(["text"], :document, model: @model, req_options: [adapter: mock])
    end

    test "returns not configured without sending a request when no model is configured" do
      mock = fn req ->
        send(self(), :unexpected_request)
        {req, Req.Response.new(status: 200, body: %{"data" => []})}
      end

      assert {:error, :embedding_model_not_configured} =
               Client.embed(["text"], :document, req_options: [adapter: mock])

      refute_received :unexpected_request
    end
  end
end
