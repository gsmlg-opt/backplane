defmodule Backplane.LLM.SseStreamMapperRegressionTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.{
    ModelAlias,
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    ProxyPlug,
    RateLimiter
  }

  alias Backplane.LLM.ModelResponse.StreamMapper
  alias Backplane.Settings.Credentials

  describe "ModelResponse.StreamMapper pure framing" do
    test "valid JSON line limits include LF and CRLF and do not depend on fragmentation" do
      for ending <- ["\n", "\r\n"] do
        line = ~s(data: {"choices":[],"model":"raw"}) <> ending
        following = ~s(data: {"model":"raw"}) <> "\n\n"
        input = line <> following

        for limit <- [byte_size(line) - 1, byte_size(line), byte_size(line) + 1] do
          expected_line =
            if byte_size(line) > limit,
              do: line,
              else: String.replace(line, ~s("raw"), ~s("alias"))

          expected = expected_line <> String.replace(following, ~s("raw"), ~s("alias"))
          splits = [1, limit - 1, limit, limit + 1, byte_size(line) - 1]

          assert run_mapper(:openai_chat_completions, "alias", "raw", [input], %{
                   max_line_bytes: limit
                 }) == expected

          for size <- splits do
            assert run_mapper(
                     :openai_chat_completions,
                     "alias",
                     "raw",
                     split_bytes(input, size),
                     %{max_line_bytes: limit}
                   ) == expected
          end
        end
      end
    end

    test "one-byte and varied fragmentation produce identical Chat Completions output without rewriting nested tool arguments" do
      fixture =
        ": keepalive\r\n\r\n" <>
          ~s(data: {"id":"chatcmpl_1","object":"chat.completion.chunk","model":"gpt-raw-1","extra_field":true,"choices":[{"index":0,"delta":{"content":"你好🚀","tool_calls":[{"id":"call_1","function":{"name":"inspect","arguments":"{\\"model\\":\\"gpt-raw-1\\"}"}}]}}]}\r\n\r\n) <>
          "data: {malformed-json}\n\n" <>
          "data: [DONE]\r\n\r\n"

      whole = run_mapper(:openai_chat_completions, "smart-alias", "gpt-raw-1", [fixture])

      one_byte =
        run_mapper(:openai_chat_completions, "smart-alias", "gpt-raw-1", split_bytes(fixture, 1))

      three_byte =
        run_mapper(:openai_chat_completions, "smart-alias", "gpt-raw-1", split_bytes(fixture, 3))

      seven_byte =
        run_mapper(:openai_chat_completions, "smart-alias", "gpt-raw-1", split_bytes(fixture, 7))

      assert one_byte == whole
      assert three_byte == whole
      assert seven_byte == whole

      assert whole =~ ~s("model":"smart-alias")
      assert whole =~ ~s("extra_field":true)
      assert whole =~ "你好🚀"
      # Nested model inside tool arguments MUST remain untouched!
      assert whole =~ ~S(\"model\":\"gpt-raw-1\")
      assert whole =~ ": keepalive\r\n\r\n"
      assert whole =~ "data: {malformed-json}\n\n"
      assert whole =~ "data: [DONE]\r\n\r\n"
    end

    test "Anthropic message_start rewrites message.model across 1-byte and CRLF/UTF-8 splits without touching nested content" do
      fixture =
        "event: message_start\r\n" <>
          ~s(data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-raw-4","content":[]}}\r\n\r\n) <>
          "event: content_block_delta\r\n" <>
          ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"中文测试 model=claude-raw-4","model":"claude-raw-4"}}\r\n\r\n) <>
          "event: message_stop\r\n" <>
          ~s(data: {"type":"message_stop"}\r\n\r\n)

      whole = run_mapper(:anthropic_messages, "claude-alias", "claude-raw-4", [fixture])

      one_byte =
        run_mapper(:anthropic_messages, "claude-alias", "claude-raw-4", split_bytes(fixture, 1))

      assert one_byte == whole
      assert whole =~ ~s("model":"claude-alias")
      assert whole =~ "中文测试 model=claude-raw-4"
      # Nested delta.model is NOT a protocol response model field and must remain untouched!
      assert whole =~
               ~s("delta":{"type":"text_delta","text":"中文测试 model=claude-raw-4","model":"claude-raw-4"})
    end

    test "handles incomplete EOF, oversized lines, and unchanged-model byte identity" do
      # Incomplete EOF does not fabricate newline or completion
      incomplete = ~s(data: {"id":"1","model":"gpt-raw-1","partial":)

      assert run_mapper(
               :openai_chat_completions,
               "alias",
               "gpt-raw-1",
               split_bytes(incomplete, 1)
             ) ==
               incomplete

      # Oversized line fails open and resumes framing after newline
      oversized = "data: " <> String.duplicate("x", 80) <> "\n"
      next = ~s(data: {"id":"2","model":"gpt-raw-1"}\n\n)

      out =
        run_mapper(
          :openai_chat_completions,
          "alias",
          "gpt-raw-1",
          split_bytes(oversized <> next, 17),
          %{max_line_bytes: byte_size(next)}
        )

      assert String.starts_with?(out, oversized)
      assert out =~ ~s("model":"alias")

      # Unchanged model preserves exact formatting and whitespace byte-for-byte
      raw = "data: {  \"model\" : \"gpt-raw-1\",  \"x\" : 1  }\r\n\r\n"

      assert run_mapper(:openai_chat_completions, "gpt-raw-1", "gpt-raw-1", split_bytes(raw, 1)) ==
               raw
    end
  end

  describe "public HTTP routes with fragmented upstream streams" do
    setup do
      RateLimiter.reset()
      ModelResolver.clear_cache()

      {:ok, _} = Credentials.store("f5-key", "f5-secret", "llm")

      {:ok, _, token} =
        Backplane.Clients.issue_client(%{
          name: "f5-sse-client",
          scopes: ["llm::invoke"],
          active: true
        })

      %{token: token}
    end

    test "POST /v1/chat/completions and POST /v1/messages restore aliases across fragmented chunks",
         %{
           token: token
         } do
      chat_sse =
        ": ping\r\n\r\n" <>
          ~s(data: {"id":"c1","object":"chat.completion.chunk","model":"gpt-5-raw","choices":[{"index":0,"delta":{"content":"hello 🚀"}}]}\r\n\r\n) <>
          "data: [DONE]\r\n\r\n"

      anthropic_sse =
        "event: message_start\n" <>
          ~s(data: {"type":"message_start","message":{"id":"m1","model":"claude-raw","role":"assistant","content":[]}}\n\n) <>
          "event: message_stop\n" <>
          ~s(data: {"type":"message_stop"}\n\n)

      server =
        BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
          payload =
            case upstream.request_path do
              "/v1/chat/completions" -> chat_sse
              "/v1/messages" -> anthropic_sse
            end

          upstream =
            upstream
            |> put_resp_content_type("text/event-stream")
            |> send_chunked(200)

          # Stream in intentionally awkward 5-byte chunks splitting `"model"`, UTF-8, and CRLF.
          Enum.reduce(split_bytes(payload, 5), upstream, fn part, conn ->
            {:ok, conn} = chunk(conn, part)
            conn
          end)
        end)

      {:ok, oai_p} =
        Provider.create(%{
          name: "f5-oai",
          api_type: :openai,
          api_url: "http://localhost:#{server.port}",
          credential: "f5-key",
          models: []
        })

      {:ok, oai_api} =
        ProviderApi.create(%{
          provider_id: oai_p.id,
          api_surface: :openai,
          native_protocols: [:openai_chat_completions],
          base_url: "http://localhost:#{server.port}"
        })

      {:ok, oai_m} =
        ProviderModel.create(%{provider_id: oai_p.id, model: "gpt-5-raw", source: :manual})

      {:ok, _} =
        ProviderModelSurface.create(%{provider_model_id: oai_m.id, provider_api_id: oai_api.id})

      {:ok, _} = ModelAlias.put("f5-chat-alias", "f5-oai/gpt-5-raw")

      {:ok, ant_p} =
        Provider.create(%{
          name: "f5-ant",
          api_type: :anthropic,
          api_url: "http://localhost:#{server.port}",
          credential: "f5-key",
          models: []
        })

      {:ok, ant_api} =
        ProviderApi.create(%{
          provider_id: ant_p.id,
          api_surface: :anthropic,
          native_protocols: [:anthropic_messages],
          base_url: "http://localhost:#{server.port}"
        })

      {:ok, ant_m} =
        ProviderModel.create(%{provider_id: ant_p.id, model: "claude-raw", source: :manual})

      {:ok, _} =
        ProviderModelSurface.create(%{provider_model_id: ant_m.id, provider_api_id: ant_api.id})

      {:ok, _} = ModelAlias.put("f5-ant-alias", "f5-ant/claude-raw")
      ModelResolver.clear_cache()

      chat_resp =
        conn(
          :post,
          "/v1/chat/completions",
          Formata.JSON.encode!(%{model: "f5-chat-alias", stream: true, messages: []})
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> ProxyPlug.call(ProxyPlug.init([]))

      assert chat_resp.status == 200
      assert chat_resp.resp_body =~ ~s("model":"f5-chat-alias")
      assert chat_resp.resp_body =~ "hello 🚀"
      assert chat_resp.resp_body =~ ": ping\r\n\r\n"
      assert chat_resp.resp_body =~ "data: [DONE]\r\n\r\n"
      refute chat_resp.resp_body =~ "gpt-5-raw"

      ant_resp =
        conn(
          :post,
          "/v1/messages",
          Formata.JSON.encode!(%{
            model: "f5-ant-alias",
            stream: true,
            max_tokens: 16,
            messages: []
          })
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> ProxyPlug.call(ProxyPlug.init([]))

      assert ant_resp.status == 200
      assert ant_resp.resp_body =~ ~s("model":"f5-ant-alias")
      refute ant_resp.resp_body =~ "claude-raw"
    end
  end

  defp run_mapper(protocol, requested, resolved, chunks, extra \\ %{}) do
    arg =
      Map.merge(
        %{protocol: protocol, requested_model: requested, resolved_model: resolved},
        extra
      )

    {:ok, state} = StreamMapper.init(200, [{"content-type", "text/event-stream"}], arg)

    {state, out} =
      Enum.reduce(chunks, {state, []}, fn chunk, {st, acc} ->
        {:ok, next, emitted} = StreamMapper.feed(st, chunk)
        {next, [emitted | acc]}
      end)

    {:ok, _final, tail} = StreamMapper.finish(state, :eof)
    IO.iodata_to_binary([Enum.reverse(out), tail])
  end

  defp split_bytes(binary, size) do
    do_split(binary, size, [])
  end

  defp do_split(<<>>, _size, acc), do: Enum.reverse(acc)

  defp do_split(bin, size, acc) when byte_size(bin) <= size do
    Enum.reverse([bin | acc])
  end

  defp do_split(bin, size, acc) do
    <<head::binary-size(size), rest::binary>> = bin
    do_split(rest, size, [head | acc])
  end
end
