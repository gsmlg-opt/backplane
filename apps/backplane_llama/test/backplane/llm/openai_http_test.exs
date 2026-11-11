defmodule Backplane.LLM.OpenAI.HTTPTest do
  use BackplaneLlama.DataCase, async: false
  import Plug.Conn
  import Plug.Test
  alias Backplane.LLM.{Provider, ProviderApi, ProxyPlug}
  alias Backplane.LLM.OpenAI.{Request, Service}
  alias Backplane.Settings.Credentials

  setup do
    {:ok, _, token} =
      Backplane.Clients.issue_client(%{
        name: "openai-http-client",
        scopes: ["llm::invoke"],
        active: true
      })

    {:ok, _} = Credentials.store("openai-http-key", "native-upstream-key", "llm")
    %{token: token}
  end

  test "Decisions preserves request fields, upstream answers, errors and credential isolation", %{
    token: token
  } do
    server =
      BackplaneLlama.Test.HTTPServer.open("POST", "/v1/decisions", fn upstream ->
        {:ok, body, upstream} = read_body(upstream)

        assert Jason.decode!(body) == %{
                 "model" => "gpt-6-luna",
                 "input" => "sample",
                 "questions" => [%{"type" => "predicate", "instructions" => "Is it safe?"}],
                 "future_field" => true
               }

        assert get_req_header(upstream, "authorization") == ["Bearer native-upstream-key"]
        assert get_req_header(upstream, "cookie") == []
        assert get_req_header(upstream, "x-api-key") == []
        assert get_req_header(upstream, "api-key") == []

        upstream
        |> put_resp_header("retry-after", "3")
        |> put_resp_content_type("application/json")
        |> send_resp(429, ~s({"error":{"code":"quota_exceeded","native":true}}))
      end)

    configure(:decisions, "gpt-6-luna", server.port)

    result =
      request(
        token,
        "/v1/decisions",
        Jason.encode!(%{
          model: "native-openai/gpt-6-luna",
          input: "sample",
          questions: [%{type: "predicate", instructions: "Is it safe?"}],
          future_field: true
        })
      )

    assert result.status == 429
    assert result.resp_body == ~s({"error":{"code":"quota_exceeded","native":true}})
    assert get_resp_header(result, "retry-after") == ["3"]
  end

  test "image edits retain binary uploads and repeated fields in multipart", %{token: token} do
    boundary = "openai-image-boundary"

    body =
      multipart(boundary, [
        {"model", nil, "native-openai/image-model"},
        {"image[]", "one.png", <<137, 80, 78, 71, 0, 255>>},
        {"image[]", "two.png", <<0, 1, 2, 3>>},
        {"include[]", nil, "alpha"},
        {"include[]", nil, "beta"},
        {"prompt", nil, "edit"}
      ])

    server =
      BackplaneLlama.Test.HTTPServer.open("POST", "/v1/images/edits", fn upstream ->
        {:ok, received, upstream} = read_body(upstream)
        assert received == String.replace(body, "native-openai/image-model", "image-model")

        upstream
        |> put_resp_content_type("application/json")
        |> send_resp(200, ~s({"data":[{"b64_json":"YWJj"}]}))
      end)

    configure(:images, "image-model", server.port)
    result = request(token, "/v1/images/edits", body, "multipart/form-data; boundary=#{boundary}")
    assert result.status == 200
    assert result.resp_body == ~s({"data":[{"b64_json":"YWJj"}]} ) |> String.trim()
  end

  test "native speech bypasses MiniMax validation and returns unchanged binary", %{token: token} do
    previous = Backplane.Audio.Config.enabled?()
    :ok = Backplane.Audio.Config.set_enabled(false)
    on_exit(fn -> Backplane.Audio.Config.set_enabled(previous) end)
    bytes = <<0, 255, 1, 128, 17>>

    server =
      BackplaneLlama.Test.HTTPServer.open("POST", "/v1/audio/speech", fn upstream ->
        {:ok, body, upstream} = read_body(upstream)
        assert Jason.decode!(body)["instructions"] == "Read warmly"
        upstream |> put_resp_content_type("audio/mpeg") |> send_resp(200, bytes)
      end)

    configure(:speech, "native-tts", server.port)

    result =
      request(
        token,
        "/v1/audio/speech",
        Jason.encode!(%{
          model: "native-openai/native-tts",
          input: "Hello",
          voice: "coral",
          instructions: "Read warmly"
        })
      )

    assert result.status == 200
    assert result.resp_body == bytes
    assert get_resp_header(result, "content-type") == ["audio/mpeg; charset=utf-8"]
  end

  test "native configuration preserves the bounded legacy MiniMax parsing path" do
    configure(:speech, "native-tts", 1)

    body =
      Jason.encode!(%{model: "legacy-minimax/speech-model", input: "Hello", voice: "default"})

    parsed =
      conn(:post, "/v1/audio/speech", body)
      |> put_req_header("content-type", "application/json")
      |> Backplane.LLM.OpenAI.Dispatch.call([])

    assert parsed.private.audio_already_parsed
    assert is_pid(parsed.private.audio_session)

    assert {:ok, %{model: "legacy-minimax/speech-model"}} =
             Backplane.Audio.Request.speech(parsed.body_params)

    Backplane.Audio.AccessLifecycle.finish(parsed.private.audio_observer, :cancelled, nil)
    Backplane.Audio.Media.Session.release(parsed.private.audio_session)

    too_large =
      Jason.encode!(%{
        model: "legacy-minimax/speech-model",
        input: String.duplicate("x", 65_536),
        voice: "default"
      })

    rejected =
      conn(:post, "/v1/audio/speech", too_large)
      |> put_req_header("content-type", "application/json")
      |> Backplane.LLM.OpenAI.Dispatch.call([])

    assert rejected.status == 413
    refute rejected.private[:audio_session]
  end

  test "native transcription preserves streamed multipart options and SSE bytes", %{token: token} do
    body =
      multipart("asr-boundary", [
        {"file", "audio.wav", "RIFF sample"},
        {"model", nil, "native-openai/gpt-transcribe"},
        {"stream", nil, "true"},
        {"include[]", nil, "logprobs"},
        {"include[]", nil, "future"}
      ])

    sse =
      "event: transcript.text.delta\ndata: {\"delta\":\"hello\"}\n\nevent: transcript.text.done\ndata: {\"text\":\"hello\"}\n\n"

    server =
      BackplaneLlama.Test.HTTPServer.open("POST", "/v1/audio/transcriptions", fn upstream ->
        {:ok, received, upstream} = read_body(upstream)
        assert received == String.replace(body, "native-openai/gpt-transcribe", "gpt-transcribe")
        upstream = upstream |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        {:ok, upstream} = chunk(upstream, sse)
        upstream
      end)

    configure(:transcription, "gpt-transcribe", server.port)

    result =
      request(
        token,
        "/v1/audio/transcriptions",
        body,
        "multipart/form-data; boundary=asr-boundary"
      )

    assert result.status == 200
    assert result.resp_body == sse
  end

  test "authentication runs before native upload parsing" do
    result =
      conn(:post, "/v1/images/edits", "malformed")
      |> put_req_header("content-type", "multipart/form-data")
      |> ProxyPlug.call([])

    assert result.status == 401
  end

  test "Realtime client secrets preserve nested session options and returned ephemeral credentials",
       %{token: token} do
    server =
      BackplaneLlama.Test.HTTPServer.open("POST", "/v1/realtime/client_secrets", fn upstream ->
        {:ok, body, upstream} = read_body(upstream)

        assert Jason.decode!(body) == %{
                 "session" => %{
                   "type" => "realtime",
                   "model" => "native-voice",
                   "instructions" => "Hello"
                 },
                 "expires_after" => %{"anchor" => "created_at", "seconds" => 60}
               }

        assert get_req_header(upstream, "authorization") == ["Bearer native-upstream-key"]

        upstream
        |> put_resp_content_type("application/json")
        |> send_resp(200, ~s({"value":"ephemeral-fixture","expires_at":1234}))
      end)

    configure(:realtime, "native-voice", server.port)

    result =
      request(
        token,
        "/v1/realtime/client_secrets",
        Jason.encode!(%{
          session: %{type: "realtime", model: "native-openai/native-voice", instructions: "Hello"},
          expires_after: %{anchor: "created_at", seconds: 60}
        })
      )

    assert result.status == 200
    assert result.resp_body == ~s({"value":"ephemeral-fixture","expires_at":1234})
  end

  test "Realtime unified calls preserve SDP multipart and upstream Location", %{token: token} do
    owner = self()

    body =
      multipart("realtime-calls", [
        {"sdp", nil, "v=0\r\na=sendrecv"},
        {"session", nil,
         Jason.encode!(%{
           type: "realtime",
           model: "native-openai/native-voice",
           instructions: "Hello"
         })}
      ])

    server =
      BackplaneLlama.Test.HTTPServer.open("POST", "/v1/realtime/calls", fn upstream ->
        {:ok, received, upstream} = read_body(upstream)
        send(owner, {:received_call, received})

        upstream
        |> put_resp_header("location", "https://api.openai.com/v1/realtime/calls/call_fixture")
        |> put_resp_content_type("application/sdp")
        |> send_resp(201, "v=0\r\na=recvonly")
      end)

    configure(:realtime, "native-voice", server.port)

    result =
      request(token, "/v1/realtime/calls", body, "multipart/form-data; boundary=realtime-calls")

    assert result.status == 201
    assert_receive {:received_call, received}

    [sdp_part, session_part] =
      :binary.split(received, "Content-Disposition: form-data; name=\"session\"\r\n\r\n")

    assert sdp_part ==
             "--realtime-calls\r\nContent-Disposition: form-data; name=\"sdp\"\r\n\r\nv=0\r\na=sendrecv\r\n--realtime-calls\r\n"

    [session, ""] = :binary.split(session_part, "\r\n--realtime-calls--\r\n")

    assert Jason.decode!(session) == %{
             "type" => "realtime",
             "model" => "native-voice",
             "instructions" => "Hello"
           }

    assert result.resp_body == "v=0\r\na=recvonly"

    assert get_resp_header(result, "location") == [
             "https://api.openai.com/v1/realtime/calls/call_fixture"
           ]
  end

  test "configured request limits fail without submitting upstream", %{token: token} do
    service = configure(:decisions, "gpt-6-luna", 1)
    {:ok, _} = Service.update(service, %{max_request_bytes: 32})

    result =
      request(
        token,
        "/v1/decisions",
        Jason.encode!(%{model: "native-openai/gpt-6-luna", input: String.duplicate("x", 100)})
      )

    assert result.status == 413
    assert get_resp_header(result, "x-should-retry") == ["false"]
  end

  test "multipart duplicate routing models are rejected" do
    body = multipart("duplicate", [{"model", nil, "one"}, {"model", nil, "two"}])
    assert {:ok, parsed} = Request.parse(body, ["multipart/form-data; boundary=duplicate"])
    assert {:error, :duplicate_model} = Request.model(parsed, :images)
  end

  defp configure(kind, model, port) do
    {:ok, provider} = Provider.create(%{name: "native-openai", credential: "openai-http-key"})

    {:ok, _} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://localhost:#{port}/v1"
      })

    {:ok, service} =
      Service.create(%{provider_id: provider.id, kind: kind, models: [model], enabled: true})

    service
  end

  defp request(token, path, body, type \\ "application/json") do
    conn(:post, path, body)
    |> put_req_header("content-type", type)
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("cookie", "private-client-cookie")
    |> put_req_header("api-key", "private-client-key")
    |> ProxyPlug.call([])
  end

  defp multipart(boundary, parts) do
    [
      Enum.map(parts, fn {name, filename, data} ->
        disposition =
          "Content-Disposition: form-data; name=\"#{name}\"" <>
            if(filename, do: "; filename=\"#{filename}\"", else: "")

        ["--", boundary, "\r\n", disposition, "\r\n\r\n", data, "\r\n"]
      end),
      "--",
      boundary,
      "--\r\n"
    ]
    |> IO.iodata_to_binary()
  end
end
