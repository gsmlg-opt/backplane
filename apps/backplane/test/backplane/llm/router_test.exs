defmodule Backplane.LLM.RouterTest do
  use Backplane.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Backplane.LLM.{ModelAlias, ModelResolver, Provider, RateLimiter, Router}
  alias Backplane.Settings.Credentials

  @anthropic_attrs %{
    name: "anthropic-prod",
    api_type: :anthropic,
    api_url: "https://api.anthropic.com",
    credential: "router-anthropic-cred",
    models: ["claude-sonnet-4-20250514", "claude-haiku-4-5-20251001"]
  }

  @openai_attrs %{
    name: "openai-prod",
    api_type: :openai,
    api_url: "https://api.openai.com",
    credential: "router-openai-cred",
    models: ["gpt-4o", "gpt-4o-mini"]
  }

  setup do
    Credentials.store("router-anthropic-cred", "sk-ant-test-key-abcd", "llm")
    Credentials.store("router-openai-cred", "sk-openai-test-key", "llm")
    Credentials.store("router-anthropic-rl-cred", "sk-ant-test-rl-abcd", "llm")
    Credentials.store("router-openai-rl-cred", "sk-openai-test-rl-abcd", "llm")
    # ModelResolver is started by the application supervision tree.
    # Clear the cache before each test to ensure isolation.
    ModelResolver.clear_cache()
    RateLimiter.reset()
    :ok
  end

  defp llm_request(method, path, body \\ nil) do
    conn_body = if body, do: Jason.encode!(body), else: ""
    c = conn(method, path, conn_body)
    c = put_req_header(c, "content-type", "application/json")
    Router.call(c, Router.init([]))
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # ── POST /v1/messages ────────────────────────────────────────────────────────

  describe "POST /v1/messages" do
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

    test "returns 400 for api_type mismatch (openai model on anthropic endpoint)" do
      {:ok, _provider} = Provider.create(@openai_attrs)

      conn =
        llm_request(:post, "/v1/messages", %{
          "model" => "openai-prod/gpt-4o",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "max_tokens" => 100
        })

      assert conn.status == 400
      body = json_body(conn)
      assert body["type"] == "error"
      assert body["error"]["type"] == "invalid_request_error"
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

  # ── POST /v1/chat/completions ─────────────────────────────────────────────────

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

    test "returns 400 for api_type mismatch (anthropic model on openai endpoint)" do
      {:ok, _provider} = Provider.create(@anthropic_attrs)

      conn =
        llm_request(:post, "/v1/chat/completions", %{
          "model" => "anthropic-prod/claude-sonnet-4-20250514",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert conn.status == 400
      body = json_body(conn)
      assert is_map(body["error"])
      assert body["error"]["type"] == "invalid_request_error"
    end
  end

  # ── Rate limiting ─────────────────────────────────────────────────────────────

  describe "rate limiting" do
    test "returns 429 with anthropic error shape when rate limited" do
      {:ok, provider} =
        Provider.create(%{
          name: "anthropic-rl",
          api_type: :anthropic,
          api_url: "https://api.anthropic.com",
          credential: "router-anthropic-rl-cred",
          models: ["claude-sonnet-4-20250514"],
          rpm_limit: 1
        })

      # Exhaust rate limit
      RateLimiter.check(provider.id, 1)

      conn =
        llm_request(:post, "/v1/messages", %{
          "model" => "anthropic-rl/claude-sonnet-4-20250514",
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
      {:ok, provider} =
        Provider.create(%{
          name: "openai-rl",
          api_type: :openai,
          api_url: "https://api.openai.com",
          credential: "router-openai-rl-cred",
          models: ["gpt-4o"],
          rpm_limit: 1
        })

      # Exhaust rate limit
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

  # ── GET /v1/models ────────────────────────────────────────────────────────────

  describe "GET /v1/models" do
    test "returns aggregated model list in OpenAI format" do
      {:ok, _} = Provider.create(@anthropic_attrs)

      conn = llm_request(:get, "/v1/models")

      assert conn.status == 200
      body = json_body(conn)
      assert body["object"] == "list"
      assert is_list(body["data"])
    end

    test "includes prefixed model ids" do
      {:ok, _} = Provider.create(@anthropic_attrs)

      conn = llm_request(:get, "/v1/models")
      body = json_body(conn)

      ids = Enum.map(body["data"], & &1["id"])
      assert "anthropic-prod/claude-sonnet-4-20250514" in ids
      assert "anthropic-prod/claude-haiku-4-5-20251001" in ids
    end

    test "includes alias entries for aliased models" do
      {:ok, provider} = Provider.create(@anthropic_attrs)

      {:ok, _alias} =
        ModelAlias.create(%{
          alias: "fast",
          model: "claude-haiku-4-5-20251001",
          provider_id: provider.id
        })

      conn = llm_request(:get, "/v1/models")
      body = json_body(conn)

      ids = Enum.map(body["data"], & &1["id"])
      assert "fast" in ids
    end

    test "excludes models from disabled providers" do
      {:ok, provider} = Provider.create(@anthropic_attrs)
      {:ok, _} = Provider.update(provider, %{enabled: false})

      conn = llm_request(:get, "/v1/models")
      body = json_body(conn)

      ids = Enum.map(body["data"], & &1["id"])
      refute "anthropic-prod/claude-sonnet-4-20250514" in ids
    end

    test "excludes models from soft-deleted providers" do
      {:ok, provider} = Provider.create(@anthropic_attrs)
      {:ok, _} = Provider.soft_delete(provider)

      conn = llm_request(:get, "/v1/models")
      body = json_body(conn)

      ids = Enum.map(body["data"], & &1["id"])
      refute "anthropic-prod/claude-sonnet-4-20250514" in ids
    end

    test "returns empty list when no providers exist" do
      conn = llm_request(:get, "/v1/models")
      body = json_body(conn)

      assert body["object"] == "list"
      assert body["data"] == []
    end

    test "returns 200 for unknown route" do
      conn = llm_request(:get, "/v1/unknown")
      # catch-all match returns 404
      assert conn.status == 404
    end
  end
end
