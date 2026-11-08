defmodule Backplane.AiProtocol.AnthropicProjectionTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{Codec, ContentBlock, Error, Request}
  alias Backplane.AiProtocol.Codec.Anthropic

  @raw " \t*** Begin Patch\r\n+你好 🌍\n*** End Patch\r\n \t"
  @schema %{"type" => "object", "properties" => %{"result" => %{"type" => "string"}}}
  @tools [
    %{
      name: "apply_patch",
      input_kind: :custom,
      description: "Apply an exact patch.",
      format: %{"type" => "grammar", "syntax" => "lark", "definition" => "start: /.+/"},
      extensions: %{"codex::output_schema" => @schema}
    },
    %{
      name: "history::search_contents",
      description: "Search history.",
      input_schema: %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}}
    },
    %{name: "collaboration::send_message", input_schema: %{"type" => "object"}}
  ]

  test "explicit preparation projects native declarations and retains metadata" do
    request = request()
    assert {:error, %Error{kind: :incompatible}} = Codec.encode_request(:anthropic, request)
    assert {:ok, %{body: body, codec_options: opts}} = Anthropic.prepare_request(request)
    assert Keyword.has_key?(opts, :anthropic_tool_projection)
    names = Enum.map(body["tools"], & &1["name"])
    assert Enum.all?(names, &Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, &1))
    assert length(Enum.uniq(names)) == length(@tools)
    assert hd(names) == "apply_patch"
    [custom | _] = body["tools"]

    assert custom["input_schema"] == %{
             "type" => "object",
             "properties" => %{"input" => %{"type" => "string"}},
             "required" => ["input"],
             "additionalProperties" => false
           }

    assert String.starts_with?(custom["description"], "Apply an exact patch.")
    assert custom["description"] =~ "codex::output_schema"
    assert custom["description"] =~ Jason.encode!(@schema)
    assert custom["description"] =~ "definition"
    assert {:ok, ^body} = Codec.encode_request(:anthropic, request, opts)
  end

  test "custom and function response identities survive exact replay and serialization" do
    for raw <- [@raw, "", "\n", "\r\n", " leading", "trailing "] do
      request = request()
      {:ok, %{body: body, codec_options: opts}} = Anthropic.prepare_request(request)
      [patch, search | _] = body["tools"]

      content = [
        tool_use("patch", patch["name"], %{"input" => raw}),
        tool_use("search", search["name"], %{"query" => "exact"})
      ]

      assert {:ok, response} = Codec.decode_response(:anthropic, 200, [], response(content), opts)
      assert [custom, function] = response.output
      assert custom.tool_call.name == "apply_patch"
      assert custom.tool_call.raw_arguments == {:custom, raw}
      assert function.tool_call.name == "history::search_contents"
      assert function.tool_call.raw_arguments == {:structured, %{"query" => "exact"}}

      {:ok, replay} =
        Request.new(%{
          model: "claude-test",
          tools: @tools,
          input: [
            %{role: :assistant, content: response.output},
            %{
              role: :tool,
              tool_call_id: "patch",
              status: :error,
              content: [%{type: :text, text: "failed"}]
            },
            %{role: :tool, tool_call_id: "search", content: [%{type: :text, text: "found"}]}
          ]
        })

      assert {:ok, replay_body} = Codec.encode_request(:anthropic, replay, opts)
      assert hd(replay_body["messages"])["content"] == content

      assert get_in(Enum.at(replay_body["messages"], 1), ["content", Access.at(0), "is_error"]) ==
               true

      assert Jason.decode!(Jason.encode!(replay_body)) == replay_body
    end
  end

  test "history-only custom calls retain their identity without an active definition" do
    {:ok, history} =
      Request.new(%{
        model: "claude-test",
        input: [
          %{
            role: :assistant,
            content: [
              %{
                type: :tool_call,
                tool_call: %{id: "old", name: "retired::patch", raw_arguments: {:custom, @raw}}
              }
            ]
          }
        ]
      })

    assert {:ok, %{body: body, codec_options: opts}} = Anthropic.prepare_request(history)
    [call] = hd(body["messages"])["content"]
    assert call["input"] == %{"input" => @raw}
    assert {:ok, decoded} = Codec.decode_response(:anthropic, 200, [], response([call]), opts)
    assert hd(decoded.output).tool_call.name == "retired::patch"
    assert hd(decoded.output).tool_call.raw_arguments == {:custom, @raw}
  end

  test "deterministic aliases are independent of declaration order and collisions fail" do
    {:ok, %{body: forward}} = Anthropic.prepare_request(request())
    {:ok, %{body: reverse}} = Anthropic.prepare_request(request(Enum.reverse(@tools)))

    assert Enum.map(forward["tools"], & &1["name"]) ==
             Enum.reverse(Enum.map(reverse["tools"], & &1["name"]))

    collision = Enum.at(forward["tools"], 1)["name"]
    assert {:error, %Error{}} = Anthropic.prepare_request(request(@tools ++ [%{name: collision}]))
    long = String.duplicate("a", 100)

    assert {:ok, %{body: mapped}} =
             Anthropic.prepare_request(request([%{name: long}, %{name: "tool.with.dots"}]))

    assert Enum.all?(mapped["tools"], &Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, &1["name"]))
    assert {:error, %Error{}} = Codec.encode_request(:anthropic, request([%{name: long}]))
  end

  test "forced tool choice uses the same table and unknown choices fail before HTTP" do
    {:ok, original} =
      Request.new(%{
        model: "claude-test",
        input: [],
        tools: @tools,
        settings: %{"tool_choice" => %{"type" => "tool", "name" => "history::search_contents"}}
      })

    assert {:ok, %{body: body}} = Anthropic.prepare_request(original)
    assert body["tool_choice"]["name"] == Enum.at(body["tools"], 1)["name"]
    invalid = %{original | settings: %{"tool_choice" => %{"type" => "tool", "name" => "missing"}}}
    assert {:error, %Error{}} = Anthropic.prepare_request(invalid)
  end

  test "a forced choice cannot select a retired history-only tool" do
    {:ok, request} =
      Request.new(%{
        model: "claude-test",
        tools: [%{name: "active"}],
        settings: %{"tool_choice" => %{"type" => "tool", "name" => "retired::patch"}},
        input: [
          %{
            role: :assistant,
            content: [
              %{
                type: :tool_call,
                tool_call: %{
                  id: "old",
                  name: "retired::patch",
                  raw_arguments: {:custom, @raw}
                }
              }
            ]
          }
        ]
      })

    assert {:error, %Error{}} = Anthropic.prepare_request(request)
  end

  test "wrong custom shape, unknown identities, malformed context and kind conflicts fail" do
    {:ok, %{codec_options: opts}} = Anthropic.prepare_request(request())

    for input <- [%{}, %{"input" => 1}, %{"input" => @raw, "extra" => true}, [], @raw] do
      assert {:error, %Error{}} =
               Codec.decode_response(
                 :anthropic,
                 200,
                 [],
                 response([tool_use("x", "apply_patch", input)]),
                 opts
               )
    end

    assert {:error, %Error{}} =
             Codec.decode_response(
               :anthropic,
               200,
               [],
               response([tool_use("x", "unknown", %{})]),
               opts
             )

    assert {:error, %Error{}} =
             Codec.encode_request(:anthropic, request(), anthropic_tool_projection: %{})

    assert {:error, %Error{}} =
             Codec.decode_response(:anthropic, 200, [], response([]),
               anthropic_tool_projection: %{}
             )

    {:ok, conflict} =
      Request.new(%{
        model: "claude-test",
        tools: @tools,
        input: [
          %{
            role: :assistant,
            content: [
              %{
                type: :tool_call,
                tool_call: %{id: "bad", name: "apply_patch", raw_arguments: {:structured, %{}}}
              }
            ]
          }
        ]
      })

    assert {:error, %Error{}} = Anthropic.prepare_request(conflict)
  end

  test "SSE custom wrappers never leak as custom deltas, across every byte boundary" do
    {:ok, %{body: body, codec_options: opts}} = Anthropic.prepare_request(request(), stream: true)
    [patch, search | _] = body["tools"]
    json = Jason.encode!(%{"input" => @raw})

    frames = [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => tool_use("patch", patch["name"], %{})
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => json}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => tool_use("search", search["name"], %{})
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"query\":\"hi\"}"}
      },
      %{"type" => "content_block_stop", "index" => 1},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
      %{"type" => "message_stop"}
    ]

    wire = Enum.map_join(frames, &sse/1)

    for split <- 0..byte_size(wire) do
      <<first::binary-size(split), second::binary>> = wire

      assert {:ok, state, first_events} =
               Codec.stream_feed(:anthropic, Codec.stream_new(:anthropic, opts), first)

      assert {:ok, state, second_events} = Codec.stream_feed(:anthropic, state, second)
      assert {:ok, _state, final_events} = Codec.stream_finish(:anthropic, state, :eof)
      events = first_events ++ second_events ++ final_events

      assert [%{name: "apply_patch"}, %{name: "history::search_contents"}] =
               Enum.filter(events, &(&1.type == :tool_call_start))

      assert [
               %{name: "apply_patch", content: %ContentBlock{tool_call: call}},
               %{name: "history::search_contents", content: %{"query" => "hi"}}
             ] = Enum.filter(events, &(&1.type == :tool_call_done))

      assert call.raw_arguments == {:custom, @raw}

      assert Enum.all?(
               Enum.filter(events, &(&1.type == :tool_call_delta and &1.name == "apply_patch")),
               &(&1.arguments_delta == @raw)
             )

      assert Enum.count(events, &(&1.type == :terminal)) == 1
    end
  end

  test "incomplete projected custom calls cannot complete a stream" do
    {:ok, %{codec_options: opts}} = Anthropic.prepare_request(request())

    start =
      sse(%{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => tool_use("x", "apply_patch", %{})
      })

    assert {:ok, state, _} =
             Codec.stream_feed(:anthropic, Codec.stream_new(:anthropic, opts), start)

    assert {:error, %Error{}, _} =
             Codec.stream_feed(
               :anthropic,
               state,
               sse(%{"type" => "content_block_stop", "index" => 0})
             )
  end

  test "projected stream lifecycle rejects duplicate, unknown and truncated blocks" do
    {:ok, %{codec_options: opts}} = Anthropic.prepare_request(request())

    start =
      sse(%{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => tool_use("x", "apply_patch", %{"input" => @raw})
      })

    stop = sse(%{"type" => "content_block_stop", "index" => 0})
    state = Codec.stream_new(:anthropic, opts)
    assert {:error, %Error{}, _} = Codec.stream_feed(:anthropic, state, stop)
    assert {:ok, opened, _} = Codec.stream_feed(:anthropic, state, start)
    assert {:error, %Error{}, _} = Codec.stream_feed(:anthropic, opened, start)

    duplicate_id =
      sse(%{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => tool_use("x", "apply_patch", %{"input" => @raw})
      })

    assert {:error, %Error{}, _} = Codec.stream_feed(:anthropic, opened, duplicate_id)
    assert {:ok, closed, _} = Codec.stream_feed(:anthropic, opened, stop)
    assert {:error, %Error{}, _} = Codec.stream_feed(:anthropic, closed, stop)
    assert {:error, %Error{}, _} = Codec.stream_finish(:anthropic, opened, :eof)

    unknown =
      sse(%{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => tool_use("x", "unknown", %{})
      })

    assert {:error, %Error{}, _} = Codec.stream_feed(:anthropic, state, unknown)
    malformed = Codec.stream_new(:anthropic, anthropic_tool_projection: %{})
    assert {:error, %Error{}, _} = Codec.stream_feed(:anthropic, malformed, start)
  end

  test "projected stream budgets include initial input and accumulated JSON bytes" do
    {:ok, %{codec_options: opts}} = Anthropic.prepare_request(request(), max_tool_input_bytes: 12)

    start =
      sse(%{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => tool_use("x", "apply_patch", %{})
      })

    delta =
      sse(%{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{
          "type" => "input_json_delta",
          "partial_json" => Jason.encode!(%{"input" => @raw})
        }
      })

    assert {:ok, state, []} =
             Codec.stream_feed(:anthropic, Codec.stream_new(:anthropic, opts), "")

    assert {:ok, state, _} = Codec.stream_feed(:anthropic, state, start)
    assert {:error, %Error{}, _} = Codec.stream_feed(:anthropic, state, delta)

    initial =
      sse(%{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => tool_use("x", "apply_patch", %{"input" => @raw})
      })

    assert {:error, %Error{}, _} =
             Codec.stream_feed(:anthropic, Codec.stream_new(:anthropic, opts), initial)

    {:ok, %{body: body, codec_options: opts}} =
      Anthropic.prepare_request(request(), max_tool_calls: 1)

    assert {:ok, state, _} =
             Codec.stream_feed(:anthropic, Codec.stream_new(:anthropic, opts), start)

    other =
      sse(%{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => tool_use("y", Enum.at(body["tools"], 1)["name"], %{})
      })

    assert {:error, %Error{}, _} = Codec.stream_feed(:anthropic, state, other)
    opts = Keyword.put(opts, :max_tool_calls, 2) |> Keyword.put(:max_total_tool_input_bytes, 3)

    assert {:ok, state, _} =
             Codec.stream_feed(:anthropic, Codec.stream_new(:anthropic, opts), start)

    assert {:error, %Error{}, _} = Codec.stream_feed(:anthropic, state, other)
  end

  defp request(tools \\ @tools) do
    {:ok, request} =
      Request.new(%{
        model: "claude-test",
        input: [%{role: :user, content: [%{type: :text, text: "test"}]}],
        tools: tools
      })

    request
  end

  defp tool_use(id, name, input),
    do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}

  defp response(content),
    do: %{"content" => content, "stop_reason" => "tool_use", "model" => "claude-test"}

  defp sse(frame), do: "data: " <> Jason.encode!(frame) <> "\n\n"
end
