defmodule Backplane.LLM.ResponsesWebSocket.SessionTest do
  use ExUnit.Case, async: false

  alias Backplane.LLM.{ModelResolver, Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.LLM.ResponsesWebSocket.{Limits, Policy, Session}
  alias Backplane.Settings.Credentials
  alias HTTP.WebSocket

  test "allows the Codex default send window for the first create" do
    {:ok, session} = Session.start_link(owner: self())

    assert :ok = Session.attach(session, self())
    assert %{first_create_timer: timer} = :sys.get_state(session)
    assert Process.read_timer(timer) in 290_000..300_000

    assert :ok = Session.close(session)
  end

  test "correlates bounded named submissions rejected before decoding" do
    {:ok, session} = Session.start_link(owner: self())
    assert :ok = Session.attach(session, self())
    expired = System.monotonic_time(:millisecond) - 1
    create = %{"type" => "response.create", "model" => "model", "stream_id" => "lane-1"}

    for {params, expected_metadata} <- [
          {create, %{stream_id: "lane-1"}},
          {%{create | "stream_id" => "invalid lane"}, nil},
          {Map.put(create, "input", String.duplicate("a", 16_384)), nil}
        ] do
      ref = make_ref()
      Session.submit(session, ref, Formata.JSON.encode!(params), expired)

      assert_receive {:responses_submit_result, ^session, ^ref,
                      {:reject_request, 408, "submission_expired", ^expected_metadata}}
    end

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

  @tag :responses_peer_limit
  test "real upstream handshakes enforce valid and invalid Responses peer metadata" do
    responses_header = "x-codex-websocket-max-message-bytes"
    mixed_case_header = "X-Codex-WebSocket-Max-Message-Bytes"
    control_header = "x-codex-websocket-max-unfragmented-message-bytes"

    for {headers, expected} <- [
          {[{mixed_case_header, "96"}, {control_header, "17"}], {:ok, 96}},
          {[{responses_header, "256"}], {:ok, 128}},
          {[], {:ok, 128}},
          {[{control_header, "17"}], {:ok, 128}},
          {[{responses_header, "-1"}], {:error, :invalid_peer_message_limit, false}},
          {[{responses_header, "96 bytes"}], {:error, :invalid_peer_message_limit, false}},
          {[{mixed_case_header, "96"}, {responses_header, "97"}],
           {:error, :invalid_handshake_metadata, true}},
          {[{responses_header, :binary.copy("9", 1025)}],
           {:error, :invalid_handshake_metadata, true}}
        ] do
      {url, server} = upstream()

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(server, 2_000)
        upgrade(socket, head(socket), headers)
        close_reply(socket)
      end)

      {:ok, session} =
        Session.start_link(
          owner: self(),
          url: url,
          headers: [],
          policy: %{},
          limits: Limits.merge(%{max_message_bytes: 128})
        )

      case expected do
        {:ok, limit} ->
          assert {:ok, %{status: 101, truncated?: false}} = Session.open(session)
          assert %{max_outbound: ^limit} = :sys.get_state(session)
          assert :ok = Session.close(session)

        {:error, reason, truncated?} ->
          assert {:error, ^reason, %{status: 101, truncated?: ^truncated?}} =
                   Session.open(session)
      end
    end
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
      pong_loop(socket, parent, :mismatch)
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
    assert %{close_info: %{cause: "upstream_pong_timeout"}} = :sys.get_state(dead_session)
    assert :ok = Session.close(dead_session)
  end

  for {name, count} <- [{"delivery FIFO", 2}, {"parser and socket read pause", 18}] do
    test "matching upstream Pong survives #{name} backpressure" do
      count = unquote(count)
      {url, server} = upstream()
      parent = self()
      events = for n <- 1..count, do: ~s({"type":"response.future","sequence":#{n}})
      policy = heartbeat_policy()

      peer =
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(server, 2_000)
          upgrade(socket, head(socket))
          assert_receive :send_events, 2_000
          :ok = :gen_tcp.send(socket, Enum.map(events, &text_frame/1))
          {9, ping} = client_frame(socket)
          :ok = :gen_tcp.send(socket, [<<0x8A, byte_size(ping)>>, ping])
          send(parent, :pong_written)
          assert {1, bytes} = client_frame(socket, read_text?: true)

          assert %{"type" => "response.create", "model" => "heartbeat-model"} =
                   Formata.JSON.decode!(bytes)

          :ok = text(socket, ~s({"type":"response.future","sequence":"tail"}))
          pong_loop(socket, parent, true)
        end)

      {session, socket} =
        start_heartbeat_session(url, upstream_ping_interval_ms: 200, policy: policy)

      send(peer, :send_events)
      [first, second | rest] = events
      assert_receive {:responses_event, ^session, ^first, first_ref}

      assert eventually(fn ->
               status = WebSocket.status(socket)

               if count == 2,
                 do: status.queued_events == 2 and status.raw_bytes == 0,
                 else: status.queued_events == 16 and status.raw_bytes > 0
             end)

      assert_receive :pong_written, 1_000
      refute_receive {:responses_event, ^session, _, _}, 70
      Session.ack(session, first_ref)
      assert_receive {:responses_event, ^session, ^second, second_ref}
      refute_receive {:responses_event, ^session, _, _}, 70
      Session.ack(session, second_ref)

      Enum.each(rest, fn bytes ->
        assert_receive {:responses_event, ^session, ^bytes, ref}
        Session.ack(session, ref)
      end)

      assert :ok =
               Session.send(
                 session,
                 ~s({"type":"response.create","model":"heartbeat/heartbeat-model"})
               )

      tail = ~s({"type":"response.future","sequence":"tail"})
      assert_receive {:responses_event, ^session, ^tail, tail_ref}
      Session.ack(session, tail_ref)
      assert_receive :upstream_ping_received, 1_000
      assert eventually(fn -> :sys.get_state(session).upstream_ping == nil end)
      refute_received {:responses_closed, ^session, _}
      refute_received {:responses_event, ^session, _, _}
      assert :ok = Session.close(session)
    end
  end

  for outcome <- [:write_completes, :write_times_out] do
    test "upstream Ping waits for its queued write: #{outcome}" do
      outcome = unquote(outcome)
      {url, server} = upstream(recbuf: 4_096)
      parent = self()
      payload = :binary.copy("x", 256 * 1_024)

      peer =
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(server, 2_000)
          upgrade(socket, head(socket))

          receive do
            :drain ->
              :ok = :inet.setopts(socket, recbuf: 256 * 1_024)
              assert {1, _} = client_frame(socket)
              assert {1, _} = client_frame(socket)
              {9, ping} = client_frame(socket)
              :ok = :gen_tcp.send(socket, [<<0x8A, byte_size(ping)>>, ping])
              send(parent, :pong_written)
              pong_loop(socket, parent, true)

            :stop ->
              :gen_tcp.close(socket)
          after
            2_000 -> :gen_tcp.close(socket)
          end
        end)

      {session, socket} =
        start_heartbeat_session(url,
          upstream_ping_interval_ms: 150,
          upstream_pong_timeout_ms: 100,
          write_timeout_ms: 1_200,
          socket_opts: [sndbuf: 4_096, high_watermark: 4_096, low_watermark: 2_048]
        )

      # The first frame fills the TCP driver's queue. A second write blocks on
      # that queue until the peer reads, leaving the Ping behind it in HTTP.WebSocket.
      assert {:ok, _} = WebSocket.send_frame_ack(socket, {:text, payload})
      assert eventually(fn -> WebSocket.status(socket).pending_send_frames == 0 end)
      assert {:ok, _} = WebSocket.send_frame_ack(socket, {:text, :binary.copy("y", 16 * 1_024)})

      assert eventually(fn -> WebSocket.status(socket).pending_send_frames == 2 end),
             inspect(WebSocket.status(socket))

      refute_receive {:responses_closed, ^session, _}, 140
      assert WebSocket.status(socket).pending_send_frames == 2

      assert_queued_write_outcome(outcome, session, peer)
      assert :ok = Session.close(session)
    end
  end

  test "continuously replenished receive backlog has an absolute heartbeat deadline" do
    {url, server} = upstream()
    parent = self()
    frame = text_frame(~s({"type":"response.future"}))

    peer =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(server, 2_000)
        upgrade(socket, head(socket))
        assert_receive :send_backlog
        :ok = :gen_tcp.send(socket, List.duplicate(frame, 70))
        {9, ping} = client_frame(socket)
        :ok = :gen_tcp.send(socket, [<<0x8A, byte_size(ping)>>, ping])
        send(parent, :pong_written)
        pong_loop(socket, parent, true)
      end)

    {session, socket} =
      start_heartbeat_session(url,
        upstream_ping_interval_ms: 50,
        upstream_pong_timeout_ms: 40,
        delivery_ack_timeout_ms: 110
      )

    send(peer, :send_backlog)
    assert_receive :pong_written
    assert eventually(fn -> WebSocket.status(socket).raw_bytes > 0 end)

    assert {:closed, delivered} = acknowledge_until_closed(session, 0)
    assert delivered in 17..69

    assert %{close_info: %{cause: "upstream_receive_backpressure_timeout"}} =
             :sys.get_state(session)

    assert :ok = GenServer.stop(session, :normal, 5_000)
    assert :ok = HTTP.ClientCompletion.await(WebSocket.completion(socket), 500)
  end

  defp acknowledge_until_closed(session, delivered) do
    receive do
      {:responses_closed, ^session, 1011} ->
        {:closed, delivered}

      {:responses_event, ^session, _bytes, ref} when delivered < 70 ->
        Process.sleep(40)
        Session.ack(session, ref)
        acknowledge_until_closed(session, delivered + 1)
    after
      300 -> :heartbeat_deadline_not_observed
    end
  end

  test "slow downstream ACK expires delivery and closes session cleanly" do
    {url, server} = upstream()
    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(server, 2_000)
      upgrade(socket, head(socket))
      text(socket, ~s({"type":"response.created","response":{"id":"resp_slow_ack"}}))
      pong_loop(socket, parent, true)
    end)

    {session, socket} =
      start_heartbeat_session(url,
        delivery_ack_timeout_ms: 240,
        upstream_ping_interval_ms: 30,
        upstream_pong_timeout_ms: 50
      )

    assert_receive {:responses_event, ^session, _, _ref}, 1_000
    monitor = Process.monitor(session)
    assert_receive :upstream_ping_received
    refute_receive {:responses_closed, ^session, _}, 100
    assert %{close_info: nil} = :sys.get_state(session)
    # No ACK: the delivery watchdog owns closing this stalled session.
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 3_000
    assert :ok = HTTP.ClientCompletion.await(WebSocket.completion(socket), 500)
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

  defp pong_loop(socket, parent, reply) do
    case client_frame(socket) do
      {9, unmasked} ->
        send(parent, :upstream_ping_received)
        pong = if reply == :mismatch, do: "wrong-pong", else: unmasked
        :gen_tcp.send(socket, [<<0x8A, byte_size(pong)>>, pong])
        pong_loop(socket, parent, reply)

      {8, _payload} ->
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

  defp client_frame(socket, opts \\ []) do
    with {:ok, <<1::1, 0::3, opcode::4, 1::1, size::7>>} <- :gen_tcp.recv(socket, 2, 2_000) do
      read_client_frame_payload(socket, opcode, size, opts)
    end
  end

  defp read_client_frame_payload(socket, opcode, size, opts) do
    bytes =
      case size do
        126 ->
          {:ok, <<bytes::16>>} = :gen_tcp.recv(socket, 2, 2_000)
          bytes

        127 ->
          {:ok, <<bytes::64>>} = :gen_tcp.recv(socket, 8, 2_000)
          bytes

        bytes ->
          bytes
      end

    {:ok, <<mask::binary-4, data::binary>>} = :gen_tcp.recv(socket, bytes + 4, 2_000)
    {opcode, if(opcode == 1 and !opts[:read_text?], do: :text, else: unmask(data, mask))}
  end

  defp start_heartbeat_session(url, overrides) do
    {socket_opts, overrides} = Keyword.pop(overrides, :socket_opts, [])
    {policy, overrides} = Keyword.pop(overrides, :policy, %{})

    limits =
      %{upstream_pong_timeout_ms: 100, delivery_ack_timeout_ms: 500, close_timeout_ms: 100}
      |> Map.merge(Map.new(overrides))
      |> Limits.merge()

    {:ok, session} =
      Session.start_link(
        owner: self(),
        url: url,
        headers: [],
        policy: policy,
        limits: limits,
        socket_opts: socket_opts
      )

    assert {:ok, _} = Session.open(session)
    assert :ok = Session.attach(session, self())
    %{socket: socket} = :sys.get_state(session)
    {session, socket}
  end

  defp heartbeat_policy do
    BackplaneDataCase.setup_sandbox(Backplane.Repo, %{async: false})
    {:ok, credential} = Credentials.store("heartbeat-key", "test-loopback-key", "llm")
    {:ok, provider} = Provider.create(%{name: "heartbeat", credential: credential.name})

    on_exit(fn ->
      ModelResolver.clear_cache()
      Backplane.Settings.Credentials.Vault.remove(credential.name)
    end)

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://127.0.0.1:1",
        native_protocols: [:openai_responses],
        responses_websocket: true
      })

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: "heartbeat-model", source: :manual})

    {:ok, _} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    ModelResolver.clear_cache()
    {:ok, route} = Policy.resolve("heartbeat/heartbeat-model")

    {:ok, policy} =
      Policy.pin(route, %Plug.Conn{assigns: %{resource_auth: %{kind: :open}}}, credential)

    policy
  end

  defp assert_queued_write_outcome(:write_completes, session, peer) do
    send(peer, :drain)
    assert_receive :pong_written, 1_000
    assert_receive :upstream_ping_received, 1_000
    assert eventually(fn -> :sys.get_state(session).upstream_ping == nil end)
    refute_received {:responses_closed, ^session, _}
  end

  defp assert_queued_write_outcome(:write_times_out, session, peer) do
    assert_receive {:responses_closed, ^session, 1011}, 1_500
    assert %{close_info: %{cause: "upstream_write_timeout"}} = :sys.get_state(session)
    send(peer, :stop)
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(2)
      eventually(fun, attempts - 1)
    end
  end

  defp upstream(opts \\ []) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}] ++ opts)

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

  defp text(socket, bytes), do: :gen_tcp.send(socket, text_frame(bytes))
  defp text_frame(bytes), do: [<<0x81, byte_size(bytes)>>, bytes]

  defp close_reply(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, <<0x88, _rest::binary>>} -> :gen_tcp.send(socket, <<0x88, 2, 1000::16>>)
      {:error, :closed} -> :ok
    end

    :gen_tcp.close(socket)
  end
end
