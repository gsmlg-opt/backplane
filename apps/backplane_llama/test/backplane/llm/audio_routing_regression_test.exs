defmodule Backplane.LLM.AudioRoutingRegressionTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.Audio.{Binding, Config, Resolver}
  alias Backplane.LLM.{ModelAlias, Provider, ProviderApi, ProviderModel, ProxyPlug}
  alias Backplane.LLM.OpenAI.{Dispatch, Service}
  alias Backplane.Settings.Credentials

  setup do
    prev_enabled = Config.enabled?()
    prev_voices = Config.voices()
    prev_loopback = Application.get_env(:backplane_llama, :audio_allow_http_loopback, false)
    :ok = Config.set_enabled(true)
    Application.put_env(:backplane_llama, :audio_allow_http_loopback, true)

    on_exit(fn ->
      :ok = Config.set_enabled(prev_enabled)
      :ok = Config.set_voices(prev_voices)
      Application.put_env(:backplane_llama, :audio_allow_http_loopback, prev_loopback)
    end)

    {:ok, _} = Credentials.store("f4-openai-key", "openai-secret", "llm")
    {:ok, _} = Credentials.store("f4-minimax-key", "minimax-secret", "llm")

    {:ok, _, token} =
      Backplane.Clients.issue_client(%{
        name: "f4-audio-client",
        scopes: ["llm::invoke"],
        active: true
      })

    %{token: token}
  end

  test "enabled OpenAI passthrough coexists with MiniMax alias and explicit MiniMax model without stealing",
       %{token: token} do
    parent = self()
    openai_audio = <<1, 2, 3, 4>>
    frame = <<0xFF, 0xFB, 0x90, 0x00>> <> :binary.copy(<<0>>, 413)
    minimax_audio = frame <> frame

    openai_server =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        {:ok, body, upstream} = read_body(upstream)
        send(parent, {:hit, :openai, Formata.JSON.decode!(body)["model"]})
        upstream |> put_resp_content_type("audio/mpeg") |> send_resp(200, openai_audio)
      end)

    minimax_server =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        {:ok, body, upstream} = read_body(upstream)
        decoded = Formata.JSON.decode!(body)
        send(parent, {:hit, :minimax, decoded["model"]})
        send_minimax_speech(upstream, minimax_audio)
      end)

    {_openai_p, _} = create_openai_audio_service("f4-openai", :speech, openai_server.port, :passthrough)
    create_minimax_audio_binding("f4-minimax", :speech, "speech-02-hd", minimax_server.port)
    {:ok, _} = ModelAlias.put("tts", "f4-minimax/speech-02-hd")

    # 1. MiniMax alias must route to MiniMax, NOT OpenAI passthrough!
    assert Resolver.claims_model?(:speech, "tts")

    alias_resp =
      post_speech(token, %{model: "tts", input: "hello", voice: "male-qn-qingse"})

    assert alias_resp.status == 200
    assert alias_resp.resp_body == minimax_audio
    assert_received {:hit, :minimax, "speech-02-hd"}
    refute_received {:hit, :openai, _}

    # 2. Explicit MiniMax provider/model routes to MiniMax only.
    explicit_mm =
      post_speech(token, %{
        model: "f4-minimax/speech-02-hd",
        input: "hello",
        voice: "male-qn-qingse"
      })

    assert explicit_mm.status == 200
    assert_received {:hit, :minimax, "speech-02-hd"}
    refute_received {:hit, :openai, _}

    # 3. Native raw model routes to OpenAI passthrough only.
    native_raw =
      post_speech(token, %{model: "gpt-4o-mini-tts", input: "hello", voice: "coral"})

    assert native_raw.status == 200
    assert native_raw.resp_body == openai_audio
    assert_received {:hit, :openai, "gpt-4o-mini-tts"}
    refute_received {:hit, :minimax, _}

    # 4. Slash-containing native model whose prefix is NOT a gateway provider stays native OpenAI.
    native_slash =
      post_speech(token, %{model: "vendor/custom-tts", input: "hello", voice: "coral"})

    assert native_slash.status == 200
    assert_received {:hit, :openai, "vendor/custom-tts"}
    refute_received {:hit, :minimax, _}

    # 5. Provider-qualified native model strips prefix and submits once to OpenAI.
    native_qualified =
      post_speech(token, %{model: "f4-openai/gpt-4o-mini-tts", input: "hello", voice: "coral"})

    assert native_qualified.status == 200
    assert_received {:hit, :openai, "gpt-4o-mini-tts"}
    refute_received {:hit, :minimax, _}
  end

  test "disabled or missing MiniMax alias target is never stolen by OpenAI passthrough and upstream errors never fall back",
       %{token: token} do
    parent = self()

    openai_server =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        send(parent, {:hit, :openai})
        upstream |> put_resp_content_type("audio/mpeg") |> send_resp(200, <<1, 2>>)
      end)

    failing_minimax =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        send(parent, {:hit, :minimax})
        upstream |> put_resp_content_type("application/json") |> send_resp(500, ~s({"error":"boom"}))
      end)

    create_openai_audio_service("f4-openai-err", :speech, openai_server.port, :passthrough)
    {mm_provider, _mm_binding} =
      create_minimax_audio_binding("f4-mm-err", :speech, "speech-err", failing_minimax.port)

    {:ok, _} = ModelAlias.put("tts-fail", "f4-mm-err/speech-err")
    {:ok, _} = ModelAlias.put("tts-missing", "ghost-provider/speech-01")
    {:ok, _} = ModelAlias.put("tts-missing-bare", "nonexistent-bare-speech-model")

    # Upstream error on MiniMax must NOT fall back to OpenAI!
    fail_resp = post_speech(token, %{model: "tts-fail", input: "hi", voice: "male-qn-qingse"})
    assert fail_resp.status in [502, 500]
    assert_received {:hit, :minimax}
    refute_received {:hit, :openai}

    # Missing target behind declared alias (prefixed or bare) must NOT leak to OpenAI!
    missing_resp = post_speech(token, %{model: "tts-missing", input: "hi", voice: "male-qn-qingse"})
    assert missing_resp.status == 404
    refute_received {:hit, :openai}

    missing_bare_resp =
      post_speech(token, %{model: "tts-missing-bare", input: "hi", voice: "male-qn-qingse"})

    assert missing_bare_resp.status == 404
    refute_received {:hit, :openai}

    # Disabled MiniMax provider behind alias must NOT leak to OpenAI!
    {:ok, _} = Provider.update(mm_provider, %{enabled: false})
    disabled_resp = post_speech(token, %{model: "tts-fail", input: "hi", voice: "male-qn-qingse"})
    assert disabled_resp.status == 404
    refute_received {:hit, :openai}
  end

  test "allowlist and ambiguous passthrough services behave deterministically alongside MiniMax aliases",
       %{token: token} do
    parent = self()

    s1 =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        send(parent, {:hit, :openai1})
        upstream |> put_resp_content_type("audio/mpeg") |> send_resp(200, <<1>>)
      end)

    s2 =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        send(parent, {:hit, :openai2})
        upstream |> put_resp_content_type("audio/mpeg") |> send_resp(200, <<2>>)
      end)

    mm =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        send(parent, {:hit, :minimax})
        frame = <<0xFF, 0xFB, 0x90, 0x00>> <> :binary.copy(<<0>>, 413)
        send_minimax_speech(upstream, frame <> frame)
      end)

    create_openai_audio_service("f4-o1", :speech, s1.port, :passthrough)
    create_openai_audio_service("f4-o2", :speech, s2.port, :passthrough)
    create_minimax_audio_binding("f4-mm-amb", :speech, "speech-amb", mm.port)
    {:ok, _} = ModelAlias.put("tts-amb", "f4-mm-amb/speech-amb")

    # MiniMax alias resolves cleanly even when two OpenAI passthrough services coexist.
    mm_resp = post_speech(token, %{model: "tts-amb", input: "hi", voice: "male-qn-qingse"})
    assert mm_resp.status == 200
    assert_received {:hit, :minimax}
    refute_received {:hit, :openai1}
    refute_received {:hit, :openai2}

    # Unclaimed raw model with two passthrough services returns 400 ambiguous_model, zero submissions.
    amb_resp = post_speech(token, %{model: "gpt-4o-mini-tts", input: "hi", voice: "coral"})
    assert amb_resp.status == 400
    assert Formata.JSON.decode!(amb_resp.resp_body)["error"]["code"] == "ambiguous_model"
    refute_received {:hit, :openai1}
    refute_received {:hit, :openai2}
  end

  test "transcription multipart routes MiniMax alias with preserved file bytes, duplicate rejection, and upload limits" do
    openai_server =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        upstream |> put_resp_content_type("application/json") |> send_resp(200, ~s({"text":"oai"}))
      end)

    create_openai_audio_service("f4-openai-asr", :transcription, openai_server.port, :passthrough)
    create_minimax_audio_binding("f4-mm-asr", :transcription, "asr-model", 1)
    {:ok, _} = ModelAlias.put("asr-alias", "f4-mm-asr/asr-model")

    audio_bytes = <<0x49, 0x44, 0x33, 0x03, 0x00, 0xFF, 0x00, 0x11, 0x22>>

    valid_body =
      multipart("f4-asr-boundary", [
        {"model", nil, "asr-alias"},
        {"file", "clip.mp3", audio_bytes},
        {"language", nil, "en"}
      ])

    parsed =
      conn(:post, "/v1/audio/transcriptions", valid_body)
      |> put_req_header("content-type", "multipart/form-data; boundary=f4-asr-boundary")
      |> Dispatch.call([])

    refute parsed.halted
    assert parsed.private.audio_already_parsed
    assert parsed.body_params["model"] == "asr-alias"
    assert File.read!(parsed.body_params["file"].path) == audio_bytes

    Backplane.Audio.AccessLifecycle.finish(parsed.private.audio_observer, :cancelled, nil)
    Backplane.Audio.Media.Session.release(parsed.private.audio_session)

    # Duplicate non-model field is rejected (400).
    dup_body =
      multipart("f4-asr-dup", [
        {"model", nil, "asr-alias"},
        {"file", "clip.mp3", audio_bytes},
        {"language", nil, "en"},
        {"language", nil, "zh"}
      ])

    dup_resp =
      conn(:post, "/v1/audio/transcriptions", dup_body)
      |> put_req_header("content-type", "multipart/form-data; boundary=f4-asr-dup")
      |> Dispatch.call([])

    assert dup_resp.halted
    assert dup_resp.status == 400
  end

  defp post_speech(token, payload) do
    conn(:post, "/v1/audio/speech", Formata.JSON.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> ProxyPlug.call(ProxyPlug.init([]))
  end

  defp create_openai_audio_service(name, kind, port, policy, models \\ []) do
    {:ok, provider} =
      Provider.create(%{
        name: name,
        api_type: :openai,
        api_url: "http://localhost:#{port}",
        credential: "f4-openai-key",
        models: []
      })

    {:ok, _api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://localhost:#{port}"
      })

    {:ok, service} =
      Service.create(%{
        provider_id: provider.id,
        kind: kind,
        enabled: true,
        model_policy: policy,
        models: models
      })

    {provider, service}
  end

  defp create_minimax_audio_binding(name, operation, model_name, port) do
    {:ok, provider} =
      Provider.create(%{
        name: name,
        api_type: :openai,
        api_url: "http://localhost:#{port}",
        credential: "f4-minimax-key",
        models: []
      })

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: model_name, source: :manual})

    {:ok, binding} =
      Binding.create(%{
        provider_id: provider.id,
        provider_model_id: model.id,
        operation: operation,
        native_protocol: :minimax,
        api_origin: "http://127.0.0.1:#{port}",
        enabled: true
      })

    :ok =
      Config.set_voices(
        Map.put(Config.voices(), name, %{"aliases" => %{}, "allow_native" => true})
      )

    {provider, binding}
  end

  defp send_minimax_speech(conn, audio_bytes) do
    hex = Base.encode16(audio_bytes, case: :lower)

    event1 =
      "data: " <>
        Formata.JSON.encode!(%{
          "base_resp" => %{"status_code" => 0},
          "data" => %{"status" => 1, "audio" => hex},
          "trace_id" => "tts-f4"
        }) <> "\n\n"

    event2 =
      "data: " <>
        Formata.JSON.encode!(%{
          "base_resp" => %{"status_code" => 0},
          "data" => %{"status" => 2, "audio" => ""},
          "trace_id" => "tts-f4",
          "extra_info" => %{"usage_characters" => 5}
        }) <> "\n\n"

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, event1 <> event2)
    conn
  end

  defp multipart(boundary, parts) do
    Enum.map_join(parts, "", fn
      {name, nil, value} ->
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"

      {name, filename, value} ->
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\nContent-Type: audio/mpeg\r\n\r\n#{value}\r\n"
    end) <> "--#{boundary}--\r\n"
  end
end
