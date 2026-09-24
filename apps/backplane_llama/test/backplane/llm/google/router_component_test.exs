defmodule Backplane.LLM.Google.RouterComponentTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.{
    AutoModel,
    AutoModelRoute,
    ModelAlias,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface
  }

  alias Backplane.LLM.Google.Router
  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  @fixture Path.expand(
             "../../../../../../integrations/google-genai/fixtures/official/generate-content-recorded-response.json",
             __DIR__
           )

  defmodule CapturingProxy do
    import Plug.Conn

    @fixture Path.expand(
               "../../../../../../integrations/google-genai/fixtures/official/generate-content-recorded-response.json",
               __DIR__
             )

    def call(conn, upstream, opts) do
      send(self(), {:google_proxy, conn, upstream, opts})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, File.read!(@fixture))
    end
  end

  defmodule TranslationProxy do
    import Plug.Conn

    def call(conn, upstream, opts) do
      send(self(), {:google_proxy, conn, upstream, opts})

      response = %{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => "translated"}]},
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{"totalTokenCount" => 4}
      }

      {status, body} =
        Process.get(
          :google_translation_reply,
          if(conn.request_path == "/v1internal:countTokens",
            do: {200, Jason.encode!(%{"totalTokens" => 2})},
            else: {200, Jason.encode!(%{"response" => response})}
          )
        )

      mapped =
        case opts[:response_stream_mapper] do
          {module, init_arg} ->
            {:ok, state} = module.init(status, [{"content-type", "text/event-stream"}], init_arg)
            frame = "data: " <> body <> "\n\n"
            {left, right} = String.split_at(frame, div(byte_size(frame), 2))
            {:ok, state, first} = module.feed(state, left)
            {:ok, state, second} = module.feed(state, right)
            {:ok, _state, final} = module.finish(state, :eof)
            IO.iodata_to_binary(first ++ second ++ final)

          nil ->
            opts[:map_response_body].(status, [{"content-type", "application/json"}], body)
        end

      case mapped do
        {:ok, mapped_body} ->
          conn |> put_resp_header("retry-after", "7") |> send_resp(status, mapped_body)

        {:error, reason, mapped_status, headers, mapped_body} ->
          conn =
            Enum.reduce(headers, conn, fn {key, value}, conn ->
              put_resp_header(conn, key, value)
            end)

          conn
          |> put_private(:relayixir_proxy_error, reason)
          |> send_resp(mapped_status, mapped_body)

        mapped_body ->
          conn |> put_resp_header("retry-after", "7") |> send_resp(status, mapped_body)
      end
    end
  end

  setup do
    old_proxy = Application.get_env(:backplane_llama, :google_http_proxy)
    old_token = Application.get_env(:backplane, :auth_token)
    Application.put_env(:backplane_llama, :google_http_proxy, CapturingProxy)
    Application.put_env(:backplane, :auth_token, "backplane-client")

    on_exit(fn ->
      restore_env(:backplane_llama, :google_http_proxy, old_proxy)
      restore_env(:backplane, :auth_token, old_token)
    end)

    {:ok, _} = Credentials.store("google-router-key", "google-upstream-secret", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "google-router",
        preset_key: "google-gemini-developer",
        credential: "google-router-key",
        default_headers: %{
          "authorization" => "must-not-win",
          "x-provider-default" => "provider"
        }
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :google,
        base_url: "https://generativelanguage.example.test/v1beta",
        default_headers: %{
          "x-goog-api-key" => "must-not-win",
          "x-api-default" => "api"
        }
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: "gemini-2.5-pro",
        source: :manual
      })

    {:ok, _} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id
      })

    {:ok, _} = ModelAlias.put("pro", "google-router/gemini-2.5-pro")
    :ok
  end

  test "forwards raw native request and response with only the bound upstream credential" do
    request_body = ~s({ "contents" : [{"parts":[{"text":"hello"}]}] })

    response =
      :post
      |> conn("/v1beta/models/pro:generateContent", request_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-goog-api-key", "backplane-client")
      |> put_req_header("user-agent", "native-google-client")
      |> put_req_header("x-goog-user-project", "native-project")
      |> Router.call(Router.init([]))

    assert response.status == 200
    assert response.resp_body == File.read!(@fixture)

    assert_received {:google_proxy, forwarded, upstream, opts}
    assert forwarded.request_path == "/models/gemini-2.5-pro:generateContent"
    assert get_req_header(forwarded, "authorization") == []
    assert get_req_header(forwarded, "x-goog-api-key") == []
    assert get_req_header(forwarded, "user-agent") == ["native-google-client"]
    assert get_req_header(forwarded, "x-goog-user-project") == ["native-project"]
    assert opts[:body] == request_body
    refute Keyword.has_key?(opts, :map_response_body)
    refute Keyword.has_key?(opts, :map_response_chunk)
    assert {"x-goog-api-key", "google-upstream-secret"} in upstream.inject_request_headers
    assert {"authorization", nil} in upstream.inject_request_headers
    assert {"x-provider-default", "provider"} in upstream.inject_request_headers
    assert upstream.default_request_headers == [{"x-api-default", "api"}]
    assert upstream.path_prefix_rewrite == "/v1beta"
  end

  test "preserves native Google stream query parameters" do
    body = %{"contents" => [%{"parts" => [%{"text" => "hello"}]}]}
    response = google_call("pro", "streamGenerateContent?alt=sse&trace=1", body)
    assert response.status == 200
    assert_received {:google_proxy, forwarded, _, _}
    assert forwarded.query_string == "alt=sse&trace=1"
  end

  test "translates Gemini JSON and SSE through an enabled Antigravity model" do
    %{provider: provider, api: api, surface: surface} = create_antigravity_provider()
    {:ok, _} = ModelAlias.put("agy-gemini", "#{provider.name}/gemini-3.8-flash-low")
    Application.put_env(:backplane_llama, :google_http_proxy, TranslationProxy)

    body = %{
      "contents" => [
        %{
          "role" => "model",
          "parts" => [
            %{
              "functionCall" => %{"name" => "lookup", "args" => %{}},
              "thoughtSignature" => "opaque-signature"
            }
          ]
        }
      ],
      "tools" => [%{"functionDeclarations" => [%{"name" => "lookup"}]}],
      "generationConfig" => %{"temperature" => 0.1},
      "sessionId" => "agy-session"
    }

    response = google_call("agy-gemini", "generateContent", body)
    assert response.status == 200

    assert get_in(Jason.decode!(response.resp_body), ["candidates", Access.at(0), "content"]) !=
             nil

    assert_received {:google_proxy, forwarded, upstream, opts}
    assert forwarded.request_path == "/v1internal:generateContent"
    assert forwarded.query_string == ""
    assert upstream.metadata.api_surface == :antigravity

    assert {"authorization", "Bearer antigravity-google-secret"} in upstream.inject_request_headers

    refute inspect(upstream.inject_request_headers) =~ "backplane-client"
    native = Jason.decode!(opts[:body])
    assert native["project"] == "managed-project"
    assert native["model"] == "gemini-3.8-flash-low"
    assert native["request"] == body
    refute Map.has_key?(native["request"], "project")

    stream = google_call("agy-gemini", "streamGenerateContent?alt=sse", body)
    assert stream.status == 200
    assert "data: " <> json = String.trim(stream.resp_body)
    assert Jason.decode!(json)["usageMetadata"]["totalTokenCount"] == 4
    assert_received {:google_proxy, streamed, _, stream_opts}
    assert streamed.request_path == "/v1internal:streamGenerateContent"
    assert streamed.query_string == "alt=sse"
    assert stream_opts[:response_stream_mapper]

    {:ok, _} = ProviderModelSurface.update(surface, %{enabled: false})
    assert google_call("agy-gemini", "generateContent", body).status == 404
    refute_received {:google_proxy, _, _, _}

    assert api.native_protocols == [:google_antigravity]
  end

  test "catalog exposes resolvable Antigravity aliases" do
    %{provider: provider} = create_antigravity_provider()
    {:ok, _} = ModelAlias.put("agy-catalog", "#{provider.name}/gemini-3.8-flash-low")

    catalog =
      :get
      |> conn("/v1beta/models")
      |> put_req_header("x-goog-api-key", "backplane-client")
      |> Router.call([])

    assert catalog.status == 200

    assert Enum.any?(
             Jason.decode!(catalog.resp_body)["models"],
             &(&1["name"] == "models/agy-catalog")
           )
  end

  test "counts direct and nested text contents through Antigravity without generation bindings" do
    %{provider: provider, surface: surface} = create_antigravity_provider()
    {:ok, _} = ModelAlias.put("agy-count", "#{provider.name}/gemini-3.8-flash-low")
    Application.put_env(:backplane_llama, :google_http_proxy, TranslationProxy)

    contents = [%{"role" => "user", "parts" => [%{"text" => "Hello world"}]}]

    for body <- [
          %{"contents" => contents},
          %{
            "generateContentRequest" => %{
              "model" => "models/agy-count",
              "contents" => contents
            }
          }
        ] do
      response = google_call("agy-count", "countTokens", body)
      assert response.status == 200
      assert Jason.decode!(response.resp_body) == %{"totalTokens" => 2}
      assert get_resp_header(response, "retry-after") == ["7"]

      assert_received {:google_proxy, forwarded, upstream, opts}
      assert forwarded.request_path == "/v1internal:countTokens"
      assert forwarded.query_string == ""
      assert upstream.metadata.api_surface == :antigravity

      assert {"authorization", "Bearer antigravity-google-secret"} in upstream.inject_request_headers

      refute inspect(upstream.inject_request_headers) =~ "backplane-client"

      assert Jason.decode!(opts[:body]) == %{
               "request" => %{
                 "model" => "gemini-3.8-flash-low",
                 "contents" => contents
               }
             }

      refute opts[:body] =~ "managed-project"
      refute opts[:body] =~ "requestId"
      refute opts[:body] =~ "sessionId"
    end

    {:ok, _} = ProviderModelSurface.update(surface, %{enabled: false})
    assert google_call("agy-count", "countTokens", %{"contents" => []}).status == 404
    refute_received {:google_proxy, _, _, _}
  end

  test "rejects unsupported or malformed Antigravity count requests before upstream" do
    %{provider: provider} = create_antigravity_provider()
    {:ok, _} = ModelAlias.put("agy-count-reject", "#{provider.name}/gemini-3.8-flash-low")

    for body <- [
          %{"contents" => [], "systemInstruction" => %{"parts" => [%{"text" => "x"}]}},
          %{"contents" => [], "tools" => []},
          %{"contents" => [%{"parts" => [%{"inlineData" => %{}}]}]},
          %{"contents" => [%{"parts" => [%{"functionResponse" => %{}}]}]},
          %{"generateContentRequest" => %{"contents" => [], "toolConfig" => %{}}}
        ] do
      assert google_call("agy-count-reject", "countTokens", body).status == 422
      refute_received {:google_proxy, _, _, _}
    end

    for body <- [
          %{"contents" => "invalid"},
          %{"contents" => [], "project" => "caller-project"},
          %{"contents" => [], "model" => "other"},
          %{
            "generateContentRequest" => %{
              "model" => "models/other",
              "contents" => []
            }
          }
        ] do
      assert google_call("agy-count-reject", "countTokens", body).status == 400
      refute_received {:google_proxy, _, _, _}
    end
  end

  test "preserves count provider errors and rejects malformed successful responses" do
    %{provider: provider} = create_antigravity_provider()
    {:ok, _} = ModelAlias.put("agy-count-response", "#{provider.name}/gemini-3.8-flash-low")
    Application.put_env(:backplane_llama, :google_http_proxy, TranslationProxy)

    upstream_error =
      Jason.encode!(%{"error" => %{"code" => 429, "status" => "RESOURCE_EXHAUSTED"}})

    Process.put(:google_translation_reply, {429, upstream_error})
    error_response = google_call("agy-count-response", "countTokens", %{"contents" => []})
    assert error_response.status == 429
    assert error_response.resp_body == upstream_error
    assert get_resp_header(error_response, "retry-after") == ["7"]

    Process.put(:google_translation_reply, {200, ~s({"totalTokens":"2"})})
    malformed = google_call("agy-count-response", "countTokens", %{"contents" => []})
    assert malformed.status == 502
    assert Jason.decode!(malformed.resp_body)["error"]["status"] == "UNAVAILABLE"
    assert malformed.private[:relayixir_proxy_error]
  end

  test "normalizes an empty successful Antigravity count response to zero" do
    %{provider: provider} = create_antigravity_provider()
    {:ok, _} = ModelAlias.put("agy-count-zero", "#{provider.name}/gemini-3.8-flash-low")
    Application.put_env(:backplane_llama, :google_http_proxy, TranslationProxy)
    Process.put(:google_translation_reply, {200, ~s({})})

    response = google_call("agy-count-zero", "countTokens", %{"contents" => []})
    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"totalTokens" => 0}
  end

  test "keeps native Gemini countTokens routing unchanged" do
    body = %{
      "generateContentRequest" => %{
        "model" => "models/pro",
        "contents" => [%{"parts" => [%{"text" => "hello"}]}]
      }
    }

    response = google_call("pro", "countTokens", body)
    assert response.status == 200
    assert response.resp_body == File.read!(@fixture)
    assert_received {:google_proxy, forwarded, upstream, opts}
    assert forwarded.request_path == "/models/gemini-2.5-pro:countTokens"
    assert upstream.metadata.api_surface == :google

    assert Jason.decode!(opts[:body])["generateContentRequest"]["model"] ==
             "models/gemini-2.5-pro"

    refute Keyword.has_key?(opts, :map_response_body)
  end

  test "requires the correct database client scope before translated invocation" do
    %{provider: provider} = create_antigravity_provider()
    {:ok, _} = ModelAlias.put("agy-scoped", "#{provider.name}/gemini-3.8-flash-low")

    {:ok, _} =
      Backplane.Clients.create_client(%{
        name: "Google models only",
        token: "google-models-token",
        scopes: ["llm::models"],
        active: true
      })

    result =
      :post
      |> conn(
        "/v1beta/models/agy-scoped:generateContent",
        Jason.encode!(%{"contents" => []})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer google-models-token")
      |> Router.call([])

    assert result.status == 403
    refute_received {:google_proxy, _, _, _}

    count_result =
      :post
      |> conn(
        "/v1beta/models/agy-scoped:countTokens",
        Jason.encode!(%{"contents" => []})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer google-models-token")
      |> Router.call([])

    assert count_result.status == 403
    refute_received {:google_proxy, _, _, _}

    unauthorized =
      :get
      |> conn("/v1beta/models")
      |> put_req_header("authorization", "Bearer invalid-token")
      |> Router.call([])

    assert unauthorized.status == 401
  end

  test "returns a real 502 when a successful Antigravity response is malformed" do
    %{provider: provider} = create_antigravity_provider()
    {:ok, _} = ModelAlias.put("agy-malformed", "#{provider.name}/gemini-3.8-flash-low")
    Application.put_env(:backplane_llama, :google_http_proxy, TranslationProxy)
    Process.put(:google_translation_reply, {200, ~s({"unexpected":true})})

    result = google_call("agy-malformed", "generateContent", %{"contents" => []})
    assert result.status == 502
    assert Jason.decode!(result.resp_body)["error"]["status"] == "UNAVAILABLE"
    assert result.private[:relayixir_proxy_error]
  end

  test "a disabled Google auto-model route cannot fall through to Antigravity" do
    %{provider: provider} = create_antigravity_provider()

    assert {:ok, _} =
             AutoModel.configure_targets("fast", [
               "#{provider.name}/gemini-3.8-flash-low"
             ])

    route = AutoModelRoute.get_by_model_and_surface("fast", :google)
    route |> AutoModelRoute.changeset(%{enabled: false}) |> Repo.update!()

    assert google_call("fast", "generateContent", %{"contents" => []}).status == 404
    refute_received {:google_proxy, _, _, _}
  end

  defp create_antigravity_provider do
    {:ok, _} =
      Credentials.store_device_token("antigravity-google-oauth", "google_oauth", %{
        "access_token" => "antigravity-google-secret",
        "refresh_token" => "refresh-token",
        "expires_at" => System.system_time(:millisecond) + 3_600_000
      })

    {:ok, provider} =
      Provider.create(%{
        name: "antigravity-google-router",
        preset_key: "google-antigravity",
        credential: "antigravity-google-oauth"
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :antigravity,
        base_url: "https://daily-cloudcode.example.test",
        backend_config: %{"project_id" => "managed-project"}
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: "gemini-3.8-flash-low",
        source: :manual,
        metadata: %{"supportedGenerationMethods" => ["generateContent"]}
      })

    {:ok, surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        metadata: model.metadata
      })

    %{provider: provider, api: api, model: model, surface: surface}
  end

  defp google_call(model, operation, body) do
    :post
    |> conn("/v1beta/models/#{model}:#{operation}", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-goog-api-key", "backplane-client")
    |> Router.call([])
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
