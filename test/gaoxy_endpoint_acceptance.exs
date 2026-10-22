# credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
if Mix.env() != :dev, do: raise("run with MIX_ENV=dev mix run --no-start")

ExUnit.start(autorun: false)

for application <- [:gaoxy_http, :phoenix, :phoenix_live_view, :phoenix_live_reload] do
  {:ok, _} = Application.ensure_all_started(application)
end

defmodule Backplane.GaoxyEndpointAcceptance do
  use ExUnit.Case, async: false
  import Bitwise

  defmodule FrameEcho do
    def init(state), do: {:ok, state}
    def handle_in({bytes, _metadata}, state), do: {:push, {:binary, "#{byte_size(bytes)}"}, state}
    def handle_info(_message, state), do: {:ok, state}
  end

  defmodule FramePlug do
    def init(options), do: options

    def call(conn, options),
      do: Plug.Conn.upgrade_adapter(conn, :websocket, {FrameEcho, [], options})
  end

  setup_all do
    start_supervised!({Phoenix.PubSub, name: Backplane.PubSub})

    ports =
      for {application, endpoint} <- [
            {:backplane_api, Backplane.Api.Endpoint},
            {:backplane_admin, Backplane.Admin.Endpoint}
          ],
          into: %{} do
        config = Application.fetch_env!(application, endpoint)
        http = Keyword.merge(config[:http], ip: {127, 0, 0, 1}, port: 0)
        config = Keyword.merge(config, server: true, http: http, watchers: [])
        Application.put_env(application, endpoint, config)
        start_supervised!(endpoint)
        {:ok, {_, port}} = Gaoxy.PhoenixAdapter.server_info(endpoint, :http)
        {application, port}
      end

    ports
  end

  test "real public endpoint serves HEAD and rejects unauthenticated host sockets", ports do
    socket = tcp(ports.backplane_api)
    :ok = :gen_tcp.send(socket, "HEAD /mcp HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert headers(socket) =~ "HTTP/1.1 204"
    :gen_tcp.close(socket)
    socket = tcp(ports.backplane_api)
    assert upgrade(socket, "/host-agent/socket/websocket?vsn=2.0.0") =~ "HTTP/1.1 403"
    :gen_tcp.close(socket)
  end

  test "real admin LiveView socket carries Phoenix heartbeat", ports do
    socket = tcp(ports.backplane_admin)
    assert upgrade(socket, "/live/websocket?vsn=2.0.0") =~ "HTTP/1.1 101"
    :ok = frame(socket, 1, 1, Jason.encode!([nil, "1", "phoenix", "heartbeat", %{}]))
    assert {1, payload} = read_frame(socket)
    assert [nil, "1", "phoenix", "phx_reply", %{"status" => "ok"}] = Jason.decode!(payload)
    :gen_tcp.close(socket)
  end

  test "both development reload sockets join through the real endpoints", ports do
    for application <- [:backplane_api, :backplane_admin] do
      socket = tcp(ports[application])
      assert upgrade(socket, "/phoenix/live_reload/socket/websocket?vsn=2.0.0") =~ "HTTP/1.1 101"
      :ok = frame(socket, 1, 1, Jason.encode!(["1", "1", "phoenix:live_reload", "phx_join", %{}]))
      assert {1, payload} = read_frame(socket)

      assert ["1", "1", "phoenix:live_reload", "phx_reply", %{"status" => "ok"}] =
               Jason.decode!(payload)

      :gen_tcp.close(socket)
    end
  end

  test "public host socket frame ceiling also bounds complete fragmented messages" do
    {_, _, options} =
      Enum.find(Backplane.Api.Endpoint.__sockets__(), &(elem(&1, 0) == "/host-agent/socket"))

    ceiling = options[:websocket][:max_frame_size]
    assert ceiling == 640 * 1_024

    server =
      start_supervised!(
        {Gaoxy.HTTP,
         plug: {FramePlug, [max_frame_size: ceiling]}, port: 0, limits: %{max_bytes: 268_435_456}}
      )

    {:ok, {_, port}} = Gaoxy.info(server, :http).local

    socket = tcp(port)
    assert upgrade(socket, "/") =~ "HTTP/1.1 101"
    :ok = frame(socket, 1, 2, :binary.copy("x", ceiling))
    assert {2, "655360"} = read_frame(socket)
    :ok = frame(socket, 0, 2, :binary.copy("x", div(ceiling, 2)))
    :ok = frame(socket, 1, 0, :binary.copy("x", div(ceiling, 2)))
    assert {2, "655360"} = read_frame(socket)
    :ok = frame(socket, 0, 2, :binary.copy("x", div(ceiling, 2)))
    :ok = frame(socket, 1, 0, :binary.copy("x", div(ceiling, 2) + 1))
    assert {8, <<1009::16, _::binary>>} = read_frame(socket)
    :gen_tcp.close(socket)

    socket = tcp(port)
    assert upgrade(socket, "/") =~ "HTTP/1.1 101"
    :ok = frame(socket, 1, 2, :binary.copy("x", ceiling + 1))
    assert {8, <<1009::16, _::binary>>} = read_frame(socket)
    :gen_tcp.close(socket)
  end

  test "host HTTP child disables missing ports" do
    for config <- [%{}, %{http_port: nil}, %{http_port: 0}] do
      assert Backplane.HostAgent.HttpServer.child_spec(config) == nil
    end
  end

  test "host HTTP child binds IPv4, IPv6 and fallback addresses and rebinds after shutdown" do
    for {bind, ip, family} <- [
          {"127.0.0.1", {127, 0, 0, 1}, :inet},
          {"::1", {0, 0, 0, 0, 0, 0, 0, 1}, :inet6},
          {nil, {127, 0, 0, 1}, :inet},
          {"", {127, 0, 0, 1}, :inet},
          {"invalid", {127, 0, 0, 1}, :inet}
        ] do
      {:ok, reservation} = :gen_tcp.listen(0, [family, ip: ip])
      {:ok, {_, port}} = :inet.sockname(reservation)
      :ok = :gen_tcp.close(reservation)
      spec = Backplane.HostAgent.HttpServer.child_spec(%{http_port: port, http_bind: bind})
      assert %{start: {Gaoxy.HTTP, :start_link, [_]}, shutdown: timeout} = spec
      assert is_integer(timeout) and timeout > 0
      owner = start_supervised!(spec)
      assert {:ok, {^ip, ^port}} = Gaoxy.info(owner, :http).local
      {:ok, socket} = :gen_tcp.connect(ip, port, [family, :binary, active: false], 2_000)
      :ok = :gen_tcp.send(socket, "GET /unknown HTTP/1.1\r\nHost: localhost\r\n\r\n")
      assert headers(socket) =~ "HTTP/1.1 404"
      :gen_tcp.close(socket)
      assert :ok = stop_supervised(spec.id)
      refute Process.alive?(owner)
      assert {:error, :econnrefused} = :gen_tcp.connect(ip, port, [family], 1_000)
      rebound = start_supervised!(spec)
      assert {:ok, {^ip, ^port}} = Gaoxy.info(rebound, :http).local
      assert :ok = stop_supervised(spec.id)
    end
  end

  defp tcp(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    socket
  end

  defp upgrade(socket, path) do
    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
      )

    headers(socket)
  end

  defp headers(socket, bytes \\ "") do
    if String.contains?(bytes, "\r\n\r\n"),
      do: bytes,
      else:
        (
          {:ok, next} = :gen_tcp.recv(socket, 0, 5_000)
          headers(socket, bytes <> next)
        )
  end

  defp frame(socket, fin, opcode, bytes) do
    size = byte_size(bytes)

    length =
      cond do
        size < 126 -> <<1::1, size::7>>
        size < 65_536 -> <<1::1, 126::7, size::16>>
        true -> <<1::1, 127::7, size::64>>
      end

    :gen_tcp.send(socket, [<<fin::1, 0::3, opcode::4>>, length, <<0::32>>, bytes])
  end

  defp read_frame(socket) do
    {:ok, <<_::4, opcode::4, mask::1, length::7>>} = :gen_tcp.recv(socket, 2, 5_000)
    assert mask == 0

    length =
      case length do
        126 ->
          {:ok, <<size::16>>} = :gen_tcp.recv(socket, 2, 5_000)
          size

        127 ->
          {:ok, <<size::64>>} = :gen_tcp.recv(socket, 8, 5_000)
          size

        size ->
          size
      end

    {:ok, bytes} = :gen_tcp.recv(socket, length, 5_000)
    {opcode &&& 15, bytes}
  end
end

result = ExUnit.run()
System.halt(if result.failures == 0, do: 0, else: 2)
