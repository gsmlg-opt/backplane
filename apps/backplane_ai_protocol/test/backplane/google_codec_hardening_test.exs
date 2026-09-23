defmodule Backplane.AiProtocol.GoogleCodecHardeningTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{Codec, ContentBlock, Error, Request, StreamEvent}

  @origin [
    profile: "google-primary",
    endpoint: "https://generativelanguage.googleapis.com",
    account: "tenant-a",
    model: "gemini-2.5-flash",
    credential_scope: "projects/example",
    credential_version: "7"
  ]

  test "REST request separates transport target from the official body shape" do
    {:ok, request} =
      Request.new(%{
        model: "gemini-2.5-flash",
        input: [%{role: :user, content: [%{type: :text, text: "hello"}]}],
        settings: %{temperature: 0.2, max_output_tokens: 64},
        output_constraints: %{response_modalities: ["TEXT"]}
      })

    assert {:ok,
            %{
              target: %{operation: :generate_content, model: "gemini-2.5-flash", stream: true},
              body: body
            }} = Codec.encode_rest_request(:google, request, stream: true)

    refute Map.has_key?(body, "model")
    refute Map.has_key?(body, "stream")

    assert body["generationConfig"] == %{
             "temperature" => 0.2,
             "maxOutputTokens" => 64,
             "responseModalities" => ["TEXT"]
           }

    assert {:ok, legacy} = Codec.encode_request(:google, request, stream: true)
    assert legacy == Map.merge(body, %{"model" => "gemini-2.5-flash", "stream" => true})
  end

  test "settings reject unknown fields and canonical candidate or modality loss" do
    for {field, value} <- [unknown: true, candidate_count: 2, response_modalities: ["AUDIO"]] do
      attrs =
        if field == :response_modalities,
          do: %{output_constraints: %{field => value}},
          else: %{settings: %{field => value}}

      {:ok, request} = Request.new(Map.merge(%{model: "m", input: []}, attrs))

      assert {:error,
              %Error{
                kind: :incompatible,
                compatibility: %{"field" => diagnostic_field}
              }} = Codec.encode_rest_request(:google, request)

      assert String.ends_with?(diagnostic_field, Atom.to_string(field))
    end
  end

  test "signed same-name tool calls replay exact parts and structured results by native ID" do
    response = %{
      "modelVersion" => "gemini-2.5-flash",
      "candidates" => [
        %{
          "index" => 0,
          "finishReason" => "STOP",
          "content" => %{
            "role" => "model",
            "parts" => [
              %{
                "functionCall" => %{
                  "id" => "native-a",
                  "name" => "lookup",
                  "args" => %{"q" => "alpha"}
                },
                "thoughtSignature" => "sig-a"
              },
              %{
                "functionCall" => %{
                  "id" => "native-b",
                  "name" => "lookup",
                  "args" => %{"q" => "beta"}
                },
                "thoughtSignature" => "sig-b"
              }
            ]
          }
        }
      ]
    }

    assert {:ok, decoded} = Codec.decode_response(:google, 200, [], response, @origin)

    assert [
             %ContentBlock{type: :tool_call, tool_call: first_call},
             %ContentBlock{type: :provider_state, state: first_state},
             %ContentBlock{type: :tool_call, tool_call: second_call},
             %ContentBlock{type: :provider_state, state: second_state}
           ] = decoded.output

    assert {first_call.native_id, second_call.native_id} == {"native-a", "native-b"}
    assert first_state.payload["position"] == %{"candidate" => 0, "part" => 0}
    assert second_state.payload["position"] == %{"candidate" => 0, "part" => 1}

    {:ok, continuation} =
      Request.new(%{
        model: "gemini-2.5-flash",
        input: [
          %{role: :assistant, content: decoded.output},
          tool_result(first_call.id, %{"result" => %{"value" => 1, "nested" => %{"ok" => true}}}),
          tool_result(second_call.id, %{"result" => %{"value" => 2, "nested" => %{"ok" => false}}})
        ],
        settings: %{temperature: 0.2, max_output_tokens: 64},
        output_constraints: %{response_modalities: ["TEXT"]}
      })

    assert {:ok, %{body: body}} = Codec.encode_rest_request(:google, continuation, @origin)

    fixture =
      Path.expand("../fixtures/google_genai/generate_content_tool_continuation.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    assert body == fixture
  end

  test "signed parts require complete same-origin credential affinity" do
    part = %{
      "functionCall" => %{"id" => "native-a", "name" => "lookup", "args" => %{}},
      "thoughtSignature" => "opaque"
    }

    response = %{
      "candidates" => [
        %{"finishReason" => "STOP", "content" => %{"parts" => [part]}}
      ]
    }

    assert {:ok, decoded} = Codec.decode_response(:google, 200, [], response, @origin)

    {:ok, replay} =
      Request.new(%{
        model: "gemini-2.5-flash",
        input: [%{role: :assistant, content: decoded.output}]
      })

    assert {:ok, _} = Codec.encode_rest_request(:google, replay, @origin)

    {:ok, changed_model_replay} =
      Request.new(%{
        model: "gemini-2.5-pro",
        input: [%{role: :assistant, content: decoded.output}]
      })

    assert {:error, %Error{kind: :incompatible, compatibility: %{"field" => "affinity"}}} =
             Codec.encode_rest_request(:google, changed_model_replay, @origin)

    for changed <- [
          [profile: "google-secondary"],
          [endpoint: "https://vertex.example"],
          [account: "tenant-b"],
          [credential_scope: "projects/other"],
          [credential_version: "8"]
        ] do
      destination = Keyword.merge(@origin, changed)

      assert {:error, %Error{kind: :incompatible, compatibility: %{"field" => "affinity"}}} =
               Codec.encode_rest_request(:google, replay, destination)
    end
  end

  test "legacy signature payload without exact part position is rejected" do
    {:ok, state} =
      Backplane.AiProtocol.ProviderState.new(%{
        source_profile: "google-primary",
        source_protocol: "google",
        kind: "google_thought_signature",
        affinity: %{
          profile: "google-primary",
          protocol: "google",
          endpoint: "https://generativelanguage.googleapis.com",
          account: "tenant-a",
          model: "gemini-2.5-flash",
          credential_scope: "projects/example",
          credential_version: "7"
        },
        payload: %{"thinking" => "legacy", "signature" => "unbound"}
      })

    {:ok, request} =
      Request.new(%{
        model: "gemini-2.5-flash",
        input: [%{role: :assistant, content: [%{type: :provider_state, state: state}]}]
      })

    assert {:error, %Error{kind: :incompatible}} =
             Codec.encode_rest_request(:google, request, @origin)
  end

  test "signed text replays the exact original part" do
    part = %{"text" => "private", "thought" => true, "thoughtSignature" => "opaque"}

    response = %{
      "candidates" => [
        %{"finishReason" => "STOP", "content" => %{"parts" => [part]}}
      ]
    }

    assert {:ok, decoded} = Codec.decode_response(:google, 200, [], response, @origin)

    {:ok, replay} =
      Request.new(%{
        model: "gemini-2.5-flash",
        input: [%{role: :assistant, content: decoded.output}]
      })

    assert {:ok, %{body: %{"contents" => [%{"parts" => [^part]}]}}} =
             Codec.encode_rest_request(:google, replay, @origin)
  end

  test "identical unsigned parts cannot exchange their opaque signatures" do
    call = %{"functionCall" => %{"name" => "lookup", "args" => %{"q" => "same"}}}

    response = %{
      "candidates" => [
        %{
          "finishReason" => "STOP",
          "content" => %{
            "parts" => [
              Map.put(call, "thoughtSignature", "first"),
              Map.put(call, "thoughtSignature", "second")
            ]
          }
        }
      ]
    }

    assert {:ok, decoded} = Codec.decode_response(:google, 200, [], response, @origin)
    [first_call, first_state, second_call, second_state] = decoded.output

    {:ok, original} =
      Request.new(%{
        model: "gemini-2.5-flash",
        input: [
          %{role: :assistant, content: decoded.output},
          tool_result(first_call.tool_call.id, %{"result" => %{"ordinal" => 1}}),
          tool_result(second_call.tool_call.id, %{"result" => %{"ordinal" => 2}})
        ]
      })

    assert {:ok, %{body: original_body}} =
             Codec.encode_rest_request(:google, original, @origin)

    assert [model_content, result_content] = original_body["contents"]

    assert model_content["parts"] == [
             Map.put(call, "thoughtSignature", "first"),
             Map.put(call, "thoughtSignature", "second")
           ]

    assert result_content["parts"] == [
             %{
               "functionResponse" => %{
                 "name" => "lookup",
                 "response" => %{"result" => %{"ordinal" => 1}}
               }
             },
             %{
               "functionResponse" => %{
                 "name" => "lookup",
                 "response" => %{"result" => %{"ordinal" => 2}}
               }
             }
           ]

    {:ok, moved} =
      Request.new(%{
        model: "gemini-2.5-flash",
        input: [
          %{
            role: :assistant,
            content: [first_call, second_state, second_call, first_state]
          }
        ]
      })

    assert {:error, %Error{kind: :incompatible}} =
             Codec.encode_rest_request(:google, moved, @origin)
  end

  test "signed tool calls in separate stream frames retain replay positions" do
    first =
      sse(%{
        "candidates" => [
          %{
            "index" => 0,
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{"name" => "lookup", "args" => %{"ordinal" => 1}},
                  "thoughtSignature" => "first"
                }
              ]
            }
          }
        ]
      })

    second =
      sse(%{
        "candidates" => [
          %{
            "index" => 0,
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{"name" => "lookup", "args" => %{"ordinal" => 2}},
                  "thoughtSignature" => "second"
                }
              ]
            },
            "finishReason" => "STOP"
          }
        ]
      })

    {state, events} = feed_all([first, second])

    assert {:ok, _state, [%StreamEvent{type: :terminal}]} =
             Codec.stream_finish(:google, state, :eof)

    content = stream_tool_content(events)
    [first_call, first_state, second_call, second_state] = content
    assert first_state.state.payload["position"] == %{"candidate" => 0, "part" => 0}
    assert second_state.state.payload["position"] == %{"candidate" => 0, "part" => 1}

    {:ok, continuation} =
      Request.new(%{
        model: "gemini-2.5-flash",
        input: [
          %{role: :assistant, content: content},
          tool_result(first_call.tool_call.id, %{"result" => %{"ordinal" => 1}}),
          tool_result(second_call.tool_call.id, %{"result" => %{"ordinal" => 2}})
        ]
      })

    assert {:ok, %{body: body}} = Codec.encode_rest_request(:google, continuation, @origin)

    assert body["contents"] |> hd() |> Map.fetch!("parts") == [
             %{
               "functionCall" => %{"name" => "lookup", "args" => %{"ordinal" => 1}},
               "thoughtSignature" => "first"
             },
             %{
               "functionCall" => %{"name" => "lookup", "args" => %{"ordinal" => 2}},
               "thoughtSignature" => "second"
             }
           ]
  end

  test "stream waits for EOF, retains tail usage once, and never promotes unknown finish" do
    content =
      sse(%{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => "héllo"}]},
            "finishReason" => "STOP"
          }
        ]
      })

    usage =
      sse(%{
        "usageMetadata" => %{
          "promptTokenCount" => 4,
          "candidatesTokenCount" => 2,
          "totalTokenCount" => 6
        }
      })

    wire = String.replace(content, "\n\n", "\r\n\r\n") <> usage <> usage
    <<first::binary-size(53), second::binary-size(2), rest::binary>> = wire
    {state, events} = feed_all([first, second, rest])

    refute Enum.any?(events, &(&1.type == :terminal))
    assert Enum.count(events, &(&1.type == :usage)) == 1

    assert {:ok, final, [%StreamEvent{type: :terminal, stop_reason: :stop}]} =
             Codec.stream_finish(:google, state, :eof)

    assert final.content_finished?
    assert final.protocol_complete?
    assert final.transport_eof?

    unknown =
      sse(%{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "partial"}]}, "finishReason" => "FUTURE"}
        ]
      })

    {unknown_state, unknown_events} = feed_all([unknown])
    refute Enum.any?(unknown_events, &(&1.type == :terminal))

    assert {:error, %Error{kind: :incompatible}, _state} =
             Codec.stream_finish(:google, unknown_state, :eof)
  end

  defp tool_result(id, response) do
    %{
      role: :tool,
      tool_call_id: id,
      status: :success,
      content: [%{type: :text, text: "structured result"}],
      extensions: %{"google::function_response" => response}
    }
  end

  defp feed_all(chunks) do
    Enum.reduce(chunks, {Codec.stream_new(:google, @origin), []}, fn chunk, {state, events} ->
      {:ok, state, emitted} = Codec.stream_feed(:google, state, chunk)
      {state, events ++ emitted}
    end)
  end

  defp stream_tool_content(events) do
    Enum.flat_map(events, fn
      %StreamEvent{
        type: :tool_call_done,
        call_id: id,
        native_id: native_id,
        name: name,
        content: args
      } ->
        [
          %{
            type: :tool_call,
            tool_call: %{
              id: id,
              native_id: native_id,
              name: name,
              raw_arguments: {:structured, args}
            }
          }
        ]

      %StreamEvent{type: :provider_state, provider_state: state} ->
        [%{type: :provider_state, state: state}]

      _event ->
        []
    end)
  end

  defp sse(value), do: "data: " <> Jason.encode!(value) <> "\n\n"
end
