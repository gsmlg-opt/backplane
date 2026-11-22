defmodule Backplane.Api.RealtimeWebSocketEndpointTest do
  use Backplane.Api.DataCase, async: false

  alias Backplane.LLM.{Provider, ProviderApi}
  alias Backplane.LLM.OpenAI.Service
  alias Backplane.Settings.Credentials
  alias HTTP.{ClientCompletion, WebSocket}
  alias HTTP.WebSocket.Event

  defmodule Upstream do
    def init(opts), do: opts

    def call(conn, owner) do
      send(owner, {:realtime_handshake, conn.query_string, conn.req_headers})

      Relayixir.Proxy.WebSocket.Adapter.upgrade(
        conn,
        Backplane.Api.RealtimeWebSocketEndpointTest.Peer,
        %{owner: owner}
      )
    end
  end

  defmodule Peer do
    @behaviour WebSock
    @impl true
    def init(state) do
      send(state.owner, {:peer_open, self()})
      {:ok, state}
    end

    @impl true
    def handle_in({bytes, opcode: :text}, state) do
      send(state.owner, {:peer_input, bytes})
      {:push, {:text, ~s({ "type":"response.output_audio.delta", "delta":"AQID" })}, state}
    end

    @impl true
    def handle_info(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, state) do
      send(state.owner, :peer_closed)
      :ok
    end
  end

  test "public endpoint authenticates and applies Realtime budgets independently of HTTP limits" do
    {:ok, _, token} =
      Backplane.Clients.issue_client(%{name: "api-voice", scopes: ["llm::invoke"]})

    upstream =
      start_supervised!({Gaoxy.HTTP, plug: {Upstream, self()}, port: 0}, id: :voice_upstream)

    %{local: {:ok, {_, upstream_port}}} = Gaoxy.info(upstream, :http)

    endpoint =
      start_supervised!({Gaoxy.HTTP, plug: {Backplane.Api.Endpoint, []}, port: 0},
        id: :voice_endpoint
      )

    %{local: {:ok, {_, port}}} = Gaoxy.info(endpoint, :http)
    {:ok, _} = Credentials.store("api-voice-key", "sk-loopback-voice", "llm")
    {:ok, provider} = Provider.create(%{name: "api-voice", credential: "api-voice-key"})

    {:ok, _} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://127.0.0.1:#{upstream_port}/v1"
      })

    event = ~s({"type":"input_audio_buffer.append","audio":"AQID"})

    {:ok, _} =
      Service.create(%{
        provider_id: provider.id,
        kind: :realtime,
        models: ["voice"],
        max_request_bytes: 1,
        max_response_bytes: 1,
        realtime_max_input_bytes: 2 * byte_size(event)
      })

    url = "ws://127.0.0.1:#{port}/v1/realtime?model=api-voice/voice"

    on_exit(fn ->
      Backplane.Settings.Credentials.Vault.remove("api-voice-key")
      Credentials.invalidate_token("api-voice-key")
    end)

    denied = WebSocket.new(url, [], http_version: :http1, mode: :browser)
    assert_receive {WebSocket, ^denied, %Event.Error{handshake: %{status: 401}}}, 5_000
    cleanup(denied)
    refute_receive {:realtime_handshake, _, _}, 50

    socket =
      WebSocket.new(url, [],
        http_version: :http1,
        mode: :browser,
        headers: [{"authorization", "Bearer " <> token}]
      )

    assert_receive {WebSocket, ^socket, %Event.Open{}}, 5_000
    assert_receive {:realtime_handshake, query, headers}
    assert URI.decode_query(query) == %{"model" => "voice"}
    assert {"authorization", "Bearer sk-loopback-voice"} in headers
    assert_receive {:peer_open, _}

    for _ <- 1..2 do
      assert :ok = WebSocket.send(socket, event)
      assert_receive {:peer_input, ^event}, 2_000
      assert_receive {WebSocket, ^socket, %Event.Message{data: bytes}}, 2_000
      assert bytes == ~s({ "type":"response.output_audio.delta", "delta":"AQID" })
    end

    assert :ok = WebSocket.send(socket, event)
    assert_receive {WebSocket, ^socket, %Event.Close{code: 1009}}, 5_000
    assert_receive :peer_closed, 5_000
    refute_receive {:peer_input, _}, 50
    cleanup(socket)
  end

  defp cleanup(socket) do
    WebSocket.close(socket)
    ClientCompletion.await(WebSocket.completion(socket), 2_000)
  end
end
