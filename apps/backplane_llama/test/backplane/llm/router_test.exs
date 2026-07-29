defmodule Backplane.LLM.RouterTest do
  use Backplane.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Backplane.Auth.Fixtures

  alias Backplane.Auth.Resources
  alias Backplane.Embedding

  alias Backplane.LLM.{
    ModelAlias,
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    RateLimiter,
    Router
  }

  alias Backplane.Settings.Credentials

  defmodule MoonshotUpstream do
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:match)
    plug(:dispatch)

    post "/v1/chat/completions" do
      moonshot_response(conn)
    end

    post "/anthropic/v1/messages" do
      moonshot_response(conn)
    end

    defp moonshot_response(conn) do
      if store = Application.get_env(:backplane, :router_test_moonshot_store) do
        Agent.update(store, &Map.put(&1, :body, conn.body_params))
      end

      if get_in(conn.body_params, ["thinking", "type"]) == "disabled" do
        send_resp(
          conn,
          400,
          Jason.encode!(%{
            "error" => %{
              "type" => "invalid_request_error",
              "message" => "invalid thinking: only type=enabled is allowed for this model"
            }
          })
        )
      else
        send_resp(
          conn,
          200,
          Jason.encode!(%{
            "id" => "chatcmpl-moonshot-test",
            "object" => "chat.completion",
            "model" => conn.body_params["model"],
            "choices" => [
              %{
                "index" => 0,
                "message" => %{"role" => "assistant", "content" => "ok"},
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
          })
        )
      end
    end

    match _ do
      send_resp(conn, 404, "Not Found")
    end
  end

  defmodule CodexUpstream do
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:match)
    plug(:dispatch)

    post "/backend-api/codex/responses" do
      if store = Application.get_env(:backplane, :router_test_codex_store) do
        Agent.update(store, fn _ ->
          %{
            path: conn.request_path,
            headers: conn.req_headers,
            body: conn.body_params
          }
        end)
      end

      events = [
        %{"type" => "response.output_text.delta", "delta" => "Hello"},
        %{"type" => "response.output_text.delta", "delta" => " from Codex"},
        %{
          "type" => "response.completed",
          "response" => %{
            "usage" => %{"input_tokens" => 3, "output_tokens" => 4, "total_tokens" => 7}
          }
        }
      ]

      send_sse(conn, events)
    end

    match _ do
      send_resp(conn, 404, "Not Found")
    end

    defp send_sse(conn, events) do
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(events, conn, fn event, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, "data: #{Jason.encode!(event)}\n\n")
        conn
      end)
    end
  end

  setup do
    auth_token = Application.get_env(:backplane, :auth_token)
    auth_tokens = Application.get_env(:backplane, :auth_tokens)

    Application.delete_env(:backplane, :auth_token)
    Application.delete_env(:backplane, :auth_tokens)

    on_exit(fn ->
      restore_env(:auth_token, auth_token)
      restore_env(:auth_tokens, auth_tokens)
    end)

    Credentials.store("router-anthropic-cred", "sk-ant-test-key-abcd", "llm")
    Credentials.store("router-openai-cred", "sk-openai-test-key", "llm")
    Credentials.store("router-anthropic-rl-cred", "sk-ant-test-rl-abcd", "llm")
    Credentials.store("router-openai-rl-cred", "sk-openai-test-rl-abcd", "llm")
    Credentials.store("router-embedding-cred", "sk-embedding-test-key", "llm")
    ModelResolver.clear_cache()
    RateLimiter.reset()
    :ok = Backplane.Settings.set(ModelAlias.setting_key(), %{})
    :ok
  end

  defp llm_request(method, path, body \\ nil) do
    conn_body = if body, do: Jason.encode!(body), else: ""
    conn = conn(method, path, conn_body)
    conn = put_req_header(conn, "content-type", "application/json")
    Router.call(conn, Router.init([]))
  end

  defp public_llm_request(method, path, body) do
    conn_body = if body, do: Jason.encode!(body), else: ""

    conn(method, path, conn_body)
    |> put_req_header("content-type", "application/json")
    |> Backplane.LLM.ProxyPlug.call(Backplane.LLM.ProxyPlug.init([]))
  end

  defp public_llm_request(method, path) do
    conn(method, path)
    |> Backplane.LLM.ProxyPlug.call(Backplane.LLM.ProxyPlug.init([]))
  end

  defp public_authenticated_llm_request(method, path, token, body \\ nil) do
    conn_body = if body, do: Jason.encode!(body), else: ""

    method
    |> conn(path, conn_body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Backplane.LLM.ProxyPlug.call(Backplane.LLM.ProxyPlug.init([]))
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)

  describe "protected /v1 resource" do
    test "returns the canonical resource descriptor in open mode" do
      conn = public_llm_request(:get, "/v1")

      assert conn.status == 200

      assert json_body(conn) == %{
               "resource" => Resources.uri(:v1),
               "resource_documentation" => Resources.documentation_uri(:v1)
             }
    end

    test "returns the canonical resource descriptor to an authenticated client" do
      token = resource_token!(:v1, ["llm::models"], [:v1])

      conn = public_authenticated_llm_request(:get, "/v1", token.value)

      assert conn.status == 200
      assert json_body(conn)["resource"] == Resources.uri(:v1)
    end

    test "challenges the protected canonical descriptor with resource metadata" do
      oauth_client_fixture!(resources: [:v1], scopes: ["llm::models"])

      conn = public_llm_request(:get, "/v1")

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_token"}

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Bearer resource_metadata="#{Resources.metadata_uri(:v1)}")
             ]
    end

    test "query-bearing and trailing-slash descriptor challenges omit resource metadata" do
      oauth_client_fixture!(resources: [:v1], scopes: ["llm::models"])

      for path <- ["/v1?x=1", "/v1/"] do
        conn = public_llm_request(:get, path)

        assert conn.status == 401
        assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      end
    end

    test "nested missing and invalid token challenges include the least scope" do
      oauth_client_fixture!(resources: [:v1], scopes: ["llm::models", "llm::invoke"])

      for {method, path, scope} <- [
            {:get, "/v1/models", "llm::models"},
            {:post, "/v1/responses", "llm::invoke"}
          ] do
        missing = public_llm_request(method, path)
        invalid = public_authenticated_llm_request(method, path, "invalid-token")

        assert missing.status == 401
        assert get_resp_header(missing, "www-authenticate") == [~s(Bearer scope="#{scope}")]

        assert invalid.status == 401

        assert get_resp_header(invalid, "www-authenticate") == [
                 ~s(Bearer error="invalid_token", scope="#{scope}")
               ]
      end
    end

    test "keeps model discovery and invocation grants separate" do
      models = resource_token!(:v1, ["llm::models"], [:v1])
      invoke = resource_token!(:v1, ["llm::invoke"], [:v1])

      assert public_authenticated_llm_request(:get, "/v1/models", models.value).status == 200

      denied_invoke =
        public_authenticated_llm_request(
          :post,
          "/v1/responses",
          models.value,
          %{"model" => "unknown/model", "input" => "hi"}
        )

      assert denied_invoke.status == 403
      assert Jason.decode!(denied_invoke.resp_body) == %{"error" => "insufficient_scope"}

      allowed_invoke =
        public_authenticated_llm_request(
          :post,
          "/v1/responses",
          invoke.value,
          %{"model" => "unknown/model", "input" => "hi"}
        )

      assert allowed_invoke.status == 404

      denied_models =
        public_authenticated_llm_request(:get, "/v1/models", invoke.value)

      assert denied_models.status == 403
      assert Jason.decode!(denied_models.resp_body) == %{"error" => "insufficient_scope"}
    end

    test "accepts both v1 and global wildcard grants" do
      for scopes <- [["llm::*"], ["*"]] do
        token = resource_token!(:v1, scopes, [:v1])

        assert public_authenticated_llm_request(:get, "/v1/models", token.value).status == 200

        conn =
          public_authenticated_llm_request(
            :post,
            "/v1/responses",
            token.value,
            %{"model" => "unknown/model", "input" => "hi"}
          )

        assert conn.status == 404
      end
    end

    test "PAT, legacy, and open modes retain full LLM access" do
      {_client, pat} = pat_fixture!(scopes: ["unrelated::scope"])

      assert public_authenticated_llm_request(:get, "/v1/models", pat).status == 200

      pat_invoke =
        public_authenticated_llm_request(
          :post,
          "/v1/responses",
          pat,
          %{"model" => "unknown/model", "input" => "hi"}
        )

      assert pat_invoke.status == 404

      Application.put_env(:backplane, :auth_token, "legacy-secret")

      assert public_authenticated_llm_request(:get, "/v1/models", "legacy-secret").status == 200

      legacy_invoke =
        public_authenticated_llm_request(
          :post,
          "/v1/responses",
          "legacy-secret",
          %{"model" => "unknown/model", "input" => "hi"}
        )

      assert legacy_invoke.status == 404

      Application.delete_env(:backplane, :auth_token)
      Backplane.Repo.delete_all(Backplane.Clients.Client)
      Backplane.Clients.refresh_cache()

      assert public_llm_request(:get, "/v1/models").status == 200

      open_invoke =
        public_llm_request(
          :post,
          "/v1/responses",
          %{"model" => "unknown/model", "input" => "hi"}
        )

      assert open_invoke.status == 404
    end

    test "rejects an MCP-audience token without opaque fallback" do
      token = resource_token!(:mcp, ["llm::models"], [:mcp, :v1])
      Application.put_env(:backplane, :auth_token, token.value)

      conn = public_authenticated_llm_request(:get, "/v1/models", token.value)

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_token"}

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Bearer error="invalid_token", scope="llm::models")
             ]
    end
  end

  describe "public GET /v1/models via ProxyPlug" do
    test "returns exposed models on the root model list" do
      create_provider_model(
        "anthropic-prod",
        :anthropic,
        "claude-sonnet",
        "router-anthropic-cred"
      )

      create_provider_model("openai-prod", :openai, "gpt-4o", "router-openai-cred")

      conn = public_llm_request(:get, "/v1/models")

      assert conn.status == 200
      body = json_body(conn)
      ids = Enum.map(body["data"], & &1["id"])

      assert body["object"] == "list"
      assert "anthropic-prod/claude-sonnet" in ids
      assert "openai-prod/gpt-4o" in ids
    end
  end

  describe "public POST /v1/messages via ProxyPlug" do
    test "routes public Anthropic messages requests to the Anthropic surface" do
      conn =
        public_llm_request(:post, "/v1/messages", %{
          "model" => "unknown-provider/unknown-model",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "max_tokens" => 100
        })

      assert conn.status == 404
      body = json_body(conn)
      assert body["type"] == "error"
      assert body["error"]["type"] == "not_found_error"
    end
  end

  describe "public POST /v1/responses via ProxyPlug" do
    test "routes public Responses API requests to the OpenAI surface" do
      conn =
        public_llm_request(:post, "/v1/responses", %{
          "model" => "unknown-provider/unknown-model",
          "input" => "hi"
        })

      assert conn.status == 404
      body = json_body(conn)
      assert is_map(body["error"])
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["code"] == "model_not_found"
    end
  end

  describe "public POST /v1/embeddings via ProxyPlug" do
    test "routes root embedding requests through the embedding provider resolver" do
      conn =
        public_llm_request(:post, "/v1/embeddings", %{
          "model" => "unknown-provider/text-embedding-3-small",
          "input" => ["hello"]
        })

      assert conn.halted
      assert conn.status == 404
      body = json_body(conn)
      assert is_map(body["error"])
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["code"] == "model_not_found"
    end

    test "does not resolve regular LLM provider models as embedding models" do
      create_provider_model(
        "llm-openai-embeddings",
        :openai,
        "text-embedding-3-small",
        "router-openai-cred"
      )

      conn =
        public_llm_request(:post, "/v1/embeddings", %{
          "model" => "llm-openai-embeddings/text-embedding-3-small",
          "input" => ["hello"]
        })

      assert conn.halted
      assert conn.status == 404
      body = json_body(conn)
      assert body["error"]["code"] == "model_not_found"
    end

    test "keeps embedding provider models out of the LLM model list" do
      create_embedding_model("router-embedding-cred")

      conn = llm_request(:get, "/v1/models")
      body = json_body(conn)
      ids = Enum.map(body["data"], & &1["id"])

      refute "router-embedding/text-embedding-3-small" in ids
    end
  end

  describe "router POST /v1/messages" do
    test "returns 404 for unknown model with anthropic error shape" do
      conn =
        llm_request(:post, "/v1/messages", %{
          "model" => "unknown-provider/unknown-model",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "max_tokens" => 100
        })

      assert conn.status == 404
      body = json_body(conn)
      assert body["type"] == "error"
      assert body["error"]["type"] == "not_found_error"
      assert is_binary(body["error"]["message"])
    end

    test "returns 404 for OpenAI-only model on anthropic endpoint" do
      create_provider_model("openai-prod", :openai, "gpt-4o", "router-openai-cred")

      conn =
        llm_request(:post, "/v1/messages", %{
          "model" => "openai-prod/gpt-4o",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "max_tokens" => 100
        })

      assert conn.status == 404
      body = json_body(conn)
      assert body["error"]["type"] == "not_found_error"
    end

    test "returns 400 when model field is missing" do
      conn =
        llm_request(:post, "/v1/messages", %{
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "max_tokens" => 100
        })

      assert conn.status == 400
      body = json_body(conn)
      assert body["type"] == "error"
      assert body["error"]["type"] == "invalid_request_error"
    end
  end

  describe "POST /v1/chat/completions" do
    test "returns 404 for unknown model with openai error shape" do
      conn =
        llm_request(:post, "/v1/chat/completions", %{
          "model" => "nonexistent-provider/gpt-99",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert conn.status == 404
      body = json_body(conn)
      assert is_map(body["error"])
      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["code"] == "model_not_found"
    end

    test "returns 404 for Anthropic-only model on OpenAI endpoint" do
      create_provider_model(
        "anthropic-prod",
        :anthropic,
        "claude-sonnet",
        "router-anthropic-cred"
      )

      conn =
        llm_request(:post, "/v1/chat/completions", %{
          "model" => "anthropic-prod/claude-sonnet",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert conn.status == 404
      body = json_body(conn)
      assert is_map(body["error"])
      assert body["error"]["code"] == "model_not_found"
    end

    test "omits disabled thinking for Moonshot K2.7 code models" do
      {:ok, store} = Agent.start_link(fn -> %{} end)
      {:ok, server_pid} = Bandit.start_link(plug: MoonshotUpstream, port: 0)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

      previous_store = Application.get_env(:backplane, :router_test_moonshot_store)
      Application.put_env(:backplane, :router_test_moonshot_store, store)

      on_exit(fn ->
        restore_env(:router_test_moonshot_store, previous_store)

        try do
          ThousandIsland.stop(server_pid)
        catch
          :exit, _ -> :ok
        end

        try do
          Agent.stop(store)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, provider} =
        Provider.create(%{
          name: "moonshot-cn-router",
          credential: "router-openai-cred",
          preset_key: "moonshot-cn"
        })

      {:ok, api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: "http://localhost:#{port}"
        })

      {:ok, model} =
        ProviderModel.create(%{
          provider_id: provider.id,
          model: "kimi-k2.7-code",
          source: :manual
        })

      {:ok, _surface} =
        ProviderModelSurface.create(%{
          provider_model_id: model.id,
          provider_api_id: api.id,
          enabled: true
        })

      conn =
        llm_request(:post, "/v1/chat/completions", %{
          "model" => "moonshot-cn-router/kimi-k2.7-code",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "thinking" => %{"type" => "disabled"}
        })

      assert conn.status == 200

      request = Agent.get(store, & &1)
      assert request.body["model"] == "kimi-k2.7-code"
      refute Map.has_key?(request.body, "thinking")
    end

    test "omits disabled thinking for Moonshot Anthropic K2.7 code models" do
      {:ok, store} = Agent.start_link(fn -> %{} end)
      {:ok, server_pid} = Bandit.start_link(plug: MoonshotUpstream, port: 0)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

      previous_store = Application.get_env(:backplane, :router_test_moonshot_store)
      Application.put_env(:backplane, :router_test_moonshot_store, store)

      on_exit(fn ->
        restore_env(:router_test_moonshot_store, previous_store)

        try do
          ThousandIsland.stop(server_pid)
        catch
          :exit, _ -> :ok
        end

        try do
          Agent.stop(store)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, provider} =
        Provider.create(%{
          name: "moonshot-cn-anthropic-router",
          credential: "router-openai-cred",
          preset_key: "moonshot-cn"
        })

      {:ok, api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :anthropic,
          base_url: "http://localhost:#{port}/anthropic"
        })

      {:ok, model} =
        ProviderModel.create(%{
          provider_id: provider.id,
          model: "kimi-k2.7-code",
          source: :manual
        })

      {:ok, _surface} =
        ProviderModelSurface.create(%{
          provider_model_id: model.id,
          provider_api_id: api.id,
          enabled: true
        })

      conn =
        llm_request(:post, "/v1/messages", %{
          "model" => "moonshot-cn-anthropic-router/kimi-k2.7-code",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "max_tokens" => 100,
          "thinking" => %{"type" => "disabled"}
        })

      assert conn.status == 200

      request = Agent.get(store, & &1)
      assert request.body["model"] == "kimi-k2.7-code"
      refute Map.has_key?(request.body, "thinking")
    end

    test "adapts OpenAI Codex OAuth chat completions to the Codex Responses backend" do
      {:ok, store} = Agent.start_link(fn -> nil end)
      {:ok, server_pid} = Bandit.start_link(plug: CodexUpstream, port: 0)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

      previous_backend = Application.get_env(:backplane, :openai_codex_backend_base_url)
      previous_store = Application.get_env(:backplane, :router_test_codex_store)

      Application.put_env(
        :backplane,
        :openai_codex_backend_base_url,
        "http://localhost:#{port}/backend-api/codex"
      )

      Application.put_env(:backplane, :router_test_codex_store, store)

      on_exit(fn ->
        restore_env(:openai_codex_backend_base_url, previous_backend)
        restore_env(:router_test_codex_store, previous_store)

        try do
          ThousandIsland.stop(server_pid)
        catch
          :exit, _ -> :ok
        end

        try do
          Agent.stop(store)
        catch
          :exit, _ -> :ok
        end
      end)

      credential = "router-codex-cred-#{System.unique_integer([:positive])}"
      expires_at = System.system_time(:millisecond) + 60 * 60 * 1000

      {:ok, _} =
        Credentials.store_device_token(
          credential,
          "openai_oauth",
          %{
            "type" => "codex_device_oauth",
            "auth_mode" => "chatgpt",
            "id_token" => "codex-id-token",
            "access_token" => "chatgpt-access-token",
            "refresh_token" => "refresh-token",
            "expires_at" => expires_at
          },
          %{"account_id" => "acc-123"}
        )

      {:ok, provider} =
        Provider.create(%{
          name: "openai-codex-router",
          credential: credential,
          preset_key: "openai-codex"
        })

      {:ok, api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: "https://api.openai.com/v1"
        })

      {:ok, model} =
        ProviderModel.create(%{
          provider_id: provider.id,
          model: "gpt-5.5",
          source: :manual
        })

      {:ok, _surface} =
        ProviderModelSurface.create(%{
          provider_model_id: model.id,
          provider_api_id: api.id,
          enabled: true
        })

      resource_token = resource_token!(:v1, ["llm::invoke"], [:v1])

      conn =
        public_authenticated_llm_request(
          :post,
          "/v1/chat/completions",
          resource_token.value,
          %{
            "model" => "openai-codex-router/gpt-5.5",
            "stream" => true,
            "max_tokens" => 100,
            "messages" => [%{"role" => "user", "content" => "hi"}]
          }
        )

      assert conn.status == 200
      assert conn.resp_body =~ "chat.completion.chunk"
      assert conn.resp_body =~ "Hello"
      assert conn.resp_body =~ " from Codex"
      assert conn.resp_body =~ "data: [DONE]"

      request = Agent.get(store, & &1)
      assert request.path == "/backend-api/codex/responses"
      assert {"authorization", "Bearer chatgpt-access-token"} in request.headers
      refute {"authorization", "Bearer #{resource_token.value}"} in request.headers
      assert {"chatgpt-account-id", "acc-123"} in request.headers
      assert {"originator", "codex_cli_rs"} in request.headers
      assert request.body["model"] == "gpt-5.5"
      assert request.body["stream"] == true
      refute Map.has_key?(request.body, "max_output_tokens")
      assert [%{"role" => "user", "content" => "hi"}] = request.body["input"]
    end
  end

  describe "rate limiting" do
    test "returns 429 with anthropic error shape when rate limited" do
      provider =
        create_provider_model(
          "anthropic-rl",
          :anthropic,
          "claude-sonnet",
          "router-anthropic-rl-cred",
          rpm_limit: 1
        )

      RateLimiter.check(provider.id, 1)

      conn =
        llm_request(:post, "/v1/messages", %{
          "model" => "anthropic-rl/claude-sonnet",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "max_tokens" => 10
        })

      assert conn.status == 429
      body = json_body(conn)
      assert body["type"] == "error"
      assert body["error"]["type"] == "rate_limit_error"
      assert Plug.Conn.get_resp_header(conn, "retry-after") != []
    end

    test "returns 429 with openai error shape when rate limited" do
      provider =
        create_provider_model(
          "openai-rl",
          :openai,
          "gpt-4o",
          "router-openai-rl-cred",
          rpm_limit: 1
        )

      RateLimiter.check(provider.id, 1)

      conn =
        llm_request(:post, "/v1/chat/completions", %{
          "model" => "openai-rl/gpt-4o",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert conn.status == 429
      body = json_body(conn)
      assert is_map(body["error"])
      assert body["error"]["type"] == "rate_limit_error"
      assert body["error"]["code"] == "rate_limit_exceeded"
      assert Plug.Conn.get_resp_header(conn, "retry-after") != []
    end
  end

  describe "router GET /v1/models" do
    test "returns aggregated model list in OpenAI format" do
      create_provider_model(
        "anthropic-prod",
        :anthropic,
        "claude-sonnet",
        "router-anthropic-cred"
      )

      conn = llm_request(:get, "/v1/models")

      assert conn.status == 200
      body = json_body(conn)
      assert body["object"] == "list"
      assert is_list(body["data"])
    end

    test "includes prefixed model ids" do
      create_provider_model(
        "anthropic-prod",
        :anthropic,
        "claude-sonnet",
        "router-anthropic-cred"
      )

      conn = llm_request(:get, "/v1/models")
      body = json_body(conn)

      ids = Enum.map(body["data"], & &1["id"])
      assert "anthropic-prod/claude-sonnet" in ids
    end

    test "includes custom alias entries for available targets" do
      create_provider_model("anthropic-prod", :anthropic, "claude-haiku", "router-anthropic-cred")
      {:ok, _alias} = ModelAlias.put("coding", "claude-haiku")

      conn = llm_request(:get, "/v1/models")
      body = json_body(conn)

      ids = Enum.map(body["data"], & &1["id"])
      assert "coding" in ids
    end

    test "excludes models from disabled providers" do
      provider =
        create_provider_model(
          "anthropic-prod",
          :anthropic,
          "claude-sonnet",
          "router-anthropic-cred"
        )

      {:ok, _} = Provider.update(provider, %{enabled: false})

      conn = llm_request(:get, "/v1/models")
      body = json_body(conn)

      ids = Enum.map(body["data"], & &1["id"])
      refute "anthropic-prod/claude-sonnet" in ids
    end

    test "excludes models from soft-deleted providers" do
      provider =
        create_provider_model(
          "anthropic-prod",
          :anthropic,
          "claude-sonnet",
          "router-anthropic-cred"
        )

      {:ok, _} = Provider.soft_delete(provider)

      conn = llm_request(:get, "/v1/models")
      body = json_body(conn)

      ids = Enum.map(body["data"], & &1["id"])
      refute "anthropic-prod/claude-sonnet" in ids
    end

    test "returns empty list when no providers exist" do
      conn = llm_request(:get, "/v1/models")
      body = json_body(conn)

      assert body["object"] == "list"
      assert body["data"] == []
    end

    test "returns 404 for unknown route" do
      conn = llm_request(:get, "/v1/unknown")
      assert conn.status == 404
    end
  end

  defp create_provider_model(name, api_surface, model_id, credential, opts \\ []) do
    attrs =
      %{
        name: name,
        credential: credential
      }
      |> Map.merge(Map.new(opts))

    {:ok, provider} = Provider.create(attrs)

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: api_surface,
        base_url: "https://api.example.com/v1"
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: model_id,
        source: :manual
      })

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    provider
  end

  defp create_embedding_model(credential) do
    {:ok, _result} =
      Embedding.create_provider_with_model(%{
        "name" => "router-embedding",
        "credential" => credential,
        "enabled" => "true",
        "base_url" => "https://api.example.com/v1",
        "default_headers" => "{}",
        "model" => "text-embedding-3-small",
        "display_name" => "Text Embedding 3 Small",
        "model_enabled" => "true",
        "metadata" => "{}"
      })
  end

  defp resource_token!(resource, scopes, resources) do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: resources, scopes: scopes)
    resource_access_token_fixture!(user, client, scopes, resource)
  end

  defp pat_fixture!(attrs) do
    token = Keyword.get(attrs, :token, "pat-#{System.unique_integer([:positive])}")

    {:ok, client} =
      Backplane.Clients.create_client(%{
        name: "PAT #{System.unique_integer([:positive])}",
        token: token,
        scopes: Keyword.fetch!(attrs, :scopes),
        active: true
      })

    {client, token}
  end
end
