defmodule Backplane.AiProtocol.ResponsesContentTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{Codec, Error, Request, Serialization}

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg=="
  @uri "data:image/png;base64," <> @png

  test "encodes an ordered user image attachment after reloading canonical history" do
    for data <- [@png, @uri], detail <- [nil, "low", "original"] do
      image = %{"data" => data, "mime_type" => "image/png"}
      image = if detail, do: Map.put(image, "detail", detail), else: image
      request = user_image_request(image)

      assert {:ok, encoded} = Serialization.to_json(request)
      assert {:ok, %{"input" => [%{"content" => content}]}} = Serialization.from_json(encoded)

      assert {:ok, restored} =
               Request.new(%{model: "fixture", input: [%{role: :user, content: content}]})

      assert {:ok, wire} = Codec.encode_request(:openai_responses, restored)
      expected_detail = detail || "auto"

      assert [
               %{
                 "type" => "message",
                 "role" => "user",
                 "content" => [
                   %{"type" => "input_text", "text" => "before"},
                   %{"type" => "input_image", "image_url" => @uri, "detail" => ^expected_detail},
                   %{"type" => "input_text", "text" => "after"}
                 ]
               }
             ] = wire["input"]
    end
  end

  test "rejects malformed and unsupported user image forms" do
    for image <- [
          %{"data" => "!", "mime_type" => "image/png"},
          %{"data" => @uri, "mime_type" => "image/jpeg"},
          %{"data" => @png, "mime_type" => "image/svg+xml"},
          %{"data" => @png, "mime_type" => "image/png", "detail" => "unknown"}
        ] do
      assert {:error, %Error{kind: :incompatible}} =
               Codec.encode_request(:openai_responses, user_image_request(image))
    end
  end

  test "projects reasoning deltas and reaches the terminal event with usage" do
    state = Codec.stream_new(:openai_responses)
    assert {:ok, state, []} = feed(state, %{"type" => "response.metadata"})

    assert {:ok, state, [%{type: :reasoning_delta, text: "consider", index: 0}]} =
             feed(state, %{
               "type" => "response.reasoning_text.delta",
               "delta" => "consider",
               "output_index" => 0
             })

    assert {:ok, state, []} =
             feed(state, %{"type" => "response.reasoning_text.done", "text" => "consider"})

    assert {:ok, state, [%{type: :text_delta, text: "answer"}]} =
             feed(state, %{"type" => "response.output_text.delta", "delta" => "answer"})

    assert {:ok, _, [%{type: :usage, usage: %{reasoning_tokens: 2}}, %{type: :terminal}]} =
             feed(state, %{"type" => "response.completed", "response" => response()})

    assert {:ok, decoded} = Codec.decode_response(:openai_responses, 200, [], response())

    assert [%{type: :reasoning, data: "consider"}, %{type: :text, text: "answer"}] =
             decoded.output
  end

  test "rejects unknown and malformed reasoning events and items" do
    for event <- [
          %{"type" => "response.future"},
          %{"type" => "response.metadata", "metadata" => []},
          %{"type" => "response.reasoning_text.delta", "delta" => 1},
          %{"type" => "response.reasoning_text.done"}
        ] do
      assert {:error, %Error{kind: :invalid_request}, _} =
               feed(Codec.stream_new(:openai_responses), event)
    end

    document = put_in(response(), ["output", Access.at(0), "content"], [%{"type" => "future"}])

    assert {:error, %Error{kind: :incompatible}} =
             Codec.decode_response(:openai_responses, 200, [], document)
  end

  defp user_image_request(image) do
    {:ok, request} =
      Request.new(%{
        model: "fixture",
        input: [
          %{
            role: :user,
            content: [
              %{type: :text, text: "before"},
              %{type: :image, data: image},
              %{type: :text, text: "after"}
            ]
          }
        ]
      })

    request
  end

  defp response do
    %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "reasoning",
          "content" => [%{"type" => "reasoning_text", "text" => "consider"}]
        },
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "answer"}]}
      ],
      "usage" => %{
        "input_tokens" => 1,
        "output_tokens" => 3,
        "total_tokens" => 4,
        "output_tokens_details" => %{"reasoning_tokens" => 2}
      }
    }
  end

  defp feed(state, event),
    do: Codec.stream_feed(:openai_responses, state, "data: #{Formata.JSON.encode!(event)}\n\n")
end
