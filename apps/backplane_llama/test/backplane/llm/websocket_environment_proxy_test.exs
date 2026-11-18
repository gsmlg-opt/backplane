defmodule Backplane.LLM.WebSocketEnvironmentProxyTest do
  use ExUnit.Case, async: false

  @proxy_vars ~w(HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy)

  setup do
    previous = Map.new(@proxy_vars, &{&1, System.get_env(&1)})
    Enum.each(@proxy_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  for {session_module, event_tag} <- [
        {Backplane.LLM.ResponsesWebSocket.Session, :responses_event},
        {Backplane.LLM.OpenAI.RealtimeWebSocket.Session, :realtime_event}
      ] do
    @session_module session_module
    @event_tag event_tag

    test "#{session_module} opens through the environment proxy and delivers events" do
      {proxy, port} = listener()
      System.put_env("HTTP_PROXY", "http://proxy-user:proxy-pass@127.0.0.1:#{port}")
      owner = self()

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(proxy, 2000)
        request = head(socket)
        send(owner, {:proxy_request, request})
        upgrade(socket, request)
        bytes = ~s({"type":"future.event","opaque":true})
        :gen_tcp.send(socket, [<<0x81, byte_size(bytes)>>, bytes])
        close_reply(socket)
      end)

      session = start_session(@session_module, "ws://origin.invalid/v1/socket?model=test")
      assert {:ok, %{status: 101}} = @session_module.open(session)
      assert :ok = @session_module.attach(session, self())
      assert_receive {:proxy_request, request}
      assert request =~ "GET http://origin.invalid/v1/socket?model=test HTTP/1.1\r\n"
      assert request =~ ~r/^host: origin.invalid\r$/mi
      assert request =~ "Basic " <> Base.encode64("proxy-user:proxy-pass")
      assert_receive {tag, ^session, bytes, ref}
      assert tag == @event_tag
      assert bytes == ~s({"type":"future.event","opaque":true})
      @session_module.ack(session, ref)
      assert :ok = @session_module.close(session)
    end

    test "#{session_module} does not fall back to direct origin after proxy failure" do
      {origin, origin_port} = listener()
      {proxy, proxy_port} = listener()
      System.put_env("HTTP_PROXY", "http://127.0.0.1:#{proxy_port}")

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(proxy, 2000)
        head(socket)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )

        :gen_tcp.close(socket)
      end)

      session = start_session(@session_module, "ws://127.0.0.1:#{origin_port}/v1/socket")
      assert {:error, :upstream_handshake_failed, %{status: 503}} = @session_module.open(session)
      assert {:error, :timeout} = :gen_tcp.accept(origin, 100)
    end

    test "#{session_module} respects NO_PROXY without contacting the proxy" do
      {origin, origin_port} = listener()
      {proxy, proxy_port} = listener()
      System.put_env("HTTP_PROXY", "http://127.0.0.1:#{proxy_port}")
      System.put_env("NO_PROXY", "127.0.0.1")
      owner = self()

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(origin, 2000)
        request = head(socket)
        send(owner, {:direct_request, request})
        upgrade(socket, request)
        close_reply(socket)
      end)

      session = start_session(@session_module, "ws://127.0.0.1:#{origin_port}/v1/socket")
      assert {:ok, %{status: 101}} = @session_module.open(session)
      assert_receive {:direct_request, request}
      assert request =~ "GET /v1/socket HTTP/1.1\r\n"
      refute request =~ ~r/proxy-authorization/i
      assert :ok = @session_module.close(session)
      assert {:error, :timeout} = :gen_tcp.accept(proxy, 100)
    end
  end

  defp start_session(module, url) do
    start_supervised!({module, owner: self(), url: url, headers: [], policy: %{}})
  end

  defp listener do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {listener, port}
  end

  defp head(socket, bytes \\ "") do
    if String.ends_with?(bytes, "\r\n\r\n") do
      bytes
    else
      {:ok, byte} = :gen_tcp.recv(socket, 1, 2000)
      head(socket, bytes <> byte)
    end
  end

  defp upgrade(socket, request) do
    [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)/i, request)
    accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

    :gen_tcp.send(
      socket,
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
    )
  end

  defp close_reply(socket) do
    {:ok, <<0x88, _::binary>>} = :gen_tcp.recv(socket, 0, 2000)
    :gen_tcp.send(socket, <<0x88, 2, 1000::16>>)
    :gen_tcp.close(socket)
  end
end
