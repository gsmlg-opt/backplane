defmodule Backplane.Api.ResponsesWebSocketEndpointTest do
  use Backplane.Api.DataCase, async: false

  alias Backplane.LLM.{
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    RateLimiter
  }

  alias Backplane.Settings.Credentials
  alias HTTP.WebSocket
  alias HTTP.WebSocket.Event

  defmodule Upstream do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      state = Agent.get(Backplane.Api.ResponsesWebSocketEndpointTest.Store, & &1)

      send(
        state.owner,
        {:upstream_handshake, conn.request_path, conn.query_string, conn.req_headers}
      )

      Agent.update(
        Backplane.Api.ResponsesWebSocketEndpointTest.Store,
        &Map.update!(&1, :connections, fn n -> n + 1 end)
      )

      if state.reject do
        conn |> put_resp_header("retry-after", "7") |> send_resp(429, "busy")
      else
        conn
        |> put_resp_header("x-codex-websocket-max-unfragmented-message-bytes", "2048")
        |> put_resp_header("x-private-upstream", "not-forwarded")
        |> Relayixir.Proxy.WebSocket.Adapter.upgrade(
          Backplane.Api.ResponsesWebSocketEndpointTest.Peer,
          %{owner: state.owner},
          []
        )
      end
    end
  end

  defmodule Peer do
    @behaviour WebSock
    @impl true
    def init(state) do
      send(state.owner, {:upstream_open, self()})
      {:ok, state}
    end

    @impl true
    def handle_in({bytes, opcode: :text}, state) do
      send(state.owner, {:upstream_create, self(), Jason.decode!(bytes)})
      # Intentionally preserve whitespace and unknown fields across the gateway.
      event = ~s({ "type": "response.future", "opaque": {"keep": "雪"} })
      {:push, {:text, event}, state}
    end

    @impl true
    def handle_info(:disconnect, state), do: {:stop, :normal, {1011, "peer finished"}, state}
    def handle_info(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, state) do
      send(state.owner, {:upstream_closed, self()})
      :ok
    end
  end

  setup do
    {:ok, client, token} =
      Backplane.Clients.issue_client(%{name: "ws-invoke", scopes: ["llm::invoke"]})

    {:ok, _client, models_token} =
      Backplane.Clients.issue_client(%{name: "ws-models", scopes: ["llm::models"]})

    owner = self()

    {:ok, store} =
      Agent.start_link(fn -> %{owner: owner, reject: false, connections: 0} end,
        name: __MODULE__.Store
      )

    {:ok, upstream} = Gaoxy.HTTP.start_link(plug: {Upstream, []}, port: 0)
    %{local: {:ok, {_, upstream_port}}} = Gaoxy.info(upstream, :http)
    {:ok, endpoint} = Gaoxy.HTTP.start_link(plug: {Backplane.Api.Endpoint, []}, port: 0)
    %{local: {:ok, {_, port}}} = Gaoxy.info(endpoint, :http)
    {:ok, _} = Credentials.store("ws-provider-key", "sk-loopback-only", "llm")
    {:ok, provider} = Provider.create(%{name: "ws-provider", credential: "ws-provider-key"})

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://127.0.0.1:#{upstream_port}",
        native_protocols: [:openai_responses],
        responses_websocket: true,
        default_headers: %{"x-provider-config" => "configured"}
      })

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: "model", source: :manual})

    {:ok, _} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    ModelResolver.clear_cache()
    RateLimiter.reset()

    on_exit(fn ->
      stop_server(endpoint)
      stop_server(upstream)
      if Process.alive?(store), do: Agent.stop(store)
      ModelResolver.clear_cache()
      RateLimiter.reset()
      Backplane.Settings.Credentials.Vault.remove("ws-provider-key")
      Credentials.invalidate_token("ws-provider-key")
    end)

    %{
      port: port,
      client: client,
      token: token,
      models_token: models_token,
      api: api,
      provider: provider
    }
  end

  test "authenticates before opening any upstream socket", ctx do
    for {headers, status} <- [
          {[], 401},
          {[{"authorization", "Bearer invalid"}], 401},
          {[{"authorization", "Bearer " <> ctx.models_token}], 403}
        ] do
      socket = connect(ctx, headers)
      assert_receive {WebSocket, ^socket, %Event.Error{handshake: %{status: ^status}}}, 5_000
      cleanup(socket)
    end

    assert connections() == 0
  end

  test "disabled upstream declaration and invalid routing requests do not upgrade", ctx do
    {:ok, _} = ProviderApi.update(ctx.api, %{responses_websocket: false})
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Error{handshake: %{status: 501}}}, 5_000
    cleanup(socket)

    {:ok, _} = ProviderApi.update(ProviderApi.get(ctx.api.id), %{responses_websocket: true})

    for query <- ["", "?model=ws-provider/model&unexpected=1"] do
      socket = connect(ctx, auth(ctx), query)
      assert_receive {WebSocket, ^socket, %Event.Error{handshake: %{status: 400}}}, 5_000
      cleanup(socket)
    end

    assert connections() == 0
  end

  test "routes native turns and preserves session headers, provider defaults and raw events",
       ctx do
    socket =
      connect(
        ctx,
        auth(ctx) ++
          [
            {"session_id", "loopback-session"},
            {"openai-beta", "responses_websockets=2025-02-01"},
            {"cookie", "must-not-forward"},
            {"chatgpt-account-id", "must-not-forward"}
          ]
      )

    assert_receive {WebSocket, ^socket, %Event.Open{handshake: handshake}}, 5_000

    assert HTTP.Headers.get(handshake.headers, "x-codex-websocket-max-unfragmented-message-bytes") ==
             "2048"

    assert_receive {:upstream_handshake, "/v1/responses", query, headers}, 2_000
    assert query == ""
    assert {"authorization", "Bearer sk-loopback-only"} in headers
    assert {"session_id", "loopback-session"} in headers
    assert {"openai-beta", "responses_websockets=2025-02-01"} in headers
    assert {"x-provider-config", "configured"} in headers
    refute Enum.any?(headers, fn {name, _} -> name in ["cookie", "chatgpt-account-id"] end)
    refute Enum.any?(headers, fn {_, value} -> String.contains?(value, ctx.token) end)
    assert_receive {:upstream_open, peer}, 2_000

    for model <- ["ws-provider/model", "model"] do
      params = %{
        "type" => "response.create",
        "model" => model,
        "input" => "hello",
        "future" => [1, 2]
      }

      :ok = WebSocket.send(socket, Jason.encode!(params))
      assert_receive {:upstream_create, ^peer, forwarded}, 2_000
      assert forwarded == Map.put(params, "model", "model")
      assert_receive {WebSocket, ^socket, %Event.Message{data: event}}, 2_000
      assert event == ~s({ "type": "response.future", "opaque": {"keep": "雪"} })
    end

    cleanup(socket)
    assert_receive {:upstream_closed, ^peer}, 5_000
    assert connections() == 1
  end

  test "propagates a safe upstream handshake rejection before downstream upgrade", ctx do
    Agent.update(__MODULE__.Store, &%{&1 | reject: true})
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Error{handshake: %{status: 429} = metadata}}, 5_000
    assert HTTP.Headers.get(metadata.headers, "retry-after") == "7"
    refute_receive {WebSocket, ^socket, %Event.Open{}}, 100
    cleanup(socket)
    assert connections() == 1
  end

  test "Codex OAuth injects account credentials and honors API originator defaults", ctx do
    {:ok, _} =
      Credentials.store_device_token(
        "ws-provider-key",
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "auth_mode" => "chatgpt",
          "id_token" => "loopback-id-token",
          "access_token" => "loopback-oauth-access",
          "refresh_token" => "loopback-refresh-token",
          "expires_at" => System.system_time(:millisecond) + 3_600_000
        },
        %{"account_id" => "provider-account", "x-openai-fedramp" => true}
      )

    {:ok, _} =
      Provider.update(ctx.provider, %{
        preset_key: "openai-codex",
        default_headers: %{
          "Originator" => "provider-originator",
          "authorization" => "must-not-win"
        }
      })

    {:ok, _} =
      ProviderApi.update(ctx.api, %{
        base_url: ctx.api.base_url <> "/backend-api/codex",
        default_headers: %{
          "originator" => "api-originator",
          "chatgpt-account-id" => "must-not-win"
        }
      })

    ModelResolver.clear_cache()

    socket =
      connect(
        ctx,
        auth(ctx) ++
          [
            {"originator", "caller-originator"},
            {"chatgpt-account-id", "caller-account"},
            {"x-openai-fedramp", "false"}
          ]
      )

    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {:upstream_handshake, "/backend-api/codex/responses", _query, headers}, 2_000
    assert {"authorization", "Bearer loopback-oauth-access"} in headers
    assert {"chatgpt-account-id", "provider-account"} in headers
    assert {"x-openai-fedramp", "true"} in headers
    assert {"originator", "api-originator"} in headers
    assert Enum.count(headers, fn {name, _} -> name == "authorization" end) == 1
    assert Enum.count(headers, fn {name, _} -> name == "originator" end) == 1
    cleanup(socket)
  end

  test "stale OAuth token cache is rejected before opening an upstream", ctx do
    tokens = %{
      "type" => "codex_device_oauth",
      "auth_mode" => "chatgpt",
      "access_token" => "old-loopback-oauth",
      "refresh_token" => "loopback-refresh",
      "expires_at" => System.system_time(:millisecond) + 3_600_000
    }

    {:ok, _} =
      Credentials.store_device_token("ws-provider-key", "openai_oauth", tokens, %{
        "account_id" => "cache-test-account"
      })

    assert {:ok, "old-loopback-oauth", _} = Credentials.fetch_with_meta("ws-provider-key")
    assert {:ok, "old-loopback-oauth"} = Backplane.Settings.TokenCache.get("ws-provider-key")

    # Direct credential upsert updates the encrypted DB/Vault snapshot but does not
    # invalidate the separately cached OAuth access token.
    {:ok, rotated} =
      Credentials.store(
        "ws-provider-key",
        Jason.encode!(Map.put(tokens, "access_token", "new-loopback-oauth")),
        "llm",
        %{"auth_type" => "openai_oauth", "account_id" => "cache-test-account"}
      )

    assert Backplane.Settings.Credentials.Vault.get("ws-provider-key") == rotated
    assert {:ok, "old-loopback-oauth"} = Backplane.Settings.TokenCache.get("ws-provider-key")

    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Error{handshake: %{status: 503}}}, 5_000
    cleanup(socket)
    assert connections() == 0
  end

  test "credential rotation during a session prevents another submission", ctx do
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {:upstream_open, peer}, 2_000
    create = Jason.encode!(%{"type" => "response.create", "model" => "model"})
    :ok = WebSocket.send(socket, create)
    assert_receive {:upstream_create, ^peer, _}, 2_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000

    {:ok, _} = Credentials.store("ws-provider-key", "sk-rotated-loopback", "llm")
    :ok = WebSocket.send(socket, create)
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
    refute_receive {:upstream_create, ^peer, _}, 100
    cleanup(socket)
    assert connections() == 1
  end

  test "revoked client token prevents another creation on an existing connection", ctx do
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {:upstream_open, peer}, 2_000
    create = Jason.encode!(%{"type" => "response.create", "model" => "model"})
    :ok = WebSocket.send(socket, create)
    assert_receive {:upstream_create, ^peer, _}, 2_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000

    {:ok, _} = Backplane.Clients.revoke_client_token(ctx.client)
    :ok = WebSocket.send(socket, create)
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
    refute_receive {:upstream_create, ^peer, _}, 100
    cleanup(socket)
  end

  test "a later turn cannot switch model or invent interrupt semantics", ctx do
    for attrs <- [
          %{"type" => "response.create", "model" => "other/model"},
          %{"type" => "response.cancel", "model" => "model"},
          %{"type" => "response.create", "model" => "model", "background" => true}
        ] do
      socket = connect(ctx)
      assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
      assert_receive {:upstream_open, peer}, 2_000
      :ok = WebSocket.send(socket, Jason.encode!(attrs))
      assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
      refute_receive {:upstream_create, ^peer, _}, 100
      cleanup(socket)
    end
  end

  test "peer message size and text-only protocol are enforced before submission", ctx do
    for {message, close_code} <- [
          {Jason.encode!(%{
             "type" => "response.create",
             "model" => "model",
             "input" => String.duplicate("a", 2048)
           }), 1008},
          {WebSocket.array_buffer("not a JSON text frame"), 1003}
        ] do
      socket = connect(ctx)
      assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
      assert_receive {:upstream_open, peer}, 2_000
      :ok = WebSocket.send(socket, message)
      assert_receive {WebSocket, ^socket, %Event.Close{code: ^close_code}}, 5_000
      refute_receive {:upstream_create, ^peer, _}, 100
      cleanup(socket)
    end
  end

  test "rate limit applies to every create within one connection", ctx do
    {:ok, _} = Provider.update(ctx.provider, %{rpm_limit: 1})
    ModelResolver.clear_cache()
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {:upstream_open, peer}, 2_000
    create = Jason.encode!(%{"type" => "response.create", "model" => "model"})
    :ok = WebSocket.send(socket, create)
    assert_receive {:upstream_create, ^peer, _}, 2_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000
    :ok = WebSocket.send(socket, create)
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
    refute_receive {:upstream_create, ^peer, _}, 100
    cleanup(socket)
  end

  test "upstream disconnect after submission does not reconnect or replay", ctx do
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {:upstream_open, peer}, 2_000

    :ok =
      WebSocket.send(socket, Jason.encode!(%{"type" => "response.create", "model" => "model"}))

    assert_receive {:upstream_create, ^peer, _}, 2_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000
    send(peer, :disconnect)
    assert_receive {WebSocket, ^socket, %Event.Close{}}, 5_000
    refute_receive {:upstream_open, _}, 250
    assert connections() == 1
    cleanup(socket)
  end

  test "disabling the API during a session prevents another submission", ctx do
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {:upstream_open, peer}, 2_000
    {:ok, _} = ProviderApi.update(ctx.api, %{responses_websocket: false})

    :ok =
      WebSocket.send(socket, Jason.encode!(%{"type" => "response.create", "model" => "model"}))

    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
    refute_receive {:upstream_create, ^peer, _}, 100
    cleanup(socket)
  end

  defp auth(ctx), do: [{"authorization", "Bearer " <> ctx.token}]
  defp connect(ctx), do: connect(ctx, auth(ctx))

  defp connect(ctx, headers, query \\ "?model=ws-provider/model") do
    WebSocket.new("ws://127.0.0.1:#{ctx.port}/v1/responses#{query}", [],
      headers: headers,
      http_version: :http1,
      connect_timeout: 2_000,
      opening_timeout: 5_000,
      close_timeout: 1_000
    )
  end

  defp connections, do: Agent.get(__MODULE__.Store, & &1.connections)

  defp cleanup(socket) do
    WebSocket.close(socket)
    assert :ok = HTTP.ClientCompletion.await(WebSocket.completion(socket), 5_000)
  end

  defp stop_server(pid) do
    if Process.alive?(pid), do: Gaoxy.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
