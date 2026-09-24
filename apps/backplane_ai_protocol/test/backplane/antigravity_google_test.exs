defmodule Backplane.AiProtocol.Antigravity.GoogleTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.Antigravity.Google
  alias Backplane.AiProtocol.Error

  test "wraps supported Gemini request fields without changing native content" do
    body = %{
      "contents" => [
        %{
          "role" => "model",
          "parts" => [%{"functionCall" => %{"name" => "f"}, "thoughtSignature" => "sig"}]
        },
        %{
          "role" => "user",
          "parts" => [%{"functionResponse" => %{"name" => "f", "response" => %{"ok" => true}}}]
        }
      ],
      "tools" => [%{"functionDeclarations" => [%{"name" => "f"}]}],
      "generationConfig" => %{"temperature" => 0.2},
      "systemInstruction" => %{"parts" => [%{"text" => "system"}]},
      "labels" => %{"client" => "agy"},
      "sessionId" => "agy-session"
    }

    assert {:ok, %{"request" => ^body}} = Google.encode_request(body)
  end

  test "rejects provider-owned and unknown request fields" do
    for body <- [
          %{"contents" => [], "project" => "caller-project"},
          %{"contents" => [], "model" => "caller-model"},
          %{"contents" => [], "unknown" => true}
        ] do
      assert {:error, %Error{kind: :invalid_request}} = Google.encode_request(body)
    end
  end

  test "unwraps successful response and leaves errors untouched" do
    response = %{
      "candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}}],
      "usageMetadata" => %{"totalTokenCount" => 3}
    }

    assert {:ok, encoded} = Google.map_response(200, Jason.encode!(%{"response" => response}))
    assert Jason.decode!(encoded) == response

    error = Jason.encode!(%{"error" => %{"code" => 429, "message" => "quota"}})
    assert {:ok, ^error} = Google.map_response(429, error)
    assert {:error, %Error{kind: :invalid_request}} = Google.map_response(200, ~s({"bad":true}))
  end

  test "builds text-only countTokens requests from direct and nested Gemini shapes" do
    contents = [
      %{"role" => "user", "parts" => [%{"text" => "Hello world"}, %{"text" => ""}]},
      %{"parts" => []}
    ]

    assert {:ok, %{"request" => request}} =
             Google.encode_count_request(%{"contents" => contents}, "alias", "gemini-resolved")

    assert request == %{"model" => "gemini-resolved", "contents" => contents}

    assert {:ok, %{"request" => ^request}} =
             Google.encode_count_request(
               %{
                 "generateContentRequest" => %{
                   "model" => "models/gemini-resolved",
                   "contents" => contents
                 }
               },
               "alias",
               "gemini-resolved"
             )
  end

  test "classifies malformed and unsupported countTokens requests" do
    for body <- [
          [],
          %{},
          %{"contents" => "text"},
          %{"contents" => [%{"role" => 1, "parts" => []}]},
          %{"contents" => [%{"role" => "", "parts" => []}]},
          %{"contents" => [%{"parts" => "text"}]},
          %{"contents" => [%{"parts" => [%{"text" => 1}]}]},
          %{"contents" => [], "generateContentRequest" => %{"contents" => []}},
          %{"generateContentRequest" => []}
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               Google.encode_count_request(body, "alias", "gemini-resolved")
    end

    for body <- [
          %{"contents" => [], "systemInstruction" => %{}},
          %{"contents" => [], "tools" => []},
          %{"contents" => [], "toolConfig" => %{}},
          %{"contents" => [], "cachedContent" => "cached"},
          %{"contents" => [], "generationConfig" => %{}},
          %{"contents" => [%{"parts" => [%{"inlineData" => %{}}]}]},
          %{"contents" => [%{"parts" => [%{"functionCall" => %{}}]}]},
          %{"contents" => [%{"parts" => [%{"text" => "ok", "thought" => true}]}]},
          %{"generateContentRequest" => %{"contents" => [], "tools" => []}}
        ] do
      assert {:error, %Error{kind: :incompatible}} =
               Google.encode_count_request(body, "alias", "gemini-resolved")
    end

    for body <- [
          %{"contents" => [], "project" => "caller"},
          %{"contents" => [], "model" => "caller-model"},
          %{"contents" => [], "authorization" => "secret"},
          %{"generateContentRequest" => %{"contents" => [], "project" => "caller"}}
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               Google.encode_count_request(body, "alias", "gemini-resolved")
    end

    assert {:error, %Error{kind: :invalid_request}} =
             Google.encode_count_request(
               %{
                 "generateContentRequest" => %{
                   "model" => "models/other",
                   "contents" => []
                 }
               },
               "alias",
               "gemini-resolved"
             )
  end

  test "validates direct Antigravity countTokens responses" do
    body = Jason.encode!(%{"totalTokens" => 3, "cachedContentTokenCount" => 1})
    assert {:ok, ^body} = Google.map_count_response(200, body)

    assert {:ok, zero_body} = Google.map_count_response(200, ~s({}))
    assert Jason.decode!(zero_body) == %{"totalTokens" => 0}

    error = Jason.encode!(%{"error" => %{"code" => 429}})
    assert {:ok, ^error} = Google.map_count_response(429, error)

    for body <- [
          ~s({"unexpected":true}),
          ~s({"totalTokens":-1}),
          ~s({"totalTokens":"2"}),
          ~s({"totalTokens":null}),
          "invalid"
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               Google.map_count_response(200, body)
    end
  end

  test "maps fragmented native SSE incrementally and preserves signatures and usage" do
    response = %{
      "candidates" => [
        %{
          "finishReason" => "STOP",
          "content" => %{
            "parts" => [
              %{
                "functionCall" => %{"name" => "lookup", "args" => %{}},
                "thoughtSignature" => "sig"
              }
            ]
          }
        }
      ],
      "usageMetadata" => %{"totalTokenCount" => 7}
    }

    frame = "data: " <> Jason.encode!(%{"response" => response}) <> "\n\n"
    {left, right} = String.split_at(frame, div(byte_size(frame), 2))
    state = Google.stream_new()
    assert {:ok, state, []} = Google.stream_feed(state, left)
    assert {:ok, state, [mapped]} = Google.stream_feed(state, right)
    assert "data: " <> json = String.trim(mapped)
    assert Jason.decode!(json) == response
    assert {:ok, _state, []} = Google.stream_finish(state, :eof)
  end

  test "rejects malformed and truncated streams instead of completing successfully" do
    state = Google.stream_new()
    assert {:error, %Error{}, _state} = Google.stream_feed(state, "data: {broken}\n\n")

    state = Google.stream_new()
    assert {:ok, state, []} = Google.stream_feed(state, "data: {\"response\":")
    assert {:error, %Error{}, _state} = Google.stream_finish(state, :eof)

    state = Google.stream_new()
    assert {:error, %Error{}, _state} = Google.stream_feed(state, "data: {}\n\n")
  end

  test "requires terminal Gemini evidence while allowing trailing usage" do
    state = Google.stream_new()
    assert {:error, %Error{}, _state} = Google.stream_finish(state, :eof)

    nonterminal = %{"response" => %{"candidates" => [%{"content" => %{"parts" => []}}]}}
    state = Google.stream_new()
    assert {:ok, state, [_]} = Google.stream_feed(state, frame(nonterminal))
    assert {:error, %Error{}, _state} = Google.stream_finish(state, :eof)

    terminal = %{
      "response" => %{
        "candidates" => [
          %{
            "finishReason" => "STOP",
            "content" => %{"parts" => [%{"functionCall" => %{"name" => "lookup"}}]}
          }
        ]
      }
    }

    usage = %{"response" => %{"usageMetadata" => %{"totalTokenCount" => 9}}}
    state = Google.stream_new()
    assert {:ok, state, [_]} = Google.stream_feed(state, frame(terminal))
    assert {:ok, state, [_]} = Google.stream_feed(state, frame(usage))
    assert {:ok, _state, []} = Google.stream_finish(state, :eof)

    blocked = %{"response" => %{"promptFeedback" => %{"blockReason" => "SAFETY"}}}
    state = Google.stream_new()
    assert {:ok, state, [_]} = Google.stream_feed(state, frame(blocked))
    assert {:ok, _state, []} = Google.stream_finish(state, :eof)
  end

  defp frame(document), do: "data: " <> Jason.encode!(document) <> "\n\n"
end
