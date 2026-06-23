defmodule Backplane.LLM.RouterTest do
  use Backplane.DataCase, async: false

  import Plug.Conn
  import Plug.Test

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

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)

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

      conn =
        llm_request(:post, "/v1/chat/completions", %{
          "model" => "openai-codex-router/gpt-5.5",
          "stream" => true,
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert conn.status == 200
      assert conn.resp_body =~ "chat.completion.chunk"
      assert conn.resp_body =~ "Hello"
      assert conn.resp_body =~ " from Codex"
      assert conn.resp_body =~ "data: [DONE]"

      request = Agent.get(store, & &1)
      assert request.path == "/backend-api/codex/responses"
      assert {"authorization", "Bearer chatgpt-access-token"} in request.headers
      assert {"chatgpt-account-id", "acc-123"} in request.headers
      assert {"originator", "codex_cli_rs"} in request.headers
      assert request.body["model"] == "gpt-5.5"
      assert request.body["stream"] == true
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
end
