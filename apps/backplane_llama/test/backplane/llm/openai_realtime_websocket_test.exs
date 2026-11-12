defmodule Backplane.LLM.OpenAI.RealtimeWebSocketTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.LLM.{Provider, ProviderApi, ProxyPlug, RateLimiter}
  alias Backplane.LLM.OpenAI.Service
  alias Backplane.LLM.OpenAI.RealtimeWebSocket.Policy
  alias Backplane.Settings.Credentials
  alias HTTP.WebSocket
  alias HTTP.WebSocket.Event

  defmodule Upstream do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, store) do
      state = Agent.get(store, & &1)

      send(
        state.owner,
        {:realtime_handshake, conn.request_path, conn.query_string, conn.req_headers}
      )

      Agent.update(store, &Map.update!(&1, :connections, fn count -> count + 1 end))

      if state.reject do
        conn |> put_resp_header("retry-after", "7") |> send_resp(429, "busy")
      else
        Relayixir.Proxy.WebSocket.Adapter.upgrade(
          conn,
          Backplane.LLM.OpenAI.RealtimeWebSocketTest.Peer,
          %{owner: state.owner},
          []
        )
      end
    end
  end

  defmodule Peer do
    @behaviour WebSock
    def init(state) do
      send(state.owner, {:realtime_open, self()})
      {:ok, state}
    end

    def handle_in({bytes, opcode: :text}, state) do
      send(state.owner, {:realtime_input, self(), bytes})

      {:push,
       {:text, ~s({ "type": "response.output_audio.delta", "delta": "AQID", "future": "雪" })},
       state}
    end

    def handle_info(:disconnect, state), do: {:stop, :normal, {1011, "peer finished"}, state}
    def handle_info({:event, bytes}, state), do: {:push, {:text, bytes}, state}
    def handle_info(_message, state), do: {:ok, state}

    def terminate(_reason, state) do
      send(state.owner, {:realtime_closed, self()})
      :ok
    end
  end

  setup do
    {:ok, client, token} =
      Backplane.Clients.issue_client(%{name: "realtime-invoke", scopes: ["llm::invoke"]})

    {:ok, _, models_token} =
      Backplane.Clients.issue_client(%{name: "realtime-models", scopes: ["llm::models"]})

    owner = self()
    store = start_supervised!({Agent, fn -> %{owner: owner, reject: false, connections: 0} end})

    upstream =
      start_supervised!({Gaoxy.HTTP, plug: {Upstream, store}, port: 0}, id: :realtime_upstream)

    %{local: {:ok, {_, upstream_port}}} = Gaoxy.info(upstream, :http)

    gateway =
      start_supervised!({Gaoxy.HTTP, plug: {ProxyPlug, []}, port: 0}, id: :realtime_gateway)

    %{local: {:ok, {_, port}}} = Gaoxy.info(gateway, :http)
    {:ok, _} = Credentials.store("realtime-provider-key", "sk-realtime-loopback", "llm")

    {:ok, provider} =
      Provider.create(%{name: "realtime-provider", credential: "realtime-provider-key"})

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://127.0.0.1:#{upstream_port}",
        default_headers: %{"x-provider-config" => "configured"}
      })

    {:ok, service} =
      Service.create(%{
        provider_id: provider.id,
        kind: :realtime,
        enabled: true,
        models: ["gpt-realtime-test"],
        default_model: "gpt-realtime-test"
      })

    RateLimiter.reset()

    on_exit(fn ->
      await_sessions_closed(System.monotonic_time(:millisecond) + 5_000)
      RateLimiter.reset()
      Backplane.Settings.Credentials.Vault.remove("realtime-provider-key")
      Credentials.invalidate_token("realtime-provider-key")
    end)

    %{
      port: port,
      token: token,
      models_token: models_token,
      client: client,
      provider: provider,
      api: api,
      service: service,
      store: store
    }
  end

  test "authenticates and checks invoke scope before opening an upstream connection", ctx do
    for {headers, status} <- [
          {[], 401},
          {[{"authorization", "Bearer invalid"}], 401},
          {[{"authorization", "Bearer " <> ctx.models_token}], 403}
        ] do
      socket = connect(ctx, headers)
      assert_receive {WebSocket, ^socket, %Event.Error{handshake: %{status: ^status}}}, 5_000
      cleanup(socket)
    end

    assert Agent.get(ctx.store, & &1.connections) == 0
  end

  test "routes native audio, cancel, and future events without the Responses-only codec", ctx do
    socket =
      connect(
        ctx,
        auth(ctx) ++
          [
            {"cookie", "private-cookie"},
            {"openai-safety-identifier", "safe-user"}
          ]
      )

    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {:realtime_handshake, "/v1/realtime", query, headers}, 2_000
    assert URI.decode_query(query) == %{"model" => "gpt-realtime-test"}
    assert {"authorization", "Bearer sk-realtime-loopback"} in headers
    assert {"x-provider-config", "configured"} in headers
    assert {"openai-safety-identifier", "safe-user"} in headers

    refute Enum.any?(headers, fn {name, value} ->
             name in ["cookie", "x-api-key"] or String.contains?(value, ctx.token)
           end)

    assert_receive {:realtime_open, peer}, 2_000

    for event <- [
          ~s({ "type": "input_audio_buffer.append", "audio": "AQID" }),
          ~s({"type":"input_audio_buffer.commit"}),
          ~s({"type":"response.create","response":{"modalities":["audio"]}}),
          ~s({"type":"response.cancel"}),
          ~s({"type":"future.event","opaque":{"keep":true}})
        ] do
      assert :ok = WebSocket.send(socket, event)
      assert_receive {:realtime_input, ^peer, ^event}, 2_000
      assert_receive {WebSocket, ^socket, %Event.Message{data: bytes}}, 2_000

      assert bytes ==
               ~s({ "type": "response.output_audio.delta", "delta": "AQID", "future": "雪" })
    end

    for event <- [
          ~s({ "type":"rate_limits.updated", "rate_limits":[{"name":"tokens","remaining":123}] }),
          ~s({"type":"response.done","response":{"usage":{"input_tokens":10,"output_tokens":20},"future":true}})
        ] do
      send(peer, {:event, event})
      assert_receive {WebSocket, ^socket, %Event.Message{data: ^event}}, 2_000
    end

    event = %{
      "type" => "session.update",
      "session" => %{"model" => "realtime-provider/gpt-realtime-test", "future" => true}
    }

    assert :ok = WebSocket.send(socket, Jason.encode!(event))
    assert_receive {:realtime_input, ^peer, forwarded}, 2_000
    assert Jason.decode!(forwarded) == put_in(event, ["session", "model"], "gpt-realtime-test")
    cleanup(socket)
    assert_receive {:realtime_closed, ^peer}, 5_000
    assert Agent.get(ctx.store, & &1.connections) == 1
  end

  test "rejects unconfigured models, duplicate query keys and unexpected query parameters", ctx do
    for query <- [
          "?model=realtime-provider/other",
          "?model=gpt-realtime-test&model=gpt-realtime-test",
          "?model=gpt-realtime-test&api_key=secret"
        ] do
      socket = connect(ctx, auth(ctx), query)
      assert_receive {WebSocket, ^socket, %Event.Error{}}, 5_000
      cleanup(socket)
    end

    assert Agent.get(ctx.store, & &1.connections) == 0
  end

  test "pins the upstream model and rejects model switching without submitting it", ctx do
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {:realtime_open, peer}, 2_000
    assert :ok = WebSocket.send(socket, ~s({"type":"session.update","session":{"model":"other"}}))
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
    refute_receive {:realtime_input, ^peer, _}, 100
    cleanup(socket)
    assert_receive {:realtime_closed, ^peer}, 5_000
    assert Agent.get(ctx.store, & &1.connections) == 1
  end

  test "omitted model uses only the configured default and still accepts its qualified identifier",
       ctx do
    socket = connect(ctx, auth(ctx), "")
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {:realtime_open, peer}, 2_000

    event =
      ~s({"type":"session.update","session":{"model":"realtime-provider/gpt-realtime-test"}})

    assert :ok = WebSocket.send(socket, event)
    assert_receive {:realtime_input, ^peer, forwarded}, 2_000
    assert Jason.decode!(forwarded)["session"]["model"] == "gpt-realtime-test"
    cleanup(socket)
    assert_receive {:realtime_closed, ^peer}, 5_000
  end

  test "disabled service and revoked principal stop further events", ctx do
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {:realtime_open, peer}, 2_000
    assert {:ok, _} = Service.update(ctx.service, %{enabled: false})
    assert :ok = WebSocket.send(socket, ~s({"type":"response.create"}))
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
    refute_receive {:realtime_input, ^peer, _}, 100
    cleanup(socket)
    assert_receive {:realtime_closed, ^peer}, 5_000

    assert {:ok, _} = Service.update(Service.get(ctx.service.id), %{enabled: true})
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {:realtime_open, peer}, 2_000
    assert {:ok, _} = Backplane.Clients.update_client(ctx.client, %{active: false})

    assert :ok =
             WebSocket.send(socket, ~s({"type":"session.update","session":{"type":"realtime"}}))

    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
    refute_receive {:realtime_input, ^peer, _}, 100
    cleanup(socket)
    assert_receive {:realtime_closed, ^peer}, 5_000
  end

  test "preserves upstream handshake errors and never reconnects after peer failure", ctx do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:backplane, :llm, :request],
        &__MODULE__.capture_access/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    Agent.update(ctx.store, &%{&1 | reject: true})
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Error{handshake: %{status: 429} = metadata}}, 5_000
    assert HTTP.Headers.get(metadata.headers, "retry-after") == "7"
    cleanup(socket)

    assert_receive {:realtime_access,
                    %{
                      status: 429,
                      client_ip: "127.0.0.1",
                      input_tokens: nil,
                      output_tokens: nil
                    }},
                   5_000

    Agent.update(ctx.store, &%{&1 | reject: false})
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {:realtime_open, peer}, 2_000
    send(peer, :disconnect)
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1011}}, 5_000
    cleanup(socket)
    assert Agent.get(ctx.store, & &1.connections) == 2
  end

  def capture_access(_event, _measurements, metadata, owner),
    do: send(owner, {:realtime_access, metadata})

  test "policy preserves opaque fields, rejects ambiguous JSON and pins all model fields", ctx do
    policy = policy(ctx)
    event = ~s({ "type": "rate_limits.future", "opaque": {"key": [true,null,3]} })
    assert {:ok, ^event, _} = Policy.prepare(policy, event)

    for invalid <- [
          ~s({"type":"session.update","session":{"model":"other"}}),
          ~s({"type":"response.create","response":{"model":"other"}}),
          ~s({"type":"session.update","session":{"model":"gpt-realtime-test","model":"other"}}),
          ~s({"type":"response.cancel","type":"response.create"}),
          ~s([]),
          ~s({"type":null})
        ] do
      assert {:error, _} = Policy.prepare(policy, invalid)
    end

    assert {:ok, _, _} =
             Policy.prepare(
               policy,
               ~s({"type":"session.update","session":{"model":"gpt-realtime-test","audio":{"input":{"transcription":{"model":"gpt-transcribe"}}}}})
             )
  end

  test "generation admission uses RPM while audio chunks avoid per-chunk database validation",
       ctx do
    assert {:ok, _} = Provider.update(ctx.provider, %{rpm_limit: 1})
    policy = policy(ctx)
    append = ~s({"type":"input_audio_buffer.append","audio":"AQID"})
    assert {:ok, ^append, cached} = Policy.prepare(policy, append)
    assert cached.revalidated_at == policy.revalidated_at
    assert {:ok, _, next} = Policy.prepare(policy, ~s({"type":"response.create"}))
    assert {:error, :rate_limited} = Policy.prepare(next, ~s({"type":"response.create"}))

    assert {:ok, _} = Service.update(ctx.service, %{enabled: false})
    expired = %{cached | revalidated_at: cached.revalidated_at - 1_001}
    assert {:error, :route_changed} = Policy.prepare(expired, append)
  end

  test "credential rotation cannot silently adopt a new upstream identity", ctx do
    policy = policy(ctx)
    assert {:ok, _} = Credentials.store("realtime-provider-key", "sk-rotated-test-only", "llm")
    assert {:error, :route_changed} = Policy.prepare(policy, ~s({"type":"response.create"}))
  end

  defp policy(ctx) do
    conn =
      Plug.Test.conn(:get, "/v1/realtime")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.token)
      |> Plug.Conn.assign(:resource_auth, %{
        kind: :client_token,
        client_id: ctx.client.id,
        scopes: ["llm::invoke"]
      })

    assert {:ok, route} = Service.resolve(:realtime, "realtime-provider/gpt-realtime-test")
    assert {:ok, policy, _} = Policy.pin(route, conn)
    policy
  end

  defp auth(ctx), do: [{"authorization", "Bearer " <> ctx.token}]

  defp await_sessions_closed(deadline) do
    if DynamicSupervisor.count_children(Backplane.LLM.OpenAI.RealtimeWebSocket.Supervisor).active >
         0 do
      assert System.monotonic_time(:millisecond) < deadline,
             "Realtime sessions did not finish cleanup"

      receive do
      after
        10 -> await_sessions_closed(deadline)
      end
    end
  end

  defp connect(ctx, headers \\ nil, query \\ "?model=realtime-provider/gpt-realtime-test") do
    WebSocket.new("ws://127.0.0.1:#{ctx.port}/v1/realtime" <> query, [],
      headers: headers || auth(ctx),
      http_version: :http1,
      mode: :browser,
      connect_timeout: 3_000,
      opening_timeout: 3_000,
      close_timeout: 500
    )
  end

  defp cleanup(socket) do
    WebSocket.close(socket)
    HTTP.ClientCompletion.await(WebSocket.completion(socket), 2_000)
  end
end
