defmodule Backplane.LLM.ResponsesWebSocket.SessionTest do
  use ExUnit.Case, async: false

  alias Backplane.LLM.ResponsesWebSocket.Session

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

    assert {:error, :message_too_big} = Session.send(session, String.duplicate("x", 2_097_153))
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
