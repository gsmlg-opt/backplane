defmodule Backplane.AiProtocol.MediaContentTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{
    Codec,
    ContentBlock,
    Error,
    Message,
    Request,
    Serialization,
    Translation
  }

  @audio %{type: :audio, data: %{"mime_type" => "audio/wav", "data" => "UklGRg=="}}
  @resource %{
    type: :resource,
    data: %{"uri" => "fixture://document", "mime_type" => "text/plain", "text" => "Fixture"}
  }
  @link %{type: :resource_link, data: %{"uri" => "fixture://document", "name" => "Fixture"}}
  @pdf_resource %{
    type: :resource,
    data: %{"uri" => "https://example.invalid/document.pdf", "mime_type" => "application/pdf"}
  }
  @pdf_link %{
    type: :resource_link,
    data: %{
      "uri" => "https://example.invalid/link.pdf",
      "mime_type" => "application/pdf",
      "name" => "Reference"
    }
  }

  test "audio and resource identities retain inline bodies, references and portable metadata" do
    fixtures = [
      @audio,
      @resource,
      @link,
      %{
        type: :audio,
        data: %{"uri" => "https://example.invalid/sound.wav", "mime_type" => "audio/wav"}
      },
      %{
        type: :resource,
        data: %{"uri" => "gs://fixture/document.pdf", "mime_type" => "application/pdf"}
      },
      %{
        type: :resource,
        data: %{
          "uri" => "fixture://bytes",
          "mime_type" => "application/octet-stream",
          "data" => "AAE="
        }
      },
      %{
        type: :resource_link,
        data: %{
          "uri" => "fixture://document",
          "name" => "Fixture",
          "mime_type" => "text/plain",
          "title" => "Title",
          "description" => "Description",
          "size" => 7
        }
      }
    ]

    for fixture <- fixtures do
      attrs =
        Map.put(fixture, :extensions, %{
          "mcp::annotations" => %{"audience" => ["assistant"]},
          "host::provenance" => %{"source" => "fixture"}
        })

      assert {:ok, block} = ContentBlock.new(attrs)
      assert block.type == fixture.type
      assert block.data == fixture.data
      assert {:ok, json} = Serialization.to_json(block)
      assert {:ok, ^block} = Serialization.decode_and_validate(json, &ContentBlock.new/1)
    end
  end

  test "mixed tool results retain media order, failed status and metadata through bounded JSON" do
    assert {:ok, message} =
             Message.new(%{
               role: :tool,
               tool_call_id: "call-1",
               status: :error,
               content: [
                 %{type: :text, text: "before"},
                 @audio,
                 @resource,
                 @link,
                 %{type: :text, text: "after"}
               ],
               extensions: %{"mcp::result" => %{"structuredContent" => %{"ok" => false}}}
             })

    assert {:ok, json} = Serialization.to_json(message)

    assert {:ok, restored} =
             Serialization.decode_and_validate(json, fn attrs ->
               Message.new(%{
                 role: :tool,
                 tool_call_id: attrs["tool_call_id"],
                 status: :error,
                 content: attrs["content"],
                 extensions: attrs["extensions"]
               })
             end)

    assert restored == message

    assert Enum.map(restored.content, & &1.type) == [
             :text,
             :audio,
             :resource,
             :resource_link,
             :text
           ]

    assert {:error, %Error{kind: :invalid_request}} =
             Serialization.decode_and_validate(json, &ContentBlock.new/1, max_encoded_bytes: 8)
  end

  test "malformed media cannot pass typed validation" do
    malformed = [
      %{type: :audio, data: %{}},
      %{type: :audio, data: %{"mime_type" => "text/plain", "data" => "AA=="}},
      %{type: :audio, data: %{"mime_type" => "audio/wav", "data" => "not base64"}},
      %{type: :audio, data: %{"mime_type" => "audio/wav", "data" => ""}},
      %{type: :audio, data: %{"mime_type" => "audio/wav", "uri" => "relative/path"}},
      %{type: :audio, data: %{"mime_type" => "audio/wav", "uri" => "https://"}},
      %{
        type: :audio,
        data: %{"mime_type" => "audio/wav", "data" => "AA==", "uri" => "fixture://audio"}
      },
      %{type: :resource, data: %{"mime_type" => "text/plain", "text" => "missing URI"}},
      %{
        type: :resource,
        data: %{"uri" => "fixture://document", "mime_type" => "invalid", "text" => "x"}
      },
      %{
        type: :resource,
        data: %{
          "uri" => "fixture://document",
          "mime_type" => "text/plain",
          "text" => "x",
          "data" => "AA=="
        }
      },
      %{type: :resource_link, data: %{"uri" => "fixture://document"}},
      %{
        type: :resource_link,
        data: %{"uri" => "fixture://document", "name" => "Fixture", "size" => -1}
      },
      %{
        type: :resource_link,
        data: %{"uri" => "fixture://document", "name" => "Fixture", "text" => "hidden body"}
      },
      Map.put(@audio, :text, "competing primary content"),
      %{type: :audio, data: %{mime_type: "audio/wav", data: "AA=="}}
    ]

    for attrs <- malformed do
      assert {:error, %Error{kind: :invalid_request}} = ContentBlock.new(attrs)
    end
  end

  test "media data and metadata use existing configurable structural limits" do
    assert {:error, %Error{kind: :invalid_request}} =
             ContentBlock.new(@audio, limits: %{max_string_bytes: 4})

    assert {:error, %Error{kind: :invalid_request}} =
             ContentBlock.new(
               Map.put(@resource, :extensions, %{"mcp::annotations" => String.duplicate("x", 40)}),
               limits: %{max_string_bytes: 32}
             )

    assert {:error, %Error{kind: :invalid_request}} =
             ContentBlock.new(@resource, limits: %{max_nodes: 2})

    assert {:error, %Error{kind: :invalid_request}} =
             ContentBlock.new(%{
               type: :resource,
               data: %{
                 "uri" => "fixture://bytes",
                 "mime_type" => "application/octet-stream",
                 "data" => <<255>>
               }
             })
  end

  test "caller limits reach Google audio and Anthropic PDF tool-reference encoding" do
    opts = [limits: %{max_string_bytes: 300_000, max_bytes: 600_000}]
    audio_data = Base.encode64(String.duplicate("a", 200_000))
    audio = put_in(@audio, [:data, "data"], audio_data)

    assert {:ok, request} =
             Request.new(%{model: "fixture", input: [%{role: :user, content: [audio]}]}, opts)

    assert {:error, %Error{kind: :invalid_request}} = Codec.encode_request(:google, request)
    assert {:ok, wire} = Codec.encode_request(:google, request, opts)

    assert hd(wire["contents"])["parts"] == [
             %{"inlineData" => %{"mimeType" => "audio/wav", "data" => audio_data}}
           ]

    # OpenAI's final audio encoder retains its existing default-limit wrapper.
    assert {:error, %Error{kind: :invalid_request}} = Codec.encode_request(:openai, request, opts)

    uri = "https://example.invalid/" <> String.duplicate("x", 263_000) <> ".pdf"
    block = put_in(@pdf_resource, [:data, "uri"], uri)

    assert {:ok, message} =
             Message.new(%{role: :tool, tool_call_id: "call-pdf", content: [block]}, opts)

    request = tool_request(message, opts)
    assert {:error, %Error{kind: :invalid_request}} = Codec.encode_request(:anthropic, request)
    assert {:ok, wire} = Codec.encode_request(:anthropic, request, opts)

    assert List.last(wire["messages"])["content"] == [
             %{
               "type" => "tool_result",
               "tool_use_id" => "call-pdf",
               "is_error" => false,
               "content" => [
                 %{"type" => "document", "source" => %{"type" => "url", "url" => uri}}
               ]
             }
           ]
  end

  test "all media preflights apply smaller caller limits while old content has no aggregate budget" do
    request = user_request([@audio])

    for protocol <- [:anthropic, :openai, :openai_responses, :google] do
      assert {:error, %Error{kind: :invalid_request}} =
               Codec.encode_request(protocol, request, limits: %{max_string_bytes: 4})
    end

    reference = %{
      type: :resource,
      data: %{"uri" => "gs://fixture/report.pdf", "mime_type" => "application/pdf"}
    }

    for {protocol, block} <- [{:openai, @audio}, {:google, @audio}, {:google, reference}] do
      assert {:ok, _} =
               Codec.encode_request(protocol, user_request([block, block]),
                 limits: %{max_list_length: 1}
               )
    end
  end

  test "OpenAI Chat encodes inline WAV and MP3 user audio without changing content order" do
    for {mime, format} <- [{"audio/wav", "wav"}, {"audio/mpeg", "mp3"}] do
      audio = put_in(@audio, [:data, "mime_type"], mime)

      request =
        user_request([%{type: :text, text: "before"}, audio, %{type: :text, text: "after"}])

      assert {:ok, wire} = Codec.encode_request(:openai, request)

      assert [
               %{"type" => "text", "text" => "before"},
               %{
                 "type" => "input_audio",
                 "input_audio" => %{"format" => ^format, "data" => "UklGRg=="}
               },
               %{"type" => "text", "text" => "after"}
             ] = hd(wire["messages"])["content"]
    end
  end

  test "Google encodes inline audio and URI resource references as typed parts" do
    reference = %{
      type: :resource,
      data: %{"uri" => "gs://fixture/document.pdf", "mime_type" => "application/pdf"}
    }

    assert {:ok, %{body: body}} =
             Codec.encode_rest_request(
               :google,
               user_request([%{type: :text, text: "before"}, @audio, reference])
             )

    assert [
             %{"text" => "before"},
             %{"inlineData" => %{"mimeType" => "audio/wav", "data" => "UklGRg=="}},
             %{
               "fileData" => %{
                 "mimeType" => "application/pdf",
                 "fileUri" => "gs://fixture/document.pdf"
               }
             }
           ] =
             hd(body["contents"])["parts"]
  end

  test "unsupported media, metadata and role combinations reject before a transport can submit" do
    for protocol <- [:anthropic, :openai, :openai_responses, :google],
        block <- [@resource, @link] do
      assert {:error, %Error{kind: :incompatible, upstream_outcome: :not_submitted}} =
               encode_then_submit(protocol, user_request([block]))
    end

    for protocol <- [:anthropic, :openai_responses] do
      assert {:error, %Error{kind: :incompatible, upstream_outcome: :not_submitted}} =
               encode_then_submit(protocol, user_request([@audio]))
    end

    for protocol <- [:openai, :google] do
      annotated = Map.put(@audio, :extensions, %{"mcp::annotations" => %{"priority" => 1}})

      assert {:error, %Error{kind: :incompatible, upstream_outcome: :not_submitted}} =
               encode_then_submit(protocol, user_request([annotated]))

      for role <- [:system, :developer, :assistant] do
        assert {:ok, request} =
                 Request.new(%{model: "fixture", input: [%{role: role, content: [@audio]}]})

        assert {:error, %Error{kind: :incompatible, upstream_outcome: :not_submitted}} =
                 encode_then_submit(protocol, request)
      end

      for block <- [
            %{
              type: :audio,
              data: %{"mime_type" => "audio/wav", "uri" => "https://example.invalid/audio.wav"}
            },
            %{type: :audio, data: %{"mime_type" => "audio/unknown", "data" => "AA=="}}
          ] do
        assert {:error, %Error{kind: :incompatible, upstream_outcome: :not_submitted}} =
                 encode_then_submit(protocol, user_request([block]))
      end
    end

    refute_received :transport_submitted
  end

  test "all codecs explicitly reject mixed media tool results without flattening or Google overrides" do
    for protocol <- [:anthropic, :openai, :openai_responses, :google] do
      assert {:ok, request} =
               Request.new(%{
                 model: "fixture",
                 input: [
                   %{
                     role: :assistant,
                     content: [
                       %{
                         type: :tool_call,
                         tool_call: %{id: "call-1", name: "read", raw_arguments: {:json, "{}"}}
                       }
                     ]
                   },
                   %{
                     role: :tool,
                     tool_call_id: "call-1",
                     content: [%{type: :text, text: "before"}, @audio, @resource, @link],
                     extensions: %{
                       "google::function_response" => %{"result" => "must not hide media"}
                     }
                   }
                 ]
               })

      assert {:error, %Error{kind: :incompatible, upstream_outcome: :not_submitted}} =
               encode_then_submit(protocol, request)
    end

    refute_received :transport_submitted
  end

  for status <- [:success, :error] do
    is_error = status == :error

    test "Anthropic PDF references preserve canonical JSON reload and #{status} tool status" do
      status = unquote(status)
      message = tool_message([@pdf_resource, @pdf_link], status)
      restored = restore_tool_message(message)
      assert restored == message
      assert Enum.map(restored.content, & &1.type) == [:resource, :resource_link]
      assert Enum.map(restored.content, & &1.data) == [@pdf_resource.data, @pdf_link.data]

      assert {:ok, wire} = Codec.encode_request(:anthropic, tool_request(restored))
      expected = Map.put(pdf_tool_result_fixture(), "is_error", unquote(is_error))
      assert List.last(wire["messages"]) == %{"role" => "user", "content" => [expected]}
      assert restored == message
    end
  end

  test "Anthropic native PDF references retain mixed text and image tool-result order" do
    image = %{
      type: :image,
      data: %{"source" => "base64", "media_type" => "image/png", "data" => "AA=="}
    }

    message =
      tool_message([
        %{type: :text, text: "before"},
        image,
        @pdf_resource,
        @pdf_link,
        %{type: :text, text: "after"}
      ])

    assert {:ok, wire} =
             Codec.encode_request(:anthropic, tool_request(restore_tool_message(message)))

    assert %{"content" => [%{"content" => content} = result]} = List.last(wire["messages"])
    assert result["tool_use_id"] == "call-pdf"
    assert result["is_error"] == false

    expected = [
      %{"type" => "text", "text" => "before"},
      %{
        "type" => "image",
        "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "AA=="}
      }
    ]

    assert content ==
             expected ++
               pdf_tool_result_fixture()["content"] ++ [%{"type" => "text", "text" => "after"}]
  end

  test "Anthropic PDF links copy their exact URI and display name without normalizing canonical data" do
    uri = "https://Example.invalid/report%20one.pdf?version=2&tag=%2F#page=3"
    name = "报告 / PDF reference"
    block = %{@pdf_link | data: %{@pdf_link.data | "uri" => uri, "name" => name}}
    message = tool_message([block])

    assert {:ok, wire} =
             Codec.encode_request(:anthropic, tool_request(restore_tool_message(message)))

    assert %{
             "content" => [
               %{
                 "content" => [
                   %{"type" => "document", "title" => ^name, "source" => source}
                 ]
               }
             ]
           } = List.last(wire["messages"])

    assert source == %{"type" => "url", "url" => uri}
    assert hd(message.content).type == :resource_link
    assert hd(message.content).data == block.data
  end

  test "PDF tool media rejects each extra body or metadata field before submission" do
    extra_forms = [
      Map.put(@pdf_resource, :data, Map.put(@pdf_resource.data, "text", "inline text")),
      Map.put(@pdf_resource, :data, Map.put(@pdf_resource.data, "data", "AA==")),
      Map.put(@pdf_link, :data, Map.put(@pdf_link.data, "title", "Reference")),
      Map.put(@pdf_link, :data, Map.put(@pdf_link.data, "description", "Description")),
      Map.put(@pdf_link, :data, Map.put(@pdf_link.data, "size", 0))
    ]

    for block <- extra_forms do
      assert_tool_media_incompatible(:anthropic, tool_message([block]))
    end

    for block <- [@pdf_resource, @pdf_link] do
      annotated = Map.put(block, :extensions, %{"mcp::annotations" => %{"priority" => 1}})
      assert_tool_media_incompatible(:anthropic, tool_message([annotated]))

      message = tool_message([block])

      for metadata <- [
            %{"mcp::result" => %{"structuredContent" => %{"ok" => true}}},
            %{"google::function_response" => %{"result" => "must not hide metadata"}}
          ] do
        assert_tool_media_incompatible(:anthropic, %{message | extensions: metadata})
      end
    end

    refute_received :transport_submitted
  end

  test "PDF tool media rejects unsupported MIME, URI scheme and missing link MIME" do
    for block <- [@pdf_resource, @pdf_link],
        mime <- ["text/plain", "application/octet-stream", "application/pdf; charset=utf-8"],
        do:
          assert_tool_media_incompatible(
            :anthropic,
            tool_message([%{block | data: Map.put(block.data, "mime_type", mime)}])
          )

    for block <- [@pdf_resource, @pdf_link],
        uri <- ["http://example.invalid/file.pdf", "gs://fixture/file.pdf", "fixture://file.pdf"],
        do:
          assert_tool_media_incompatible(
            :anthropic,
            tool_message([%{block | data: Map.put(block.data, "uri", uri)}])
          )

    assert_tool_media_incompatible(
      :anthropic,
      tool_message([%{@pdf_link | data: Map.delete(@pdf_link.data, "mime_type")}])
    )

    refute_received :transport_submitted
  end

  test "new PDF tool routes do not admit other protocols, message roles or tool audio" do
    for protocol <- [:openai, :openai_responses, :google], block <- [@pdf_resource, @pdf_link] do
      assert_tool_media_incompatible(protocol, tool_message([block]))
    end

    for role <- [:system, :developer, :user, :assistant], block <- [@pdf_resource, @pdf_link] do
      assert {:ok, request} =
               Request.new(%{model: "fixture", input: [%{role: role, content: [block]}]})

      assert {:error, %Error{kind: :incompatible, upstream_outcome: :not_submitted}} =
               encode_then_submit(:anthropic, request)
    end

    for protocol <- [:anthropic, :openai, :openai_responses, :google] do
      assert_tool_media_incompatible(protocol, tool_message([@audio]))
    end

    refute_received :transport_submitted
  end

  test "translation requires explicit media capabilities instead of inferring text support" do
    request = user_request([@audio])
    source = %{capabilities: %{"role_user" => :supported, "audio" => :supported}}

    assert {:error, %Error{kind: :incompatible}} =
             Translation.plan(request, source, %{capabilities: %{"role_user" => :supported}}, %{})

    assert {:ok, %{executable: true}} = Translation.plan(request, source, source, %{})
  end

  test "Google audio response and streaming content retain audio identity" do
    part = %{"inlineData" => %{"mimeType" => "audio/wav", "data" => "UklGRg=="}}
    document = %{"candidates" => [%{"content" => %{"parts" => [part]}, "finishReason" => "STOP"}]}

    assert {:ok, %{output: [%ContentBlock{type: :audio, data: data}]}} =
             Codec.decode_response(:google, 200, [], document)

    assert data == @audio.data
    state = Codec.stream_new(:google)

    assert {:ok, _, events} =
             Codec.stream_feed(:google, state, "data: " <> Jason.encode!(document) <> "\n\n")

    assert Enum.any?(
             events,
             &match?(%{type: :content, content: %ContentBlock{type: :audio, data: ^data}}, &1)
           )
  end

  test "Google resource responses retain URI identity and incoming media metadata" do
    part = %{
      "fileData" => %{
        "mimeType" => "application/pdf",
        "fileUri" => "gs://fixture/document.pdf",
        "displayName" => "Fixture"
      }
    }

    document = %{"candidates" => [%{"content" => %{"parts" => [part]}, "finishReason" => "STOP"}]}

    assert {:ok, %{output: [%ContentBlock{type: :resource} = block]}} =
             Codec.decode_response(:google, 200, [], document)

    assert block.data == %{"uri" => "gs://fixture/document.pdf", "mime_type" => "application/pdf"}
    assert block.extensions == %{"google::media_metadata" => %{"displayName" => "Fixture"}}

    assert {:error, %Error{kind: :incompatible, upstream_outcome: :not_submitted}} =
             Codec.encode_request(:google, user_request([block]))

    state = Codec.stream_new(:google)

    assert {:ok, _, events} =
             Codec.stream_feed(:google, state, "data: " <> Jason.encode!(document) <> "\n\n")

    assert Enum.any?(events, &match?(%{type: :content, content: ^block}, &1))
  end

  defp user_request(content) do
    assert {:ok, request} =
             Request.new(%{model: "fixture", input: [%{role: :user, content: content}]})

    request
  end

  defp tool_message(content, status \\ :success) do
    assert {:ok, message} =
             Message.new(%{
               role: :tool,
               tool_call_id: "call-pdf",
               status: status,
               content: content
             })

    message
  end

  defp tool_request(message, opts \\ []) do
    assert {:ok, request} =
             Request.new(
               %{
                 model: "fixture",
                 input: [
                   %{
                     role: :assistant,
                     content: [
                       %{
                         type: :tool_call,
                         tool_call: %{
                           id: "call-pdf",
                           name: "read_pdf",
                           raw_arguments: {:json, "{}"}
                         }
                       }
                     ]
                   },
                   message
                 ]
               },
               opts
             )

    request
  end

  defp restore_tool_message(message) do
    assert {:ok, json} = Serialization.to_json(message)

    assert {:ok, restored} =
             Serialization.decode_and_validate(json, fn attrs ->
               status =
                 case attrs["status"] do
                   "success" -> :success
                   "error" -> :error
                 end

               Message.new(%{
                 role: :tool,
                 tool_call_id: attrs["tool_call_id"],
                 status: status,
                 content: attrs["content"],
                 extensions: attrs["extensions"]
               })
             end)

    restored
  end

  defp pdf_tool_result_fixture do
    __DIR__
    |> Path.join("../fixtures/anthropic/pdf_tool_result.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp assert_tool_media_incompatible(protocol, message) do
    assert {:error, %Error{kind: :incompatible, upstream_outcome: :not_submitted}} =
             encode_then_submit(protocol, tool_request(message))
  end

  defp encode_then_submit(protocol, request) do
    with {:ok, body} <- Codec.encode_request(protocol, request) do
      send(self(), :transport_submitted)
      {:ok, body}
    end
  end
end
