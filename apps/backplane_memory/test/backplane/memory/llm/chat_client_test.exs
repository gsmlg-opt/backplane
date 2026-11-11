defmodule Backplane.Memory.LLM.ChatClientTest do
  use ExUnit.Case, async: false

  alias Backplane.Memory.LLM.ChatClient

  @model "test-chat-model"
  @settings_table :backplane_settings
  @tools [
    %{
      name: "write_memory",
      description: "Store a memory",
      parameters: %{"type" => "object", "properties" => %{}}
    }
  ]

  setup do
    HTTP.Test.verify_on_exit!()
    :ok
  end

  defp stub(fun) do
    HTTP.Test.stub(__MODULE__, fun)
    [http_options: [adapter: {HTTP.Test, __MODULE__}]]
  end

  defp respond(status, body) when is_binary(body), do: HTTP.Test.response(status, body)
  defp respond(status, body), do: HTTP.Test.json(body, status)

  test "posts a non-streaming chat request with tools and decodes tool calls" do
    parent = self()

    adapter = fn request ->
      send(parent, {:request, request})

      respond(200, %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "write_memory", "arguments" => ~s({"kind":"fact"})}
                },
                %{
                  "id" => "call_2",
                  "type" => "function",
                  "function" => %{"name" => "write_memory", "arguments" => "{not json"}
                }
              ]
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 4}
      })
    end

    messages = [%{"role" => "user", "content" => "hi"}]

    assert {:ok, %{content: nil, tool_calls: calls, usage: usage}} =
             ChatClient.complete(messages, @tools, [model: @model] ++ stub(adapter))

    assert calls == [
             %{id: "call_1", name: "write_memory", arguments: %{"kind" => "fact"}},
             %{id: "call_2", name: "write_memory", arguments: %{"_invalid_json" => "{not json"}}
           ]

    assert usage == %{"prompt_tokens" => 10, "completion_tokens" => 4}

    assert_received {:request, request}
    assert request.url.path == "/v1/chat/completions"
    assert HTTP.Headers.get_all(request.headers, "x-backplane-memory-capture") == ["skip"]
    assert HTTP.Headers.get_all(request.headers, "x-backplane-memory-origin") == ["agent"]

    body = Jason.decode!(IO.iodata_to_binary(request.body))
    assert body["stream"] == false
    assert body["model"] == @model
    assert body["tool_choice"] == "auto"
    assert body["messages"] == messages

    assert body["tools"] == [
             %{
               "type" => "function",
               "function" => %{
                 "name" => "write_memory",
                 "description" => "Store a memory",
                 "parameters" => %{"type" => "object", "properties" => %{}}
               }
             }
           ]
  end

  test "returns plain content without tool calls" do
    adapter = fn _request ->
      respond(200, %{"choices" => [%{"message" => %{"content" => "done"}}]})
    end

    assert {:ok, %{content: "done", tool_calls: [], usage: nil}} =
             ChatClient.complete([], @tools, [model: @model] ++ stub(adapter))
  end

  test "maps HTTP errors to a readable string naming the model and status" do
    adapter = fn _request ->
      respond(400, %{"error" => %{"message" => "tools are not supported"}})
    end

    assert {:error, message} = ChatClient.complete([], @tools, [model: @model] ++ stub(adapter))
    assert message =~ "LLM proxy returned HTTP 400 for model #{@model}: "
    assert message =~ "tools are not supported"
  end

  test "truncates long HTTP error bodies to 300 characters" do
    body = String.duplicate("x", 1_000)
    adapter = fn _request -> respond(422, body) end

    assert {:error, message} = ChatClient.complete([], @tools, [model: @model] ++ stub(adapter))

    assert message ==
             "LLM proxy returned HTTP 422 for model #{@model}: " <> String.slice(body, 0, 300)
  end

  test "reports a response without choices" do
    adapter = fn _request -> respond(200, %{"choices" => []}) end

    assert {:error, "LLM response for model #{@model} had no choices"} ==
             ChatClient.complete([], @tools, [model: @model] ++ stub(adapter))
  end

  test "reports a malformed tool call instead of passing it on" do
    adapter = fn _request ->
      respond(200, %{
        "choices" => [%{"message" => %{"tool_calls" => [%{"function" => %{"name" => "x"}}]}}]
      })
    end

    assert {:error, "LLM response for model #{@model} had a malformed tool call"} ==
             ChatClient.complete([], @tools, [model: @model] ++ stub(adapter))
  end

  test "reports an unreachable proxy" do
    adapter = fn _request -> HTTP.Test.transport_error(:econnrefused) end

    assert {:error, "LLM proxy unreachable: " <> reason} =
             ChatClient.complete([], @tools, [model: @model] ++ stub(adapter))

    assert reason =~ "connection refused"
  end

  test "returns the not-configured error when no model is set" do
    rows = :ets.lookup(@settings_table, "memory.llm_model")
    :ets.delete(@settings_table, "memory.llm_model")

    on_exit(fn -> if rows != [], do: :ets.insert(@settings_table, rows) end)

    adapter = fn _request -> flunk("request sent without a model") end

    assert {:error, "memory.llm_model not configured"} ==
             ChatClient.complete([], @tools, stub(adapter))
  end
end
