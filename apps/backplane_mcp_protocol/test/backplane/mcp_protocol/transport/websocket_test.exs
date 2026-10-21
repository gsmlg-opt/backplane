if Code.ensure_loaded?(HTTP.WebSocket) do
  defmodule Backplane.McpProtocol.Transport.WebSocketTest do
    use ExUnit.Case, async: false
    use Mimic

    alias Backplane.McpProtocol.Transport.WebSocket
    alias HTTP.WebSocket, as: HttpWebSocket
    alias HTTP.WebSocket.Event

    @moduletag capture_log: true

    setup :set_mimic_global
    setup :verify_on_exit!

    setup do
      previous_trap_exit = Process.flag(:trap_exit, true)
      client = start_supervised!(StubClient)
      :ok = StubClient.subscribe()
      owner = self()
      socket_pid = spawn(fn -> Process.sleep(:infinity) end)
      socket = %HttpWebSocket{pid: socket_pid, ref: make_ref(), url: "ws://localhost/ws"}

      Mimic.stub(HttpWebSocket, :new, fn _url, _protocols, _options -> socket end)
      Mimic.stub(HttpWebSocket, :send, fn _socket, _message -> :ok end)

      Mimic.stub(HttpWebSocket, :close, fn closed_socket ->
        send(owner, {:socket_closed, closed_socket})
        :ok
      end)

      on_exit(fn ->
        Process.flag(:trap_exit, previous_trap_exit)
        if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill)
      end)

      %{client: client, socket: socket, socket_pid: socket_pid}
    end

    test "fails with invalid options" do
      assert_raise Peri.InvalidSchema, fn ->
        WebSocket.start_link(server: [base_path: "/mcp", ws_path: "/ws"])
      end
    end

    test "opens asynchronously with normalized URL, explicit headers, and the transport owner", %{
      client: client,
      socket: socket
    } do
      test_pid = self()

      Mimic.expect(HttpWebSocket, :new, fn url, [], options ->
        send(test_pid, {:new_called, url, options, self()})
        socket
      end)

      assert {:ok, transport} =
               WebSocket.start_link(
                 client: client,
                 server: [
                   base_url: "https://example.test/root?token=test",
                   base_path: "/mcp",
                   ws_path: "/ws"
                 ],
                 headers: %{"authorization" => "Bearer explicit"},
                 transport_opts: [
                   owner: test_pid,
                   headers: [{"authorization", "Bearer ignored"}],
                   opening_timeout: 1_000
                 ]
               )

      assert_receive {:new_called, %URI{} = url, options, ^transport}
      assert URI.to_string(url) == "wss://example.test/root/mcp/ws?token=test"
      assert options[:owner] == transport
      assert options[:headers] == [{"authorization", "Bearer explicit"}]
      assert options[:opening_timeout] == 1_000
      refute Keyword.has_key?(options, :ssl)
      assert {:error, :not_connected} = WebSocket.send_message(transport, "early", [])

      send(transport, {HttpWebSocket, socket, %Event.Open{}})
      assert_receive {:stub_client_signal, :initialize}
      assert Process.alive?(transport)

      WebSocket.shutdown(transport)
      assert_receive {:socket_closed, ^socket}
      assert_receive {:EXIT, ^transport, :normal}
    end

    test "preserves ws and wss schemes", %{client: client, socket: socket} do
      test_pid = self()

      Mimic.expect(HttpWebSocket, :new, 2, fn url, [], _options ->
        send(test_pid, {:url, URI.to_string(url)})
        socket
      end)

      for scheme <- ["ws", "wss"] do
        expected_url = "#{scheme}://example.test/mcp/ws"

        {:ok, transport} =
          WebSocket.start_link(
            client: client,
            server: [base_url: "#{scheme}://example.test", base_path: "/mcp", ws_path: "/ws"]
          )

        assert_receive {:url, ^expected_url}
        WebSocket.shutdown(transport)
        assert_receive {:socket_closed, ^socket}
        assert_receive {:EXIT, ^transport, :normal}
      end
    end

    test "overrides both string and atom owner and header keys", %{client: client, socket: socket} do
      test_pid = self()

      Mimic.expect(HttpWebSocket, :new, fn url, [], options ->
        assert {:ok, normalized} = HTTP.WebSocket.Options.new(url, [], options)
        assert normalized.owner == self()
        assert normalized.headers == [{"Authorization", "Bearer explicit"}]
        assert normalized.mode == :browser
        assert normalized.delivery == :legacy
        assert normalized.ssl == []
        socket
      end)

      {:ok, transport} =
        WebSocket.start_link(
          client: client,
          server: [base_url: "https://example.test"],
          headers: %{"authorization" => "Bearer explicit"},
          transport_opts: %{
            :owner => test_pid,
            "owner" => test_pid,
            :headers => [{"authorization", "atom ignored"}],
            "headers" => [{"authorization", "string ignored"}],
            "mode" => "browser",
            "delivery" => "legacy"
          }
        )

      assert {:error, :not_connected} = WebSocket.send_message(transport, "early", [])
      WebSocket.shutdown(transport)
      assert_receive {:socket_closed, ^socket}
      assert_receive {:EXIT, ^transport, :normal}
    end

    test "rejects unsupported delivery and mode options before creating a socket", %{
      client: client
    } do
      Mimic.reject(HttpWebSocket, :new, 3)

      for {key, value, option} <- [
            {:delivery, :ack, :delivery},
            {:delivery, "ack", :delivery},
            {"delivery", :ack, :delivery},
            {"delivery", "ack", :delivery},
            {:mode, :proxy, :mode},
            {:mode, "proxy", :mode},
            {"mode", :proxy, :mode},
            {"mode", "proxy", :mode}
          ],
          options <- [[{key, value}], %{key => value}] do
        {:ok, transport} =
          WebSocket.start_link(
            client: client,
            server: [base_url: "http://localhost:4000"],
            transport_opts: options
          )

        assert_receive {:EXIT, ^transport,
                        {:websocket_open_failed, {:unsupported_transport_option, ^option}}}
      end

      for options <- [
            %{:delivery => :legacy, "delivery" => "ack"},
            %{:mode => :browser, "mode" => "proxy"}
          ] do
        {:ok, transport} =
          WebSocket.start_link(
            client: client,
            server: [base_url: "http://localhost:4000"],
            transport_opts: options
          )

        assert_receive {:EXIT, ^transport,
                        {:websocket_open_failed, {:unsupported_transport_option, _option}}}
      end
    end

    test "sends text after open and maps library send failures", %{client: client, socket: socket} do
      {:ok, transport} = start_transport(client)
      send(transport, {HttpWebSocket, socket, %Event.Open{}})
      assert_receive {:stub_client_signal, :initialize}

      Mimic.expect(HttpWebSocket, :send, fn ^socket, "request" -> :ok end)
      assert :ok = WebSocket.send_message(transport, "request", [])

      Mimic.expect(HttpWebSocket, :send, fn ^socket, "failed" -> {:error, :closed} end)
      assert {:error, :send_failed} = WebSocket.send_message(transport, "failed", [])

      Mimic.expect(HttpWebSocket, :send, fn ^socket, "exception" -> raise "send failed" end)
      assert {:error, :send_failed} = WebSocket.send_message(transport, "exception", [])

      WebSocket.shutdown(transport)
      assert_receive {:socket_closed, ^socket}
      assert_receive {:EXIT, ^transport, :normal}
    end

    test "forwards text messages with the existing client cast", %{client: client, socket: socket} do
      {:ok, transport} = start_transport(client)
      send(transport, {HttpWebSocket, socket, %Event.Open{}})
      assert_receive {:stub_client_signal, :initialize}

      message = ~s({"jsonrpc":"2.0","method":"test","params":{}})
      send(transport, {HttpWebSocket, socket, %Event.Message{data: message}})

      assert_receive {:stub_client_response, ^message}
      assert StubClient.get_messages() == [message]

      WebSocket.shutdown(transport)
      assert_receive {:socket_closed, ^socket}
      assert_receive {:EXIT, ^transport, :normal}
    end

    test "stops normally on a remote close without a code", %{client: client, socket: socket} do
      {:ok, transport} = start_transport(client)
      send(transport, {HttpWebSocket, socket, %Event.Open{}})
      assert_receive {:stub_client_signal, :initialize}

      send(transport, {HttpWebSocket, socket, %Event.Close{code: nil}})
      assert_receive {:EXIT, ^transport, :normal}
      refute_received {:socket_closed, _socket}
    end

    test "preserves a remote close code and reason", %{client: client, socket: socket} do
      {:ok, transport} = start_transport(client)
      send(transport, {HttpWebSocket, socket, %Event.Open{}})
      assert_receive {:stub_client_signal, :initialize}

      send(transport, {HttpWebSocket, socket, %Event.Close{code: 1000, reason: "Normal closure"}})

      assert_receive {:EXIT, ^transport, {:ws_closed, 1000, "Normal closure"}}
      refute_received {:socket_closed, _socket}
    end

    test "reports immediate open failures", %{client: client} do
      Mimic.expect(HttpWebSocket, :new, fn _url, [], _options -> {:error, :invalid_url} end)

      {:ok, transport} = start_transport(client)
      assert_receive {:EXIT, ^transport, {:websocket_open_failed, :invalid_url}}
    end

    test "reports opening timeout and established connection errors", %{
      client: client,
      socket: socket
    } do
      {:ok, opening_transport} = start_transport(client)

      send(
        opening_transport,
        {HttpWebSocket, socket, %Event.Error{reason: :opening_timeout}}
      )

      assert_receive {:EXIT, ^opening_transport, {:websocket_error, :opening_timeout}}
      assert_receive {:socket_closed, ^socket}

      {:ok, open_transport} = start_transport(client)
      send(open_transport, {HttpWebSocket, socket, %Event.Open{}})
      assert_receive {:stub_client_signal, :initialize}
      send(open_transport, {HttpWebSocket, socket, %Event.Error{reason: :econnreset}})
      assert_receive {:EXIT, ^open_transport, {:websocket_error, :econnreset}}
      assert_receive {:socket_closed, ^socket}
    end

    test "ignores stale events and unrelated process monitors", %{client: client, socket: socket} do
      {:ok, transport} = start_transport(client)
      stale_socket = %{socket | ref: make_ref()}

      send(transport, {HttpWebSocket, stale_socket, %Event.Open{}})
      send(transport, {HttpWebSocket, stale_socket, %Event.Error{reason: :stale}})
      send(transport, {HttpWebSocket, stale_socket, %Event.Close{code: 1000}})
      send(transport, {HttpWebSocket, socket, %Event.Message{data: "before open"}})
      send(transport, {:DOWN, make_ref(), :process, self(), :unrelated})
      assert %{connection_state: :opening} = :sys.get_state(transport)
      assert StubClient.get_signals() == []
      assert StubClient.get_messages() == []

      send(transport, {HttpWebSocket, socket, %Event.Open{}})
      assert_receive {:stub_client_signal, :initialize}
      send(transport, {HttpWebSocket, socket, %Event.Open{}})
      send(transport, {HttpWebSocket, stale_socket, %Event.Message{data: "stale"}})

      send(
        transport,
        {HttpWebSocket, socket, %Event.Message{data: HttpWebSocket.array_buffer("binary")}}
      )

      assert %{connection_state: :open} = :sys.get_state(transport)
      assert StubClient.get_signals() == [:initialize]
      assert StubClient.get_messages() == []
      WebSocket.shutdown(transport)
      assert_receive {:socket_closed, ^socket}
      assert_receive {:EXIT, ^transport, :normal}
    end

    test "stops when the monitored connection process dies", %{
      client: client,
      socket_pid: socket_pid
    } do
      {:ok, transport} = start_transport(client)
      assert %{socket_monitor: monitor} = :sys.get_state(transport)
      assert is_reference(monitor)
      Process.exit(socket_pid, :kill)
      assert_receive {:EXIT, ^transport, {:websocket_down, :killed}}
    end

    test "terminate closes the current socket", %{client: client, socket: socket} do
      {:ok, transport} = start_transport(client)
      assert %{socket: ^socket} = :sys.get_state(transport)
      GenServer.stop(transport, :shutdown)
      assert_receive {:socket_closed, ^socket}
      assert_receive {:EXIT, ^transport, :shutdown}
    end

    defp start_transport(client) do
      WebSocket.start_link(
        client: client,
        server: [base_url: "http://localhost:4000", base_path: "/mcp", ws_path: "/ws"]
      )
    end
  end

  defmodule Backplane.McpProtocol.Transport.WebSocketIntegrationTest do
    use ExUnit.Case, async: false

    alias Backplane.McpProtocol.Transport.WebSocket

    @moduletag capture_log: true

    defmodule Socket do
      @behaviour WebSock

      @impl WebSock
      def init(owner) do
        send(owner, {:server_open, self()})
        {:ok, owner}
      end

      @impl WebSock
      def handle_info(_message, owner), do: {:ok, owner}

      @impl WebSock
      def handle_in({"close", [opcode: :text]}, owner) do
        {:stop, :normal, {1000, "requested close"}, owner}
      end

      def handle_in({message, [opcode: :text]}, owner) do
        send(owner, {:server_received, message})
        {:push, [{:text, "echo:" <> message}], owner}
      end
    end

    defmodule Endpoint do
      import Plug.Conn

      def init(options), do: options

      def call(conn, owner: owner) do
        send(
          owner,
          {:upgrade_request, conn.request_path, conn.query_string,
           get_req_header(conn, "authorization")}
        )

        conn
        |> WebSockAdapter.upgrade(Socket, owner, timeout: 1_000)
        |> halt()
      end
    end

    setup do
      previous_trap_exit = Process.flag(:trap_exit, true)
      client = start_supervised!(StubClient)
      :ok = StubClient.subscribe()

      {:ok, server} =
        Bandit.start_link(plug: {Endpoint, owner: self()}, ip: {127, 0, 0, 1}, port: 0)

      Process.unlink(server)
      {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

      on_exit(fn ->
        Process.flag(:trap_exit, previous_trap_exit)
        if Process.alive?(server), do: ThousandIsland.stop(server)
      end)

      %{client: client, port: port}
    end

    test "upgrades with path, query, and headers, exchanges text, and handles close", %{
      client: client,
      port: port
    } do
      {:ok, transport} =
        WebSocket.start_link(
          client: client,
          server: [
            base_url: "http://127.0.0.1:#{port}/root?token=test",
            base_path: "/mcp",
            ws_path: "/ws"
          ],
          headers: %{"authorization" => "Bearer integration"}
        )

      assert_receive {:upgrade_request, "/root/mcp/ws", "token=test", ["Bearer integration"]}
      assert_receive {:stub_client_signal, :initialize}
      assert_receive {:server_open, server_connection}
      server_monitor = Process.monitor(server_connection)
      %{socket: %{pid: socket_pid}} = :sys.get_state(transport)
      socket_monitor = Process.monitor(socket_pid)
      assert :ok = WebSocket.send_message(transport, "hello", [])
      assert_receive {:server_received, "hello"}
      assert_receive {:stub_client_response, "echo:hello"}

      assert :ok = WebSocket.send_message(transport, "close", [])
      assert_receive {:EXIT, ^transport, {:ws_closed, 1000, "requested close"}}, 2_000
      assert_receive {:DOWN, ^socket_monitor, :process, ^socket_pid, :normal}, 2_000
      assert_receive {:DOWN, ^server_monitor, :process, ^server_connection, _reason}, 2_000
    end

    for shutdown <- [:local, :terminate, :owner_death] do
      test "cleans up the real connection on #{shutdown}", %{client: client, port: port} do
        {:ok, transport} =
          WebSocket.start_link(client: client, server: [base_url: "http://127.0.0.1:#{port}"])

        assert_receive {:stub_client_signal, :initialize}, 1_000
        assert_receive {:server_open, server_connection}, 1_000
        server_monitor = Process.monitor(server_connection)
        %{socket: %{pid: socket_pid}} = :sys.get_state(transport)
        socket_monitor = Process.monitor(socket_pid)

        case unquote(shutdown) do
          :local -> WebSocket.shutdown(transport)
          :terminate -> GenServer.stop(transport, :shutdown)
          :owner_death -> Process.exit(transport, :kill)
        end

        expected_reason =
          %{local: :normal, terminate: :shutdown, owner_death: :killed}[unquote(shutdown)]

        assert_receive {:EXIT, ^transport, ^expected_reason}, 2_000
        assert_receive {:DOWN, ^socket_monitor, :process, ^socket_pid, _reason}, 2_000
        assert_receive {:DOWN, ^server_monitor, :process, ^server_connection, _reason}, 2_000
      end
    end

    for shutdown <- [:local, :owner_death, :timeout] do
      test "cleans up a pending handshake on #{shutdown}", %{client: client} do
        test_pid = self()
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        on_exit(fn -> :gen_tcp.close(listener) end)
        {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

        peer =
          Task.async(fn ->
            {:ok, socket} = :gen_tcp.accept(listener, 2_000)
            {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
            send(test_pid, {:handshake_pending, request})
            result = :gen_tcp.recv(socket, 0, 3_000)
            :gen_tcp.close(socket)
            result
          end)

        {:ok, transport} =
          WebSocket.start_link(
            client: client,
            server: [base_url: "http://127.0.0.1:#{port}"],
            transport_opts: [opening_timeout: 1_000]
          )

        assert_receive {:handshake_pending, request}, 1_000
        assert request =~ "Upgrade: websocket"

        assert %{connection_state: :opening, socket: %{pid: socket_pid}} =
                 :sys.get_state(transport)

        assert %{worker: worker} = :sys.get_state(socket_pid)
        assert is_pid(worker)
        socket_monitor = Process.monitor(socket_pid)
        worker_monitor = Process.monitor(worker)
        assert {:error, :not_connected} = WebSocket.send_message(transport, "early", [])

        expected_reason =
          case unquote(shutdown) do
            :local ->
              WebSocket.shutdown(transport)
              :normal

            :owner_death ->
              Process.exit(transport, :kill)
              :killed

            :timeout ->
              {:websocket_error, :timeout}
          end

        assert_receive {:EXIT, ^transport, ^expected_reason}, 2_000
        assert_receive {:DOWN, ^socket_monitor, :process, ^socket_pid, _reason}, 2_000
        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 2_000
        assert Task.await(peer) == {:error, :closed}
        assert StubClient.get_signals() == []
      end
    end

    test "reports an unsupported URL scheme without creating atoms", %{client: client} do
      scheme = "unsupported-#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(scheme) end

      {:ok, transport} =
        WebSocket.start_link(client: client, server: [base_url: "#{scheme}://example.test"])

      assert_receive {:EXIT, ^transport, {:websocket_open_failed, {:unsupported_scheme, ^scheme}}}
      assert_raise ArgumentError, fn -> String.to_existing_atom(scheme) end
    end
  end
end
