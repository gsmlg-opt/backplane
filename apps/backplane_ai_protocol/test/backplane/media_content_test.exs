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

  defp encode_then_submit(protocol, request) do
    with {:ok, body} <- Codec.encode_request(protocol, request) do
      send(self(), :transport_submitted)
      {:ok, body}
    end
  end
end
