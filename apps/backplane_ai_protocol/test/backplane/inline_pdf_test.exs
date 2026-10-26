defmodule Backplane.AiProtocol.InlinePdfTest do
  use ExUnit.Case, async: false

  alias Backplane.AiProtocol.{
    Codec,
    ContentBlock,
    Error,
    Media,
    Message,
    Request,
    Serialization,
    Validation
  }

  @paths [:anthropic, :google, :google_rest]
  @limits %{max_string_bytes: 13_981_016, max_bytes: 33_554_432}
  @opts [limits: @limits]
  @json_opts [limits: @limits, max_encoded_bytes: 33_554_432]

  test "public construction and JSON reload preserve two distinct PDFs and every prompt position" do
    request = fixture_request()
    assert {:ok, json} = Serialization.to_json(request)

    assert {:ok, restored} =
             Serialization.decode_and_validate(json, &restore(&1, @opts), @json_opts)

    assert restored == request

    assert Enum.map(hd(restored.input).content, & &1.type) == [
             :text,
             :resource,
             :text,
             :resource,
             :text
           ]

    for {block, name} <-
          Enum.zip(
            Enum.filter(hd(restored.input).content, &(&1.type == :resource)),
            ~w(first second)
          ) do
      assert block.data == %{
               "uri" => "file:///fixture/#{name}.pdf",
               "mime_type" => "application/pdf",
               "data" => Base.encode64(pdf(name))
             }
    end

    for path <- @paths do
      assert {:ok, wire} = encode(path, restored, @opts)
      assert wire == native_fixture(path)
      assert native_texts(path, wire) == ["before", "between", "after"]
      assert Enum.map(native_pdfs(path, wire), &Base.decode64!/1) == [pdf("first"), pdf("second")]
      refute Jason.encode!(wire) =~ "file:///fixture/"
    end

    assert {:ok, %{body: body, target: target}} =
             Codec.encode_rest_request(:google, restored, @opts)

    assert target == %{operation: :generate_content, model: "fixture-model", stream: false}
    refute Enum.any?(~w(model operation stream), &Map.has_key?(body, &1))
    assert {:ok, legacy} = Codec.encode_request(:google, restored, @opts)
    assert legacy == Map.merge(body, %{"model" => target.model, "stream" => target.stream})
  end

  test "canonical-only absolute identities are retained exactly and never become native metadata" do
    for uri <- [
          "file:///fixture/report%20one.pdf#page=2",
          "fixture://Report/one?x=%2F",
          "https://Example.invalid/a.pdf?x=1#page=3",
          "gs://fixture/report.pdf"
        ] do
      block = put_in(inline(pdf("first")), [:data, "uri"], uri)
      request = request([block]) |> reload()
      assert hd(hd(request.input).content).data["uri"] == uri

      for path <- @paths do
        assert {:ok, wire} = encode(path, request)
        assert native_pdfs(path, wire) == [Base.encode64(pdf("first"))]
        refute Jason.encode!(wire) =~ uri
      end
    end
  end

  test "a PDF above the default string budget traverses every explicit limits stage" do
    block = inline(sized_pdf(210_000))
    assert byte_size(block.data["data"]) > Validation.default_limits().max_string_bytes
    assert {:error, %Error{kind: :invalid_request}} = ContentBlock.new(block)
    assert {:ok, content} = ContentBlock.new(block, @opts)

    assert {:error, %Error{kind: :invalid_request}} =
             Message.new(%{role: :user, content: [content]})

    assert {:ok, message} = Message.new(%{role: :user, content: [content]}, @opts)

    assert {:error, %Error{kind: :invalid_request}} =
             Request.new(%{model: "fixture-model", input: [message]})

    assert {:ok, request} = Request.new(%{model: "fixture-model", input: [message]}, @opts)
    assert {:ok, json} = Serialization.to_json(request)

    assert {:error, %Error{kind: :invalid_request}} =
             Serialization.decode_and_validate(json, &restore(&1, @opts))

    assert {:error, %Error{kind: :invalid_request}} =
             Serialization.decode_and_validate(json, &restore(&1, []), @json_opts)

    assert {:ok, restored} =
             Serialization.decode_and_validate(json, &restore(&1, @opts), @json_opts)

    assert restored == request

    for path <- @paths do
      assert {:error, %Error{kind: :invalid_request}} = encode(path, restored)

      assert {:error, %Error{kind: :invalid_request}} =
               encode(path, restored, limits: %{max_string_bytes: 200_000})

      assert {:ok, wire} = encode(path, restored, @opts)
      assert native_pdfs(path, wire) == [block.data["data"]]
    end
  end

  @tag timeout: 120_000
  test "the fixed decoded ceiling accepts 10 MiB and rejects one byte more on every public path" do
    for size <- [10_485_760, 10_485_761] do
      bytes = sized_pdf(size)
      assert byte_size(bytes) == size
      request = request([inline(bytes)], @opts) |> reload(@opts, @json_opts)

      for path <- @paths do
        if size == 10_485_760 do
          assert {:ok, wire} = encode(path, request, @opts)
          assert Enum.map(native_pdfs(path, wire), &Base.decode64!/1) == [bytes]
        else
          assert_incompatible(encode(path, request, @opts))
        end
      end
    end
  end

  test "aggregate PDF maps use caller bytes across messages without budgeting the whole request" do
    block = inline(pdf("first"))
    map_bytes = Enum.sum(for {key, value} <- block.data, do: byte_size(key) + byte_size(value))
    opts = [limits: %{max_bytes: map_bytes}]
    one = request([block], opts)
    prompt = %{type: :text, text: String.duplicate("p", map_bytes)}
    two = %{one | input: one.input ++ request([prompt, block, prompt], opts).input}

    for path <- @paths do
      assert {:ok, _} = encode(path, one, opts)
      assert {:error, %Error{kind: :invalid_request, message: message}} = encode(path, two, opts)
      assert message =~ "Payload exceeds #{map_bytes} bytes"
      assert {:ok, _} = encode(path, two, limits: %{max_bytes: 2 * map_bytes})
    end
  end

  test "the PDF collection obeys list depth and node limits after valid individual blocks" do
    block = inline(pdf("first"))
    request = request([block, block])

    for limits <- [%{max_list_length: 1}, %{max_depth: 1}, %{max_nodes: 4}] do
      assert {:ok, _} = ContentBlock.new(block, limits: limits)

      for path <- @paths do
        assert {:error, %Error{kind: :invalid_request}} = encode(path, request, limits: limits)
      end
    end

    for path <- @paths do
      assert {:ok, _} =
               encode(path, request, limits: %{max_list_length: 2, max_depth: 2, max_nodes: 9})

      assert {:error, %Error{kind: :invalid_request}} =
               encode(path, request, limits: %{max_map_entries: 2})
    end
  end

  test "JSON encoded budgets and existing defaults remain independently enforced" do
    request = fixture_request()
    assert {:ok, json} = Serialization.to_json(request)

    assert {:error, %Error{kind: :invalid_request, message: message}} =
             Serialization.decode_and_validate(json, &restore(&1, @opts),
               limits: @limits,
               max_encoded_bytes: byte_size(json) - 1
             )

    assert message =~ "Encoded JSON exceeds"

    assert {:ok, ^request} =
             Serialization.decode_and_validate(json, &restore(&1, @opts),
               limits: @limits,
               max_encoded_bytes: byte_size(json)
             )

    assert Validation.default_limits() == %{
             max_depth: 32,
             max_map_entries: 512,
             max_list_length: 4_096,
             max_bytes: 1_048_576,
             max_string_bytes: 262_144,
             max_nodes: 16_384
           }

    large_json = Jason.encode!(String.duplicate("x", 2_097_152))

    assert {:error, %Error{kind: :invalid_request, message: "Encoded JSON exceeds 2097152 bytes"}} =
             Serialization.from_json(large_json)
  end

  test "empty PDF bodies roles protocols and portable metadata remain incompatible" do
    for path <- @paths do
      assert_incompatible(encode(path, request([inline("")])))

      assert_incompatible(
        encode(
          path,
          request([Map.put(inline(pdf("first")), :extensions, %{"fixture::tag" => true})])
        )
      )

      request = request([%{type: :text, text: "before"}, inline(pdf("first"))])
      [message] = request.input

      assert_incompatible(
        encode(path, %{request | input: [%{message | extensions: %{"fixture::tag" => true}}]})
      )

      for role <- [:assistant, :system, :developer, :tool] do
        attrs = %{role: role, content: [inline(pdf("first"))], tool_call_id: "fixture-call"}
        assert {:ok, request} = Request.new(%{model: "fixture-model", input: [attrs]})
        assert_incompatible(encode(path, request))
      end

      for mime <- [
            "application/octet-stream",
            "application/pdf; charset=utf-8",
            "APPLICATION/PDF"
          ] do
        assert_incompatible(
          encode(path, request([put_in(inline(pdf("first")), [:data, "mime_type"], mime)]))
        )
      end
    end

    for protocol <- [:openai, :openai_responses] do
      assert_incompatible(Codec.encode_request(protocol, fixture_request(), @opts))
      large = request([inline(sized_pdf(210_000))], @opts)
      assert {:error, %Error{kind: :invalid_request}} = Codec.encode_request(protocol, large)
      assert_incompatible(Codec.encode_request(protocol, large, @opts))
    end
  end

  test "malformed canonical data retains validation errors instead of being stripped" do
    for block <- [
          put_in(inline(pdf("first")), [:data, "data"], "not base64"),
          put_in(inline(pdf("first")), [:data, "data"], nil),
          put_in(inline(pdf("first")), [:data, "uri"], "relative.pdf"),
          put_in(inline(pdf("first")), [:data, "title"], "keep me"),
          put_in(inline(pdf("first")), [:data, "text"], "competing body")
        ] do
      assert {:error, %Error{kind: :invalid_request}} = ContentBlock.new(block)

      forged = %{
        fixture_request()
        | input: [%Message{role: :user, content: [struct!(ContentBlock, block)]}]
      }

      for path <- @paths do
        assert {:error, %Error{kind: :invalid_request}} = encode(path, forged)
      end
    end
  end

  test "media wrappers and explicit option arities enforce the same PDF subset" do
    block = hd(hd(request([inline(pdf("first"))]).input).content)
    message = %{role: :user, extensions: %{}}
    assert {:ok, wire} = Media.encode(block, :anthropic)
    assert {:ok, ^wire} = Media.encode(block, :anthropic, message)
    assert {:ok, ^wire} = Media.encode(block, :anthropic, message, [])
    assert :ok = Media.preflight(fixture_request(), :anthropic)
    assert :ok = Media.preflight(fixture_request(), :anthropic, @opts)

    assert_incompatible(
      Media.encode(block, :anthropic, %{role: :user, extensions: %{"fixture::tag" => 1}}, [])
    )

    assert_incompatible(Media.encode(block, :google, %{role: :assistant, extensions: %{}}, []))
    large = hd(hd(request([inline(sized_pdf(210_000))], @opts).input).content)
    assert {:error, %Error{kind: :invalid_request}} = Media.encode(large, :anthropic, message)
    assert {:ok, _} = Media.encode(large, :anthropic, message, @opts)
    assert {:ok, _} = Media.encode(large, :google, message, @opts)
  end

  test "actual serialized public output reaches both loopback native HTTP targets intact" do
    Enum.each([:inets, :ssl, :public_key, :asn1, :crypto], &Mix.ensure_application!/1)
    assert {:ok, _} = Application.ensure_all_started(:inets)
    request = fixture_request() |> reload()

    for {path, target_path} <- [
          {:anthropic, "/v1/messages"},
          {:google_rest, "/v1beta/models/fixture-model:generateContent"}
        ] do
      assert {:ok, wire} = encode(path, request, @opts)
      assert {:ok, json} = Serialization.to_json(wire)

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, {_, port}} = :inet.sockname(listener)
      server = Task.async(fn -> capture(listener) end)
      url = String.to_charlist("http://127.0.0.1:#{port}#{target_path}")

      assert {:ok, {{_, 200, _}, _, _}} =
               :httpc.request(:post, {url, [], ~c"application/json", json}, [timeout: 5_000], [])

      {headers, captured, length} = Task.await(server, 5_000)
      assert headers =~ "POST #{target_path} HTTP/1.1"
      assert length == byte_size(json)
      assert byte_size(captured) == length
      assert captured == json
      assert Jason.decode!(captured) == native_fixture(path)
      assert native_texts(path, Jason.decode!(captured)) == ["before", "between", "after"]

      assert Enum.map(native_pdfs(path, Jason.decode!(captured)), &Base.decode64!/1) == [
               pdf("first"),
               pdf("second")
             ]
    end
  end

  defp inline(bytes, name \\ "first"),
    do: %{
      type: :resource,
      data: %{
        "uri" => "file:///fixture/#{name}.pdf",
        "mime_type" => "application/pdf",
        "data" => Base.encode64(bytes)
      }
    }

  defp request(content, opts \\ []) do
    {:ok, blocks} =
      Enum.reduce_while(content, {:ok, []}, fn attrs, {:ok, blocks} ->
        case ContentBlock.new(attrs, opts) do
          {:ok, block} -> {:cont, {:ok, blocks ++ [block]}}
          error -> {:halt, error}
        end
      end)

    {:ok, message} = Message.new(%{role: :user, content: blocks}, opts)
    {:ok, request} = Request.new(%{model: "fixture-model", input: [message]}, opts)
    request
  end

  defp fixture_request,
    do:
      request(
        [
          %{type: :text, text: "before"},
          inline(pdf("first")),
          %{type: :text, text: "between"},
          inline(pdf("second"), "second"),
          %{type: :text, text: "after"}
        ],
        @opts
      )

  defp reload(request, opts \\ @opts, json_opts \\ @json_opts) do
    assert {:ok, json} = Serialization.to_json(request)

    assert {:ok, restored} =
             Serialization.decode_and_validate(json, &restore(&1, opts), json_opts)

    restored
  end

  defp restore(attrs, opts) do
    roles = %{
      "user" => :user,
      "assistant" => :assistant,
      "system" => :system,
      "developer" => :developer,
      "tool" => :tool
    }

    statuses = %{"success" => :success, "error" => :error, nil => nil}

    input =
      Enum.map(attrs["input"], fn item ->
        %{
          role: Map.fetch!(roles, item["role"]),
          content: item["content"],
          status: Map.fetch!(statuses, item["status"]),
          tool_call_id: item["tool_call_id"],
          extensions: item["extensions"]
        }
      end)

    Request.new(
      %{
        model: attrs["model"],
        input: input,
        tools: attrs["tools"],
        settings: attrs["settings"],
        output_constraints: attrs["output_constraints"],
        permitted_downgrades: attrs["permitted_downgrades"],
        correlation: attrs["correlation"],
        extensions: attrs["extensions"]
      },
      opts
    )
  end

  defp encode(:google_rest, request, opts) do
    case Codec.encode_rest_request(:google, request, opts) do
      {:ok, %{body: body}} -> {:ok, body}
      error -> error
    end
  end

  defp encode(path, request, opts), do: Codec.encode_request(path, request, opts)
  defp encode(path, request), do: encode(path, request, [])

  defp native_pdfs(:anthropic, wire),
    do:
      for(
        %{"type" => "document", "source" => source} <- hd(wire["messages"])["content"],
        do: source["data"]
      )

  defp native_pdfs(_, wire),
    do: for(%{"inlineData" => data} <- hd(wire["contents"])["parts"], do: data["data"])

  defp native_texts(:anthropic, wire),
    do: for(%{"type" => "text", "text" => text} <- hd(wire["messages"])["content"], do: text)

  defp native_texts(_, wire),
    do: for(%{"text" => text} <- hd(wire["contents"])["parts"], do: text)

  defp native_fixture(:google),
    do: Map.merge(native_fixture(:google_rest), %{"model" => "fixture-model", "stream" => false})

  defp native_fixture(path),
    do:
      __DIR__
      |> Path.join(
        "../fixtures/#{if path == :anthropic, do: "anthropic", else: "google_genai"}/inline_pdf_user.json"
      )
      |> File.read!()
      |> Jason.decode!()

  defp pdf(name), do: File.read!(Path.join(__DIR__, "../fixtures/pdf/#{name}.pdf"))

  defp sized_pdf(size) do
    original = pdf("first")
    [head, tail] = :binary.split(original, "%%EOF")
    head <> "%" <> String.duplicate("x", size - byte_size(original) - 2) <> "\n%%EOF" <> tail
  end

  defp assert_incompatible(result),
    do:
      assert(
        {:error,
         %Error{kind: :incompatible, stage: :translation, upstream_outcome: :not_submitted}} =
          result
      )

  defp capture(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)

    try do
      {headers, body} = receive_headers(socket, "")
      [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
      length = String.to_integer(length)
      body = receive_body(socket, body, length)

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        )

      {headers, body, length}
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
