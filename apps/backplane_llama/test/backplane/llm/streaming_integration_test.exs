defmodule Backplane.LLM.StreamingIntegrationTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Backplane.Auth.Fixtures

  alias Backplane.Clients

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
    auth_token = Application.get_env(:backplane, :auth_token)
    auth_tokens = Application.get_env(:backplane, :auth_tokens)

    Application.delete_env(:backplane, :auth_token)
    Application.delete_env(:backplane, :auth_tokens)

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

      restore_env(:auth_token, auth_token)
      restore_env(:auth_tokens, auth_tokens)
    end)

    %{auth_store: auth_store, port: port, provider: provider}
  end

  defp llm_request(method, path, body) do
    conn_body = if body, do: Jason.encode!(body), else: ""

    conn(method, path, conn_body)
    |> put_req_header("content-type", "application/json")
    |> Router.call(Router.init([]))
  end

  defp public_llm_request(method, path, body, bearer) do
    method
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("x-api-key", "inbound-key-must-not-leak")
    |> Backplane.LLM.ProxyPlug.call(Backplane.LLM.ProxyPlug.init([]))
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

    test "replaces OAuth, PAT, and legacy credentials before forwarding to an OpenAI provider",
         %{auth_store: auth_store, port: port, provider: provider} do
      {:ok, api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: "http://localhost:#{port}/v1"
        })

      {:ok, model} =
        ProviderModel.create(%{
          provider_id: provider.id,
          model: "gpt-credential-isolation",
          source: :manual
        })

      {:ok, _surface} =
        ProviderModelSurface.create(%{
          provider_model_id: model.id,
          provider_api_id: api.id,
          enabled: true
        })

      ModelResolver.clear_cache()

      user = auth_user_fixture!()

      oauth_client =
        oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])

      oauth_token =
        resource_access_token_fixture!(user, oauth_client, ["llm::invoke"], :v1)

      pat = "pat-provider-isolation"

      assert {:ok, pat_client} =
               Clients.create_client(%{
                 name: "Provider isolation PAT",
                 token: pat,
                 scopes: ["unrelated::scope"],
                 active: true
               })

      legacy = "legacy-provider-isolation"
      Application.put_env(:backplane, :auth_token, legacy)

      for inbound_bearer <- [oauth_token.value, pat, legacy] do
        request = fn ->
          public_llm_request(
            :post,
            "/v1/chat/completions",
            %{
              "model" => "test-integration/gpt-credential-isolation",
              "messages" => [%{"role" => "user", "content" => "hi"}]
            },
            inbound_bearer
          )
        end

        conn =
          if inbound_bearer == pat do
            pat_request(pat_client, request)
          else
            request.()
          end

        assert conn.status == 200
        captured = Agent.get(auth_store, & &1)

        authorization_values =
          for {"authorization", value} <- captured.headers, do: value

        x_api_key_values =
          for {"x-api-key", value} <- captured.headers, do: value

        assert authorization_values == ["Bearer sk-test-integration"]
        assert x_api_key_values == []
        refute "Bearer #{inbound_bearer}" in authorization_values
      end
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

  defp pat_request(client, request) when is_function(request, 0) do
    previous_last_seen = Clients.get_client(client.id).last_seen_at
    result = request.()
    await_pat_touch!(client.id, previous_last_seen)
    result
  end

  defp await_pat_touch!(client_id, previous_last_seen) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_await_pat_touch!(client_id, previous_last_seen, deadline)
  end

  defp do_await_pat_touch!(client_id, previous_last_seen, deadline) do
    current_last_seen = Clients.get_client(client_id).last_seen_at

    cond do
      current_last_seen != previous_last_seen ->
        current_last_seen

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(5)
        do_await_pat_touch!(client_id, previous_last_seen, deadline)

      true ->
        flunk("PAT last_seen_at did not change within 1000ms for client #{client_id}")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)
end
