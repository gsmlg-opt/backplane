defmodule Backplane.ResponsesWebSocket.ClientTest do
  use ExUnit.Case, async: false
  alias Backplane.ResponsesWebSocket.Client

  test "authenticated handshake, native request, bounded metadata and local cleanup" do
    {url, server} =
      upstream(fn socket, owner, request ->
        assert request =~ ~r/^authorization: Bearer test-only-key\r$/mi
        assert request =~ ~r/^session_id: test-session\r$/mi

        upgrade(socket, request, [
          {"retry-after", "2"},
          {"x-codex-websocket-max-unfragmented-message-bytes", "4096"},
          {"x-session-routing", "not-exposed"},
          {"set-cookie", "not-exposed"}
        ])

        {1, bytes} = frame(socket)
        send(owner, {:submitted, Jason.decode!(bytes)})
        text(socket, ~s({"type":"response.completed","response":{"id":"r1"}}))
        echo_close(socket)
      end)

    assert {:ok, client, metadata} =
             Client.open(url, [
               {"authorization", "Bearer test-only-key"},
               {"session_id", "test-session"}
             ])

    assert metadata.status == 101
    assert HTTP.Headers.get(metadata.headers, "retry-after") == "2"
    assert HTTP.Headers.get(metadata.headers, "x-session-routing") == nil
    assert HTTP.Headers.get(metadata.headers, "set-cookie") == nil
    refute inspect(client) =~ "test-only-key"
    assert {:error, :receive_timeout} = Client.next_event(client, 0)

    assert Task.async(fn -> Client.create(client, %{"model" => "m"}) end) |> Task.await() ==
             {:error, :wrong_owner}

    assert :ok = Client.create(client, %{"model" => "m", "input" => "hello"})
    assert_receive {:submitted, %{"type" => "response.create", "input" => "hello"}}, 1000
    assert {:ok, %{"type" => "response.completed"}} = Client.next_event(client)
    assert :ok = Client.close(client)
    assert_receive {:server_done, ^server}, 1000
  end

  test "rejected handshake exposes selected metadata and cleans up" do
    {url, _server} =
      upstream(fn socket, _owner, _request ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 7\r\nSet-Cookie: secret\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
      end)

    assert {:error, :handshake_failed, metadata, :ok} = Client.open(url)
    assert metadata.status == 429
    assert HTTP.Headers.get(metadata.headers, "retry-after") == "7"
    assert HTTP.Headers.get(metadata.headers, "set-cookie") == nil
  end

  test "duplicate and oversized selected handshake headers are reported as truncated" do
    {url, _server} =
      upstream(fn socket, _owner, request ->
        upgrade(socket, request, [
          {"retry-after", "1"},
          {"retry-after", "2"},
          {"x-codex-websocket-max-unfragmented-message-bytes", String.duplicate("1", 1025)}
        ])

        echo_close(socket)
      end)

    assert {:error, :handshake_metadata_truncated, metadata, :ok} = Client.open(url)
    assert metadata.truncated?
    assert HTTP.Headers.get(metadata.headers, "retry-after") == nil

    assert HTTP.Headers.get(metadata.headers, "x-codex-websocket-max-unfragmented-message-bytes") ==
             nil
  end

  test "advertised peer message limit rejects oversize sends before submission" do
    {url, _server} =
      upstream(fn socket, _owner, request ->
        upgrade(socket, request, [{"x-codex-websocket-max-unfragmented-message-bytes", "64"}])
        # Only a Close frame is permitted; an application send would fail this fixture.
        echo_close(socket)
      end)

    assert {:ok, client, _} = Client.open(url)

    assert {:error, :message_exceeds_peer_limit} =
             Client.create(client, %{"model" => "m", "input" => String.duplicate("a", 100)})

    assert :ok = Client.close(client)
  end

  test "disconnect after submission never reconnects or replays" do
    owner = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      request = head(socket)
      upgrade(socket, request)
      {1, _body} = frame(socket)
      :gen_tcp.close(socket)
      send(owner, {:reconnect, :gen_tcp.accept(listener, 250)})
    end)

    assert {:ok, client, _} = Client.open("ws://127.0.0.1:#{port}/v1/responses")
    assert :ok = Client.create(client, %{"model" => "m"})
    assert {:error, :transport_failed, :ok} = Client.next_event(client)
    assert_receive {:reconnect, {:error, :timeout}}, 1000
  end

  test "owner death closes transport and seals the retained cleanup receipt" do
    parent = self()

    {url, _server} =
      upstream(fn socket, owner, request ->
        upgrade(socket, request)
        send(owner, {:peer_closed, :gen_tcp.recv(socket, 0, 3000)})
      end)

    owner =
      spawn(fn ->
        {:ok, client, _} = Client.open(url)
        send(parent, {:receipt, Client.completion(client)})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:receipt, receipt}, 1000
    Process.exit(owner, :kill)
    assert :ok = HTTP.ClientCompletion.await(receipt, 3000)
    assert_receive {:peer_closed, {:error, :closed}}, 1000
  end

  test "declared oversized frame fails without waiting for its payload" do
    {url, _server} =
      upstream(fn socket, _owner, request ->
        upgrade(socket, request)
        :gen_tcp.send(socket, <<0x81, 126, 200::16>>)
        # A local protocol close may follow; no application payload is sent.
        :gen_tcp.recv(socket, 0, 2000)
      end)

    assert {:ok, client, _} = Client.open(url, [], max_message_size: 1024, max_frame_bytes: 128)
    assert {:error, :transport_failed, :ok} = Client.next_event(client)
  end

  test "invalid endpoints and HTTP-only request controls are rejected locally" do
    for url <- [
          "https://example.com/v1/responses",
          "ws://secret@example.com/",
          "ws://example.com/#fragment",
          nil
        ] do
      assert {:error, :invalid_endpoint} = Client.open(url)
    end

    {url, _server} =
      upstream(fn socket, _owner, request ->
        upgrade(socket, request)
        echo_close(socket)
      end)

    assert {:ok, client, _} = Client.open(url)

    assert {:error, %Backplane.AiProtocol.Error{}} =
             Client.create(client, %{"model" => "m", "background" => true})

    assert :ok = Client.close(client)
  end

  defp upstream(fun) do
    owner = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        fun.(socket, owner, head(socket))
        :gen_tcp.close(socket)
        send(owner, {:server_done, self()})
      end)

    {"ws://127.0.0.1:#{port}/v1/responses", server}
  end

  defp head(socket, buffer \\ "") do
    if String.ends_with?(buffer, "\r\n\r\n") do
      buffer
    else
      {:ok, byte} = :gen_tcp.recv(socket, 1, 3000)
      head(socket, buffer <> byte)
    end
  end

  defp upgrade(socket, request, headers \\ []) do
    [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)/i, request)
    accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()
    extras = Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end)

    :gen_tcp.send(socket, [
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n",
      extras,
      "\r\n"
    ])
  end

  defp frame(socket) do
    {:ok, <<_fin::1, _rsv::3, opcode::4, 1::1, length::7>>} = :gen_tcp.recv(socket, 2, 3000)

    length =
      case length do
        126 ->
          {:ok, <<n::16>>} = :gen_tcp.recv(socket, 2, 3000)
          n

        n when n < 126 ->
          n
      end

    {:ok, mask} = :gen_tcp.recv(socket, 4, 3000)
    payload = if length == 0, do: <<>>, else: elem(:gen_tcp.recv(socket, length, 3000), 1)

    decoded =
      for {byte, index} <- Enum.with_index(:binary.bin_to_list(payload)), into: <<>> do
        <<Bitwise.bxor(byte, :binary.at(mask, rem(index, 4)))>>
      end

    {opcode, decoded}
  end

  defp text(socket, bytes), do: :gen_tcp.send(socket, [<<0x81, byte_size(bytes)>>, bytes])

  defp echo_close(socket) do
    {8, bytes} = frame(socket)
    :gen_tcp.send(socket, [<<0x88, byte_size(bytes)>>, bytes])
  end
end
