defmodule Relayixir.Proxy.HTTPSProxyTest do
  use ExUnit.Case, async: true

  alias Relayixir.Proxy.{HttpClient, Upstream}

  @certfile Path.expand("../../fixtures/tls/localhost-cert.pem", __DIR__)
  @keyfile Path.expand("../../fixtures/tls/localhost-key.pem", __DIR__)
  @cafile Path.expand("../../fixtures/tls/ca-cert.pem", __DIR__)

  test "trusted TLS proxy receives an authenticated absolute target and preserves compressed bytes" do
    compressed = :zlib.gzip("data: raw proxy response\n\n")
    {listener, proxy_port} = tls_listener()

    proxy =
      Task.async(fn ->
        {:ok, transport} = :ssl.transport_accept(listener, 2_000)
        {:ok, socket} = :ssl.handshake(transport, 2_000)

        try do
          request = read_request(:ssl, socket)

          :ok =
            :ssl.send(socket, [
              "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n",
              "Content-Length: #{byte_size(compressed)}\r\nConnection: close\r\n\r\n",
              compressed
            ])

          request
        after
          :ssl.close(socket)
        end
      end)

    upstream = upstream("origin.invalid", 80)

    {:ok, client} =
      HttpClient.connect(upstream, %{
        "HTTP_PROXY" => "https://user:secret@localhost:#{proxy_port}"
      })

    client = trust_local_certificate(client)

    {:ok, client, _ref} =
      HttpClient.send_request(client, "POST", "/mutate?raw=1", [], "mutation entity")

    try do
      assert %HTTP.Response{} = response = Task.await(client.promise.task, 2_000)
      client = %{client | response: response}
      assert {:ok, client, events} = HttpClient.recv_response(client, 2_000)
      assert {:status, 200} in events
      assert {:headers, headers} = Enum.find(events, &match?({:headers, _}, &1))
      assert {"content-encoding", "gzip"} in headers
      assert {"content-length", to_string(byte_size(compressed))} in headers

      assert events
             |> Enum.flat_map(fn
               {:data, bytes} -> [bytes]
               _ -> []
             end)
             |> IO.iodata_to_binary() == compressed

      assert :done in events
      HttpClient.release(client)

      assert {head, "mutation entity"} = Task.await(proxy, 2_000)
      assert head =~ ~r/^POST http:\/\/origin\.invalid(?::80)?\/mutate\?raw=1 HTTP\/1\.1\r\n/
      assert [_, authorization] = Regex.run(~r/\r\nproxy-authorization:\s*([^\r]+)\r\n/i, head)
      assert authorization == "Basic " <> Base.encode64("user:secret")
      refute head =~ "CONNECT "
    after
      HttpClient.close(client)
    end
  end

  test "untrusted TLS proxy fails without connecting directly to the origin" do
    {origin, origin_port} = tcp_listener()
    {listener, proxy_port} = tls_listener()

    proxy =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 2_000)

        try do
          :ssl.handshake(socket, 2_000)
        after
          :ssl.close(socket)
        end
      end)

    {:ok, client} =
      HttpClient.connect(upstream("127.0.0.1", origin_port), %{
        "HTTP_PROXY" => "https://localhost:#{proxy_port}"
      })

    {:ok, client, _ref} = HttpClient.send_request(client, "GET", "/must-use-proxy", [], nil)
    started = System.monotonic_time(:millisecond)

    try do
      assert {:error, :upstream_connect_failed} = HttpClient.recv_response(client, 2_000)
      assert System.monotonic_time(:millisecond) - started < 2_000
      assert {:error, _tls_error} = Task.await(proxy, 2_000)
      assert {:error, :timeout} = :gen_tcp.accept(origin, 100)
    after
      HttpClient.close(client)
    end
  end

  test "NO_PROXY bypasses the TLS proxy without leaking its authentication" do
    {listener, origin_port} = tcp_listener()
    {proxy_listener, proxy_port} = tls_listener()

    origin =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)

        try do
          request = read_request(:gen_tcp, socket)
          :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
          request
        after
          :gen_tcp.close(socket)
        end
      end)

    {:ok, client} =
      HttpClient.connect(upstream("127.0.0.1", origin_port), %{
        "HTTP_PROXY" => "https://user:secret@localhost:#{proxy_port}",
        "NO_PROXY" => "127.0.0.1"
      })

    refute Keyword.has_key?(client.options, :proxy)
    {:ok, client, _ref} = HttpClient.send_request(client, "GET", "/direct", [], nil)

    try do
      assert {:ok, client, events} = HttpClient.recv_response(client, 2_000)
      assert {:data, "ok"} in events
      HttpClient.release(client)

      assert {head, ""} = Task.await(origin, 2_000)
      assert head =~ "GET /direct HTTP/1.1\r\n"
      refute String.downcase(head) =~ "proxy-authorization"
      assert {:error, :timeout} = :ssl.transport_accept(proxy_listener, 100)
    after
      HttpClient.close(client)
    end
  end

  defp upstream(host, port) do
    %Upstream{
      scheme: :http,
      host: host,
      port: port,
      proxy: :environment,
      connect_timeout: 1_000,
      request_timeout: 2_000
    }
  end

  defp trust_local_certificate(client) do
    [{:Certificate, certificate, :not_encrypted}] =
      @cafile |> File.read!() |> :public_key.pem_decode()

    %{
      client
      | options: Keyword.put(client.options, :ssl, verify: :verify_peer, cacerts: [certificate])
    }
  end

  defp tls_listener do
    {:ok, listener} =
      :ssl.listen(0,
        mode: :binary,
        active: false,
        reuseaddr: true,
        certfile: String.to_charlist(@certfile),
        keyfile: String.to_charlist(@keyfile)
      )

    {:ok, {_address, port}} = :ssl.sockname(listener)
    on_exit(fn -> :ssl.close(listener) end)
    {listener, port}
  end

  defp tcp_listener do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {listener, port}
  end

  defp read_request(transport, socket, pending \\ "") do
    case :binary.split(pending, "\r\n\r\n") do
      [head, body] ->
        length =
          case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, head) do
            [_, length] -> String.to_integer(length)
            nil -> 0
          end

        {head <> "\r\n", read_body(transport, socket, body, length)}

      [_incomplete] ->
        {:ok, bytes} = transport.recv(socket, 0, 2_000)
        read_request(transport, socket, pending <> bytes)
    end
  end

  defp read_body(_transport, _socket, body, length) when byte_size(body) >= length,
    do: binary_part(body, 0, length)

  defp read_body(transport, socket, body, length) do
    {:ok, bytes} = transport.recv(socket, 0, 2_000)
    read_body(transport, socket, body <> bytes, length)
  end
end
