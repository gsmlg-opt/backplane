defmodule Backplane.AiProtocol.OpenAIResponsesWebSocketTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{Error, OpenAIResponsesWebSocket, Request}

  test "native create and continuation retain tools, lane IDs and unknown provider fields" do
    params = %{
      "model" => "provider-model",
      "input" => [%{"type" => "function_call_output", "call_id" => "call_1", "output" => "done"}],
      "previous_response_id" => "resp_1",
      "stream_id" => "tools",
      "generate" => false,
      "store" => false,
      "future_field" => %{"enabled" => true}
    }

    assert {:ok, json} = OpenAIResponsesWebSocket.encode_create(params)
    assert Jason.decode!(json) == Map.put(params, "type", "response.create")
    refute String.starts_with?(json, "data:")
  end

  test "canonical requests reuse Responses encoding without HTTP stream or a custom envelope" do
    assert {:ok, request} =
             Request.new(%{
               model: "model",
               input: [%{role: :user, content: [%{type: :text, text: "hello"}]}]
             })

    assert {:ok, json} = OpenAIResponsesWebSocket.encode_request(request, stream: true)
    decoded = Jason.decode!(json)
    assert decoded["type"] == "response.create"
    assert decoded["model"] == "model"

    assert [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "hello"}]}] =
             decoded["input"]

    refute Map.has_key?(decoded, "stream")
    refute Map.has_key?(decoded, "protocol")
  end

  test "rejects HTTP-only controls and does not invent cancel or steering requests" do
    for attrs <- [
          %{"stream" => true},
          %{"background" => false},
          %{"type" => "response.cancel"},
          %{"type" => "response.steer"},
          %{"model" => ""}
        ] do
      assert {:error, %Error{}} =
               OpenAIResponsesWebSocket.encode_create(Map.merge(%{"model" => "m"}, attrs))
    end

    assert {:error, %Error{}} = OpenAIResponsesWebSocket.encode_create(%{model: "m"})

    assert {:error, %Error{}} =
             OpenAIResponsesWebSocket.encode_create(%{
               "model" => "m",
               "input" => [%{role: "user"}]
             })
  end

  test "each message is independent, preserving interleaved responses and future event types" do
    for event <- [
          %{
            "type" => "response.output_text.delta",
            "response_id" => "r1",
            "stream_id" => "a",
            "delta" => "a"
          },
          %{"type" => "response.completed", "response" => %{"id" => "r2"}, "stream_id" => "b"},
          %{"type" => "response.future", "response_id" => "r1", "opaque" => [1, nil]},
          %{"type" => "response.failed", "response" => %{"id" => "r1"}},
          %{"type" => "error", "error" => %{"code" => "server_error"}}
        ] do
      assert {:ok, ^event} = OpenAIResponsesWebSocket.decode_event(Jason.encode!(event))
    end
  end

  test "rejects fragments, concatenated messages, SSE, invalid UTF-8 and non-event JSON" do
    for payload <- [
          "{",
          "{}{}",
          "data: {}\n\n",
          <<255>>,
          "[]",
          "null",
          "{}",
          ~s({"type":1}),
          ~s({"type":""})
        ] do
      assert {:error, %Error{}} = OpenAIResponsesWebSocket.decode_event(payload)
    end
  end

  test "encoded and structural budgets apply in both directions" do
    event = %{"type" => "response.created", "response" => %{"id" => "r1"}}
    json = Jason.encode!(event)

    assert {:ok, ^event} =
             OpenAIResponsesWebSocket.decode_event(json, max_encoded_bytes: byte_size(json))

    assert {:error, %Error{}} =
             OpenAIResponsesWebSocket.decode_event(json, max_encoded_bytes: byte_size(json) - 1)

    assert {:error, %Error{}} =
             OpenAIResponsesWebSocket.decode_event(json, limits: %{max_depth: 1})

    assert {:error, %Error{}} =
             OpenAIResponsesWebSocket.encode_create(%{"model" => "m"}, max_encoded_bytes: 8)

    assert {:error, %Error{}} =
             OpenAIResponsesWebSocket.encode_create(%{"model" => "m", "input" => [1, 2]},
               limits: %{max_list_length: 1}
             )
  end

  test "invalid limits return errors without disabling bounds" do
    for opts <- [
          [max_encoded_bytes: 0],
          [limits: %{max_depth: -1}],
          [limits: %{unknown: 1}],
          [limits: nil],
          %{}
        ] do
      assert {:error, %Error{}} =
               OpenAIResponsesWebSocket.decode_event(~s({"type":"error"}), opts)

      assert {:error, %Error{}} = OpenAIResponsesWebSocket.encode_create(%{"model" => "m"}, opts)
    end
  end
end
