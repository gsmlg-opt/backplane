defmodule Backplane.AiProtocol.ResponsesImageTest do
  use ExUnit.Case, async: false

  alias Backplane.AiProtocol.{
    Codec,
    ContentBlock,
    Error,
    Message,
    Request,
    Serialization,
    ToolCall
  }

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg=="
  @uri "data:image/png;base64," <> @png

  test "independent native function and custom fixture retains ordered image outputs" do
    request = fixture_request()
    assert {:ok, wire} = Codec.encode_request(:openai_responses, request)
    assert wire == fixture()
  end

  test "all image details and the explicit auto default survive both data forms and JSON reload" do
    for kind <- [:function, :custom],
        detail <- [nil, "auto", "low", "high", "original"],
        data <- [@png, @uri],
        status <- [nil, :success] do
      request = request(kind, [image(data, detail)], status)
      restored = reload(request)
      assert restored == request
      assert {:ok, wire} = Codec.encode_request(:openai_responses, restored)

      assert [_, %{"call_id" => id, "type" => type, "output" => [output]}] = wire["input"]
      assert id == "image_#{kind}"

      assert type ==
               if(kind == :custom, do: "custom_tool_call_output", else: "function_call_output")

      assert output == %{
               "type" => "input_image",
               "image_url" => @uri,
               "detail" => detail || "auto"
             }
    end
  end

  test "supported MIME types encode without sniffing or changing bytes" do
    for mime <- ~w(image/png image/jpeg image/webp image/gif),
        data <- [@png, "data:#{mime};base64," <> @png] do
      block = %{type: :image, data: %{"data" => data, "mime_type" => mime}}
      assert {:ok, wire} = Codec.encode_request(:openai_responses, request(:function, [block]))

      assert List.last(wire["input"])["output"] == [
               %{
                 "type" => "input_image",
                 "image_url" => "data:#{mime};base64," <> @png,
                 "detail" => "auto"
               }
             ]
    end
  end

  test "unsupported and malformed opaque image forms reject explicitly before submission" do
    for data <- [
          "opaque",
          %{},
          %{"data" => @png},
          %{"mime_type" => "image/png"},
          %{"data" => "", "mime_type" => "image/png"},
          %{"data" => "!!!!", "mime_type" => "image/png"},
          %{"data" => @png, "mime_type" => "image/svg+xml"},
          %{"data" => "https://example.test/a.png", "mime_type" => "image/png"},
          %{"data" => "data:image/jpeg;base64," <> @png, "mime_type" => "image/png"},
          %{"data" => "data:image/png," <> @png, "mime_type" => "image/png"},
          %{"data" => "data:image/png;charset=utf-8;base64," <> @png, "mime_type" => "image/png"},
          %{"data" => "data:image/png;base64,", "mime_type" => "image/png"},
          %{"file_id" => "file_1", "mime_type" => "image/png"},
          %{"data" => @png, "mime_type" => "image/png", "uri" => "https://example.test/a.png"},
          %{"data" => @png, "mime_type" => "image/png", "detail" => "maximum"},
          %{"data" => @png, "mime_type" => "image/png", "detail" => nil},
          %{"data" => @png, "mime_type" => "image/png", "detail" => 1}
        ] do
      assert {:ok, _} = ContentBlock.new(%{type: :image, data: data})
      assert_incompatible(request(:function, [%{type: :image, data: data}]))
    end
  end

  test "new image route refuses metadata, other content and non-tool image roles" do
    for kind <- [:function, :custom] do
      for block <- [
            Map.put(image(), :extensions, %{"fixture::tag" => true}),
            Map.put(image(), :reason, "retain this"),
            %{type: :text, text: "text", extensions: %{"fixture::tag" => true}},
            %{type: :text, text: "text", reason: "retain this"},
            %{type: :refusal, text: "refused"},
            %{type: :audio, data: %{"mime_type" => "audio/wav", "data" => "AA=="}}
          ] do
        assert_incompatible(request(kind, [image(), block]))
      end

      request = request(kind, [image()])
      [call, result] = request.input

      assert_incompatible(%{
        request
        | input: [call, %{result | extensions: %{"fixture::tag" => true}}]
      })
    end

    for role <- [:user, :assistant, :system, :developer] do
      assert {:ok, request} =
               Request.new(%{model: "fixture", input: [%{role: role, content: [image()]}]})

      assert_incompatible(request)
    end
  end

  test "error result status survives reload and cannot be erased for either output kind" do
    for kind <- [:function, :custom], content <- [[image()], [%{type: :text, text: "failed"}]] do
      request = reload(request(kind, content, :error))
      assert List.last(request.input).status == :error
      assert_incompatible(request)
    end
  end

  test "ordinary text-only results retain string output and typed calls must precede results" do
    for kind <- [:function, :custom], status <- [nil, :success] do
      request =
        request(kind, [%{type: :text, text: "first"}, %{type: :text, text: "second"}], status)

      assert {:ok, wire} = Codec.encode_request(:openai_responses, request)
      assert List.last(wire["input"])["output"] == "first\nsecond"
      [call, result] = request.input

      assert {:error, %Error{}} =
               Codec.encode_request(:openai_responses, %{request | input: [result, call]})

      assert {:error, %Error{}} =
               Codec.encode_request(:openai_responses, %{request | input: [result]})
    end
  end

  test "canonical reload feeds exact public codec JSON through an actual HTTP host client" do
    request = fixture_request() |> reload()
    assert {:ok, wire} = Codec.encode_request(:openai_responses, request)
    assert {:ok, json} = Serialization.to_json(wire)
    Enum.each([:inets, :ssl, :public_key, :asn1, :crypto], &Mix.ensure_application!/1)
    assert {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    server = Task.async(fn -> capture(listener) end)
    url = ~c"http://127.0.0.1:#{port}/v1/responses"

    assert {:ok, {{_, 200, _}, _, _}} =
             :httpc.request(:post, {url, [], ~c"application/json", json}, [timeout: 5_000], [])

    {headers, captured} = Task.await(server, 5_000)
    assert headers =~ "POST /v1/responses HTTP/1.1"
    assert captured == json
    assert Jason.decode!(captured) == fixture()
  end

  test "bounded opaque construction and the three legacy image representations remain compatible" do
    assert {:ok, %{data: "opaque"}} = ContentBlock.new(%{type: :image, data: "opaque"})
    assert {:error, %Error{}} = ContentBlock.new(image(), limits: %{max_string_bytes: 8})

    for {protocol, data, expected} <- [
          {:anthropic, %{"source" => "base64", "media_type" => "image/png", "data" => @png},
           %{
             "type" => "image",
             "source" => %{"type" => "base64", "media_type" => "image/png", "data" => @png}
           }},
          {:openai, %{"source" => "base64", "media_type" => "image/png", "data" => @png},
           %{"type" => "image_url", "image_url" => %{"url" => @uri}}},
          {:google, %{"source" => "base64", "media_type" => "image/png", "data" => @png},
           %{"inlineData" => %{"mimeType" => "image/png", "data" => @png}}}
        ] do
      assert {:ok, request} =
               Request.new(%{
                 model: "fixture",
                 input: [%{role: :user, content: [%{type: :image, data: data}]}]
               })

      assert {:ok, wire} = Codec.encode_request(protocol, request)

      content =
        if protocol == :google,
          do: hd(wire["contents"])["parts"],
          else: hd(wire["messages"])["content"]

      assert content == [expected]
    end
  end

  defp image(data \\ @png, detail \\ "original") do
    data = %{"data" => data, "mime_type" => "image/png"}
    %{type: :image, data: if(is_nil(detail), do: data, else: Map.put(data, "detail", detail))}
  end

  defp request(kind, content, status \\ :success) do
    raw = if kind == :custom, do: {:custom, "image.png"}, else: {:structured, %{}}

    {:ok, request} =
      Request.new(%{
        model: "fixture",
        input: [
          %{
            role: :assistant,
            content: [
              %{
                type: :tool_call,
                tool_call: %{id: "image_#{kind}", name: "read_image", raw_arguments: raw}
              }
            ]
          },
          %{role: :tool, tool_call_id: "image_#{kind}", status: status, content: content}
        ]
      })

    request
  end

  defp fixture_request do
    function =
      request(:function, [%{type: :text, text: "before"}, image(), %{type: :text, text: "after"}])

    custom =
      request(:custom, [
        %{type: :text, text: "before"},
        image(@uri),
        %{type: :text, text: "after"}
      ])

    %{function | input: function.input ++ custom.input}
  end

  defp fixture,
    do:
      __DIR__
      |> Path.join("../fixtures/openai_responses/image_tool_results.json")
      |> File.read!()
      |> Jason.decode!()

  defp reload(request) do
    assert {:ok, json} = Serialization.to_json(request)
    assert {:ok, attrs} = Serialization.from_json(json)

    input =
      Enum.map(attrs["input"], fn message ->
        blocks =
          Enum.map(message["content"], fn
            %{"type" => "tool_call", "tool_call" => call} ->
              raw = call["raw_arguments"]

              encoding =
                case raw["encoding"] do
                  "custom" -> :custom
                  "structured" -> :structured
                end

              assert {:ok, call} =
                       ToolCall.new(%{
                         id: call["id"],
                         name: call["name"],
                         raw_arguments: {encoding, raw["value"]}
                       })

              %{type: :tool_call, tool_call: call}

            block ->
              block
          end)

        role = if message["role"] == "tool", do: :tool, else: :assistant

        status =
          case message["status"] do
            "success" -> :success
            "error" -> :error
            nil -> nil
          end

        assert {:ok, restored} =
                 Message.new(%{
                   role: role,
                   content: blocks,
                   status: status,
                   tool_call_id: message["tool_call_id"],
                   extensions: message["extensions"]
                 })

        restored
      end)

    assert {:ok, restored} = Request.new(%{model: attrs["model"], input: input})
    restored
  end

  defp assert_incompatible(request) do
    assert {:error,
            %Error{kind: :incompatible, stage: :translation, upstream_outcome: :not_submitted}} =
             Codec.encode_request(:openai_responses, request)
  end

  defp capture(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)

    try do
      {headers, body} = receive_headers(socket, "")
      [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
      body = receive_body(socket, body, String.to_integer(length))

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        )

      {headers, body}
    after
      :gen_tcp.close(socket)
    end
  end

  defp receive_headers(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        {headers, body}

      [_] ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
        receive_headers(socket, bytes <> chunk)
    end
  end

  defp receive_body(_socket, bytes, length) when byte_size(bytes) == length, do: bytes

  defp receive_body(socket, bytes, length) do
    {:ok, chunk} = :gen_tcp.recv(socket, length - byte_size(bytes), 5_000)
    receive_body(socket, bytes <> chunk, length)
  end
end
