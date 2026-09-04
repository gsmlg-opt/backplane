defmodule Backplane.LLM.OpenAICodexProxyPlugTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Backplane.Auth.Fixtures

  alias Backplane.LLM.{
    OpenAICodex,
    OpenAICodexProxyPlug,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    RateLimiter
  }

  alias Backplane.Settings.{Credentials, TokenCache}
  alias Backplane.LLM.ModelResolver

  setup do
    {:ok, server_pid} = Bandit.start_link(plug: Backplane.Test.CodexUpstream, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)
    backend_base_url = "http://127.0.0.1:#{port}"

    previous_backend = Application.get_env(:backplane, :openai_codex_backend_base_url)

    Application.put_env(:backplane, :openai_codex_backend_base_url, backend_base_url)

    on_exit(fn ->
      try do
        ThousandIsland.stop(server_pid)
      catch
        :exit, _ -> :ok
      end

      if previous_backend do
        Application.put_env(:backplane, :openai_codex_backend_base_url, previous_backend)
      else
        Application.delete_env(:backplane, :openai_codex_backend_base_url)
      end
    end)

    TokenCache.clear()
    RateLimiter.reset()
    expires_at = System.system_time(:millisecond) + 60 * 60 * 1000

    {:ok, _} =
      Credentials.store_device_token(
        "codex-proxy-token",
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "id_token" => "codex-id-token",
          "access_token" => "chatgpt-access-token",
          "refresh_token" => "refresh-token",
          "expires_at" => expires_at
        },
        %{"account_id" => "acc-123"}
      )

    {:ok, provider} =
      Provider.create(%{
        name: "openai-codex",
        preset_key: "openai-codex",
        api_type: :openai,
        api_url: backend_base_url,
        credential: "codex-proxy-token",
        models: []
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: backend_base_url,
        model_discovery_path: "/models"
      })

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: "gpt-5.5", source: :discovered})

    ProviderModelSurface.create(%{provider_model_id: model.id, provider_api_id: api.id})
    ModelResolver.clear_cache()

    {:ok, %{provider: provider, api: api}}
  end

  test "dispatches provider-scoped route before the generic router", %{provider: provider} do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])
    access_token = resource_access_token_fixture!(user, client, ["llm::invoke"], :v1)

    conn =
      :post
      |> conn("/v1/providers/#{provider.name}/responses", "raw-body")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{access_token.value}")
      |> OpenAICodexProxyPlug.call([])

    assert conn.status == 201
  end

  test "retains the Codex backend path prefix and query for every direct endpoint", %{
    provider: provider,
    api: api
  } do
    {:ok, _api} =
      ProviderApi.update(api, %{base_url: "#{api.base_url}/backend-api/codex"})

    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::models", "llm::invoke"])

    access_token =
      resource_access_token_fixture!(user, client, ["llm::models", "llm::invoke"], :v1)

    for {method, endpoint, expected_status} <- [
          {:get, "models?limit=2", 200},
          {:post, "responses?stream=true", 201},
          {:post, "responses/compact?foo=bar", 201}
        ] do
      body = if method == :post, do: "raw-#{endpoint}", else: nil

      conn =
        method
        |> conn("/v1/providers/#{provider.name}/#{endpoint}", body)
        |> put_req_header("authorization", "Bearer #{access_token.value}")
        |> OpenAICodexProxyPlug.call([])

      assert conn.status == expected_status
      response = Jason.decode!(conn.resp_body)
      assert response["request_target"] == "/backend-api/codex/#{endpoint}"
      if method == :post, do: assert(response["body"] == body)
    end
  end

  test "disabled providers return a local error without contacting upstream", %{
    provider: provider
  } do
    parent = self()
    handler_id = "codex-provider-disabled-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:backplane, :codex, :proxy, :request, :failed],
      fn _event, measurements, metadata, _config ->
        send(parent, {:failed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _disabled} = Provider.update(provider, %{enabled: false})

    conn =
      :post
      |> conn("/v1/providers/#{provider.name}/responses", "raw-body")
      |> OpenAICodexProxyPlug.call([])

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "provider_disabled"}}

    assert_receive {:failed, %{latency_ms: latency_ms}, metadata}, 1_000
    assert latency_ms >= 0
    assert metadata.provider_id == provider.id
    assert metadata.provider_name == provider.name
    assert metadata.endpoint == "responses"
    assert metadata.status == 503
    assert metadata.error_class == :provider_disabled
  end

  test "missing provider credentials return credential_unavailable", %{provider: provider} do
    assert :ok = Credentials.delete(provider.credential)

    conn =
      :post
      |> conn("/v1/providers/#{provider.name}/responses", "raw-body")
      |> OpenAICodexProxyPlug.call([])

    assert conn.status == 503

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{"code" => "credential_unavailable"}
           }
  end

  test "provider rate limits return 429 with retry-after", %{provider: provider} do
    {:ok, provider} = Provider.update(provider, %{rpm_limit: 1})
    assert :ok = RateLimiter.check(provider.id, provider.rpm_limit)

    conn =
      :post
      |> conn("/v1/providers/#{provider.name}/responses", "raw-body")
      |> OpenAICodexProxyPlug.call([])

    assert conn.status == 429
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) > 0

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "message" => "Provider rate limit exceeded. Retry after #{retry_after} seconds.",
               "type" => "rate_limit_error",
               "code" => "rate_limit_exceeded"
             }
           }
  end

  test "provider-scoped models requires the model-list scope", %{provider: provider} do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])
    access_token = resource_access_token_fixture!(user, client, ["llm::invoke"], :v1)

    conn =
      :get
      |> conn("/v1/providers/#{provider.name}/models")
      |> put_req_header("authorization", "Bearer #{access_token.value}")
      |> OpenAICodexProxyPlug.call([])

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "insufficient_scope"}
  end

  test "replaces all provider-owned client header spellings", %{provider: provider} do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])
    access_token = resource_access_token_fixture!(user, client, ["llm::invoke"], :v1)

    conn =
      :post
      |> conn("/v1/providers/#{provider.name}/responses", "raw-body")
      |> Map.put(:req_headers, [
        {"authorization", "Bearer #{access_token.value}"},
        {"x-api-key", "client-api-key"},
        {"ChatGPT-Account-ID", "client-account"},
        {"X-OpenAI-FedRAMP", "client-fedramp"}
      ])
      |> OpenAICodexProxyPlug.call([])

    assert conn.status == 201, conn.resp_body
    headers = Jason.decode!(conn.resp_body)["headers"]
    assert headers["authorization"] == "Bearer chatgpt-access-token", inspect(headers)
    assert headers["chatgpt-account-id"] == "acc-123"
    refute headers["x-api-key"]
    refute headers["x-openai-fedramp"]
    assert headers["originator"] == "codex_cli_rs"
  end

  test "preserves client metadata headers and client originator", %{provider: provider} do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])
    access_token = resource_access_token_fixture!(user, client, ["llm::invoke"], :v1)

    metadata_headers = [
      {"user-agent", "codex-test/1.0"},
      {"originator", "codex_desktop"},
      {"session-id", "session-123"},
      {"thread-id", "thread-456"},
      {"x-client-request-id", "client-789"},
      {"x-openai-subagent", "reviewer"},
      {"openai-beta", "responses=v1"},
      {"x-codex-future", "codex-value"},
      {"x-responsesapi-future", "responses-value"}
    ]

    conn =
      :post
      |> conn("/v1/providers/#{provider.name}/responses", "raw-body")
      |> Map.put(:req_headers, [
        {"authorization", "Bearer #{access_token.value}"} | metadata_headers
      ])
      |> OpenAICodexProxyPlug.call([])

    assert conn.status == 201
    upstream_headers = Jason.decode!(conn.resp_body)["headers"]

    Enum.each(metadata_headers, fn {name, value} ->
      assert upstream_headers[name] == value
    end)
  end

  test "preserves unknown JSON fields byte-for-byte", %{provider: provider} do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])
    access_token = resource_access_token_fixture!(user, client, ["llm::invoke"], :v1)

    json_body =
      Jason.encode!(%{
        "model" => "future-model-without-a-local-row",
        "input" => "hello",
        "tools" => [%{"type" => "function", "name" => "lookup"}],
        "reasoning" => %{"effort" => "high", "future_option" => true},
        "metadata" => %{"trace" => "abc"},
        "unknown_future_field" => %{"nested" => [1, 2, 3]}
      })

    conn =
      :post
      |> conn("/v1/providers/#{provider.name}/responses?mode=raw", json_body)
      |> put_req_header("authorization", "Bearer #{access_token.value}")
      |> put_req_header("content-type", "application/json")
      |> OpenAICodexProxyPlug.call([])

    assert conn.status == 200
    assert conn.resp_body == json_body
  end

  test "preserves a zstd-encoded request body byte-for-byte", %{provider: provider} do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])
    access_token = resource_access_token_fixture!(user, client, ["llm::invoke"], :v1)

    zstd_body =
      Base.decode16!(
        "28B52FFD0458850200B244111880276E9354648C6C8CC3D8467634910531D0CB0E3668EE08AD0900A3184480FC201F50CFC84F6242A5E85A2D687F7CADBA3483CD33C7BD044EEB0E5573A393279E359C0502003B35AE5C7309A3EC3DE1"
      )

    conn =
      :post
      |> conn("/v1/providers/#{provider.name}/responses?mode=raw", zstd_body)
      |> put_req_header("authorization", "Bearer #{access_token.value}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("content-encoding", "zstd")
      |> OpenAICodexProxyPlug.call([])

    assert conn.status == 200
    assert conn.resp_body == zstd_body
    assert get_resp_header(conn, "x-seen-content-encoding") == ["zstd"]
  end

  test "preserves SSE bytes without adding chat chunks or DONE", %{provider: provider} do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])
    access_token = resource_access_token_fixture!(user, client, ["llm::invoke"], :v1)

    conn =
      :post
      |> conn("/v1/providers/#{provider.name}/responses?mode=sse", "raw-body")
      |> put_req_header("authorization", "Bearer #{access_token.value}")
      |> put_req_header("accept", "text/event-stream")
      |> OpenAICodexProxyPlug.call([])

    expected =
      "event: response.output_text.delta\n" <>
        ~s|data: {"type":"response.output_text.delta","delta":"ok"}\n\n| <>
        ": keep-alive\n\n" <>
        "event: response.completed\n" <>
        ~s|data: {"type":"response.completed"}\n\n|

    assert conn.status == 200
    assert conn.resp_body == expected
    refute conn.resp_body =~ "chat.completion.chunk"
    refute conn.resp_body =~ "[DONE]"
  end

  test "preserves upstream errors and records them as completed upstream responses", %{
    provider: provider
  } do
    parent = self()
    handler_id = "codex-upstream-error-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:backplane, :codex, :proxy, :request, :completed],
        [:backplane, :codex, :proxy, :request, :failed]
      ],
      fn event, measurements, metadata, _config ->
        send(parent, {event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])
    access_token = resource_access_token_fixture!(user, client, ["llm::invoke"], :v1)

    conn =
      :post
      |> conn("/v1/providers/#{provider.name}/responses?mode=upstream-error", "raw-body")
      |> put_req_header("authorization", "Bearer #{access_token.value}")
      |> put_req_header("x-client-request-id", "client-req-123")
      |> OpenAICodexProxyPlug.call([])

    assert conn.status == 502
    assert conn.resp_body == ~s({"error":{"code":"upstream_bad_gateway"}})
    assert get_resp_header(conn, "retry-after") == ["17"]
    assert get_resp_header(conn, "x-request-id") == ["upstream-req-502"]

    assert_receive {
                     [:backplane, :codex, :proxy, :request, :completed],
                     %{latency_ms: latency_ms},
                     metadata
                   },
                   1_000

    assert latency_ms >= 0
    assert metadata.status == 502
    assert metadata.stream == false
    assert metadata.client_request_id == "client-req-123"
    assert metadata.upstream_request_id == "upstream-req-502"
    assert metadata.error_class == nil
    refute_receive {[:backplane, :codex, :proxy, :request, :failed], _, _}
  end

  test "does not classify a missing legacy compact endpoint as a missing model", %{
    provider: provider
  } do
    parent = self()
    handler_id = "codex-compact-404-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:backplane, :codex, :proxy, :request, :completed],
      fn _event, _measurements, metadata, _config ->
        send(parent, {:completed, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])
    access_token = resource_access_token_fixture!(user, client, ["llm::invoke"], :v1)

    conn =
      :post
      |> conn(
        "/v1/providers/#{provider.name}/responses/compact?mode=upstream-not-found",
        "raw-body"
      )
      |> put_req_header("authorization", "Bearer #{access_token.value}")
      |> OpenAICodexProxyPlug.call([])

    assert conn.status == 404
    assert conn.resp_body == ~s({"error":{"code":"upstream_not_found"}})
    assert_receive {:completed, metadata}, 1_000
    assert metadata.endpoint == "responses/compact"
    assert metadata.error_class == nil
  end

  test "rejects disallowed method without upstream" do
    conn =
      :delete
      |> conn("/v1/providers/openai-codex/responses")
      |> OpenAICodexProxyPlug.call([])

    assert conn.status == 404

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{"code" => "unsupported_endpoint"}
           }
  end

  test "emits failure telemetry on upstream transport error", %{
    provider: provider,
    api: api
  } do
    parent = self()

    :telemetry.attach(
      "codex-transport-error-test",
      [:backplane, :codex, :proxy, :request, :failed],
      fn _event, measurements, metadata, _config ->
        send(parent, {:failed, measurements, metadata})
      end,
      nil
    )

    {:ok, _} = ProviderApi.update(api, %{base_url: "http://127.0.0.1:1"})
    ModelResolver.clear_cache()

    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])
    access_token = resource_access_token_fixture!(user, client, ["llm::invoke"], :v1)

    conn =
      :post
      |> conn("/v1/providers/#{provider.name}/responses", "raw-body")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{access_token.value}")
      |> OpenAICodexProxyPlug.call([])

    assert conn.status == 502

    assert_receive {:failed, %{latency_ms: latency}, metadata}, 1_000
    assert latency >= 0
    assert metadata.error_class == :upstream_transport_error
    assert metadata.endpoint == "responses"
    assert metadata.status == 502
    assert metadata.stream == false
    assert metadata.upstream_request_id == nil
  after
    :telemetry.detach("codex-transport-error-test")
  end

  test "cancels streaming upstream and reports client_disconnected", %{provider: provider} do
    parent = self()
    handler_id = "codex-client-disconnect-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:backplane, :codex, :proxy, :request, :failed],
      fn _event, measurements, metadata, _config ->
        send(parent, {:failed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])
    access_token = resource_access_token_fixture!(user, client, ["llm::invoke"], :v1)

    conn =
      :post
      |> conn("/v1/providers/#{provider.name}/responses?mode=sse", "raw-body")
      |> put_req_header("authorization", "Bearer #{access_token.value}")
      |> put_req_header("accept", "text/event-stream")

    {_adapter, adapter_state} = conn.adapter
    conn = %{conn | adapter: {Backplane.Test.ClosedChunkAdapter, adapter_state}}
    result = OpenAICodexProxyPlug.call(conn, [])

    assert result.private[:relayixir_downstream_disconnected] == true

    assert_receive {:failed, %{latency_ms: latency_ms}, metadata}, 1_000
    assert latency_ms >= 0
    assert metadata.error_class == :client_disconnected
    assert metadata.status == 200
    assert metadata.stream == true
  end

  test "provider predicate only accepts Codex OAuth" do
    {:ok, codex_provider} =
      Provider.create(%{
        name: "codex-predicate",
        preset_key: "openai-codex",
        api_type: :openai,
        api_url: "https://chatgpt.com/backend-api/codex",
        credential: "codex-proxy-token",
        models: []
      })

    api = %ProviderApi{api_surface: :openai}
    assert OpenAICodex.enabled?(codex_provider, api)
    assert not OpenAICodex.enabled?(%{codex_provider | preset_key: "openai"}, api)
  end

  test "backend validation preserves case-sensitive custom path prefixes", %{api: api} do
    expected = api.base_url <> "/Backend-API/Codex"

    assert {:ok, ^expected} =
             OpenAICodex.validate_backend_base_url(api.base_url <> "/Backend-API/Codex/")
  end
end

defmodule Backplane.Test.ClosedChunkAdapter do
  @behaviour Plug.Conn.Adapter

  defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
  defdelegate send_file(state, status, headers, path, offset, length), to: Plug.Adapters.Test.Conn
  defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
  defdelegate read_req_body(state, opts), to: Plug.Adapters.Test.Conn
  defdelegate inform(state, status, headers), to: Plug.Adapters.Test.Conn
  defdelegate upgrade(state, protocol, opts), to: Plug.Adapters.Test.Conn
  defdelegate push(state, path, headers), to: Plug.Adapters.Test.Conn
  defdelegate get_peer_data(state), to: Plug.Adapters.Test.Conn
  defdelegate get_sock_data(state), to: Plug.Adapters.Test.Conn
  defdelegate get_ssl_data(state), to: Plug.Adapters.Test.Conn
  defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn

  def chunk(_state, _body), do: {:error, :closed}
end

defmodule Backplane.Test.CodexUpstream do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/models" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"models" => []}))
  end

  post "/responses" do
    respond_with_request(conn, 201)
  end

  get "/backend-api/codex/models" do
    respond_with_request(conn, 200)
  end

  post "/backend-api/codex/responses" do
    respond_with_request(conn, 201)
  end

  post "/backend-api/codex/responses/compact" do
    respond_with_request(conn, 201)
  end

  post "/responses/compact" do
    respond_with_request(conn, 201)
  end

  defp respond_with_request(conn, status) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    headers = Map.new(conn.req_headers)

    request_target =
      case conn.query_string do
        "" -> conn.request_path
        query -> conn.request_path <> "?" <> query
      end

    case URI.decode_query(conn.query_string) do
      %{"mode" => "raw"} ->
        content_encoding = get_req_header(conn, "content-encoding") |> List.first() || ""

        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("x-seen-content-encoding", content_encoding)
        |> send_resp(200, body)

      %{"mode" => "sse"} ->
        {:ok, conn} =
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)
          |> chunk(
            "event: response.output_text.delta\n" <>
              "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\n"
          )

        {:ok, conn} = chunk(conn, ": keep-alive\n\n")

        {:ok, conn} =
          chunk(
            conn,
            "event: response.completed\n" <>
              "data: {\"type\":\"response.completed\"}\n\n"
          )

        conn

      %{"mode" => "upstream-error"} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("retry-after", "17")
        |> put_resp_header("x-request-id", "upstream-req-502")
        |> send_resp(502, ~s({"error":{"code":"upstream_bad_gateway"}}))

      %{"mode" => "upstream-not-found"} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, ~s({"error":{"code":"upstream_not_found"}}))

      _params ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          status,
          Jason.encode!(%{
            "request_target" => request_target,
            "body" => body,
            "headers" => headers
          })
        )
    end
  end
end
