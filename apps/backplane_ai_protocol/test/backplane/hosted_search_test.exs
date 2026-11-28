defmodule Backplane.AiProtocol.HostedSearchTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{Codec, ContentBlock, Error, HostedSearch, Request, Serialization}

  @call %{
    "type" => "server_tool_use",
    "id" => "srvtoolu_search",
    "name" => "web_search",
    "input" => %{"query" => "Elixir release"}
  }
  @result %{
    "type" => "web_search_tool_result",
    "tool_use_id" => "srvtoolu_search",
    "content" => [
      %{
        "type" => "web_search_result",
        "url" => "https://elixir-lang.org/",
        "title" => "Elixir",
        "encrypted_content" => "opaque-source-bytes",
        "page_age" => "1 day"
      }
    ]
  }
  @citation %{
    "type" => "web_search_result_location",
    "url" => "https://elixir-lang.org/",
    "title" => "Elixir",
    "encrypted_index" => "opaque-index",
    "cited_text" => "Elixir release evidence"
  }
  @responses_call %{
    "type" => "web_search_call",
    "id" => "ws_search",
    "status" => "completed",
    "action" => %{
      "type" => "search",
      "query" => "Elixir release",
      "sources" => [%{"type" => "url", "url" => "https://elixir-lang.org/"}]
    }
  }

  test "Runtime declarations encode native tools with explicit Anthropic version" do
    request =
      request([], [
        %{
          type: "web_search",
          external_web_access: true,
          filters: %{allowed_domains: ["elixir-lang.org"]},
          user_location: %{type: "approximate", country: "US"}
        }
      ])

    assert {:ok,
            %{
              "tools" => [
                %{
                  "type" => "web_search_20250305",
                  "name" => "web_search",
                  "allowed_domains" => ["elixir-lang.org"],
                  "user_location" => %{"country" => "US"}
                } = tool
              ]
            }} =
             Codec.encode_request(:anthropic, request,
               anthropic_web_search_version: "web_search_20250305"
             )

    refute Map.has_key?(tool, "input_schema")
    refute Map.has_key?(tool, "external_web_access")

    assert {:ok, %{"tools" => [%{"type" => "web_search", "external_web_access" => true}]}} =
             Codec.encode_request(:openai_responses, request)

    assert {:error, %Error{}} = Codec.encode_request(:anthropic, request)

    assert {:error, %Error{}} =
             Codec.encode_request(:anthropic, request,
               anthropic_web_search_version: "future_version"
             )

    for option <- [
          %{external_web_access: false},
          %{indexed_web_access: true},
          %{search_context_size: "high"},
          %{search_content_types: ["image"]}
        ] do
      request = request([], [Map.merge(%{type: "web_search", external_web_access: true}, option)])

      assert {:error, %Error{}} =
               Codec.encode_request(:anthropic, request,
                 anthropic_web_search_version: "web_search_20250305"
               )
    end
  end

  test "buffered Anthropic search correlates results and preserves cited text as evidence" do
    assert {:ok, response} = Codec.decode_response(:anthropic, 200, [], anthropic_document())

    assert [
             %ContentBlock{type: :hosted_search, data: evidence},
             %ContentBlock{type: :text, text: "Found Elixir", extensions: citations}
           ] = response.output

    assert evidence == %{
             "source_protocol" => "anthropic",
             "id" => "srvtoolu_search",
             "status" => "completed",
             "call" => @call,
             "result" => @result
           }

    assert citations["backplane::citations"] == %{
             "source_protocol" => "anthropic",
             "citations" => [@citation]
           }

    refute Enum.any?(response.output, &(&1.type == :tool_call))
  end

  test "split Anthropic SSE emits hosted observations without local calls" do
    frames = [
      %{"type" => "message_start", "message" => %{"model" => "claude-test"}},
      start(0, %{@call | "input" => %{}}),
      delta(0, %{"type" => "input_json_delta", "partial_json" => ~s({"query":"Elixir release"})}),
      stop(0),
      start(1, @result),
      stop(1),
      start(2, %{"type" => "text", "text" => ""}),
      delta(2, %{"type" => "text_delta", "text" => "Found Elixir"}),
      delta(2, %{"type" => "citations_delta", "citation" => @citation}),
      stop(2),
      %{"type" => "message_stop"}
    ]

    events = stream(:anthropic, frames)
    refute Enum.any?(events, &(&1.type in [:tool_call_start, :tool_call_delta, :tool_call_done]))
    hosted = Enum.filter(events, &(&1.type == :provider_hosted_event))

    assert %{
             content: %{
               type: :hosted_search,
               data: %{"status" => "completed", "call" => @call, "result" => @result}
             }
           } = List.last(hosted)

    assert %{
             type: :provider_hosted_event,
             capability: "web_search",
             event: %{"status" => "completed"}
           } =
             HostedSearch.runtime_event(List.last(hosted))

    assert Enum.any?(
             events,
             &match?(
               %{
                 type: :citation,
                 content: %{"source_protocol" => "anthropic", "citation" => @citation}
               },
               &1
             )
           )

    assert List.last(events).type == :terminal
  end

  test "Anthropic search errors remain correlated hosted results" do
    error = %{
      @result
      | "content" => %{
          "type" => "web_search_tool_result_error",
          "error_code" => "max_uses_exceeded"
        }
    }

    assert {:ok,
            %{output: [%{type: :hosted_search, data: %{"status" => "error", "result" => ^error}}]}} =
             Codec.decode_response(:anthropic, 200, [], %{
               anthropic_document()
               | "content" => [@call, error]
             })

    events =
      stream(:anthropic, [
        start(0, @call),
        stop(0),
        start(1, error),
        stop(1),
        %{"type" => "message_stop"}
      ])

    assert %{content: %{data: %{"status" => "error"}}} =
             events |> Enum.filter(&(&1.type == :provider_hosted_event)) |> List.last()
  end

  test "Responses public codec observes hosted searches and cited text" do
    assert {:ok, response} =
             Codec.decode_response(:openai_responses, 200, [], responses_document())

    assert [
             %{
               type: :hosted_search,
               data: %{"source_protocol" => "openai_responses", "call" => @responses_call}
             },
             %{type: :text, extensions: %{"backplane::citations" => %{"citations" => [_]}}}
           ] = response.output

    events =
      stream(:openai_responses, [
        %{
          "type" => "response.output_item.added",
          "output_index" => 0,
          "item" => %{@responses_call | "status" => "in_progress"}
        },
        %{
          "type" => "response.web_search_call.searching",
          "output_index" => 0,
          "item_id" => "ws_search"
        },
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => @responses_call},
        %{
          "type" => "response.output_text.annotation.added",
          "output_index" => 1,
          "content_index" => 0,
          "annotation" => %{
            "type" => "url_citation",
            "url" => "https://elixir-lang.org/",
            "title" => "Elixir"
          }
        },
        %{"type" => "response.completed", "response" => responses_document()}
      ])

    refute Enum.any?(events, &(&1.type in [:tool_call_start, :tool_call_delta, :tool_call_done]))

    assert Enum.any?(
             events,
             &match?(
               %{type: :provider_hosted_event, content: %{data: %{"status" => "completed"}}},
               &1
             )
           )

    assert List.last(events).stop_reason == :stop
  end

  test "same-session switches capture historical evidence at destination in both directions" do
    for {source, destination, document} <- [
          {:anthropic, :openai_responses, anthropic_document()},
          {:openai_responses, :anthropic, responses_document()}
        ] do
      assert {:ok, decoded} = Codec.decode_response(source, 200, [], document)
      request = request(decoded.output)
      before = request
      assert {:ok, body} = Codec.encode_request(destination, request)
      assert request == before
      assert {:ok, json} = Serialization.to_json(body)
      assert json =~ "Historical provider-hosted web search evidence"
      assert json =~ "https://elixir-lang.org/"
      assert json =~ Atom.to_string(source)
      assert json =~ "Elixir"
      refute body["tools"]

      refute Enum.any?(
               body["input"] || body["messages"],
               &(&1["type"] in ["function_call", "web_search_call"])
             )

      assert {:ok, encoded} = Serialization.to_json(request)
      assert {:ok, %{"input" => [%{"content" => blocks} | _]}} = Serialization.from_json(encoded)
      for block <- blocks, do: assert({:ok, %ContentBlock{}} = ContentBlock.new(block))
    end
  end

  test "an unresolved search stays unresolved across provider switch" do
    assert {:ok, %{output: [%{type: :hosted_search, data: %{"status" => "unresolved"}}] = output}} =
             Codec.decode_response(:anthropic, 200, [], %{
               anthropic_document()
               | "content" => [@call]
             })

    assert {:ok, body} = Codec.encode_request(:openai_responses, request(output))
    refute Map.has_key?(hd(output).data, "result")
    assert {:ok, json} = Serialization.to_json(body)
    assert json =~ "unresolved"
    refute json =~ "function_call"
    refute json =~ ~s(\"result\")
  end

  test "streamed search history projects on the next provider turn without repeating searches" do
    cases = [
      {:anthropic, :openai_responses,
       [
         start(0, @call),
         stop(0),
         start(1, @result),
         stop(1),
         start(2, %{"type" => "text", "text" => ""}),
         delta(2, %{"type" => "text_delta", "text" => "Found Elixir"}),
         delta(2, %{"type" => "citations_delta", "citation" => @citation}),
         stop(2),
         %{"type" => "message_stop"}
       ]},
      {:openai_responses, :anthropic,
       [
         %{
           "type" => "response.output_item.added",
           "output_index" => 0,
           "item" => %{@responses_call | "status" => "in_progress"}
         },
         %{
           "type" => "response.web_search_call.completed",
           "output_index" => 0,
           "item_id" => "ws_search"
         },
         %{"type" => "response.output_item.done", "output_index" => 0, "item" => @responses_call},
         %{
           "type" => "response.output_text.delta",
           "output_index" => 1,
           "content_index" => 0,
           "delta" => "Found Elixir"
         },
         %{
           "type" => "response.output_text.annotation.added",
           "output_index" => 1,
           "content_index" => 0,
           "annotation" => %{
             "type" => "url_citation",
             "url" => "https://elixir-lang.org/",
             "title" => "Elixir"
           }
         },
         %{"type" => "response.completed", "response" => responses_document()}
       ]}
    ]

    for {source, destination, frames} <- cases do
      journal = stream(source, frames)
      original_journal = journal

      derived =
        Enum.reduce(journal, %{searches: %{}, text: "", citations: []}, fn
          %{type: :provider_hosted_event, content: block}, acc ->
            put_in(acc.searches[block.data["id"]], block)

          %{type: :text_delta, text: text}, acc ->
            %{acc | text: acc.text <> text}

          %{type: :citation, content: %{"citation" => citation}}, acc ->
            %{acc | citations: acc.citations ++ [citation]}

          _event, acc ->
            acc
        end)

      assert [search] = Map.values(derived.searches)
      assert search.data["status"] == "completed"
      search = %{search | extensions: %{"backplane::source" => %{"provider" => "source-account"}}}

      assert {:ok, text} =
               HostedSearch.text(derived.text, derived.citations, Atom.to_string(source))

      assert {:ok, body} = Codec.encode_request(destination, request([search, text]))
      assert {:ok, captured} = Serialization.to_json(body)
      assert captured =~ "Found Elixir"
      assert captured =~ "https://elixir-lang.org/"
      assert captured =~ "source-account"
      refute body["tools"]
      assert journal == original_journal

      refute Enum.any?(
               journal,
               &(&1.type in [:tool_call_start, :tool_call_delta, :tool_call_done])
             )

      if source == :openai_responses do
        assert Enum.any?(journal, &match?(%{type: :text_delta, index: 1, content_index: 0}, &1))
      end
    end
  end

  test "malformed hosted identities and unmatched results fail explicitly" do
    for content <- [
          [%{@call | "id" => ""}],
          [@call, @call],
          [@call, %{@result | "tool_use_id" => "other"}],
          [%{@call | "name" => "unexpected_server_tool"}]
        ] do
      assert {:error, %Error{}} =
               Codec.decode_response(:anthropic, 200, [], %{
                 anthropic_document()
                 | "content" => content
               })
    end

    assert {:error, %Error{}} =
             ContentBlock.new(%{
               type: :hosted_search,
               data: %{
                 "source_protocol" => "anthropic",
                 "id" => "search",
                 "status" => "completed"
               }
             })
  end

  test "Responses terminal search evidence must match its observed completion" do
    added = %{
      "type" => "response.output_item.added",
      "output_index" => 0,
      "item" => %{@responses_call | "status" => "in_progress"}
    }

    done = %{
      "type" => "response.output_item.done",
      "output_index" => 0,
      "item" => @responses_call
    }

    assert {:ok, state, _} =
             Codec.stream_feed(
               :openai_responses,
               Codec.stream_new(:openai_responses),
               frame(added) <> frame(done)
             )

    changed =
      put_in(responses_document(), ["output", Access.at(0), "action", "query"], "different")

    terminal = %{"type" => "response.completed", "response" => changed}
    assert {:error, %Error{}, _} = Codec.stream_feed(:openai_responses, state, frame(terminal))
  end

  test "search observations retain aggregate bounds" do
    first = %{@responses_call | "id" => "first", "status" => "in_progress"}
    second = %{@responses_call | "id" => "second", "status" => "in_progress"}
    opts = [limits: %{max_list_length: 1}]

    assert {:ok, state, _} =
             Codec.stream_feed(
               :openai_responses,
               Codec.stream_new(:openai_responses, opts),
               frame(%{
                 "type" => "response.output_item.added",
                 "output_index" => 0,
                 "item" => first
               })
             )

    assert {:error, %Error{}, _} =
             Codec.stream_feed(
               :openai_responses,
               state,
               frame(%{
                 "type" => "response.output_item.added",
                 "output_index" => 1,
                 "item" => second
               })
             )
  end

  test "malformed declarations and search result bodies fail before becoming evidence" do
    for options <- [
          %{external_web_access: "true"},
          %{filters: %{unsupported: []}},
          %{filters: %{blocked_domains: ["example.org"]}},
          %{search_context_size: "huge"}
        ] do
      declaration = Map.merge(%{type: "web_search"}, options)

      assert {:error, %Error{}} =
               Codec.encode_request(:openai_responses, request([], [declaration]))
    end

    invalid = %{@result | "content" => ["untyped evidence"]}

    assert {:error, %Error{}} =
             Codec.decode_response(:anthropic, 200, [], %{
               anthropic_document()
               | "content" => [@call, invalid]
             })
  end

  test "streaming large uncited text keeps its existing bounded-framing behavior" do
    text = String.duplicate("x", 100_000)

    frames =
      [start(0, %{"type" => "text", "text" => ""})] ++
        List.duplicate(delta(0, %{"type" => "text_delta", "text" => text}), 4) ++
        [stop(0), %{"type" => "message_stop"}]

    events = stream(:anthropic, frames)

    assert events |> Enum.filter(&(&1.type == :text_delta)) |> Enum.map_join(& &1.text) ==
             String.duplicate(text, 4)
  end

  defp request(output, hosted_tools \\ []) do
    input =
      if output == [],
        do: [%{role: :user, content: [%{type: :text, text: "Search Elixir"}]}],
        else: [
          %{role: :assistant, content: output},
          %{role: :user, content: [%{type: :text, text: "Continue with this evidence"}]}
        ]

    extensions =
      if hosted_tools == [], do: %{}, else: %{"backplane::hosted_tools" => hosted_tools}

    {:ok, request} = Request.new(%{model: "fixture-model", input: input, extensions: extensions})
    request
  end

  defp anthropic_document,
    do: %{
      "stop_reason" => "end_turn",
      "model" => "claude-test",
      "content" => [
        @call,
        @result,
        %{"type" => "text", "text" => "Found Elixir", "citations" => [@citation]}
      ]
    }

  defp responses_document,
    do: %{
      "status" => "completed",
      "model" => "gpt-test",
      "output" => [
        @responses_call,
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "Found Elixir",
              "annotations" => [
                %{
                  "type" => "url_citation",
                  "url" => "https://elixir-lang.org/",
                  "title" => "Elixir"
                }
              ]
            }
          ]
        }
      ]
    }

  defp start(index, block),
    do: %{"type" => "content_block_start", "index" => index, "content_block" => block}

  defp delta(index, delta),
    do: %{"type" => "content_block_delta", "index" => index, "delta" => delta}

  defp stop(index), do: %{"type" => "content_block_stop", "index" => index}

  defp frame(event),
    do: "event: " <> event["type"] <> "\ndata: " <> Formata.JSON.encode!(event) <> "\n\n"

  defp stream(protocol, frames) do
    bytes = Enum.map_join(frames, &frame/1)
    chunks = for <<chunk::binary-size(7) <- bytes>>, do: chunk
    offset = length(chunks) * 7
    chunks = chunks ++ [binary_part(bytes, offset, byte_size(bytes) - offset)]

    {state, events} =
      Enum.reduce(chunks, {Codec.stream_new(protocol), []}, fn chunk, {state, events} ->
        assert {:ok, next, emitted} = Codec.stream_feed(protocol, state, chunk)
        {next, events ++ emitted}
      end)

    assert {:ok, _, trailing} = Codec.stream_finish(protocol, state, :eof)
    events ++ trailing
  end
end
