defmodule AntigravityNativeConsumerTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.Antigravity

  test "packaged API completes the native account and tool lifecycle" do
    assert {:ok, bootstrap} =
             Antigravity.build_request(:load_code_assist, %{}, project: "project-example")

    assert bootstrap.body["metadata"]["duetProject"] == "project-example"
    refute Enum.any?(bootstrap.headers, fn {name, _value} -> name == "authorization" end)

    assert {:ok, enrollment} =
             Antigravity.build_request(:onboard_user, %{"tierId" => "standard-tier"},
               project: "project-example"
             )

    assert enrollment.body["metadata"]["duetProject"] == "project-example"
    assert Antigravity.onboarding_status(%{"done" => false}) == :pending

    done = %{
      "done" => true,
      "response" => %{"cloudaicompanionProject" => %{"id" => "project-example"}}
    }

    assert Antigravity.onboarding_status(done) == {:complete, "project-example"}

    model_document = %{
      "models" => %{
        "gemini-example" => %{
          "quotaInfo" => %{"remainingFraction" => 0.5},
          "nativeMetadata" => %{"keep" => true}
        }
      }
    }

    assert {:ok, catalog} =
             Antigravity.build_request(:fetch_available_models, %{}, project: "project-example")

    assert catalog.body == %{"project" => "project-example"}
    assert Antigravity.models(model_document) == model_document["models"]

    signed_tool_call = %{
      "role" => "model",
      "parts" => [
        %{
          "functionCall" => %{"name" => "lookup", "args" => %{"city" => "Shanghai"}},
          "thoughtSignature" => "opaque-signature"
        }
      ]
    }

    tool_result = %{
      "role" => "user",
      "parts" => [
        %{
          "functionResponse" => %{
            "name" => "lookup",
            "response" => %{"temperature" => 21, "units" => "celsius"}
          }
        }
      ]
    }

    inner = %{
      "contents" => [signed_tool_call, tool_result],
      "candidateCount" => 2,
      "nativeToolConfig" => %{"keep" => true}
    }

    assert {:ok, generation} =
             Antigravity.build_request(:generate_content, %{"request" => inner},
               project: "project-example",
               model: "gemini-example",
               session_id: "session-example",
               request_id: "request-example"
             )

    assert generation.body["request"] == Map.put(inner, "sessionId", "session-example")

    response = %{
      "response" => %{
        "candidates" => [
          %{"index" => 0, "content" => signed_tool_call, "finishReason" => "STOP"},
          %{"index" => 1, "content" => %{"parts" => [%{"text" => "alternate"}]}}
        ],
        "unknown" => [1, 2, 3]
      }
    }

    assert {:ok, ^response} =
             Antigravity.decode_response(:generate_content, 200, [], Jason.encode!(response))

    wire = "data: " <> Jason.encode!(response) <> "\n\n"

    {stream, documents} =
      wire
      |> :binary.bin_to_list()
      |> Enum.reduce({Antigravity.stream_new(), []}, fn byte, {stream, documents} ->
        assert {:ok, stream, decoded} = Antigravity.stream_feed(stream, <<byte>>)
        {stream, documents ++ decoded}
      end)

    assert [^response] = documents
    assert {:ok, _stream, []} = Antigravity.stream_finish(stream, :eof)
  end
end
