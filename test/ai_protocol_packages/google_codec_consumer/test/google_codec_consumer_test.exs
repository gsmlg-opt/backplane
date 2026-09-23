defmodule GoogleCodecConsumerTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{Codec, ContentBlock, Request}

  @origin [
    profile: "google-primary",
    endpoint: "https://generativelanguage.googleapis.com",
    account: "tenant-a",
    model: "gemini-2.5-flash",
    credential_scope: "projects/example",
    credential_version: "7"
  ]

  test "packaged codec completes a signed structured tool continuation" do
    response = %{
      "modelVersion" => "gemini-2.5-flash",
      "candidates" => [
        %{
          "finishReason" => "STOP",
          "content" => %{
            "parts" => [
              %{
                "functionCall" => %{
                  "name" => "lookup",
                  "args" => %{"query" => "weather"}
                },
                "thoughtSignature" => "opaque-signature"
              }
            ]
          }
        }
      ]
    }

    assert {:ok, decoded} = Codec.decode_response(:google, 200, [], response, @origin)

    assert [
             %ContentBlock{type: :tool_call, tool_call: %{native_id: nil} = call},
             %ContentBlock{type: :provider_state}
           ] = decoded.output

    structured_result = %{"temperature" => 21.5, "units" => "celsius"}

    {:ok, continuation} =
      Request.new(%{
        model: "gemini-2.5-flash",
        input: [
          %{role: :assistant, content: decoded.output},
          %{
            role: :tool,
            tool_call_id: call.id,
            status: :success,
            content: [%{type: :text, text: "structured result"}],
            extensions: %{"google::function_response" => structured_result}
          }
        ]
      })

    assert {:ok, %{target: target, body: body}} =
             Codec.encode_rest_request(:google, continuation, @origin)

    assert target == %{
             operation: :generate_content,
             model: "gemini-2.5-flash",
             stream: false
           }

    assert [model_content, result_content] = body["contents"]

    assert [
             %{
               "functionCall" => %{"name" => "lookup"},
               "thoughtSignature" => "opaque-signature"
             }
           ] = model_content["parts"]

    assert [
             %{
               "functionResponse" => %{
                 "name" => "lookup",
                 "response" => ^structured_result
               }
             }
           ] = result_content["parts"]
  end
end
