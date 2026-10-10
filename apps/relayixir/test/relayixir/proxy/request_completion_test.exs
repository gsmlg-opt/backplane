defmodule Relayixir.Proxy.RequestCompletionTest do
  use ExUnit.Case

  alias Relayixir.Proxy.{HttpClient, Upstream}
  alias HTTP.{Promise, RequestCompletion}

  for route <- [:pooled, :proxy] do
    test "#{route} cancellation before headers settles the upload source and peer socket" do
      owner = self()

      {port, peer} =
        start_peer(fn socket ->
          request = read_until(socket, "payload", "")
          send(owner, {:upload_received, request})
          send(owner, {:upload_socket_closed, :gen_tcp.recv(socket, 0, 2_000)})
        end)

      client = client(unquote(route), port)
      {:ok, client, ref} = HttpClient.send_request(client, "POST", "/upload", [], :stream)

      try do
        assert {:ok, client} = HttpClient.stream_body_chunk(client, ref, "payload")
        assert_receive {:upload_received, request}, 1_000
        assert request =~ "POST "
        completion = Promise.completion(client.promise)
        assert_pending(completion, unquote(route))

        assert {:ok, _client} = HttpClient.close(client)
        assert_settled(completion, unquote(route))
        assert_stopped(client.upload, unquote(route))
        assert_receive {:upload_socket_closed, {:error, :closed}}, 2_500
        assert :ok = Task.await(peer, 1_000)
      after
        HttpClient.close(client)
      end
    end

    test "#{route} cancellation after headers settles the response helper and peer socket" do
      owner = self()

      {port, peer} =
        start_peer(fn socket ->
          read_until(socket, "\r\n\r\n", "")
          :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n")
          send(owner, {:response_socket_closed, :gen_tcp.recv(socket, 0, 2_000)})
        end)

      {:ok, client, _ref} =
        HttpClient.send_request(client(unquote(route), port), "GET", "/response", [], "")

      try do
        assert {:ok, client, 200, _headers, [], :more} =
                 HttpClient.recv_until_headers(client, 1_000)

        assert is_pid(client.response.body)
        completion = Promise.completion(client.promise)
        assert_pending(completion, unquote(route))
        assert {:ok, _client} = HttpClient.close(client)
        assert_settled(completion, unquote(route))
        assert_stopped(client.response.body, unquote(route))
        assert_receive {:response_socket_closed, {:error, :closed}}, 2_500
        assert :ok = Task.await(peer, 1_000)
      after
        HttpClient.close(client)
      end
    end
  end

  test "completed pooled request preserves its socket and cannot cancel the next lease" do
    owner = self()

    {port, peer} =
      start_peer(fn socket ->
        first_head = read_until(socket, "\r\n\r\n", "")
        send(owner, {:first_request, first_head})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none")
        second_head = read_until(socket, "\r\n\r\n", "")
        send(owner, {:second_request_same_socket, second_head})

        receive do
          :finish_second -> :ok
        after
          2_000 -> flunk("second request was not released")
        end

        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo")
      end)

    {:ok, first, _ref} = HttpClient.send_request(client(:pooled, port), "GET", "/one", [], "")

    try do
      assert {:ok, first, events} = HttpClient.recv_response(first, 1_000)
      assert {:data, "one"} in events
      first_completion = Promise.completion(first.promise)
      assert :ok = HttpClient.release(first)
      assert :ok = RequestCompletion.await(first_completion, 1_000)
      refute Process.alive?(first.response.body)

      {:ok, second, _ref} = HttpClient.send_request(client(:pooled, port), "GET", "/two", [], "")

      try do
        assert_receive {:first_request, "GET /one HTTP/1.1\r\n" <> _}, 1_000
        assert_receive {:second_request_same_socket, "GET /two HTTP/1.1\r\n" <> _}, 1_000
        assert :ok = RequestCompletion.abort_and_await(first_completion, 0)
        send(peer.pid, :finish_second)
        assert {:ok, second, events} = HttpClient.recv_response(second, 1_000)
        assert {:data, "two"} in events
        assert :ok = HttpClient.release(second)
        assert :ok = RequestCompletion.await(Promise.completion(second.promise), 1_000)
        assert :ok = Task.await(peer, 1_000)
      after
        HttpClient.close(second)
      end
    after
      HttpClient.close(first)
    end
  end

  defp assert_pending(completion, :pooled),
    do: assert({:error, :cleanup_pending} = RequestCompletion.await(completion, 0))

  # Public completion does not yet cover an explicit HTTP proxy in 0.20.
  defp assert_pending(completion, :proxy),
    do:
      assert({:error, {:unsupported_completion, :proxy}} = RequestCompletion.await(completion, 0))

  defp assert_settled(completion, :pooled),
    do: assert(:ok = RequestCompletion.await(completion, 0))

  defp assert_settled(completion, :proxy),
    do:
      assert({:error, {:unsupported_completion, :proxy}} = RequestCompletion.await(completion, 0))

  defp assert_stopped(stream, :pooled), do: refute(Process.alive?(stream))

  defp assert_stopped(stream, :proxy) do
    monitor = Process.monitor(stream)
    assert_receive {:DOWN, ^monitor, :process, ^stream, _reason}, 1_000
    refute Process.alive?(stream)
  end

  defp client(route, port) do
    upstream = %Upstream{
      scheme: :http,
      host: if(route == :proxy, do: "origin.invalid", else: "127.0.0.1"),
      port: if(route == :proxy, do: 80, else: port),
      pool_size: if(route == :pooled, do: 2, else: 0),
      proxy: if(route == :proxy, do: :environment, else: :direct),
      connect_timeout: 1_000,
      request_timeout: 5_000
    }

    {:ok, client} = HttpClient.connect(upstream, %{"HTTP_PROXY" => "http://127.0.0.1:#{port}"})
    client
  end

  defp start_peer(callback) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)

        try do
          callback.(socket)
          :ok
        after
          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(peer.pid), do: Process.exit(peer.pid, :kill)
    end)

    {port, peer}
  end

  defp read_until(socket, delimiter, pending) do
    if String.contains?(pending, delimiter) do
      pending
    else
      {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
      read_until(socket, delimiter, pending <> bytes)
    end
  end
end
