defmodule Backplane.AiProtocol.AntigravityTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{Antigravity, Error}

  @fixture_path Path.expand("../fixtures/antigravity/native_lifecycle.json", __DIR__)

  test "exposes exactly the five evidenced native RPC descriptors" do
    assert [
             %{operation: :load_code_assist, rpc: "loadCodeAssist", streaming?: false},
             %{operation: :onboard_user, rpc: "onboardUser", streaming?: false},
             %{
               operation: :fetch_available_models,
               rpc: "fetchAvailableModels",
               streaming?: false
             },
             %{operation: :generate_content, rpc: "generateContent", streaming?: false},
             %{
               operation: :stream_generate_content,
               rpc: "streamGenerateContent",
               streaming?: true
             }
           ] = Antigravity.operations()

    for {rpc, operation} <- [
          {"loadCodeAssist", :load_code_assist},
          {"onboardUser", :onboard_user},
          {"fetchAvailableModels", :fetch_available_models},
          {"generateContent", :generate_content},
          {"streamGenerateContent", :stream_generate_content}
        ] do
      assert {:ok, ^operation} = Antigravity.operation(rpc)
    end

    assert {:error, %Error{kind: :invalid_request}} = Antigravity.operation("countTokens")
    assert {:error, %Error{kind: :invalid_request}} = Antigravity.operation("GenerateContent")
  end

  test "builds bootstrap, onboarding and model catalog requests without credentials" do
    assert {:ok, bootstrap} =
             Antigravity.build_request(
               :load_code_assist,
               %{
                 "metadata" => %{"platform" => 7, "native" => %{"keep" => true}}
               },
               project: "configured-project",
               user_agent: "Backplane/1"
             )

    assert bootstrap.path == "/v1internal:loadCodeAssist"
    assert bootstrap.query == ""

    assert bootstrap.body == %{
             "metadata" => %{
               "ideType" => 9,
               "pluginType" => 2,
               "platform" => 7,
               "duetProject" => "configured-project",
               "native" => %{"keep" => true}
             },
             "mode" => 1
           }

    assert {"user-agent", "Backplane/1"} in bootstrap.headers

    refute Enum.any?(bootstrap.headers, fn {name, _} ->
             String.downcase(name) == "authorization"
           end)

    refute Enum.any?(bootstrap.headers, fn {name, _} -> name == "x-goog-api-client" end)

    assert {:ok, onboarding} =
             Antigravity.build_request(:onboard_user, %{"tierId" => "standard-tier"},
               project: "configured-project"
             )

    assert onboarding.body["metadata"]["duetProject"] == "configured-project"
    refute Map.has_key?(onboarding.body, "project")
    refute Map.has_key?(onboarding.body, "cloudaicompanionProject")

    assert {:ok, catalog} =
             Antigravity.build_request(:fetch_available_models, %{"opaque" => [1, 2]},
               project: "configured-project"
             )

    assert catalog.body == %{
             "project" => "configured-project",
             "opaque" => [1, 2]
           }
  end

  test "generation binds trusted routing fields and preserves the inner native request" do
    native_request = %{
      "contents" => [
        %{
          "role" => "model",
          "parts" => [
            %{
              "functionCall" => %{"name" => "lookup", "args" => %{"city" => "Shanghai"}},
              "thoughtSignature" => "opaque-signature"
            }
          ]
        },
        %{
          "role" => "user",
          "parts" => [
            %{
              "functionResponse" => %{
                "name" => "lookup",
                "response" => %{"temperature" => 21}
              }
            }
          ]
        }
      ],
      "candidateCount" => 2,
      "unknownNativeField" => %{"keep" => true}
    }

    assert {:ok, request} =
             Antigravity.build_request(
               :stream_generate_content,
               %{"request" => native_request},
               project: "project-a",
               model: "gemini-example",
               session_id: "session-a",
               request_id: "request-a",
               user_agent: "Backplane/1",
               client_version: "1.2.3"
             )

    assert request.path == "/v1internal:streamGenerateContent"
    assert request.query == "alt=sse"
    assert request.body["project"] == "project-a"
    assert request.body["model"] == "gemini-example"
    assert request.body["requestId"] == "request-a"
    assert request.body["userAgent"] == "antigravity"
    assert request.body["requestType"] == "agent"
    assert request.body["request"] == Map.put(native_request, "sessionId", "session-a")
    assert {"x-machine-session-id", "session-a"} in request.headers
    assert {"user-agent", "Backplane/1"} in request.headers
    assert {"x-client-version", "1.2.3"} in request.headers
  end

  test "rejects missing and conflicting bindings plus unsafe identifiers" do
    body = %{"model" => "gemini-example", "request" => %{}}

    assert {:error, %Error{message: message}} =
             Antigravity.build_request(:generate_content, body)

    assert message =~ "project"

    assert {:error, %Error{message: message}} =
             Antigravity.build_request(:generate_content, body,
               project: "trusted-project",
               model: "other-model"
             )

    assert message =~ "model conflicts"

    for opts <- [
          [project: "project-a", model: "models/gemini"],
          [project: "project-a\r\nx-evil: yes", model: "gemini-example"],
          [project: "project-a", model: "gemini-example", session_id: "s\r\nx: y"],
          [project: "project-a", model: "gemini-example", request_id: String.duplicate("x", 257)]
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               Antigravity.build_request(:generate_content, %{"request" => %{}}, opts)
    end

    assert {:error, %Error{kind: :invalid_request}} =
             Antigravity.build_request(
               :generate_content,
               %{"model" => "gemini-example", "requestId" => "bad\nheader", "request" => %{}},
               project: "project-a"
             )

    assert {:error, %Error{kind: :invalid_request}} =
             Antigravity.build_request(
               :load_code_assist,
               %{"metadata" => %{"duetProject" => "caller-project"}},
               project: "trusted-project"
             )
  end

  test "decodes native documents unchanged and exposes lifecycle fields" do
    fixtures = fixture()

    for {operation, key} <- [
          {:load_code_assist, "loadCodeAssist"},
          {:onboard_user, "onboardPending"},
          {:onboard_user, "onboardDone"},
          {:fetch_available_models, "models"},
          {:generate_content, "toolResponse"}
        ] do
      document = fixtures[key]

      assert {:ok, ^document} =
               Antigravity.decode_response(operation, 200, [], Jason.encode!(document))
    end

    assert Antigravity.project(fixtures["loadCodeAssist"]) == "example-project"
    assert Antigravity.onboarding_status(fixtures["onboardPending"]) == :pending

    assert Antigravity.onboarding_status(fixtures["onboardDone"]) ==
             {:complete, "example-project"}

    assert %{"gemini-example" => model} = Antigravity.models(fixtures["models"])
    assert model["unknownNativeField"] == %{"keep" => true}
    assert Antigravity.project(%{}) == nil
    assert Antigravity.models(%{}) == nil
  end

  test "sanitizes provider errors while retaining HTTP and retry metadata" do
    statuses = [400, 401, 403, 429, 500, 503]

    for status <- statuses do
      body =
        Jason.encode!(%{"error" => %{"status" => "RESOURCE_EXHAUSTED", "message" => "secret"}})

      assert {:error, %Error{} = error} =
               Antigravity.decode_response(
                 :generate_content,
                 status,
                 [{"Retry-After", "3"}],
                 body
               )

      assert error.http_status == status
      assert error.provider_code == "RESOURCE_EXHAUSTED"
      assert error.retry_after_ms == 3_000
      refute inspect(error) =~ "secret"
    end

    assert {:error, %Error{http_status: 429, retry_after_ms: 5_000, provider_code: nil}} =
             Antigravity.decode_response(
               :generate_content,
               429,
               [{"retry-after", "Sun, 06 Nov 1994 08:49:42 GMT"}],
               "not-json",
               now_unix: 784_111_777
             )

    assert {:error, %Error{provider_code: nil} = error} =
             Antigravity.decode_response(
               :generate_content,
               400,
               [],
               Jason.encode!(%{"error" => %{"status" => "secret account data"}})
             )

    refute inspect(error) =~ "secret account data"
  end

  test "malformed nested project documents do not raise or invent a project" do
    for response <- ["invalid", ["invalid"], 42, true, nil, %{"cloudaicompanionProject" => []}] do
      document = %{"done" => true, "response" => response}
      assert Antigravity.project(document) == nil
      assert {:error, %Error{kind: :invalid_request}} = Antigravity.onboarding_status(document)
    end
  end

  test "native stream preserves envelopes across arbitrary fragmentation and marks error frames" do
    document = fixture()["toolResponse"]
    wire = "data: " <> Jason.encode!(document) <> "\n\n"

    {state, documents} =
      wire
      |> :binary.bin_to_list()
      |> Enum.reduce({Antigravity.stream_new(), []}, fn byte, {state, documents} ->
        assert {:ok, state, decoded} = Antigravity.stream_feed(state, <<byte>>)
        {state, documents ++ decoded}
      end)

    assert [^document] = documents
    assert {:ok, state, []} = Antigravity.stream_finish(state, :eof)
    assert state.terminal == :eof

    error_document = %{"error" => %{"status" => "RESOURCE_EXHAUSTED"}, "opaque" => true}
    error_wire = "data: " <> Jason.encode!(error_document) <> "\n\n"

    assert {:ok, error_state, [^error_document]} =
             Antigravity.stream_feed(Antigravity.stream_new(), error_wire)

    assert error_state.protocol_terminal == :failed

    assert {:error, %Error{kind: :cancelled}, cancelled} =
             Antigravity.stream_finish(Antigravity.stream_new(), :cancelled)

    assert cancelled.terminal == :cancelled
  end

  test "native stream bounds malformed, oversized and excess events without DONE synthesis" do
    assert {:error, %Error{}, _state} =
             Antigravity.stream_feed(Antigravity.stream_new(), "data: {bad}\n\n")

    assert {:error, %Error{}, _state} =
             Antigravity.stream_feed(
               Antigravity.stream_new(max_total_bytes: 8),
               "data: too large\n\n"
             )

    state = Antigravity.stream_new(max_events: 1)

    assert {:error, %Error{}, _state} =
             Antigravity.stream_feed(state, "data: {}\n\ndata: {}\n\n")

    assert {:error, %Error{}, _state} =
             Antigravity.stream_feed(Antigravity.stream_new(), "data: [DONE]\n\n")
  end

  defp fixture do
    @fixture_path
    |> File.read!()
    |> Jason.decode!()
  end
end
