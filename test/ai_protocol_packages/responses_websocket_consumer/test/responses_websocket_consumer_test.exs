defmodule ResponsesWebsocketConsumerTest do
  use ExUnit.Case
  alias Backplane.AiProtocol.OpenAIResponsesWebSocket

  test "standalone consumer can prepare a native message and read provider events" do
    assert {:ok, message} =
             OpenAIResponsesWebSocket.encode_create(%{
               "model" => "model",
               "stream_id" => "main",
               "input" => "Hello"
             })

    assert %{"type" => "response.create", "input" => "Hello"} = Jason.decode!(message)

    assert {:ok, %{"response" => %{"id" => "r1"}}} =
             OpenAIResponsesWebSocket.decode_event(
               ~s({"type":"response.completed","response":{"id":"r1"}})
             )

    refute Code.ensure_loaded?(Backplane.Repo)
    refute Code.ensure_loaded?(Phoenix.Endpoint)
    refute Code.ensure_loaded?(HTTP.WebSocket)
  end
end
