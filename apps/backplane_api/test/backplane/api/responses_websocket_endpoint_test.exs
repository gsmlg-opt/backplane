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
  alias Backplane.LLM.ResponsesWebSocket.Limits
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
        |> put_resp_header(
          "x-codex-websocket-max-message-bytes",
          Map.get(state, :max_message_bytes, "134217728")
        )
        |> put_resp_header("x-private-upstream", "not-forwarded")
        |> Relayixir.Proxy.WebSocket.Adapter.upgrade(
          Backplane.Api.ResponsesWebSocketEndpointTest.Peer,
          %{owner: state.owner, capture_create_size: Map.get(state, :capture_create_size, false)},
          max_frame_size: Map.get(state, :upstream_max_frame_size, 134_217_728),
          max_message_size: Map.get(state, :upstream_max_frame_size, 134_217_728)
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
      case Formata.JSON.decode!(bytes) do
        %{"type" => "response.interrupt"} = interrupt ->
          send(state.owner, {:upstream_interrupt, self(), interrupt})
          {:ok, state}

        %{"type" => "response.steer"} = steer ->
          send(state.owner, {:upstream_steer, self(), steer})
          {:ok, state}

        create ->
          send(state.owner, {:upstream_create, self(), create})

          if state.capture_create_size,
            do: send(state.owner, {:upstream_create_size, self(), byte_size(bytes)})

          # Intentionally preserve whitespace and unknown fields across the gateway.
          event = ~s({ "type": "response.future", "opaque": {"keep": "雪"} })
          {:push, {:text, event}, state}
      end
    end

    @impl true
    def handle_info({:event, event}, state), do: {:push, {:text, event}, state}
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

  test "first-create routing errors are returned without opening an upstream", ctx do
    {:ok, _} = ProviderApi.update(ctx.api, %{responses_websocket: false})
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    send_create(socket)
    assert_error(socket, 501, "responses_websocket_disabled")
    cleanup(socket)

    {:ok, _} = ProviderApi.update(ProviderApi.get(ctx.api.id), %{responses_websocket: true})

    for {event, status, code} <- [
          {%{"type" => "response.create", "stream_id" => "initial"}, 400, "invalid_model"},
          {%{"type" => "response.cancel", "model" => "ws-provider/model"}, 400,
           "invalid_request"},
          {codex_interrupt("resp_unbound"), 400, "invalid_request"},
          {steer_request("resp_unbound", "Update"), 400, "invalid_request"},
          {%{"type" => "response.create", "model" => "unknown/model"}, 404, "model_unavailable"}
        ] do
      socket = connect(ctx)
      assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
      :ok = WebSocket.send(socket, Formata.JSON.encode!(event))
      response = assert_error(socket, status, code)
      assert Map.get(response, "stream_id") == Map.get(event, "stream_id")
      cleanup(socket)
    end

    assert connections() == 0
  end

  test "each connection routes from its first create and ignores the model query", ctx do
    {:ok, model} =
      ProviderModel.create(%{provider_id: ctx.provider.id, model: "second", source: :manual})

    {:ok, _} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: ctx.api.id,
        enabled: true
      })

    ModelResolver.clear_cache()

    for {query, model} <- [{"", "model"}, {"?model=ws-provider/model", "second"}] do
      socket = connect(ctx, auth(ctx), query)
      assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
      refute_receive {:upstream_open, _}, 100
      send_create(socket, "ws-provider/#{model}")
      assert_receive {:upstream_open, peer}, 2_000
      assert_receive {:upstream_create, ^peer, %{"model" => ^model}}, 2_000
      assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000
      cleanup(socket)
    end

    assert connections() == 2
  end

  test "forwards creates with a large Codex tool catalog on a shared connection", ctx do
    Agent.update(__MODULE__.Store, &Map.put(&1, :max_message_bytes, "1048576"))

    properties =
      Map.new(1..36, fn field ->
        {"field_#{field}",
         %{"type" => "string", "description" => "Example argument", "enum" => ["a", "b"]}}
      end)

    tools =
      Enum.map(1..89, fn tool ->
        %{
          "type" => "function",
          "name" => "tool_#{tool}",
          "parameters" => %{"type" => "object", "properties" => properties}
        }
      end)

    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    create = %{"type" => "response.create", "model" => "ws-provider/model", "tools" => tools}

    :ok = WebSocket.send(socket, Formata.JSON.encode!(Map.put(create, "generate", false)))
    assert_receive {:upstream_open, peer}, 5_000
    assert_receive {:upstream_create, ^peer, %{"model" => "model", "tools" => ^tools}}, 5_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 5_000

    :ok = WebSocket.send(socket, Formata.JSON.encode!(create))
    assert_receive {:upstream_create, ^peer, %{"model" => "model", "tools" => ^tools}}, 5_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 5_000
    cleanup(socket)
  end

  test "forwards messages above 2 MiB and records terminal usage", ctx do
    capture_ws_access()
    Agent.update(__MODULE__.Store, &Map.put(&1, :max_message_bytes, "20971520"))
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000

    text = String.duplicate("a", 2_097_152)
    create = %{"type" => "response.create", "model" => "ws-provider/model", "input" => text}
    :ok = WebSocket.send(socket, Formata.JSON.encode!(create))
    assert_receive {:upstream_open, peer}, 5_000
    assert_receive {:upstream_create, ^peer, %{"model" => "model", "input" => ^text}}, 5_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 5_000

    terminal =
      Formata.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_large",
          "output" => text,
          "usage" => %{"input_tokens" => 7, "output_tokens" => 3, "total_tokens" => 10}
        }
      })

    send(peer, {:event, terminal})
    assert_receive {WebSocket, ^socket, %Event.Message{data: ^terminal}}, 5_000

    assert_receive {:ws_access, %{"provider_request_id" => "resp_large", "total_tokens" => 10}},
                   5_000

    cleanup(socket)
  end

  test "enforces configured message and JSON limits", ctx do
    original = Application.fetch_env(:backplane_llama, Limits)
    Application.put_env(:backplane_llama, Limits, %{max_message_bytes: 512, max_nodes: 5})

    on_exit(fn ->
      case original do
        {:ok, limits} -> Application.put_env(:backplane_llama, Limits, limits)
        :error -> Application.delete_env(:backplane_llama, Limits)
      end
    end)

    create = %{"type" => "response.create", "model" => "ws-provider/model"}
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    :ok = WebSocket.send(socket, Formata.JSON.encode!(Map.put(create, "input", [1, 2, 3])))
    assert_error(socket, 400, "invalid_request")
    cleanup(socket)

    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000

    :ok =
      WebSocket.send(
        socket,
        Formata.JSON.encode!(Map.put(create, "input", String.duplicate("a", 512)))
      )

    assert_receive {WebSocket, ^socket, %Event.Close{code: 1009}}, 5_000
    cleanup(socket)
    assert connections() == 0
  end

  test "reports WebSocket handshakes as a separate Responses protocol", ctx do
    capture_ws_access()
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    send_create(socket)

    assert_receive {:ws_access,
                    %{
                      "operation" => "responses.websocket.handshake",
                      "api_surface" => "openai_responses_ws",
                      "http_method" => "GET",
                      "status" => 101,
                      "outcome" => "success",
                      "provider_name" => "ws-provider",
                      "requested_model" => "ws-provider/model",
                      "stream" => "true"
                    } = record},
                   5_000

    refute Map.has_key?(record, "input_tokens")
    refute Map.has_key?(record, "output_tokens")
    cleanup(socket)

    Agent.update(__MODULE__.Store, &%{&1 | reject: true})
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    send_create(socket)
    assert_error(socket, 429, "upstream_websocket_rejected")

    assert_receive {:ws_access,
                    %{
                      "api_surface" => "openai_responses_ws",
                      "status" => 429,
                      "outcome" => "error"
                    }}

    cleanup(socket)
  end

  test "records terminal usage once per response on a shared WebSocket", ctx do
    capture_ws_access()
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)
    assert_receive {:ws_access, %{"operation" => "responses.websocket.handshake"}}

    for lane <- ~w(a b c d) do
      create = %{"type" => "response.create", "model" => "model", "stream_id" => lane}
      :ok = WebSocket.send(socket, Jason.encode!(create))
      assert_receive {:upstream_create, ^peer, ^create}, 2_000
      assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000
      push_response(peer, socket, "response.created", lane, %{})
    end

    usage = %{
      "input_tokens" => 21,
      "output_tokens" => 5,
      "total_tokens" => 26,
      "input_tokens_details" => %{"cached_tokens" => 12},
      "output_tokens_details" => %{"reasoning_tokens" => 2}
    }

    push_response(peer, socket, "response.incomplete", "b", %{"usage" => usage})

    assert_receive {:ws_access,
                    %{
                      "api_surface" => "openai_responses_ws",
                      "operation" => "responses.websocket.create",
                      "provider_request_id" => "resp_b",
                      "outcome" => "error",
                      "input_tokens" => 21,
                      "output_tokens" => 5,
                      "total_tokens" => 26,
                      "cached_tokens" => 12,
                      "reasoning_tokens" => 2
                    }}

    push_response(peer, socket, "response.incomplete", "b", %{"usage" => usage})

    push_response(peer, socket, "response.completed", "a", %{
      "usage" => %{"input_tokens" => 3, "output_tokens" => 0}
    })

    assert_receive {:ws_access,
                    %{
                      "provider_request_id" => "resp_a",
                      "outcome" => "success",
                      "input_tokens" => 3,
                      "output_tokens" => 0,
                      "total_tokens" => 3
                    }}

    push_response(peer, socket, "response.failed", "c", %{})
    assert_receive {:ws_access, %{"provider_request_id" => "resp_c", "outcome" => "error"} = log}
    refute Map.has_key?(log, "input_tokens")
    refute Map.has_key?(log, "output_tokens")
    cleanup(socket)

    # Lane "d" received response.created without a terminal event: closing the socket
    # must record a transport-interrupted create row (no fabricated usage/completion)
    # and exactly one connection-end close diagnostic record.
    assert_receive {:ws_access,
                    %{
                      "operation" => "responses.websocket.create",
                      "provider_request_id" => "resp_d",
                      "outcome" => "cancelled",
                      "error_code" => "responses_interrupted"
                    } = interrupted_log},
                   2_000

    refute Map.has_key?(interrupted_log, "input_tokens")
    refute Map.has_key?(interrupted_log, "output_tokens")
    refute Map.has_key?(interrupted_log, "total_tokens")

    assert_receive {:ws_access,
                    %{
                      "operation" => "responses.websocket.close",
                      "api_surface" => "openai_responses_ws",
                      "metadata" => %{
                        "websocket_close" => %{
                          "initiator" => "client",
                          "interrupted_responses" => 1
                        }
                      }
                    }},
                   2_000

    refute_receive {:ws_access, %{"operation" => "responses.websocket.close"}}, 100
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

    refute HTTP.Headers.get(handshake.headers, "x-codex-websocket-max-unfragmented-message-bytes")
    peer = bind(socket)

    assert_receive {:upstream_handshake, "/v1/responses", query, headers}, 2_000
    assert query == ""
    assert {"authorization", "Bearer sk-loopback-only"} in headers
    assert {"session_id", "loopback-session"} in headers
    assert {"openai-beta", "responses_websockets=2025-02-01"} in headers
    assert {"x-provider-config", "configured"} in headers
    refute Enum.any?(headers, fn {name, _} -> name in ["cookie", "chatgpt-account-id"] end)
    refute Enum.any?(headers, fn {_, value} -> String.contains?(value, ctx.token) end)

    for model <- ["ws-provider/model", "model"] do
      params = %{
        "type" => "response.create",
        "model" => model,
        "input" => "hello",
        "future" => [1, 2]
      }

      :ok = WebSocket.send(socket, Formata.JSON.encode!(params))
      assert_receive {:upstream_create, ^peer, forwarded}, 2_000
      assert forwarded == Map.put(params, "model", "model")
      assert_receive {WebSocket, ^socket, %Event.Message{data: event}}, 2_000
      assert event == ~s({ "type": "response.future", "opaque": {"keep": "雪"} })
    end

    cleanup(socket)
    assert_receive {:upstream_closed, ^peer}, 5_000
    assert connections() == 1
  end

  test "propagates an upstream handshake rejection as a WebSocket error", ctx do
    Agent.update(__MODULE__.Store, &%{&1 | reject: true})
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000

    :ok =
      WebSocket.send(
        socket,
        Formata.JSON.encode!(%{
          "type" => "response.create",
          "model" => "ws-provider/model",
          "stream_id" => "initial"
        })
      )

    assert %{"headers" => %{"retry-after" => "7"}, "stream_id" => "initial"} =
             assert_error(socket, 429, "upstream_websocket_rejected")

    assert_receive {WebSocket, ^socket, %Event.Close{}}, 5_000
    cleanup(socket)
    assert connections() == 1
  end

  test "Codex OAuth injects account credentials and accepts CLI WebSocket creates", ctx do
    configure_codex(ctx)

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
    warmup = %{"type" => "response.create", "model" => "model", "generate" => false}

    :ok =
      WebSocket.send(
        socket,
        Jason.encode!(%{warmup | "model" => "ws-provider/model"} |> Map.put("stream", true))
      )

    assert_receive {:upstream_handshake, "/backend-api/codex/responses", _query, headers}, 2_000
    assert {"authorization", "Bearer loopback-oauth-access"} in headers
    assert {"chatgpt-account-id", "provider-account"} in headers
    assert {"x-openai-fedramp", "true"} in headers
    assert {"originator", "api-originator"} in headers
    assert Enum.count(headers, fn {name, _} -> name == "authorization" end) == 1
    assert Enum.count(headers, fn {name, _} -> name == "originator" end) == 1
    assert_receive {:upstream_open, peer}, 2_000

    assert_receive {:upstream_create, ^peer, ^warmup}, 2_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000

    create = %{
      "type" => "response.create",
      "model" => "model",
      "previous_response_id" => "resp_previous"
    }

    :ok = WebSocket.send(socket, Jason.encode!(Map.put(create, "stream", true)))
    assert_receive {:upstream_create, ^peer, ^create}, 2_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000

    create = %{"type" => "response.create", "model" => "model", "stream" => false}
    :ok = WebSocket.send(socket, Jason.encode!(create))
    assert_error(socket, 400, "invalid_request")
    refute_receive {:upstream_create, ^peer, _}, 100

    # Request-scoped rejection leaves the healthy session open for subsequent creates.
    follow_up = %{"type" => "response.create", "model" => "model", "input" => "after-reject"}
    :ok = WebSocket.send(socket, Jason.encode!(follow_up))
    assert_receive {:upstream_create, ^peer, ^follow_up}, 2_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000
    cleanup(socket)
  end

  test "forwards the Codex interrupt for a response on the pinned upstream", ctx do
    configure_codex(ctx)
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)
    push_response(peer, socket, "response.created", "codex_lane", %{})
    interrupt = codex_interrupt("resp_codex_lane")

    for rejected <- [
          codex_interrupt("resp_other_connection"),
          %{interrupt | "mode" => "unknown"},
          Map.put(interrupt, "model", "other/model")
        ] do
      :ok = WebSocket.send(socket, Jason.encode!(rejected))
      assert_error(socket, 400, "invalid_request")
      refute_receive {:upstream_interrupt, ^peer, _}, 100
    end

    :ok = WebSocket.send(socket, Jason.encode!(interrupt))
    assert_receive {:upstream_interrupt, ^peer, ^interrupt}, 2_000

    push_response(peer, socket, "response.completed", "codex_lane", %{})
    ack = ~s({ "type": "response.interrupt.accepted", "response_id": "resp_codex_lane" })
    send(peer, {:event, ack})
    assert_receive {WebSocket, ^socket, %Event.Message{data: ^ack}}, 2_000

    send_create(socket)
    assert_receive {:upstream_create, ^peer, %{"type" => "response.create"}}, 2_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000
    assert connections() == 1
    cleanup(socket)
  end

  test "rechecks a Codex client's authorization before forwarding an interrupt", ctx do
    configure_codex(ctx)
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)
    push_response(peer, socket, "response.created", "codex_lane", %{})
    {:ok, _} = Backplane.Clients.revoke_client_token(ctx.client)

    :ok = WebSocket.send(socket, Jason.encode!(codex_interrupt("resp_codex_lane")))
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
    refute_receive {:upstream_interrupt, ^peer, _}, 100
    cleanup(socket)
  end

  test "forwards Platform steering and the upstream successor on the target lane", ctx do
    capture_ws_access()
    {:ok, _} = Provider.update(ctx.provider, %{preset_key: "openai", rpm_limit: 2})
    ModelResolver.clear_cache()
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)
    push_response(peer, socket, "response.created", "platform_lane", %{})

    steer =
      steer_request("resp_platform_lane", [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "input_text", "text" => "Use this file instead."},
            %{"type" => "input_file", "file_id" => "file_fixture"}
          ]
        }
      ])

    for invalid <- [
          Map.put(steer, "stream_id", "wrong_lane"),
          %{steer | "input" => [%{"role" => "developer", "content" => "invalid"}]},
          %{steer | "input" => [%{"type" => "function_call_output", "output" => "invalid"}]},
          %{steer | "input" => []}
        ] do
      :ok = WebSocket.send(socket, Formata.JSON.encode!(invalid))
      assert %{"stream_id" => "platform_lane"} = assert_error(socket, 400, "invalid_request")
      refute_received {:upstream_steer, ^peer, _}
    end

    :ok =
      WebSocket.send(
        socket,
        Formata.JSON.encode!(%{steer | "previous_response_id" => "resp_other"})
      )

    refute Map.has_key?(assert_error(socket, 400, "invalid_request"), "stream_id")
    refute_received {:upstream_steer, ^peer, _}

    :ok = WebSocket.send(socket, Formata.JSON.encode!(steer))
    assert_receive {:upstream_steer, ^peer, ^steer}, 2_000

    accepted =
      ~s({ "type": "response.steer.accepted", "stream_id": "platform_lane", "steer": {"id":"steer_fixture","previous_response_id":"resp_platform_lane"} })

    send(peer, {:event, accepted})
    assert_receive {WebSocket, ^socket, %Event.Message{data: ^accepted}}, 2_000

    push_response(peer, socket, "response.incomplete", "platform_lane", %{
      "incomplete_details" => %{"reason" => "steered"}
    })

    assert_receive {:ws_access,
                    %{
                      "provider_request_id" => "resp_platform_lane",
                      "outcome" => "success",
                      "finish_reason" => "steered",
                      "metadata" => %{
                        "protocol_observation" => %{"protocol_terminal" => "incomplete"}
                      }
                    }}

    successor =
      ~s({ "type":"response.created", "stream_id":"platform_lane", "response":{"id":"resp_successor","previous_response_id":"resp_platform_lane"} })

    send(peer, {:event, successor})
    assert_receive {WebSocket, ^socket, %Event.Message{data: ^successor}}, 2_000

    next_steer = Formata.JSON.encode!(steer_request("resp_successor", "One more update"))
    :ok = WebSocket.send(socket, next_steer)

    assert %{
             "stream_id" => "platform_lane",
             "error" => %{
               "type" => "rate_limit_error",
               "message" => "rate_limited",
               "param" => nil
             }
           } = assert_error(socket, 429, "rate_limited")

    refute_received {:upstream_steer, ^peer, _}

    assert connections() == 1
    {:ok, _} = Backplane.Clients.revoke_client_token(ctx.client)
    :ok = WebSocket.send(socket, next_steer)
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
    refute_received {:upstream_steer, ^peer, _}
    cleanup(socket)
    assert_receive {:ws_access, %{"operation" => "responses.websocket.close"}}, 5_000
  end

  test "preserves lane correlation on structural validation failures", ctx do
    capture_ws_access()
    put_ws_limits(%{max_list_length: 1})
    {:ok, _} = Provider.update(ctx.provider, %{preset_key: "openai"})
    ModelResolver.clear_cache()

    create = %{
      "type" => "response.create",
      "model" => "ws-provider/model",
      "stream_id" => "create_lane",
      "input" => [
        %{"role" => "user", "content" => "One"},
        %{"role" => "user", "content" => "Two"}
      ]
    }

    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    :ok = WebSocket.send(socket, Formata.JSON.encode!(create))
    assert %{"stream_id" => "create_lane"} = assert_error(socket, 400, "invalid_request")
    cleanup(socket)
    assert_receive {:ws_access, %{"operation" => "responses.websocket.close"}}, 5_000

    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)
    push_response(peer, socket, "response.created", "steer_lane", %{})

    :ok = WebSocket.send(socket, Formata.JSON.encode!(create))
    assert %{"stream_id" => "create_lane"} = assert_error(socket, 400, "invalid_request")
    refute_received {:upstream_create, ^peer, _}

    steer =
      steer_request("resp_steer_lane", [
        %{"role" => "user", "content" => String.duplicate("a", 16_384)},
        %{"role" => "user", "content" => "Two"}
      ])

    :ok = WebSocket.send(socket, Formata.JSON.encode!(steer))

    assert %{"stream_id" => "steer_lane", "error" => %{"type" => "invalid_request_error"}} =
             assert_error(socket, 400, "invalid_request")

    refute_received {:upstream_steer, ^peer, _}
    cleanup(socket)
    assert_receive {:ws_access, %{"operation" => "responses.websocket.close"}}, 5_000
  end

  test "evicts oldest finished steering targets before losing active responses", ctx do
    capture_ws_access()
    put_ws_limits(%{max_response_ids: 3})
    {:ok, _} = Provider.update(ctx.provider, %{preset_key: "openai"})
    ModelResolver.clear_cache()
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)
    push_response(peer, socket, "response.created", "active", %{})

    for lane <- ["oldest", "recent"] do
      push_response(peer, socket, "response.created", lane, %{})
      push_response(peer, socket, "response.completed", lane, %{})
    end

    push_response(peer, socket, "response.created", "new", %{})

    for lane <- ["new", "active", "recent"] do
      steer = steer_request("resp_#{lane}", "Follow up")
      :ok = WebSocket.send(socket, Formata.JSON.encode!(steer))
      assert_receive {:upstream_steer, ^peer, ^steer}, 2_000
    end

    expired = steer_request("resp_oldest", "Follow up")
    :ok = WebSocket.send(socket, Formata.JSON.encode!(expired))
    refute Map.has_key?(assert_error(socket, 400, "invalid_request"), "stream_id")
    refute_received {:upstream_steer, ^peer, ^expired}

    push_response(peer, socket, "response.created", "last_slot", %{})
    push_response(peer, socket, "response.created", "over_limit", %{})
    over_limit = steer_request("resp_over_limit", "Follow up")
    :ok = WebSocket.send(socket, Formata.JSON.encode!(over_limit))
    assert_error(socket, 400, "invalid_request")
    refute_received {:upstream_steer, ^peer, ^over_limit}

    for lane <- ["new", "active", "last_slot"] do
      steer = steer_request("resp_#{lane}", "Follow up")
      :ok = WebSocket.send(socket, Formata.JSON.encode!(steer))
      assert_receive {:upstream_steer, ^peer, ^steer}, 2_000
    end

    cleanup(socket)
    assert_receive {:ws_access, %{"operation" => "responses.websocket.close"}}, 5_000
  end

  test "relays pending steering and preserves the explicit tool continuation", ctx do
    capture_ws_access()
    {:ok, _} = Provider.update(ctx.provider, %{preset_key: "openai"})
    ModelResolver.clear_cache()
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)
    push_response(peer, socket, "response.created", "tool_lane", %{})

    steer = steer_request("resp_tool_lane", "Correlate the tool result.")
    :ok = WebSocket.send(socket, Formata.JSON.encode!(steer))
    assert_receive {:upstream_steer, ^peer, ^steer}, 2_000

    call = %{"type" => "function_call", "name" => "fixture", "call_id" => "call_fixture"}
    push_response(peer, socket, "response.completed", "tool_lane", %{"output" => [call]})

    pending =
      ~s({ "type":"response.steer.pending", "stream_id":"tool_lane", "steer":{"id":"steer_fixture","previous_response_id":"resp_tool_lane"}, "required_input":[{"type":"function_call_output","call_id":"call_fixture"}] })

    send(peer, {:event, pending})
    assert_receive {WebSocket, ^socket, %Event.Message{data: ^pending}}, 2_000

    continuation = %{
      "type" => "response.create",
      "model" => "model",
      "stream_id" => "tool_lane",
      "previous_response_id" => "resp_tool_lane",
      "input" => [
        %{"type" => "function_call_output", "call_id" => "call_fixture", "output" => "ok"}
      ]
    }

    :ok = WebSocket.send(socket, Formata.JSON.encode!(continuation))
    assert_receive {:upstream_create, ^peer, ^continuation}, 2_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000
    assert connections() == 1
    cleanup(socket)
    assert_receive {:ws_access, %{"operation" => "responses.websocket.close"}}, 5_000
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
        Formata.JSON.encode!(Map.put(tokens, "access_token", "new-loopback-oauth")),
        "llm",
        %{"auth_type" => "openai_oauth", "account_id" => "cache-test-account"}
      )

    assert Backplane.Settings.Credentials.Vault.get("ws-provider-key") == rotated
    assert {:ok, "old-loopback-oauth"} = Backplane.Settings.TokenCache.get("ws-provider-key")

    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    send_create(socket)
    assert_error(socket, 503, "responses_websocket_unavailable")
    cleanup(socket)
    assert connections() == 0
  end

  test "credential rotation during a session prevents another submission", ctx do
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)

    {:ok, _} = Credentials.store("ws-provider-key", "sk-rotated-loopback", "llm")
    send_create(socket)
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
    refute_receive {:upstream_create, ^peer, _}, 100
    cleanup(socket)
    assert connections() == 1
  end

  test "revoked client token prevents another creation on an existing connection", ctx do
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)

    {:ok, _} = Backplane.Clients.revoke_client_token(ctx.client)
    send_create(socket)
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
    refute_receive {:upstream_create, ^peer, _}, 100
    cleanup(socket)
  end

  test "revoked client token is rechecked before opening the upstream", ctx do
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    {:ok, _} = Backplane.Clients.revoke_client_token(ctx.client)
    send_create(socket)
    assert_error(socket, 403, "principal_changed")
    assert connections() == 0
    cleanup(socket)
  end

  test "an established non-Codex session rejects model switches and unsupported events",
       ctx do
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)
    push_response(peer, socket, "response.created", "live_lane", %{})

    for {attrs, expected_code} <- [
          {%{"type" => "response.create", "model" => "other/model"}, "model_mismatch"},
          {%{"type" => "response.cancel", "model" => "model"}, "invalid_request"},
          {codex_interrupt("resp_live_lane"), "invalid_request"},
          {steer_request("resp_live_lane", "Update"), "invalid_request"},
          {%{"type" => "response.create", "model" => "model", "stream" => true},
           "invalid_request"},
          {%{"type" => "response.create", "model" => "model", "background" => true},
           "invalid_request"}
        ] do
      :ok = WebSocket.send(socket, Formata.JSON.encode!(attrs))
      assert_error(socket, 400, expected_code)
      refute_receive {:upstream_create, ^peer, _}, 100
      refute_received {:upstream_interrupt, ^peer, _}
      refute_received {:upstream_steer, ^peer, _}
    end

    # Unaffected in-flight lane still delivers terminal events after request-scoped rejections.
    push_response(peer, socket, "response.completed", "live_lane", %{})
    cleanup(socket)
  end

  test "binary frames close with 1003", ctx do
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)
    :ok = WebSocket.send(socket, WebSocket.array_buffer("not a JSON text frame"))
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1003}}, 5_000
    refute_receive {:upstream_create, ^peer, _}, 100
    cleanup(socket)
  end

  test "rewritten creates are capped by the smaller local limit", ctx do
    assert_rewritten_create_limit(ctx, :local)
  end

  @tag :responses_peer_limit
  test "rewritten creates are capped by the smaller peer limit from the upstream 101", ctx do
    assert_rewritten_create_limit(ctx, :peer)
  end

  defp assert_rewritten_create_limit(ctx, source) do
    {:ok, long_model} =
      ProviderModel.create(%{
        provider_id: ctx.provider.id,
        model: "very-long-upstream-model-identifier-for-size-test",
        source: :manual
      })

    {:ok, _} =
      ProviderModelSurface.create(%{
        provider_model_id: long_model.id,
        provider_api_id: ctx.api.id,
        enabled: true
      })

    {:ok, _} =
      Backplane.LLM.ModelAlias.create(%{
        alias: "s",
        target: "#{ctx.provider.name}/very-long-upstream-model-identifier-for-size-test"
      })

    ModelResolver.clear_cache()

    base = Formata.JSON.encode!(%{"type" => "response.create", "model" => "s", "input" => ""})

    rewritten_base =
      Formata.JSON.encode!(%{
        "type" => "response.create",
        "model" => "very-long-upstream-model-identifier-for-size-test",
        "input" => ""
      })

    limit = byte_size(rewritten_base) + 10
    Agent.update(__MODULE__.Store, &Map.put(&1, :capture_create_size, true))

    expected_error =
      case source do
        :local ->
          put_ws_limits(%{max_message_bytes: limit})
          "message_too_big"

        :peer ->
          Agent.update(__MODULE__.Store, &Map.put(&1, :max_message_bytes, to_string(limit)))
          "message_exceeds_peer_limit"
      end

    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    # First create fits easily (10 bytes headroom).
    :ok =
      WebSocket.send(
        socket,
        Formata.JSON.encode!(%{"type" => "response.create", "model" => "s", "input" => "ok"})
      )

    assert_receive {:upstream_open, peer2}, 2_000
    assert_receive {:upstream_create, ^peer2, %{"input" => "ok"}}, 2_000
    assert_receive {:upstream_create_size, ^peer2, _}, 2_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000

    # Exact rewritten limit succeeds.
    exact_input = String.duplicate("x", 10)
    assert byte_size(base) + byte_size(exact_input) < limit

    :ok =
      WebSocket.send(
        socket,
        Formata.JSON.encode!(%{
          "type" => "response.create",
          "model" => "s",
          "input" => exact_input
        })
      )

    assert_receive {:upstream_create, ^peer2, %{"input" => ^exact_input}}, 2_000
    assert_receive {:upstream_create_size, ^peer2, ^limit}, 2_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000

    # 1 byte over rewritten limit (even though original client JSON is well under limit!) is rejected locally.
    over_input = String.duplicate("x", 11)
    assert byte_size(base) + byte_size(over_input) < limit

    :ok =
      WebSocket.send(
        socket,
        Formata.JSON.encode!(%{
          "type" => "response.create",
          "model" => "s",
          "input" => over_input
        })
      )

    assert_error(socket, 413, expected_error)
    refute_receive {:upstream_create, ^peer2, _}, 100
    send_create(socket, "s")

    assert_receive {:upstream_create, ^peer2,
                    %{"model" => "very-long-upstream-model-identifier-for-size-test"}},
                   2_000

    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000
    assert connections() == 1
    cleanup(socket)
  end

  test "rate limit rejects only the throttled create and preserves unaffected lanes", ctx do
    {:ok, _} = Provider.update(ctx.provider, %{rpm_limit: 1})
    ModelResolver.clear_cache()
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)
    push_response(peer, socket, "response.created", "rpm_lane", %{})

    for lane <- ["second.lane", "third-lane"] do
      :ok =
        WebSocket.send(
          socket,
          Formata.JSON.encode!(%{
            "type" => "response.create",
            "model" => "model",
            "stream_id" => lane
          })
        )
    end

    for lane <- ["second.lane", "third-lane"] do
      assert %{"stream_id" => ^lane} = assert_error(socket, 429, "rate_limited")
    end

    refute_receive {:upstream_create, ^peer, _}, 100
    # Existing lane still receives its completion event on the open socket.
    push_response(peer, socket, "response.completed", "rpm_lane", %{})
    cleanup(socket)
  end

  test "upstream disconnect after submission does not reconnect or replay", ctx do
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)
    send(peer, :disconnect)
    assert_receive {WebSocket, ^socket, %Event.Close{}}, 5_000
    refute_receive {:upstream_open, _}, 250
    assert connections() == 1
    cleanup(socket)
  end

  test "disabling the API during a session prevents another submission", ctx do
    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)
    {:ok, _} = ProviderApi.update(ctx.api, %{responses_websocket: false})
    send_create(socket)

    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
    refute_receive {:upstream_create, ^peer, _}, 100
    cleanup(socket)
  end

  test "output-only client and quiet reasoning periods stay alive past read-idle window via gateway ping/pong",
       ctx do
    capture_ws_access()

    put_ws_limits(%{
      downstream_read_timeout_ms: 200,
      downstream_ping_interval_ms: 60,
      downstream_pong_timeout_ms: 150,
      upstream_ping_interval_ms: 60,
      upstream_pong_timeout_ms: 150,
      max_lifetime_ms: :infinity
    })

    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)

    # Client never sends another frame for > 450ms (> 2x read_timeout), only consumes output.
    for i <- 1..5 do
      Process.sleep(70)

      event =
        Formata.JSON.encode!(%{"type" => "response.output_text.delta", "delta" => "chunk-#{i}"})

      send(peer, {:event, event})
      assert_receive {WebSocket, ^socket, %Event.Message{data: ^event}}, 2_000
    end

    # Quiet period (no frames in either direction) also stays alive via hop-local Ping/Pong.
    Process.sleep(250)

    # Later tool continuation still succeeds on the same connection.
    continuation = %{
      "type" => "response.create",
      "model" => "model",
      "previous_response_id" => "resp_1",
      "input" => "tool_output"
    }

    :ok = WebSocket.send(socket, Formata.JSON.encode!(continuation))
    assert_receive {:upstream_create, ^peer, ^continuation}, 2_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000
    cleanup(socket)

    assert_receive {:ws_access,
                    %{
                      "operation" => "responses.websocket.close",
                      "outcome" => "success",
                      "metadata" => %{"websocket_close" => %{"cause" => "client_close"}}
                    }},
                   2_000
  end

  test "nonresponsive downstream peer is closed within pong timeout with distinct close diagnostic",
       ctx do
    capture_ws_access()

    put_ws_limits(%{
      downstream_read_timeout_ms: :infinity,
      downstream_ping_interval_ms: 60,
      downstream_pong_timeout_ms: 100
    })

    # Connect in proxy mode with automatic_pong: false so this client ignores gateway Ping frames.
    socket =
      WebSocket.new("ws://127.0.0.1:#{ctx.port}/v1/responses", [],
        headers: auth(ctx),
        mode: :proxy,
        automatic_pong: false,
        delivery: :ack,
        http_version: :http1,
        connect_timeout: 2_000,
        opening_timeout: 5_000,
        close_timeout: 1_000
      )

    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000

    :ok =
      WebSocket.send_frame(
        socket,
        {:text,
         Formata.JSON.encode!(%{"type" => "response.create", "model" => "ws-provider/model"})}
      )

    assert_receive {:upstream_open, _peer}, 2_000

    # Acknowledge incoming frames (including gateway Ping) without replying Pong so
    # HTTP.WebSocket's ACK queue stays drained and delivers the gateway Close frame.
    drain_without_pong = fn loop ->
      receive do
        {WebSocket, ^socket, %Event.Frame{}, ref} ->
          WebSocket.acknowledge(socket, ref)
          loop.(loop)

        {WebSocket, ^socket, %Event.Close{code: 1001}} ->
          :ok
      after
        3_000 -> flunk("expected gateway Close 1001 after downstream pong timeout")
      end
    end

    assert :ok = drain_without_pong.(drain_without_pong)

    assert_receive {:ws_access,
                    %{
                      "operation" => "responses.websocket.close",
                      "outcome" => "error",
                      "error_kind" => "timeout",
                      "error_code" => "downstream_pong_timeout",
                      "metadata" => %{
                        "websocket_close" => %{
                          "initiator" => "gateway",
                          "cause" => "downstream_pong_timeout"
                        }
                      }
                    }},
                   2_000

    cleanup(socket)
  end

  test "deliberately configured finite max_lifetime_ms closes cleanly with downstream_lifetime diagnostic",
       ctx do
    capture_ws_access()

    put_ws_limits(%{
      max_lifetime_ms: 200,
      downstream_read_timeout_ms: :infinity,
      downstream_ping_interval_ms: 50,
      downstream_pong_timeout_ms: 150
    })

    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    _peer = bind(socket)

    assert_receive {WebSocket, ^socket, %Event.Close{}}, 2_000

    assert_receive {:ws_access,
                    %{
                      "operation" => "responses.websocket.close",
                      "outcome" => "error",
                      "error_kind" => "timeout",
                      "error_code" => "downstream_lifetime",
                      "metadata" => %{"websocket_close" => %{"cause" => "downstream_lifetime"}}
                    }},
                   2_000

    cleanup(socket)
  end

  test "configured read-idle timeout without pings closes with downstream_read_idle diagnostic",
       ctx do
    capture_ws_access()

    put_ws_limits(%{
      max_lifetime_ms: :infinity,
      downstream_read_timeout_ms: 150,
      downstream_ping_interval_ms: :infinity
    })

    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    _peer = bind(socket)

    assert_receive {WebSocket, ^socket, %Event.Close{}}, 2_000

    assert_receive {:ws_access,
                    %{
                      "operation" => "responses.websocket.close",
                      "outcome" => "error",
                      "error_kind" => "timeout",
                      "error_code" => "downstream_read_idle",
                      "metadata" => %{"websocket_close" => %{"cause" => "downstream_read_idle"}}
                    }},
                   2_000

    cleanup(socket)
  end

  test "same-account OAuth refresh fails closed with distinct credential_refreshed diagnostic",
       ctx do
    capture_ws_access()

    {:ok, _} =
      Credentials.store_device_token(
        "ws-provider-key",
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "auth_mode" => "chatgpt",
          "access_token" => "initial-oauth-access",
          "refresh_token" => "initial-oauth-refresh",
          "expires_at" => System.system_time(:millisecond) + 3_600_000
        },
        %{"account_id" => "acct-same-refresh"}
      )

    {:ok, _} = Provider.update(ctx.provider, %{preset_key: "openai-codex"})
    ModelResolver.clear_cache()

    socket = connect(ctx)
    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    peer = bind(socket)

    # Simulate background OAuth token refresh for the exact same account_id.
    {:ok, _} =
      Credentials.store_device_token(
        "ws-provider-key",
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "auth_mode" => "chatgpt",
          "access_token" => "refreshed-oauth-access",
          "refresh_token" => "refreshed-oauth-refresh",
          "expires_at" => System.system_time(:millisecond) + 7_200_000,
          "last_refresh" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        %{"account_id" => "acct-same-refresh"}
      )

    send_create(socket)
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1008}}, 5_000
    refute_receive {:upstream_create, ^peer, _}, 100

    assert_receive {:ws_access,
                    %{
                      "operation" => "responses.websocket.close",
                      "outcome" => "error",
                      "error_kind" => "policy",
                      "error_code" => "credential_refreshed",
                      "metadata" => %{"websocket_close" => %{"cause" => "credential_refreshed"}}
                    }},
                   2_000

    cleanup(socket)
  end

  test "forwards a real-socket large Codex request above 20 MiB and near 128 MB within submission budget",
       ctx do
    # Start dedicated servers with the production 512 MiB Gaoxy admission limit.
    {:ok, large_upstream} =
      Gaoxy.HTTP.start_link(
        plug: {Upstream, []},
        port: 0,
        limits: %{max_bytes: 536_870_912}
      )

    %{local: {:ok, {_, large_upstream_port}}} = Gaoxy.info(large_upstream, :http)

    {:ok, large_endpoint} =
      Gaoxy.HTTP.start_link(
        plug: {Backplane.Api.Endpoint, []},
        port: 0,
        limits: %{max_bytes: 536_870_912}
      )

    %{local: {:ok, {_, large_port}}} = Gaoxy.info(large_endpoint, :http)

    on_exit(fn ->
      stop_server(large_endpoint)
      stop_server(large_upstream)
    end)

    {:ok, _} =
      ProviderApi.update(ctx.api, %{base_url: "http://127.0.0.1:#{large_upstream_port}"})

    ModelResolver.clear_cache()

    # 32 MiB payload (> old 20 MiB cap) + 120 MB payload (near 128 MB new default).
    for payload_bytes <- [33_554_432, 120_000_000] do
      text = :binary.copy("a", payload_bytes)

      encoded =
        Formata.JSON.encode!(%{
          "type" => "response.create",
          "model" => "ws-provider/model",
          "input" => text
        })

      :erlang.garbage_collect()

      socket =
        WebSocket.new("ws://127.0.0.1:#{large_port}/v1/responses", [],
          headers: auth(ctx),
          http_version: :http1,
          connect_timeout: 5_000,
          opening_timeout: 5_000,
          write_timeout: 15_000,
          close_timeout: 2_000,
          max_message_size: 134_217_728,
          max_frame_bytes: 134_217_728,
          max_send_queue: 134_217_728 + 256
        )

      assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
      started = System.monotonic_time(:millisecond)
      :ok = WebSocket.send(socket, encoded)
      assert_receive {:upstream_open, peer}, 15_000

      assert_receive {:upstream_create, ^peer, %{"model" => "model", "input" => received}},
                     25_000

      elapsed = System.monotonic_time(:millisecond) - started
      assert byte_size(received) == payload_bytes
      # Must complete well within the 30s default submission budget.
      assert elapsed < 25_000
      assert_receive {WebSocket, ^socket, %Event.Message{}}, 5_000
      cleanup(socket)
    end
  end

  defp put_ws_limits(overrides) do
    original = Application.fetch_env(:backplane_llama, Limits)
    Application.put_env(:backplane_llama, Limits, overrides)

    on_exit(fn ->
      case original do
        {:ok, limits} -> Application.put_env(:backplane_llama, Limits, limits)
        :error -> Application.delete_env(:backplane_llama, Limits)
      end
    end)
  end

  def capture_access(_event, _measurements, %{attributes: attributes}, owner),
    do: send(owner, {:ws_access, attributes})

  defp capture_ws_access do
    app = :backplane_telemetry

    flags = [
      observability_v2_enabled: true,
      observability_v2_llm_write: true,
      observability_v2_test_disabled: false
    ]

    original = Map.new(flags, fn {key, _} -> {key, Application.fetch_env(app, key)} end)
    Enum.each(flags, fn {key, value} -> Application.put_env(app, key, value) end)

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:backplane, :llm_proxy, :request, :stop],
        &__MODULE__.capture_access/4,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler)

      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(app, key, value)
        {key, :error} -> Application.delete_env(app, key)
      end)
    end)
  end

  defp push_response(peer, socket, type, lane, fields) do
    event =
      Jason.encode!(%{
        "type" => type,
        "stream_id" => lane,
        "response" => Map.put(fields, "id", "resp_#{lane}")
      })

    send(peer, {:event, event})
    assert_receive {WebSocket, ^socket, %Event.Message{data: ^event}}, 2_000
  end

  defp auth(ctx), do: [{"authorization", "Bearer " <> ctx.token}]
  defp connect(ctx), do: connect(ctx, auth(ctx))

  defp configure_codex(ctx) do
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
  end

  defp codex_interrupt(response_id) do
    %{
      "type" => "response.interrupt",
      "response_id" => response_id,
      "mode" => "discard_partial_items"
    }
  end

  defp steer_request(response_id, input) do
    %{"type" => "response.steer", "previous_response_id" => response_id, "input" => input}
  end

  defp connect(ctx, headers, query \\ "") do
    WebSocket.new("ws://127.0.0.1:#{ctx.port}/v1/responses#{query}", [],
      headers: headers,
      http_version: :http1,
      connect_timeout: 2_000,
      opening_timeout: 5_000,
      close_timeout: 1_000
    )
  end

  defp send_create(socket, model \\ "ws-provider/model") do
    :ok =
      WebSocket.send(
        socket,
        Formata.JSON.encode!(%{"type" => "response.create", "model" => model})
      )
  end

  defp bind(socket) do
    send_create(socket)
    assert_receive {:upstream_open, peer}, 2_000
    assert_receive {:upstream_create, ^peer, %{"model" => "model"}}, 2_000
    assert_receive {WebSocket, ^socket, %Event.Message{}}, 2_000
    peer
  end

  defp assert_error(socket, status, code) do
    assert_receive {WebSocket, ^socket, %Event.Message{data: body}}, 5_000

    assert %{"type" => "error", "status" => ^status, "error" => %{"code" => ^code}} =
             Formata.JSON.decode!(body)
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
