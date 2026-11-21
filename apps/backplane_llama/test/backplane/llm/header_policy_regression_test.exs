defmodule Backplane.LLM.HeaderPolicyRegressionTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Backplane.Auth.Fixtures

  alias Backplane.LLM.{
    CredentialPlug,
    HeaderPolicy,
    ModelAlias,
    ModelResolver,
    OpenAICodexProxyPlug,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    ProxyPlug,
    RateLimiter
  }

  alias Backplane.LLM.OpenAI.Service
  alias Backplane.LLM.ResponsesWebSocket.Headers, as: WSHeaders
  alias Backplane.Settings.{Credentials, TokenCache}

  setup do
    TokenCache.clear()
    RateLimiter.reset()
    ModelResolver.clear_cache()

    {:ok, _} = Credentials.store("f2-api-key", "secret-upstream-key", "llm")

    {:ok, _} =
      Credentials.store_device_token(
        "f2-codex-oauth",
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "id_token" => "id-tok",
          "access_token" => "codex-access-secret",
          "refresh_token" => "codex-refresh",
          "expires_at" => System.system_time(:millisecond) + 3_600_000
        },
        %{"account_id" => "acc-f2"}
      )

    {:ok, _, token} =
      Backplane.Clients.issue_client(%{
        name: "f2-header-client",
        scopes: ["llm::invoke"],
        active: true
      })

    %{token: token}
  end

  test "HeaderPolicy merges provider and API defaults case-insensitively with API precedence and protects credentials" do
    merged =
      HeaderPolicy.merge_defaults(
        %{
          "X-Shared" => "provider-value",
          "X-Provider-Only" => "from-provider",
          "Authorization" => "Bearer spoofed-provider",
          "X-API-Key" => "spoofed-key",
          "Connection" => "keep-alive",
          "X-CRLF" => "bad\r\nvalue"
        },
        %{
          "x-shared" => "api-value",
          "X-Api-Only" => "from-api",
          "authorization" => "Bearer spoofed-api",
          "Host" => "evil.example"
        },
        surface: :openai
      )

    assert merged == [
             {"x-api-only", "from-api"},
             {"x-provider-only", "from-provider"},
             {"x-shared", "api-value"}
           ]
  end

  test "ordinary HTTP applies API-only default headers, API overrides Provider on mixed-case collision, and credentials stay protected",
       %{token: token} do
    parent = self()

    server =
      BackplaneLlama.Test.HTTPServer.open("POST", "/v1/chat/completions", fn upstream ->
        send(parent, {:upstream_headers, upstream.req_headers})

        upstream
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Formata.JSON.encode!(%{
            "id" => "chatcmpl_f2",
            "model" => "gpt-f2",
            "choices" => []
          })
        )
      end)

    {:ok, provider} =
      Provider.create(%{
        name: "f2-openai",
        api_type: :openai,
        api_url: "http://localhost:#{server.port}",
        credential: "f2-api-key",
        default_headers: %{
          "X-Provider-Only" => "prov",
          "X-Collision" => "from-provider",
          "AUTHORIZATION" => "Bearer spoof-prov"
        },
        models: []
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        native_protocols: [:openai_chat_completions],
        base_url: "http://localhost:#{server.port}",
        default_headers: %{
          "X-Api-Only" => "api-only",
          "x-collision" => "from-api",
          "authorization" => "Bearer spoof-api"
        }
      })

    {:ok, model} = ProviderModel.create(%{provider_id: provider.id, model: "gpt-f2", source: :manual})
    {:ok, _} = ProviderModelSurface.create(%{provider_model_id: model.id, provider_api_id: api.id})
    {:ok, _} = ModelAlias.put("f2-chat", "f2-openai/gpt-f2")
    ModelResolver.clear_cache()

    resp =
      conn(
        :post,
        "/v1/chat/completions",
        Formata.JSON.encode!(%{model: "f2-chat", messages: [%{role: "user", content: "hi"}]})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("connection", "x-hop-nominated")
      |> put_req_header("x-hop-nominated", "drop-me")
      |> ProxyPlug.call(ProxyPlug.init([]))

    assert resp.status == 200
    assert_received {:upstream_headers, headers}

    assert header_values(headers, "authorization") == ["Bearer secret-upstream-key"]
    assert header_values(headers, "x-provider-only") == ["prov"]
    assert header_values(headers, "x-api-only") == ["api-only"]
    assert header_values(headers, "x-collision") == ["from-api"]
    assert header_values(headers, "x-hop-nominated") == []
  end

  test "Responses lifecycle create and follow-up apply API defaults and invalidate on api.default_headers change",
       %{token: token} do
    parent = self()

    server =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        send(parent, {:lifecycle_headers, upstream.method, upstream.request_path, upstream.req_headers})

        body =
          case {upstream.method, upstream.request_path} do
            {"POST", "/v1/responses"} ->
              Formata.JSON.encode!(%{"id" => "resp_f2_1", "status" => "completed", "model" => "gpt-resp"})

            {"GET", "/v1/responses/resp_f2_1"} ->
              Formata.JSON.encode!(%{"id" => "resp_f2_1", "status" => "completed", "model" => "gpt-resp"})
          end

        upstream
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)
      end)

    {:ok, provider} =
      Provider.create(%{
        name: "f2-lifecycle",
        api_type: :openai,
        api_url: "http://localhost:#{server.port}",
        credential: "f2-api-key",
        default_headers: %{
          "X-Shared" => "provider",
          "X-Provider-Header" => "prov-val",
          "Authorization" => "Bearer bad-prov"
        },
        models: []
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        native_protocols: [:openai_responses],
        base_url: "http://localhost:#{server.port}",
        responses_lifecycle: true,
        default_headers: %{
          "x-shared" => "api",
          "X-API-Header" => "api-val",
          "authorization" => "Bearer bad-api"
        }
      })

    {:ok, model} = ProviderModel.create(%{provider_id: provider.id, model: "gpt-resp", source: :manual})
    {:ok, _} = ProviderModelSurface.create(%{provider_model_id: model.id, provider_api_id: api.id})
    ModelResolver.clear_cache()

    create_resp =
      conn(
        :post,
        "/v1/responses",
        Formata.JSON.encode!(%{model: "f2-lifecycle/gpt-resp", input: "hello"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> ProxyPlug.call(ProxyPlug.init([]))

    assert create_resp.status == 200
    assert_received {:lifecycle_headers, "POST", "/v1/responses", create_headers}
    assert header_values(create_headers, "authorization") == ["Bearer secret-upstream-key"]
    assert header_values(create_headers, "x-shared") == ["api"]
    assert header_values(create_headers, "x-provider-header") == ["prov-val"]
    assert header_values(create_headers, "x-api-header") == ["api-val"]

    get_resp =
      conn(:get, "/v1/responses/resp_f2_1")
      |> put_req_header("authorization", "Bearer #{token}")
      |> ProxyPlug.call(ProxyPlug.init([]))

    assert get_resp.status == 200
    assert_received {:lifecycle_headers, "GET", "/v1/responses/resp_f2_1", get_headers}
    assert header_values(get_headers, "authorization") == ["Bearer secret-upstream-key"]
    assert header_values(get_headers, "x-shared") == ["api"]
    assert header_values(get_headers, "x-api-header") == ["api-val"]

    # Changing api.default_headers must invalidate the lifecycle route fingerprint (409).
    {:ok, _} =
      ProviderApi.update(api, %{default_headers: %{"x-shared" => "api-v2", "X-API-Header" => "api-val"}})

    stale_resp =
      conn(:get, "/v1/responses/resp_f2_1")
      |> put_req_header("authorization", "Bearer #{token}")
      |> ProxyPlug.call(ProxyPlug.init([]))

    assert stale_resp.status == 409
    assert Formata.JSON.decode!(stale_resp.resp_body)["error"]["code"] == "response_route_changed"
  end

  test "Codex direct forwarding applies API defaults with API > Provider while preserving caller metadata precedence" do
    parent = self()

    server =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        assert upstream.method == "POST"
        assert upstream.request_path == "/responses"
        send(parent, {:codex_headers, upstream.req_headers})

        upstream
        |> put_resp_content_type("application/json")
        |> send_resp(200, ~s({"id":"resp_codex","status":"completed"}))
      end)

    {:ok, provider} =
      Provider.create(%{
        name: "f2-codex",
        preset_key: "openai-codex",
        api_type: :openai,
        api_url: "http://localhost:#{server.port}",
        credential: "f2-codex-oauth",
        default_headers: %{
          "X-Shared" => "from-provider",
          "X-Provider-Only" => "prov",
          "Originator" => "provider-originator",
          "ChatGPT-Account-ID" => "spoof-prov"
        },
        models: []
      })

    {:ok, _api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://localhost:#{server.port}",
        default_headers: %{
          "x-shared" => "from-api",
          "X-Api-Only" => "api",
          "originator" => "api-originator",
          "chatgpt-account-id" => "spoof-api",
          "authorization" => "Bearer spoof-api"
        }
      })

    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])
    access_token = resource_access_token_fixture!(user, client, ["llm::invoke"], :v1)

    # 1. Absent caller headers receive API defaults (API > Provider > fallback).
    resp1 =
      conn(:post, "/v1/providers/f2-codex/responses", ~s({"input":"hi"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{access_token.value}")
      |> OpenAICodexProxyPlug.call([])

    assert resp1.status == 200
    assert_received {:codex_headers, headers1}
    assert header_values(headers1, "authorization") == ["Bearer codex-access-secret"]
    assert header_values(headers1, "chatgpt-account-id") == ["acc-f2"]
    assert header_values(headers1, "x-shared") == ["from-api"]
    assert header_values(headers1, "x-provider-only") == ["prov"]
    assert header_values(headers1, "x-api-only") == ["api"]
    assert header_values(headers1, "originator") == ["api-originator"]

    # 2. Present caller metadata still beats configured defaults on Codex direct,
    #    while protected credentials still override caller values.
    resp2 =
      conn(:post, "/v1/providers/f2-codex/responses", ~s({"input":"hi"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{access_token.value}")
      |> put_req_header("originator", "caller-originator")
      |> put_req_header("x-shared", "caller-shared")
      |> put_req_header("chatgpt-account-id", "caller-spoof")
      |> OpenAICodexProxyPlug.call([])

    assert resp2.status == 200
    assert_received {:codex_headers, headers2}
    assert header_values(headers2, "originator") == ["caller-originator"]
    assert header_values(headers2, "x-shared") == ["caller-shared"]
    assert header_values(headers2, "chatgpt-account-id") == ["acc-f2"]
    assert header_values(headers2, "authorization") == ["Bearer codex-access-secret"]
  end

  test "Responses WS headers and OpenAI Service auth_headers share API > Provider precedence and credential protection" do
    {:ok, provider} =
      Provider.create(%{
        name: "f2-ws-parity",
        api_type: :openai,
        api_url: "https://api.example.test",
        credential: "f2-api-key",
        default_headers: %{
          "X-Shared" => "provider",
          "X-Provider-Only" => "prov",
          "AUTHORIZATION" => "Bearer spoof-prov"
        },
        models: []
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        native_protocols: [:openai_responses],
        base_url: "https://api.example.test",
        responses_websocket: true,
        default_headers: %{
          "x-shared" => "api",
          "X-Api-Only" => "api",
          "authorization" => "Bearer spoof-api",
          "Content-Type" => "text/plain"
        }
      })

    ws_conn =
      conn(:get, "/v1/responses")
      |> put_req_header("originator", "ws-caller")
      |> put_req_header("connection", "user-agent")
      |> put_req_header("user-agent", "drop-me")

    assert {:ok, ws_headers, _snapshot} = WSHeaders.build(ws_conn, %{provider: provider, api: api})
    assert header_values(ws_headers, "authorization") == ["Bearer secret-upstream-key"]
    assert header_values(ws_headers, "x-shared") == ["api"]
    assert header_values(ws_headers, "x-provider-only") == ["prov"]
    assert header_values(ws_headers, "x-api-only") == ["api"]
    assert header_values(ws_headers, "originator") == ["ws-caller"]
    assert header_values(ws_headers, "user-agent") == []

    assert {:ok, service_headers} = Service.auth_headers(%{provider: provider, api: api})
    assert header_values(service_headers, "authorization") == ["Bearer secret-upstream-key"]
    assert header_values(service_headers, "x-shared") == ["api"]
    assert header_values(service_headers, "x-provider-only") == ["prov"]
    assert header_values(service_headers, "x-api-only") == ["api"]
    assert header_values(service_headers, "content-type") == []
  end

  test "Google and Antigravity build_auth_headers apply API > Provider precedence and protect owned headers" do
    {:ok, _} = Credentials.store("f2-google-key", "goog-secret", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "f2-google",
        api_type: :google,
        api_url: "https://generativelanguage.googleapis.com/v1beta",
        credential: "f2-google-key",
        default_headers: %{
          "X-Shared" => "provider",
          "X-Goog-Api-Key" => "spoof-prov"
        },
        models: []
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :google,
        native_protocols: [:google_generate_content],
        base_url: "https://generativelanguage.googleapis.com/v1beta",
        default_headers: %{
          "x-shared" => "api",
          "X-Api-Only" => "api-only",
          "x-goog-api-key" => "spoof-api"
        }
      })

    assert {:ok, headers} = CredentialPlug.build_auth_headers(provider, :google, api)
    assert header_values(headers, "x-goog-api-key") == ["goog-secret"]
    assert header_values(headers, "x-shared") == ["api"]
    assert header_values(headers, "x-api-only") == ["api-only"]
  end

  defp header_values(headers, name) do
    for {k, v} <- headers, String.downcase(k) == name, do: v
  end
end
