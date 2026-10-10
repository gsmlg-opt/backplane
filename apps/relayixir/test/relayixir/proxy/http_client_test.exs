defmodule Relayixir.Proxy.HttpClientTest do
  use ExUnit.Case, async: true

  alias Relayixir.Proxy.{HttpClient, Upstream}

  test "keeps upstreams direct by default" do
    upstream = %Upstream{scheme: :https, host: "chatgpt.com", port: 443}

    options =
      HttpClient.connect_options(upstream, %{
        "HTTPS_PROXY" => "http://proxy.internal:3128"
      })

    assert options[:http_version] == :http1
    assert options[:connect_timeout] == 5_000
    refute Keyword.has_key?(options, :proxy)
    refute Keyword.has_key?(options, :http1_reuse)
  end

  test "adds environment proxy options only when the upstream opts in" do
    upstream = %Upstream{
      scheme: :https,
      host: "chatgpt.com",
      port: 443,
      proxy: :environment,
      connect_timeout: 10_000
    }

    options =
      HttpClient.connect_options(upstream, %{
        "HTTPS_PROXY" => "http://proxy.internal:3128"
      })

    assert options[:connect_timeout] == 10_000
    assert options[:proxy] == {:http, "proxy.internal", 3128, [headers: [], timeout: 10_000]}
  end

  test "uses transparent header-first proxy semantics" do
    options = HttpClient.connect_options(%Upstream{scheme: :http, host: "origin", port: 80}, %{})

    assert options[:request_mode] == :proxy
    assert options[:redirect] == :manual
    assert options[:decode_body] == false
    assert options[:stream_response] == true
    assert options[:tls_backend] == :ssl
    assert options[:error_mode] == :structured
  end

  test "nests proxy authentication in the explicit proxy options" do
    upstream = %Upstream{
      scheme: :https,
      host: "chatgpt.com",
      port: 443,
      proxy: :environment
    }

    options =
      HttpClient.connect_options(upstream, %{
        "HTTPS_PROXY" => "http://user:secret@proxy.internal:3128"
      })

    assert {:http, "proxy.internal", 3128, proxy_options} = options[:proxy]

    assert proxy_options[:headers] == [
             {"proxy-authorization", "Basic " <> Base.encode64("user:secret")}
           ]

    refute Keyword.has_key?(options, :proxy_headers)
  end

  test "enables bounded HTTP/1 reuse only for configured pooling" do
    upstream = %Upstream{scheme: :http, host: "origin", port: 80, pool_size: 4}
    options = HttpClient.connect_options(upstream, %{})

    assert options[:http1_reuse] == true
    assert options[:http1_scope] == "relayixir"
    assert options[:http1_pool_size] == 4
  end

  test "accepts an authenticated HTTPS proxy for an HTTP origin" do
    upstream = %Upstream{scheme: :http, host: "origin", port: 80, proxy: :environment}

    assert {:ok, client} =
             HttpClient.connect(upstream, %{
               "HTTP_PROXY" => "https://user:secret@proxy.internal:3128"
             })

    assert {:https, "proxy.internal", 3128, proxy_options} = client.options[:proxy]
    assert proxy_options[:timeout] == upstream.connect_timeout

    assert proxy_options[:headers] == [
             {"proxy-authorization", "Basic " <> Base.encode64("user:secret")}
           ]

    assert client.options[:tls_backend] == :ssl
    refute Keyword.has_key?(client.options, :ssl)
  end

  for target <- ["//tenant/api", "//tenant/api?x=1"] do
    test "preserves the origin-form request target #{target}" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_address, port}} = :inet.sockname(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      peer =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)

          try do
            request = recv_until_entity(socket, "")
            :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            request
          after
            :gen_tcp.close(socket)
          end
        end)

      upstream = %Upstream{scheme: :http, host: "127.0.0.1", port: port}
      {:ok, client} = HttpClient.connect(upstream)

      {:ok, client, _ref} =
        HttpClient.send_request(client, "POST", unquote(target), [], "mutation entity")

      try do
        assert {:ok, client, _events} = HttpClient.recv_response(client, 2_000)
        assert :ok = HttpClient.release(client)
        assert Task.await(peer, 2_000) =~ "POST #{unquote(target)} HTTP/1.1\r\n"
      after
        HttpClient.close(client)
      end
    end
  end

  test "pooled connection refusal unblocks a streaming upload before the body timeout" do
    upstream = %Upstream{
      scheme: :http,
      host: "127.0.0.1",
      port: 1,
      pool_size: 2,
      connect_timeout: 200,
      request_timeout: 2_000
    }

    assert_upload_connect_failure(upstream, %{})
  end

  test "proxy connection refusal unblocks a streaming upload before the body timeout" do
    upstream = %Upstream{
      scheme: :http,
      host: "origin.invalid",
      port: 80,
      proxy: :environment,
      connect_timeout: 200,
      request_timeout: 2_000
    }

    assert_upload_connect_failure(upstream, %{"HTTP_PROXY" => "http://127.0.0.1:1"})
  end

  test "direct connection refusal retains confirmed pre-send failure evidence" do
    upstream = %Upstream{
      scheme: :http,
      host: "127.0.0.1",
      port: 1,
      connect_timeout: 200,
      request_timeout: 1_000
    }

    error = original_request_error(upstream, %{})
    assert error.reason == :econnrefused
    assert error.phase == :connect
    assert error.request_started == false
    assert HTTP.RequestError.pre_send?(error)
  end

  test "proxy connection refusal retains conservative dispatch evidence" do
    upstream = %Upstream{
      scheme: :http,
      host: "origin.invalid",
      port: 80,
      proxy: :environment,
      connect_timeout: 200,
      request_timeout: 1_000
    }

    error = original_request_error(upstream, %{"HTTP_PROXY" => "http://127.0.0.1:1"})
    assert error.reason == :econnrefused
    assert error.phase == :unknown
    assert error.request_started == :unknown
    refute HTTP.RequestError.pre_send?(error)
  end

  test "does not replay a dispatched request after a proxy disconnects" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    proxy =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        request = recv_until_entity(socket, "")
        :ok = :gen_tcp.close(socket)
        {request, :gen_tcp.accept(listener, 300)}
      end)

    upstream = %Upstream{
      scheme: :http,
      host: "origin.invalid",
      port: 80,
      proxy: :environment,
      connect_timeout: 1_000,
      request_timeout: 1_000
    }

    {:ok, client} =
      HttpClient.connect(upstream, %{"HTTP_PROXY" => "http://127.0.0.1:#{port}"})

    assert {:ok, client, _ref} =
             HttpClient.send_request(client, "POST", "/mutate", [], "mutation entity")

    try do
      assert {:error, %HTTP.RequestError{} = error} = Task.await(client.promise.task, 2_000)
      assert error.phase == :unknown
      assert error.request_started == :unknown
      refute HTTP.RequestError.pre_send?(error)
      assert {request, {:error, :timeout}} = Task.await(proxy, 2_000)
      assert request =~ ~r/^POST http:\/\/origin\.invalid(?::80)?\/mutate HTTP\/1\.1\r\n/
      assert request =~ "mutation entity"
    after
      HttpClient.close(client)
    end
  end

  defp original_request_error(upstream, env) do
    {:ok, client} = HttpClient.connect(upstream, env)

    {:ok, client, _ref} =
      HttpClient.send_request(client, "POST", "/mutate", [], "mutation entity")

    try do
      assert {:error, %HTTP.RequestError{} = error} = Task.await(client.promise.task, 2_000)
      error
    after
      HttpClient.close(client)
    end
  end

  defp recv_until_entity(socket, pending) do
    if String.contains?(pending, "mutation entity") do
      pending
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
      recv_until_entity(socket, pending <> data)
    end
  end

  defp assert_upload_connect_failure(upstream, env) do
    {:ok, client} = HttpClient.connect(upstream, env)
    {:ok, client, ref} = HttpClient.send_request(client, "POST", "/upload", [], :stream)
    started = System.monotonic_time(:millisecond)

    try do
      assert {:error, _client, :upstream_connect_failed} =
               HttpClient.stream_body_chunk(client, ref, "payload")

      assert System.monotonic_time(:millisecond) - started < 500
    after
      HttpClient.close(client)
    end
  end
end
