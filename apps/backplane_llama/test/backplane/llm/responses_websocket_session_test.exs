defmodule Backplane.LLM.ResponsesWebSocket.SessionTest do
  use ExUnit.Case, async: false

  alias Backplane.LLM.ResponsesWebSocket.{Limits, Session}

  test "allows the Codex default send window for the first create" do
    {:ok, session} = Session.start_link(owner: self())

    assert :ok = Session.attach(session, self())
    assert %{first_create_timer: timer} = :sys.get_state(session)
    assert Process.read_timer(timer) in 290_000..300_000

    assert :ok = Session.close(session)
  end

  test "uses the environment proxy before resolving an upstream WebSocket host" do
    variables = ~w(HTTP_PROXY http_proxy NO_PROXY no_proxy)
    original = Map.new(variables, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    {proxy_url, listener} = upstream()
    proxy = URI.parse(proxy_url)
    System.put_env("HTTP_PROXY", "http://#{proxy.host}:#{proxy.port}")
    System.delete_env("NO_PROXY")
    System.delete_env("no_proxy")
    parent = self()

    peer =
      spawn(fn ->
        case :gen_tcp.accept(listener, 7_000) do
          {:ok, socket} ->
            request = head(socket)
            send(parent, {:proxy_request, request})
            upgrade(socket, request)
            close_reply(socket)

          {:error, _} ->
            :ok
        end
      end)

    on_exit(fn -> if Process.alive?(peer), do: Process.exit(peer, :kill) end)

    {:ok, session} =
      Session.start_link(
        owner: self(),
        url: "ws://responses.example.invalid/v1/responses",
        headers: [],
        policy: %{}
      )

    assert {:ok, %{status: 101}} = Session.open(session)
    assert_receive {:proxy_request, request}
    assert request =~ "responses.example.invalid/v1/responses HTTP/1.1\r\n"
    assert :ok = Session.close(session)
  end

  test "expired or oversized creation is rejected before policy lookup or any upstream send" do
    {url, server} = upstream()
    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(server, 2_000)
      upgrade(socket, head(socket))
      # Only a Close frame is legal after the local size rejection.
      {:ok, <<0x88, _rest::binary>>} = :gen_tcp.recv(socket, 0, 2_000)
      :gen_tcp.send(socket, <<0x88, 2, 1000::16>>)
      :gen_tcp.close(socket)
      send(parent, :nothing_submitted)
    end)

    {:ok, session} =
      Session.start_link(
        owner: self(),
        url: url,
        headers: [],
        policy: %{token: "test-only-private-principal"}
      )

    assert {:ok, _} = Session.open(session)
    assert :ok = Session.attach(session, self())
    refute inspect(:sys.get_status(session)) =~ "test-only-private-principal"

    assert {:error, :message_not_admitted} =
             GenServer.call(
               session,
               {:send, ~s({"type":"response.create","model":"m"}),
                System.monotonic_time(:millisecond) - 1}
             )

    message_limit = Limits.current().max_message_bytes

    assert {:error, :message_too_big} =
             Session.send(session, String.duplicate("x", message_limit + 1))

    assert :ok = Session.close(session)
    assert_receive :nothing_submitted
  end

  test "status formatting redacts retained credentials and message diagnostics" do
    secret = "test-only-sensitive-payload"

    status =
      Session.format_status(%{
        state: %{token: secret},
        message: {:send, secret},
        reason: {:badmatch, secret},
        log: [{:in, secret}]
      })

    refute inspect(status) =~ secret
    assert status.state == :redacted
    assert status.message == :redacted
    assert status.reason == :redacted
    assert status.log == []
  end

  test "upstream authentication precedes attachment and native events retain unknown fields" do
    {url, server} = upstream()
    parent = self()

    peer =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(server, 2_000)
        request = head(socket)
        assert request =~ ~r/^authorization: Bearer test-provider\r$/mi
        assert request =~ ~r/^session_id: test-session\r$/mi
        upgrade(socket, request, [{"retry-after", "2"}])
        text(socket, ~s({"type":"response.future","opaque":{"keep":true}}))
        send(parent, :event_sent)
        close_reply(socket)
      end)

    {:ok, session} =
      Session.start_link(
        owner: self(),
        url: url,
        headers: [{"authorization", "Bearer test-provider"}, {"session_id", "test-session"}],
        policy: %{}
      )

    assert {:ok, %{status: 101} = metadata} = Session.open(session)
    assert HTTP.Headers.get(metadata.headers, "retry-after") == "2"
    assert_receive :event_sent
    refute_receive {:responses_event, ^session, _, _}, 50
    assert :ok = Session.attach(session, self())
    assert_receive {:responses_event, ^session, bytes, ref}
    assert bytes == ~s({"type":"response.future","opaque":{"keep":true}})
    Session.ack(session, ref)
    assert :ok = Session.close(session)
    refute Process.alive?(session)
    monitor = Process.monitor(peer)
    assert_receive {:DOWN, ^monitor, :process, ^peer, _}
  end

  test "delivery credit preserves terminal events before a peer close" do
    {url, server} = upstream()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(server, 2_000)
      upgrade(socket, head(socket))
      text(socket, ~s({"type":"response.created"}))
      text(socket, ~s({"type":"response.completed"}))
      :gen_tcp.send(socket, <<0x88, 2, 1000::16>>)
      :gen_tcp.recv(socket, 0, 2_000)
      :gen_tcp.close(socket)
    end)

    {:ok, session} = Session.start_link(owner: self(), url: url, headers: [], policy: %{})
    assert {:ok, _} = Session.open(session)
    assert :ok = Session.attach(session, self())
    assert_receive {:responses_event, ^session, first, ref1}
    assert first == ~s({"type":"response.created"})
    refute_receive {:responses_event, ^session, _, _}, 50
    Session.ack(session, ref1)
    assert_receive {:responses_event, ^session, second, ref2}
    assert second == ~s({"type":"response.completed"})
    refute_receive {:responses_closed, ^session, _}, 50
    Session.ack(session, ref2)
    assert_receive {:responses_closed, ^session, 1000}
    assert :ok = Session.close(session)
  end

  test "rejected handshake returns safe status metadata without a downstream upgrade" do
    {url, server} = upstream()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(server, 2_000)
      head(socket)

      :gen_tcp.send(
        socket,
        "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 9\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      )

      :gen_tcp.close(socket)
    end)

    {:ok, session} = Session.start_link(owner: self(), url: url, headers: [], policy: %{})
    assert {:error, :upstream_handshake_failed, metadata} = Session.open(session)
    assert metadata.status == 429
    assert HTTP.Headers.get(metadata.headers, "retry-after") == "9"
  end

  test "duplicate selected metadata is rejected before attachment" do
    {url, server} = upstream()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(server, 2_000)
      upgrade(socket, head(socket), [{"retry-after", "1"}, {"retry-after", "2"}])
      close_reply(socket)
    end)

    {:ok, session} = Session.start_link(owner: self(), url: url, headers: [], policy: %{})
    assert {:error, :invalid_handshake_metadata, %{truncated?: true}} = Session.open(session)
  end

  test "owner death closes the upstream without a reconnect" do
    {url, server} = upstream()
    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(server, 2_000)
      upgrade(socket, head(socket))
      close_reply(socket)
      send(parent, {:reconnect, :gen_tcp.accept(server, 200)})
    end)

    owner =
      spawn(fn ->
        receive do
          {:open, session} ->
            send(parent, {:opened, Session.open(session)})

            receive do
              :stop -> :ok
            end
        end
      end)

    {:ok, session} = Session.start_link(owner: owner, url: url, headers: [], policy: %{})
    send(owner, {:open, session})
    assert_receive {:opened, {:ok, _}}, 2_000
    monitor = Process.monitor(session)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 3_000
    assert_receive {:reconnect, {:error, :timeout}}, 3_000
  end

  test "attachment transfers ownership from request to downstream" do
    {url, server} = upstream()
    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(server, 2_000)
      upgrade(socket, head(socket))
      close_reply(socket)
      send(parent, :peer_closed)
    end)

    request =
      spawn(fn ->
        receive do
          {:open, session} ->
            send(parent, {:opened, Session.open(session)})

            receive do
              :stop -> :ok
            end
        end
      end)

    {:ok, session} = Session.start_link(owner: request, url: url, headers: [], policy: %{})
    send(request, {:open, session})
    assert_receive {:opened, {:ok, _}}, 2_000

    downstream =
      spawn(fn ->
        send(parent, {:attached, Session.attach(session, self())})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:attached, :ok}
    Process.exit(request, :kill)
    refute_receive :peer_closed, 50
    assert Process.alive?(session)
    monitor = Process.monitor(session)
    Process.exit(downstream, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 3_000
    assert_receive :peer_closed, 3_000
  end

  test "Limits defaults support 128 MiB local policy while preserving independent structural caps and overrides" do
    defaults = Limits.defaults()
    assert defaults.max_message_bytes == 134_217_728
    assert defaults.max_bytes == 134_217_728
    assert defaults.max_string_bytes == 134_217_728
    assert defaults.max_depth == 320
    assert defaults.max_map_entries == 5_120
    assert defaults.max_list_length == 40_960
    assert defaults.max_nodes == 327_680
    assert defaults.max_response_ids == 20_480
    assert defaults.max_lifetime_ms == :infinity
    assert defaults.downstream_read_timeout_ms == :infinity

    # Lower partial override caps implicit string/aggregate defaults while keeping explicit overrides.
    lower = Limits.merge(%{max_message_bytes: 4_096})
    assert lower.max_message_bytes == 4_096
    assert lower.max_bytes == 4_096
    assert lower.max_string_bytes == 4_096
    assert lower.max_nodes == 327_680

    partial = Limits.merge(%{max_message_bytes: 4_096, max_string_bytes: 1_024})
    assert partial.max_string_bytes == 1_024
    assert partial.max_bytes == 4_096
  end

  test "parse_handshake reads x-codex-websocket-max-message-bytes case-insensitively and ignores control-socket header" do
    local = 134_217_728

    # Peer limit below local cap -> min(peer, local)
    assert {:ok, %{protocol: ""}, 4_096} =
             Session.parse_handshake(
               %{
                 status: 101,
                 truncated?: false,
                 headers: HTTP.Headers.new([{"X-Codex-WebSocket-Max-Message-Bytes", "4096"}])
               },
               "",
               local
             )

    # Peer limit above local cap -> clamped to local cap
    assert {:ok, %{protocol: ""}, ^local} =
             Session.parse_handshake(
               %{
                 status: 101,
                 truncated?: false,
                 headers: HTTP.Headers.new([{"x-codex-websocket-max-message-bytes", "999999999"}])
               },
               "",
               local
             )

    # Missing peer metadata -> local policy
    assert {:ok, %{protocol: ""}, ^local} =
             Session.parse_handshake(
               %{status: 101, truncated?: false, headers: HTTP.Headers.new([])},
               "",
               local
             )

    # Control-socket header alone is NOT a Responses limit
    assert {:ok, %{protocol: ""}, ^local} =
             Session.parse_handshake(
               %{
                 status: 101,
                 truncated?: false,
                 headers:
                   HTTP.Headers.new([{"x-codex-websocket-max-unfragmented-message-bytes", "64"}])
               },
               "",
               local
             )

    # Conflicting Responses and control-socket headers -> Responses header wins
    assert {:ok, %{protocol: ""}, 8_192} =
             Session.parse_handshake(
               %{
                 status: 101,
                 truncated?: false,
                 headers:
                   HTTP.Headers.new([
                     {"x-codex-websocket-max-unfragmented-message-bytes", "64"},
                     {"x-codex-websocket-max-message-bytes", "8192"}
                   ])
               },
               "",
               local
             )

    # Malformed values rejected
    for bad <- ["0", "-10", "abc", "1024b", "", " 1024"] do
      assert {:error, :invalid_peer_message_limit} =
               Session.parse_handshake(
                 %{
                   status: 101,
                   truncated?: false,
                   headers: HTTP.Headers.new([{"x-codex-websocket-max-message-bytes", bad}])
                 },
                 "",
                 local
               )
    end

    # Duplicate Responses headers rejected
    assert {:error, :invalid_peer_message_limit} =
             Session.parse_handshake(
               %{
                 status: 101,
                 truncated?: false,
                 headers:
                   HTTP.Headers.new([
                     {"x-codex-websocket-max-message-bytes", "1024"},
                     {"x-codex-websocket-max-message-bytes", "2048"}
                   ])
               },
               "",
               local
             )

    # Truncated metadata rejected
    assert {:error, :invalid_handshake_metadata} =
             Session.parse_handshake(
               %{status: 101, truncated?: true, headers: HTTP.Headers.new([])},
               "",
               local
             )
  end

  test "upstream ping/pong keeps quiet connection alive and closes unresponsive upstream peer" do
    {url, server} = upstream()
    parent = self()

    # Responsive upstream peer: answers Ping with Pong.
    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(server, 2_000)
      upgrade(socket, head(socket))
      pong_loop(socket, parent, true)
    end)

    limits =
      Limits.merge(%{
        upstream_ping_interval_ms: 40,
        upstream_pong_timeout_ms: 150,
        upstream_idle_timeout_ms: :infinity
      })

    {:ok, session} =
      Session.start_link(owner: self(), url: url, headers: [], policy: %{}, limits: limits)

    assert {:ok, _} = Session.open(session)
    assert :ok = Session.attach(session, self())
    assert_receive :upstream_ping_received, 500
    assert_receive :upstream_ping_received, 500
    refute_receive {:responses_closed, ^session, _}, 50
    assert :ok = Session.close(session)

    # Unresponsive upstream peer: ignores Ping -> gateway closes within pong timeout.
    {dead_url, dead_server} = upstream()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(dead_server, 2_000)
      upgrade(socket, head(socket))
      pong_loop(socket, parent, false)
    end)

    dead_limits =
      Limits.merge(%{
        upstream_ping_interval_ms: 40,
        upstream_pong_timeout_ms: 100,
        upstream_idle_timeout_ms: :infinity
      })

    {:ok, dead_session} =
      Session.start_link(
        owner: self(),
        url: dead_url,
        headers: [],
        policy: %{},
        limits: dead_limits
      )

    assert {:ok, _} = Session.open(dead_session)
    assert :ok = Session.attach(dead_session, self())
    assert_receive :upstream_ping_received, 500
    assert_receive {:responses_closed, ^dead_session, 1011}, 1_000
    assert :ok = Session.close(dead_session)
  end

  test "slow downstream ACK expires delivery and closes session cleanly" do
    {url, server} = upstream()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(server, 2_000)
      upgrade(socket, head(socket))
      text(socket, ~s({"type":"response.created","response":{"id":"resp_slow_ack"}}))
      close_reply(socket)
    end)

    limits =
      Limits.merge(%{
        delivery_ack_timeout_ms: 80,
        close_timeout_ms: 100,
        upstream_ping_interval_ms: :infinity
      })

    {:ok, session} =
      Session.start_link(owner: self(), url: url, headers: [], policy: %{}, limits: limits)

    assert {:ok, _} = Session.open(session)
    assert :ok = Session.attach(session, self())
    assert_receive {:responses_event, ^session, _, _ref}, 1_000
    # Deliberately omit Session.ack/2 so delivery_ack_timeout_ms expires.
    monitor = Process.monitor(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
  end

  test "reassembles fragmented multi-frame upstream text messages cleanly in proxy mode" do
    {url, server} = upstream()
    part1 = ~s({"type":"response.created","res)
    part2 = ~s(ponse":{"id":"resp_frag_1"}})
    full = part1 <> part2

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(server, 2_000)
      upgrade(socket, head(socket))
      # FIN=0 text frame (0x01) followed by FIN=1 continuation frame (0x80)
      :gen_tcp.send(socket, [<<0x01, byte_size(part1)>>, part1])
      :gen_tcp.send(socket, [<<0x80, byte_size(part2)>>, part2])
      close_reply(socket)
    end)

    limits = Limits.merge(%{upstream_ping_interval_ms: :infinity})

    {:ok, session} =
      Session.start_link(owner: self(), url: url, headers: [], policy: %{}, limits: limits)

    assert {:ok, _} = Session.open(session)
    assert :ok = Session.attach(session, self())
    assert_receive {:responses_event, ^session, ^full, ref}, 1_000
    assert :ok = Session.ack(session, ref)
    assert :ok = Session.close(session)
  end

  defp pong_loop(socket, parent, reply?) do
    case :gen_tcp.recv(socket, 2, 2_000) do
      {:ok, <<_fin::1, _rsv::3, 9::4, 1::1, len::7>>} when len <= 125 ->
        {:ok, mask} = :gen_tcp.recv(socket, 4, 2_000)
        {:ok, payload} = if len == 0, do: {:ok, <<>>}, else: :gen_tcp.recv(socket, len, 2_000)
        unmasked = unmask(payload, mask)
        send(parent, :upstream_ping_received)
        if reply?, do: :gen_tcp.send(socket, [<<0x8A, byte_size(unmasked)>>, unmasked])
        pong_loop(socket, parent, reply?)

      {:ok, <<_fin::1, _rsv::3, 8::4, _rest::binary>>} ->
        :gen_tcp.send(socket, <<0x88, 2, 1000::16>>)
        :gen_tcp.close(socket)

      _ ->
        :gen_tcp.close(socket)
    end
  end

  defp unmask(payload, mask) do
    for {byte, idx} <- Enum.with_index(:binary.bin_to_list(payload)), into: <<>> do
      <<Bitwise.bxor(byte, :binary.at(mask, rem(idx, 4)))>>
    end
  end

  defp upstream do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {"ws://127.0.0.1:#{port}/v1/responses", listener}
  end

  defp head(socket, bytes \\ "") do
    if String.ends_with?(bytes, "\r\n\r\n") do
      bytes
    else
      {:ok, byte} = :gen_tcp.recv(socket, 1, 2_000)
      head(socket, bytes <> byte)
    end
  end

  defp upgrade(socket, request, headers \\ []) do
    [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)/i, request)
    accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()
    extras = Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)

    :gen_tcp.send(socket, [
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n",
      extras,
      "\r\n"
    ])
  end

  defp text(socket, bytes), do: :gen_tcp.send(socket, [<<0x81, byte_size(bytes)>>, bytes])

  defp close_reply(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, <<0x88, _rest::binary>>} -> :gen_tcp.send(socket, <<0x88, 2, 1000::16>>)
      {:error, :closed} -> :ok
    end

    :gen_tcp.close(socket)
  end
end
