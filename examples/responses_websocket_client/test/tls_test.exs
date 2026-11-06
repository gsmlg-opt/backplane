defmodule Backplane.ResponsesWebSocket.TLSTest do
  use ExUnit.Case, async: false
  alias Backplane.ResponsesWebSocket.Client

  @cert Path.expand("fixtures/tls/cert.pem", __DIR__) |> String.to_charlist()
  @ca Path.expand("fixtures/tls/ca.pem", __DIR__) |> String.to_charlist()
  @key Path.expand("fixtures/tls/key.pem", __DIR__) |> String.to_charlist()

  setup do
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  test "WSS verifies a caller-selected trust anchor and sends native messages" do
    owner = self()
    {port, listener} = listen()

    server =
      spawn_link(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 3000)
        {:ok, socket} = :ssl.handshake(socket, 3000)
        request = head(socket)
        assert request =~ "GET /v1/responses"
        assert request =~ ~r/^authorization: Bearer tls-test-only\r$/mi
        [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)/i, request)

        accept =
          :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

        :ok =
          :ssl.send(
            socket,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
          )

        # Read the masked native client message, then send a complete provider event.
        {:ok, <<0x81, 1::1, length::7>>} = :ssl.recv(socket, 2, 3000)
        assert length < 126

        {:ok, <<mask::binary-size(4), payload::binary-size(length)>>} =
          :ssl.recv(socket, 4 + length, 3000)

        bytes =
          for {byte, index} <- Enum.with_index(:binary.bin_to_list(payload)), into: <<>> do
            <<Bitwise.bxor(byte, :binary.at(mask, rem(index, 4)))>>
          end

        assert %{"type" => "response.create", "model" => "m"} = Jason.decode!(bytes)
        event = ~s({"type":"response.completed","response":{"id":"tls-r1"}})
        :ok = :ssl.send(socket, [<<0x81, byte_size(event)>>, event])
        # The peer may close immediately after its terminal event. No cancellation inferred.
        :ssl.close(socket)
        send(owner, {:tls_done, self()})
      end)

    assert {:ok, client, %{status: 101}} =
             Client.open(
               "wss://localhost:#{port}/v1/responses",
               [{"authorization", "Bearer tls-test-only"}],
               connect_address: {127, 0, 0, 1},
               ssl: [cacertfile: @ca, verify: :verify_peer]
             )

    assert :ok = Client.create(client, %{"model" => "m"})
    assert {:ok, %{"response" => %{"id" => "tls-r1"}}} = Client.next_event(client)
    assert :ok = Client.close(client)
    assert_receive {:tls_done, ^server}, 1000
  end

  test "trusted certificate with the wrong endpoint identity fails before HTTP credentials" do
    {port, listener} = listen()
    owner = self()

    spawn_link(fn ->
      {:ok, socket} = :ssl.transport_accept(listener, 3000)
      result = :ssl.handshake(socket, 3000)

      case result do
        {:ok, secure} ->
          send(owner, {:http_bytes, :ssl.recv(secure, 0, 1000)})
          :ssl.close(secure)

        {:error, _} ->
          send(owner, :tls_rejected)
      end
    end)

    assert {:error, :handshake_failed, nil, :ok} =
             Client.open(
               "wss://127.0.0.1:#{port}/v1/responses",
               [{"authorization", "Bearer must-not-send"}],
               ssl: [cacertfile: @ca, verify: :verify_peer]
             )

    receive do
      :tls_rejected -> :ok
      {:http_bytes, result} -> assert match?({:error, _}, result)
    after
      2000 -> flunk("TLS peer did not observe rejected identity")
    end
  end

  defp listen do
    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        certfile: @cert,
        keyfile: @key,
        versions: [:"tlsv1.3"]
      ])

    on_exit(fn -> :ssl.close(listener) end)
    {:ok, {_, port}} = :ssl.sockname(listener)
    {port, listener}
  end

  defp head(socket, bytes \\ "") do
    if String.ends_with?(bytes, "\r\n\r\n") do
      bytes
    else
      {:ok, byte} = :ssl.recv(socket, 1, 3000)
      head(socket, bytes <> byte)
    end
  end
end
