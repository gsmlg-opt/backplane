defmodule Backplane.AiProtocol.ProviderCodecTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{Codec, ContentBlock, Error, ProviderState, Request, StreamEvent}

  @limits %{max_bytes: 12_000_000, max_string_bytes: 6_000_000}

  test "anthropic preserves images, tools, tool results, and signed thinking" do
    request = request_fixture()

    assert {:ok, wire} = Codec.encode_request(:anthropic, request, stream: true)
    assert wire["stream"]

    assert [%{"type" => "text"}, %{"type" => "image"}] =
             wire["messages"] |> hd() |> Map.fetch!("content")

    assert [%{"type" => "tool_result", "tool_use_id" => "call-1", "is_error" => true}] =
             wire["messages"] |> Enum.at(2) |> Map.fetch!("content")

    body =
      Jason.encode!(%{
        "id" => "msg-1",
        "model" => "claude-test",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 8, "output_tokens" => 3},
        "content" => [
          %{"type" => "thinking", "thinking" => "private", "signature" => "signed"},
          %{"type" => "text", "text" => "answer"}
        ]
      })

    assert {:ok, response} = Codec.decode_response(:anthropic, 200, [], body, profile: "p")

    assert [%ContentBlock{type: :provider_state, state: state}, %ContentBlock{type: :text}] =
             response.output

    assert state.kind == "anthropic_signed_thinking"
    assert state.payload == %{"signature" => "signed", "thinking" => "private"}
  end

  test "anthropic rejects signed thinking replay outside its origin affinity" do
    {:ok, state} =
      Backplane.AiProtocol.ProviderState.new(%{
        source_profile: "source",
        source_protocol: "anthropic",
        kind: "anthropic_signed_thinking",
        affinity: %{
          profile: "source",
          protocol: "anthropic",
          endpoint: "https://source.invalid",
          model: "source-model"
        },
        payload: %{"thinking" => "private", "signature" => "secret-signature"}
      })

    {:ok, request} =
      Request.new(%{
        model: "different-model",
        input: [
          %{
            role: :assistant,
            content: [%{type: :provider_state, state: state}]
          }
        ]
      })

    assert {:error, %Error{kind: :incompatible}} =
             Codec.encode_request(:anthropic, request,
               profile: "different",
               endpoint: "https://different.invalid",
               model: "different-model"
             )
  end

  test "all opaque replay kinds use the request model and require a complete origin" do
    cases = [
      {:anthropic, "anthropic_signed_thinking", %{"thinking" => "private", "signature" => "a"}},
      {:openai, "minimax_reasoning_details", [%{"type" => "reasoning", "text" => "opaque"}]},
      {:google, "google_thought_signature", %{"thinking" => "private", "signature" => "g"}}
    ]

    opts = [profile: "p", endpoint: "https://api.example", model: "original"]

    for {protocol, kind, payload} <- cases do
      {:ok, state} = provider_state(protocol, kind, payload, "original")
      {:ok, request} = replay_request("original", state)
      assert {:ok, _wire} = Codec.encode_request(protocol, request, opts)

      {:ok, changed_request} = replay_request("changed", state)

      assert {:error, %Error{kind: :incompatible}} =
               Codec.encode_request(protocol, changed_request, opts)

      {:ok, incomplete_state} = provider_state(protocol, kind, payload, nil)
      {:ok, incomplete_request} = replay_request("original", incomplete_state)

      assert {:error, %Error{kind: :incompatible}} =
               Codec.encode_request(protocol, incomplete_request, opts)
    end
  end

  test "anthropic rejects message_stop while tool arguments are incomplete" do
    state = Codec.stream_new(:anthropic, [])

    wire =
      sse(%{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "call-1",
          "name" => "lookup",
          "input" => %{}
        }
      }) <>
        sse(%{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "{"}
        }) <>
        sse(%{"type" => "message_stop"})

    assert {:error, %Error{kind: :invalid_request}, _state} =
             Codec.stream_feed(:anthropic, state, wire)
  end

  test "anthropic stream preserves stop reason, trailing usage, final frame, and signed replay" do
    wire =
      sse(%{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "max_tokens"},
        "usage" => %{"output_tokens" => 4}
      }) <> "data: {\"type\":\"message_stop\"}"

    state = Codec.stream_new(:anthropic, [])
    assert {:ok, state, events} = Codec.stream_feed(:anthropic, state, wire)
    assert [%StreamEvent{type: :usage, usage: %{output_tokens: 4}}] = events

    assert {:ok, _state, [%StreamEvent{type: :terminal, stop_reason: :max_output_tokens}]} =
             Codec.stream_finish(:anthropic, state, :eof)

    body =
      Jason.encode!(%{
        "model" => "m",
        "stop_reason" => "end_turn",
        "content" => [
          %{"type" => "thinking", "thinking" => "private", "signature" => "signed"}
        ]
      })

    opts = [profile: "p", endpoint: "https://api.example", model: "m"]
    assert {:ok, response} = Codec.decode_response(:anthropic, 200, [], body, opts)

    {:ok, request} =
      Request.new(%{model: "m", input: [%{role: :assistant, content: response.output}]})

    assert {:ok, _wire} = Codec.encode_request(:anthropic, request, opts)
  end

  test "anthropic rejects content after terminal state" do
    state = Codec.stream_new(:anthropic, [])

    assert {:ok, state, [%StreamEvent{type: :terminal}]} =
             Codec.stream_feed(:anthropic, state, sse(%{"type" => "message_stop"}))

    event = %{
      "type" => "content_block_start",
      "index" => 0,
      "content_block" => %{"type" => "text", "text" => "late"}
    }

    assert {:error, %Error{kind: :incompatible}, _state} =
             Codec.stream_feed(:anthropic, state, sse(event))
  end

  test "openai emits indexed interleaved tool deltas and trailing usage once" do
    chunks = [
      sse(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 1,
                  "id" => "c2",
                  "function" => %{"name" => "b", "arguments" => "{\"b\":"}
                },
                %{
                  "index" => 0,
                  "id" => "c1",
                  "function" => %{"name" => "a", "arguments" => "{\"a\":"}
                }
              ]
            }
          }
        ]
      }),
      sse(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "function" => %{"arguments" => "1}"}},
                %{"index" => 1, "function" => %{"arguments" => "2}"}}
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 1, "total_tokens" => 3}
      }),
      "data: [DONE]\n\n"
    ]

    {state, events} = feed_all(:openai, chunks)

    assert Enum.map(Enum.filter(events, &(&1.type == :tool_call_delta)), & &1.index) == [
             1,
             0,
             0,
             1
           ]

    assert Enum.count(events, &(&1.type == :terminal)) == 1

    assert [%StreamEvent{type: :usage, usage: %{native_total: 3}}] =
             Enum.filter(events, &(&1.type == :usage))

    assert {:ok, _, []} = Codec.stream_finish(:openai, state, :eof)
  end

  test "openai rejects invalid completed tool JSON" do
    state = Codec.stream_new(:openai, [])

    chunk =
      sse(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "id" => "c", "function" => %{"name" => "a", "arguments" => "{"}}
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      })

    assert {:error, %Error{kind: :invalid_request}, _state} =
             Codec.stream_feed(:openai, state, chunk)
  end

  test "openai request and response preserve MiniMax reasoning and sanitize errors" do
    {:ok, state} =
      Backplane.AiProtocol.ProviderState.new(%{
        source_profile: "p",
        source_protocol: "openai",
        kind: "minimax_reasoning_details",
        affinity: %{profile: "p", protocol: "openai", endpoint: "https://api.example", model: "m"},
        payload: [%{"type" => "reasoning", "text" => "opaque"}]
      })

    {:ok, request} =
      Request.new(%{
        model: "m",
        input: [
          %{
            role: :assistant,
            content: [%{type: :reasoning, data: "why"}, %{type: :provider_state, state: state}]
          }
        ],
        extensions: %{"minimax::reasoning_split" => true}
      })

    opts = [profile: "p", endpoint: "https://api.example", model: "m"]

    assert {:ok, %{"reasoning_split" => true, "messages" => [message]}} =
             Codec.encode_request(:openai, request, opts)

    assert message["reasoning_content"] == "why"
    assert message["reasoning_details"] == [state.payload]

    body =
      Jason.encode!(%{
        "model" => "m",
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{
              "content" => "ok",
              "reasoning_content" => "why",
              "reasoning_details" => state.payload
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 1, "total_tokens" => 3}
      })

    assert {:ok, %{stop_reason: :stop, usage: %{native_total: 3}}} =
             Codec.decode_response(:openai, 200, [], body, opts)

    secret = "sk-secret-signature"

    assert {:error, %Error{message: message}} =
             Codec.decode_error(:openai, 401, [], %{"error" => %{"message" => secret}}, [])

    refute message =~ secret
  end

  test "openai rejects incomplete tools at DONE and preserves streaming reasoning details" do
    state = Codec.stream_new(:openai, profile: "p", model: "m")

    start =
      sse(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "reasoning_details" => %{"token" => "opaque"},
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call",
                  "function" => %{"name" => "lookup", "arguments" => "{"}
                }
              ]
            }
          }
        ]
      })

    assert {:ok, state, events} = Codec.stream_feed(:openai, state, start)
    assert Enum.any?(events, &(&1.type == :provider_state))
    assert {:error, %Error{}, _state} = Codec.stream_feed(:openai, state, "data: [DONE]\n\n")
  end

  test "openai rejects multiple streamed choices and assembles fragmented tool identity" do
    multiple = %{
      "choices" => [
        %{"index" => 0, "delta" => %{"content" => "a"}},
        %{"index" => 1, "delta" => %{"content" => "b"}}
      ]
    }

    assert {:error, %Error{kind: :incompatible}, _state} =
             Codec.stream_feed(:openai, Codec.stream_new(:openai, []), sse(multiple))

    first = %{
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "call-",
                "function" => %{"name" => "look", "arguments" => "{"}
              }
            ]
          }
        }
      ]
    }

    second = %{
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "1",
                "function" => %{"name" => "up", "arguments" => "}"}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ]
    }

    state = Codec.stream_new(:openai, [])
    assert {:ok, state, _events} = Codec.stream_feed(:openai, state, sse(first))
    assert {:ok, _state, events} = Codec.stream_feed(:openai, state, sse(second))

    assert %StreamEvent{type: :tool_call_done, call_id: "call-1", name: "lookup"} =
             Enum.find(events, &(&1.type == :tool_call_done))
  end

  test "openai refuses unsupported refusals and streamed errors" do
    body =
      Jason.encode!(%{
        "choices" => [
          %{"finish_reason" => "stop", "message" => %{"content" => nil, "refusal" => "blocked"}}
        ]
      })

    assert {:error, %Error{kind: :incompatible}} =
             Codec.decode_response(:openai, 200, [], body, [])

    state = Codec.stream_new(:openai, [])

    assert {:error, %Error{kind: :incompatible}, _state} =
             Codec.stream_feed(
               :openai,
               state,
               sse(%{"choices" => [%{"delta" => %{"refusal" => "blocked"}}]})
             )

    assert {:error, %Error{kind: :upstream_error}, _state} =
             Codec.stream_feed(:openai, state, sse(%{"error" => %{"message" => "secret"}}))
  end

  test "google derives function response names and survives every byte split" do
    request = request_fixture()
    assert {:ok, wire} = Codec.encode_request(:google, request, stream: true)

    parts = wire["contents"] |> Enum.at(2) |> Map.fetch!("parts")

    assert [%{"functionResponse" => %{"name" => "lookup", "response" => %{"error" => "failed"}}}] =
             parts

    event = %{
      "candidates" => [
        %{"index" => 0, "content" => %{"parts" => [%{"text" => "ok"}]}, "finishReason" => "STOP"}
      ],
      "usageMetadata" => %{
        "promptTokenCount" => 2,
        "candidatesTokenCount" => 1,
        "totalTokenCount" => 3
      }
    }

    wire = sse(event)

    for split <- 0..byte_size(wire) do
      <<left::binary-size(^split), right::binary>> = wire
      {state, events} = feed_all(:google, [left, right])
      assert Enum.any?(events, &match?(%StreamEvent{type: :text_delta, text: "ok"}, &1))
      assert Enum.count(events, &(&1.type == :terminal)) == 1
      assert {:ok, _, []} = Codec.stream_finish(:google, state, :eof)
    end
  end

  test "google non-stream preserves signatures, images, tools, usage, and errors" do
    body =
      Jason.encode!(%{
        "modelVersion" => "gemini-test",
        "candidates" => [
          %{
            "finishReason" => "STOP",
            "content" => %{
              "parts" => [
                %{"text" => "thought", "thought" => true, "thoughtSignature" => "signed"},
                %{"inlineData" => %{"mimeType" => "image/png", "data" => "aGVsbG8="}},
                %{"functionCall" => %{"name" => "a", "args" => %{"x" => 1}}},
                %{"functionCall" => %{"name" => "a", "args" => %{"x" => 1}}}
              ]
            }
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 2,
          "candidatesTokenCount" => 1,
          "thoughtsTokenCount" => 1,
          "totalTokenCount" => 4
        }
      })

    assert {:ok, response} =
             Codec.decode_response(:google, 200, [], body,
               profile: "p",
               endpoint: "https://google.example",
               model: "m"
             )

    calls = for %ContentBlock{type: :tool_call, tool_call: call} <- response.output, do: call.id
    assert calls == ["google-0-2", "google-0-3"]
    assert Enum.any?(response.output, &match?(%ContentBlock{type: :provider_state}, &1))
    assert response.usage.reasoning_tokens == 1

    assert {:error, %Error{kind: :rate_limited, message: "Google provider request failed"}} =
             Codec.decode_error(:google, 429, [], %{"error" => %{"message" => "secret"}}, [])
  end

  test "google rejects safety-only responses and streamed errors" do
    blocked = %{"promptFeedback" => %{"blockReason" => "SAFETY"}}

    assert {:error, %Error{kind: :incompatible}} =
             Codec.decode_response(:google, 200, [], blocked, [])

    state = Codec.stream_new(:google, [])

    assert {:error, %Error{kind: :incompatible}, _state} =
             Codec.stream_feed(:google, state, sse(blocked))

    assert {:error, %Error{kind: :upstream_error}, _state} =
             Codec.stream_feed(:google, state, sse(%{"error" => %{"message" => "secret"}}))
  end

  test "google rejects signatures attached to non-thought content" do
    parts = [
      %{"text" => "plain", "thoughtSignature" => "signed"},
      %{
        "inlineData" => %{"mimeType" => "image/png", "data" => "aGVsbG8="},
        "thoughtSignature" => "signed"
      },
      %{
        "functionCall" => %{"name" => "lookup", "args" => %{}},
        "thoughtSignature" => "signed"
      }
    ]

    for part <- parts do
      response = %{
        "candidates" => [
          %{"content" => %{"parts" => [part]}, "finishReason" => "STOP"}
        ]
      }

      assert {:error, %Error{kind: :incompatible}} =
               Codec.decode_response(:google, 200, [], response, [])

      assert {:error, %Error{kind: :incompatible}, _state} =
               Codec.stream_feed(:google, Codec.stream_new(:google, []), sse(response))
    end
  end

  test "provider codecs reject malformed 2xx documents, core overrides, and unsupported tool results" do
    for protocol <- [:anthropic, :openai, :google] do
      assert {:error, %Error{}} = Codec.decode_response(protocol, 200, [], "{}", [])
    end

    {:ok, request} = Request.new(%{model: "m", input: [], settings: %{"model" => "override"}})
    assert {:error, %Error{}} = Codec.encode_request(:openai, request, [])
    assert {:error, %Error{}} = Codec.encode_request(:anthropic, request, [])

    {:ok, request} =
      Request.new(%{
        model: "m",
        input: [
          %{
            role: :assistant,
            content: [
              %{
                type: :tool_call,
                tool_call: %{id: "c", name: "a", raw_arguments: {:structured, %{}}}
              }
            ]
          },
          %{
            role: :tool,
            tool_call_id: "c",
            status: :success,
            content: [%{type: :reasoning, data: "opaque"}]
          }
        ]
      })

    assert {:error, %Error{kind: :incompatible}} = Codec.encode_request(:openai, request, [])
    assert {:error, %Error{kind: :incompatible}} = Codec.encode_request(:google, request, [])
  end

  test "per-call limits propagate to nested image validation" do
    image = String.duplicate("a", 2_000_000)

    assert {:error, %Error{}} =
             Request.new(%{
               model: "m",
               input: [%{role: :user, content: [%{type: :image, data: image}]}]
             })

    assert {:ok, %Request{}} =
             Request.new(
               %{model: "m", input: [%{role: :user, content: [%{type: :image, data: image}]}]},
               limits: @limits
             )
  end

  defp request_fixture do
    {:ok, request} =
      Request.new(%{
        model: "model",
        input: [
          %{
            role: :user,
            content: [
              %{type: :text, text: "hello"},
              %{
                type: :image,
                data: %{"source" => "base64", "media_type" => "image/png", "data" => "aGVsbG8="}
              }
            ]
          },
          %{
            role: :assistant,
            content: [
              %{
                type: :tool_call,
                tool_call: %{
                  id: "call-1",
                  name: "lookup",
                  raw_arguments: {:structured, %{"q" => "x"}}
                }
              }
            ]
          },
          %{
            role: :tool,
            tool_call_id: "call-1",
            status: :error,
            content: [%{type: :text, text: "failed"}]
          }
        ],
        tools: [%{name: "lookup", input_schema: %{"type" => "object"}}],
        extensions: %{"minimax::reasoning_split" => true}
      })

    request
  end

  defp provider_state(protocol, kind, payload, model) do
    ProviderState.new(%{
      source_profile: "p",
      source_protocol: Atom.to_string(protocol),
      kind: kind,
      affinity: %{
        profile: "p",
        protocol: Atom.to_string(protocol),
        endpoint: if(model, do: "https://api.example"),
        model: model
      },
      payload: payload
    })
  end

  defp replay_request(model, state) do
    Request.new(%{
      model: model,
      input: [%{role: :assistant, content: [%{type: :provider_state, state: state}]}]
    })
  end

  defp feed_all(protocol, chunks) do
    Enum.reduce(chunks, {Codec.stream_new(protocol, []), []}, fn chunk, {state, events} ->
      {:ok, state, emitted} = Codec.stream_feed(protocol, state, chunk)
      {state, events ++ emitted}
    end)
  end

  defp sse(value), do: "data: " <> Jason.encode!(value) <> "\n\n"
end
