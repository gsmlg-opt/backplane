defmodule Backplane.LLM.StreamingIntegrationTest do
  use Backplane.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Backplane.LLM.{
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    RateLimiter,
    Router
  }

  alias Backplane.Settings.Credentials

  setup do
    # Start test LLM upstream
    {:ok, auth_store} =
      Agent.start_link(fn -> %{} end, name: Backplane.Test.TestLLMUpstream.AuthStore)

    {:ok, server_pid} = Bandit.start_link(plug: Backplane.Test.TestLLMUpstream, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

    # Create credential and provider
    {:ok, _} = Credentials.store("test-llm-key", "sk-test-integration", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "test-integration",
        credential: "test-llm-key"
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :anthropic,
        base_url: "http://localhost:#{port}"
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: "claude-test",
        source: :manual
      })

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    ModelResolver.clear_cache()
    RateLimiter.reset()

    on_exit(fn ->
      Provider.soft_delete(provider)
      Credentials.delete("test-llm-key")

      try do
        ThousandIsland.stop(server_pid)
      catch
        :exit, _ -> :ok
      end

      try do
        Agent.stop(auth_store)
      catch
        :exit, _ -> :ok
      end
    end)

    %{port: port, provider: provider}
  end

  defp llm_request(method, path, body) do
    conn_body = if body, do: Jason.encode!(body), else: ""

    conn(method, path, conn_body)
    |> put_req_header("content-type", "application/json")
    |> Router.call(Router.init([]))
  end

  describe "non-streaming proxy" do
    test "proxies anthropic request end-to-end" do
      conn =
        llm_request(:post, "/v1/messages", %{
          "model" => "test-integration/claude-test",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "max_tokens" => 10
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["type"] == "message"
      assert body["usage"]["input_tokens"] == 10
    end

    test "rewrites model field in forwarded body" do
      conn =
        llm_request(:post, "/v1/messages", %{
          "model" => "test-integration/claude-test",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "max_tokens" => 10
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      # Model should be "claude-test" (stripped prefix), echoed back by test server
      assert body["model"] == "claude-test"
    end

    test "proxies openai request without duplicating provider base URL version path", %{
      port: port,
      provider: provider
    } do
      {:ok, api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: "http://localhost:#{port}/v1"
        })

      {:ok, model} =
        ProviderModel.create(%{
          provider_id: provider.id,
          model: "gpt-test",
          source: :manual
        })

      {:ok, _surface} =
        ProviderModelSurface.create(%{
          provider_model_id: model.id,
          provider_api_id: api.id,
          enabled: true
        })

      ModelResolver.clear_cache()

      conn =
        llm_request(:post, "/v1/chat/completions", %{
          "model" => "test-integration/gpt-test",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert get_in(body, ["choices", Access.at(0), "message", "content"]) ==
               "Hello from test upstream"

      assert body["model"] == "gpt-test"

      repeated_v1_conn =
        llm_request(:post, "/v1/v1/chat/completions", %{
          "model" => "test-integration/gpt-test",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert repeated_v1_conn.status == 200
    end
  end

  describe "streaming proxy" do
    test "streams anthropic SSE events to client" do
      conn =
        llm_request(:post, "/v1/messages", %{
          "model" => "test-integration/claude-test",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "max_tokens" => 10,
          "stream" => true
        })

      assert conn.status == 200
      # For streaming, the response will be chunked
      # Check that content-type is text/event-stream
      content_type =
        Enum.find_value(conn.resp_headers, fn
          {"content-type", v} -> v
          _ -> nil
        end)

      assert content_type =~ "text/event-stream"
    end
  end

  describe "error handling" do
    test "returns 404 for unknown model" do
      conn =
        llm_request(:post, "/v1/messages", %{
          "model" => "nonexistent/model",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "max_tokens" => 10
        })

      assert conn.status == 404
    end

    test "returns 400 for missing model field" do
      conn =
        llm_request(:post, "/v1/messages", %{
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "max_tokens" => 10
        })

      assert conn.status == 400
    end
  end
end
