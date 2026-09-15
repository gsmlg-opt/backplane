defmodule Backplane.LLM.StreamingIntegrationTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Backplane.Auth.Fixtures

  alias Backplane.Clients

  alias Backplane.LLM.{
    ModelResolver,
    AutoModel,
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
    |> put_req_header("api-key", "inbound-api-key-must-not-leak")
    |> put_req_header("x-goog-api-key", "inbound-google-key-must-not-leak")
    |> put_req_header("cookie", "session=inbound-cookie-must-not-leak")
    |> Backplane.LLM.ProxyPlug.call(Backplane.LLM.ProxyPlug.init([]))
  end

  defp raw_llm_request(method, path, body) do
    method
    |> conn(path, body)
    |> put_req_header("content-type", "application/json")
    |> Router.call(Router.init([]))
  end

  describe "non-streaming proxy" do
    test "native APIs preserve original request bytes when model routing needs no rewrite", %{
      auth_store: auth_store,
      port: port,
      provider: provider
    } do
      model = setup_openai_model(provider, port, "fast")

      anthropic_api =
        provider.id
        |> ProviderApi.list_for_provider()
        |> Enum.find(&(&1.api_surface == :anthropic))

      {:ok, _surface} =
        ProviderModelSurface.create(%{
          provider_model_id: model.id,
          provider_api_id: anthropic_api.id,
          enabled: true
        })

      assert {:ok, %{target_count: 2}} = AutoModel.configure_targets("fast", ["fast"])
      ModelResolver.clear_cache()

      requests = [
        {"/v1/responses",
         "{\n  \"model\": \"fast\", \"input\": \"雪\", \"future_extension\": {\"tool\": {\"arguments\": {\"x\": 1}}}\n}\n"},
        {"/v1/chat/completions",
         "{ \"model\" : \"fast\", \"messages\": [{\"role\":\"user\",\"content\":\"雪\"}], \"provider_extension\": true }"},
        {"/v1/messages",
         "{\n\t\"model\":\"fast\",\"messages\":[{\"role\":\"user\",\"content\":\"雪\"}],\"max_tokens\":8,\"future\":{\"nested\":true}}"}
      ]

      :erlang.trace_pattern(
        {Backplane.AiProtocol.Translation, :plan, 4},
        [{:_, [], [{:return_trace}]}],
        []
      )

      :erlang.trace(self(), true, [:call])

      on_exit(fn ->
        :erlang.trace(self(), false, [:call])
        :erlang.trace_pattern({Backplane.AiProtocol.Translation, :plan, 4}, false, [])
      end)

      for {path, body} <- requests do
        assert %{status: 200} = raw_llm_request(:post, path, body)
        assert Agent.get(auth_store, & &1.raw_body) == body
      end

      refute_receive {:trace, _, :call, {Backplane.AiProtocol.Translation, :plan, _}}
    end

    test "ordinary Responses uses the real public proxy path once", %{
      auth_store: auth_store,
      port: port,
      provider: provider
    } do
      setup_openai_model(provider, port, "responses-test")
      legacy = "bp-first-consumer-token"
      Application.put_env(:backplane, :auth_token, legacy)

      conn =
        public_llm_request(
          :post,
          "/v1/responses",
          %{"model" => "test-integration/responses-test", "input" => "hello"},
          legacy
        )

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["id"] == "resp_host_1"

      captured = Agent.get(auth_store, & &1)
      assert captured.submissions == 1
      assert captured.path == "/v1/responses"
      assert captured.body["model"] == "responses-test"

      assert Enum.filter(captured.headers, &(elem(&1, 0) == "authorization")) ==
               [{"authorization", "Bearer sk-test-integration"}]

      refute Enum.any?(captured.headers, fn {name, value} ->
               name == "x-api-key" or value == "Bearer #{legacy}"
             end)
    end

    test "malformed nested Responses JSON fails open with exact bytes and one submission", %{
      auth_store: auth_store,
      port: port,
      provider: provider
    } do
      setup_openai_model(provider, port, "responses-malformed")
      legacy = "bp-malformed-json-token"
      Application.put_env(:backplane, :auth_token, legacy)

      conn =
        public_llm_request(
          :post,
          "/v1/responses",
          %{
            "model" => "test-integration/responses-malformed",
            "input" => "malformed-nested"
          },
          legacy
        )

      expected =
        ~S({"id":"resp_malformed","status":"completed","output":[{"type":"function_call","id":"fc_bad","name":"lookup","arguments":null}],"usage":{"input_tokens":2,"output_tokens":1,"input_tokens_details":1}})

      assert conn.status == 200
      assert conn.resp_body == expected
      assert Agent.get(auth_store, & &1.submissions) == 1
    end

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

    test "model mapping changes only the model field semantically", %{auth_store: auth_store} do
      client_body = %{
        "model" => "test-integration/claude-test",
        "messages" => [
          %{
            "role" => "user",
            "content" => "雪",
            "tool_result" => %{"arguments" => %{"nested" => [1, true, nil]}}
          }
        ],
        "max_tokens" => 10,
        "provider_extension" => %{"future" => true}
      }

      conn =
        llm_request(:post, "/v1/messages", client_body)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["model"] == "claude-test"

      assert Agent.get(auth_store, & &1.body) ==
               Map.put(client_body, "model", "claude-test")
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

        refute Enum.any?(captured.headers, fn {name, _value} ->
                 name in ["api-key", "x-goog-api-key", "cookie", "proxy-authorization"]
               end)

        refute "Bearer #{inbound_bearer}" in authorization_values
      end
    end

    test "rejects an unavailable cross-protocol route before contacting upstream", %{
      auth_store: auth_store,
      port: port,
      provider: provider
    } do
      {:ok, api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: "http://localhost:#{port}",
          native_protocols: [:openai_responses]
        })

      {:ok, model} =
        ProviderModel.create(%{
          provider_id: provider.id,
          model: "responses-only",
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
        raw_llm_request(
          :post,
          "/v1/chat/completions",
          ~S({"model":"test-integration/responses-only","messages":[{"role":"user","content":"hi"}]})
        )

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "unsupported_protocol_translation"
      assert Agent.get(auth_store, &Map.get(&1, :submissions, 0)) == 0
    end

    test "ordinary routes honor environment proxy policy and NO_PROXY", %{
      port: port,
      provider: provider
    } do
      setup_openai_model(provider, port, "proxy-policy")

      proxy_vars = ~w(HTTP_PROXY http_proxy ALL_PROXY all_proxy NO_PROXY no_proxy)
      previous = Map.new(proxy_vars, &{&1, System.get_env(&1)})

      on_exit(fn ->
        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      Enum.each(~w(HTTP_PROXY http_proxy ALL_PROXY all_proxy), fn name ->
        System.put_env(name, "http://127.0.0.1:1")
      end)

      Enum.each(~w(NO_PROXY no_proxy), &System.delete_env/1)

      blocked =
        raw_llm_request(
          :post,
          "/v1/chat/completions",
          ~S({"model":"test-integration/proxy-policy","messages":[]})
        )

      assert blocked.status == 502

      System.put_env("NO_PROXY", "localhost")

      bypassed =
        raw_llm_request(
          :post,
          "/v1/chat/completions",
          ~S({"model":"test-integration/proxy-policy","messages":[]})
        )

      assert bypassed.status == 200
    end

    test "observer startup failure and observer exit do not fail native forwarding", %{
      port: port,
      provider: provider
    } do
      setup_openai_model(provider, port, "observer-failure")
      previous = Application.get_env(:backplane_llama, :usage_accumulator_factory)

      on_exit(fn ->
        restore_app_env(:backplane_llama, :usage_accumulator_factory, previous)
      end)

      Application.put_env(:backplane_llama, :usage_accumulator_factory, fn _protocol ->
        raise "observer startup failed"
      end)

      conn =
        raw_llm_request(
          :post,
          "/v1/responses",
          ~S({"model":"test-integration/observer-failure","input":"still forwarded","stream":true})
        )

      assert conn.status == 200

      Application.put_env(:backplane_llama, :usage_accumulator_factory, fn protocol ->
        pid = Backplane.LLM.UsageAccumulator.new(protocol)
        Process.exit(pid, :kill)
        pid
      end)

      conn =
        raw_llm_request(
          :post,
          "/v1/responses",
          ~S({"model":"test-integration/observer-failure","input":"still forwarded","stream":true})
        )

      assert conn.status == 200
    end

    test "observer timeout is bounded and does not stall native forwarding", %{
      port: port,
      provider: provider
    } do
      setup_openai_model(provider, port, "observer-timeout")
      previous = Application.get_env(:backplane_llama, :usage_accumulator_factory)
      observer_store = start_supervised!({Agent, fn -> [] end})

      on_exit(fn ->
        restore_app_env(:backplane_llama, :usage_accumulator_factory, previous)
      end)

      Application.put_env(:backplane_llama, :usage_accumulator_factory, fn protocol ->
        pid = Backplane.LLM.UsageAccumulator.new(protocol, snapshot_timeout: 5)
        Agent.update(observer_store, &[pid | &1])
        :erlang.suspend_process(pid)
        pid
      end)

      started = System.monotonic_time(:millisecond)

      conn =
        raw_llm_request(
          :post,
          "/v1/responses",
          ~S({"model":"test-integration/observer-timeout","input":"still forwarded","stream":true})
        )

      elapsed = System.monotonic_time(:millisecond) - started

      assert conn.status == 200
      assert elapsed < 250
      assert [pid] = Agent.get(observer_store, & &1)
      refute Process.alive?(pid)
    end
  end

  describe "streaming proxy" do
    test "streams ordinary Responses without a second submission", %{
      auth_store: auth_store,
      port: port,
      provider: provider
    } do
      setup_openai_model(provider, port, "responses-stream")

      conn =
        llm_request(:post, "/v1/responses", %{
          "model" => "test-integration/responses-stream",
          "input" => "hello",
          "stream" => true
        })

      assert conn.status == 200
      assert conn.resp_body =~ "response.completed"
      assert Agent.get(auth_store, & &1.submissions) == 1
    end

    test "malformed nested Responses SSE fails open with exact chunks and one submission", %{
      auth_store: auth_store,
      port: port,
      provider: provider
    } do
      setup_openai_model(provider, port, "responses-malformed-stream")
      legacy = "bp-malformed-sse-token"
      Application.put_env(:backplane, :auth_token, legacy)

      conn =
        public_llm_request(
          :post,
          "/v1/responses",
          %{
            "model" => "test-integration/responses-malformed-stream",
            "input" => "malformed-nested",
            "stream" => true
          },
          legacy
        )

      expected =
        [
          ~S(data: {"type":"response.created","response":1}) <> "\n\n",
          ~S(data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_bad","name":"lookup","arguments":{"q":"bad"},"status":"completed"}}) <>
            "\n\n",
          ~S(data: {"type":"response.completed","response":{"id":"resp_malformed_stream","status":"completed","usage":{"input_tokens":2,"output_tokens":1}}}) <>
            "\n\n"
        ]
        |> IO.iodata_to_binary()

      assert conn.status == 200
      assert conn.resp_body == expected
      assert Agent.get(auth_store, & &1.submissions) == 1
    end

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

  defp setup_openai_model(provider, port, model_name) do
    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://localhost:#{port}",
        native_protocols: [:openai_chat_completions, :openai_responses]
      })

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: model_name, source: :manual})

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    ModelResolver.clear_cache()
    model
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
