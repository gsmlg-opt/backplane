if Code.ensure_loaded?(HTTP.WebSocket) do
  defmodule Backplane.McpProtocol.Transport.WebSocket do
    @moduledoc """
    A transport implementation that uses WebSockets for bidirectional communication
    with the MCP server.

    > ## Notes {: .info}
    >
    > For initialization and setup, check our [Installation & Setup](./installation.html) and
    > the [Transport options](./transport_options.html) guides for reference.
    """

    @behaviour Backplane.McpProtocol.Transport.Behaviour

    use GenServer
    use Backplane.McpProtocol.Logging

    import Peri

    alias Backplane.McpProtocol.Telemetry
    alias Backplane.McpProtocol.Transport.Behaviour, as: Transport
    alias HTTP.WebSocket, as: HttpWebSocket
    alias HTTP.WebSocket.Event

    @type t :: GenServer.server()

    @typedoc """
    The options for the MCP server.

    - `:base_url` - The base URL of the MCP server (e.g. http://localhost:8000) (required).
    - `:base_path` - The base path of the MCP server (e.g. /mcp).
    - `:ws_path` - The path to the WebSocket endpoint (e.g. /mcp/ws) (default `:base_path` + `/ws`).
    """
    @type server ::
            Enumerable.t(
              {:base_url, String.t()}
              | {:base_path, String.t()}
              | {:ws_path, String.t()}
            )

    @type params_t :: Enumerable.t(option)
    @typedoc """
    The options for the WebSocket transport.

    - `:name` - The name of the transport process, respecting the `GenServer` "Name Registration" section.
    - `:client` - The client to send the messages to, respecting the `GenServer` "Name Registration" section.
    - `:server` - The server configuration.
    - `:headers` - The headers to send with the WebSocket upgrade request.
    - `:transport_opts` - A keyword list or map of options passed to `HTTP.WebSocket.new/3`,
      including the library's supported string map keys. The transport always overrides
      owner and headers, including string keys. Only browser mode with legacy delivery
      is supported; ACK delivery and proxy mode are rejected. Incoming text messages
      are forwarded to the client; binary messages are ignored. TLS verification uses
      the library defaults unless explicitly configured through these options.
    """
    @type option ::
            {:name, GenServer.name()}
            | {:client, GenServer.server()}
            | {:server, server}
            | {:headers, map()}
            | {:transport_opts, keyword() | map()}
            | GenServer.option()

    defschema(:options_schema, %{
      name: {{:custom, &Backplane.McpProtocol.genserver_name/1}, {:default, __MODULE__}},
      client:
        {:required,
         {:oneof,
          [
            {:custom, &Backplane.McpProtocol.genserver_name/1},
            :pid,
            {:tuple, [:atom, :any]}
          ]}},
      server: [
        base_url: {:required, {:string, {:transform, &URI.new!/1}}},
        base_path: {:string, {:default, "/"}},
        ws_path: {:string, {:default, "/ws"}}
      ],
      headers: {:map, {:default, %{}}},
      transport_opts: {:any, {:default, []}}
    })

    @impl Transport
    @spec start_link(params_t) :: GenServer.on_start()
    def start_link(opts \\ []) do
      opts = options_schema!(opts)
      GenServer.start_link(__MODULE__, Map.new(opts), name: opts[:name])
    end

    @impl Transport
    def send_message(pid, message, opts) when is_binary(message) do
      GenServer.call(pid, {:send, message}, Keyword.get(opts, :timeout, 5000))
    end

    @impl Transport
    def shutdown(pid) do
      GenServer.cast(pid, :close_connection)
    end

    @impl Transport
    def supported_protocol_versions, do: :all

    @impl GenServer
    def init(%{} = opts) do
      ws_url =
        opts.server[:base_url]
        |> URI.append_path(opts.server[:base_path])
        |> URI.append_path(opts.server[:ws_path])
        |> normalize_websocket_scheme()

      state =
        Map.merge(opts, %{
          ws_url: ws_url,
          socket: nil,
          socket_monitor: nil,
          connection_state: :opening
        })

      Telemetry.execute(
        Telemetry.event_transport_init(),
        %{system_time: System.system_time()},
        %{transport: :websocket, ws_url: URI.to_string(ws_url), client: opts.client}
      )

      {:ok, state, {:continue, :connect}}
    end

    @impl GenServer
    def handle_continue(:connect, state) do
      uri = state.ws_url
      port = uri.port || if(uri.scheme == "wss", do: 443, else: 80)

      metadata = %{
        transport: :websocket,
        ws_url: URI.to_string(uri),
        host: uri.host,
        port: port,
        protocol: Map.get(%{"ws" => :ws, "wss" => :wss}, uri.scheme)
      }

      Telemetry.execute(
        Telemetry.event_transport_connect(),
        %{system_time: System.system_time()},
        metadata
      )

      result =
        with {:ok, options} <- websocket_options(state.transport_opts, state.headers) do
          HttpWebSocket.new(uri, [], options)
        end

      case result do
        %HttpWebSocket{} = socket ->
          monitor = Process.monitor(socket.pid)
          {:noreply, %{state | socket: socket, socket_monitor: monitor}}

        {:error, reason} ->
          Logging.transport_event("websocket_open_failed", %{reason: reason}, level: :error)

          Telemetry.execute(
            Telemetry.event_transport_error(),
            %{system_time: System.system_time()},
            Map.put(metadata, :error, reason)
          )

          {:stop, {:websocket_open_failed, reason}, state}
      end
    end

    @impl GenServer
    def handle_call({:send, message}, _from, %{connection_state: :open, socket: socket} = state) do
      Telemetry.execute(
        Telemetry.event_transport_send(),
        %{system_time: System.system_time()},
        %{transport: :websocket, message_size: byte_size(message)}
      )

      case HttpWebSocket.send(socket, message) do
        :ok ->
          Logging.transport_event("ws_message_sent", String.slice(message, 0, 100))
          {:reply, :ok, state}

        {:error, reason} ->
          Logging.transport_event("ws_send_failed", %{reason: reason}, level: :error)
          {:reply, {:error, :send_failed}, state}
      end
    rescue
      error ->
        Logging.transport_event("ws_send_failed", %{error: Exception.message(error)},
          level: :error
        )

        {:reply, {:error, :send_failed}, state}
    end

    def handle_call({:send, _message}, _from, state) do
      {:reply, {:error, :not_connected}, state}
    end

    @impl GenServer
    def handle_info(
          {HttpWebSocket, socket, %Event.Open{}},
          %{socket: socket, connection_state: :opening, client: client} = state
        ) do
      Logging.transport_event("ws_upgrade_success", "WebSocket connection established")
      GenServer.cast(client, :initialize)
      {:noreply, %{state | connection_state: :open}}
    end

    def handle_info(
          {HttpWebSocket, socket, %Event.Message{data: data}},
          %{socket: socket, connection_state: :open, client: client} = state
        )
        when is_binary(data) do
      Logging.transport_event("ws_message_received", String.slice(data, 0, 100))

      Telemetry.execute(
        Telemetry.event_transport_receive(),
        %{system_time: System.system_time()},
        %{transport: :websocket, message_size: byte_size(data)}
      )

      GenServer.cast(client, {:response, data})
      {:noreply, state}
    end

    def handle_info(
          {HttpWebSocket, socket, %Event.Close{code: nil}},
          %{socket: socket} = state
        ) do
      Logging.transport_event("ws_closed", "Connection closed by server", level: :warning)

      Telemetry.execute(
        Telemetry.event_transport_disconnect(),
        %{system_time: System.system_time()},
        %{transport: :websocket, reason: :normal_close}
      )

      {:stop, :normal, clear_socket(state)}
    end

    def handle_info(
          {HttpWebSocket, socket, %Event.Close{code: code, reason: reason}},
          %{socket: socket} = state
        ) do
      Logging.transport_event("ws_closed", %{code: code, reason: reason}, level: :warning)

      Telemetry.execute(
        Telemetry.event_transport_disconnect(),
        %{system_time: System.system_time()},
        %{transport: :websocket, code: code, reason: reason}
      )

      {:stop, {:ws_closed, code, reason}, clear_socket(state)}
    end

    def handle_info(
          {HttpWebSocket, socket, %Event.Error{reason: reason}},
          %{socket: socket, connection_state: connection_state} = state
        ) do
      Logging.transport_event("websocket_error", %{reason: reason}, level: :error)

      Telemetry.execute(
        Telemetry.event_transport_error(),
        %{system_time: System.system_time()},
        %{transport: :websocket, error: connection_state, reason: reason}
      )

      {:stop, {:websocket_error, reason}, state}
    end

    def handle_info(
          {:DOWN, monitor, :process, pid, reason},
          %{socket: %HttpWebSocket{pid: pid}, socket_monitor: monitor} = state
        ) do
      Logging.transport_event("websocket_down", %{reason: reason}, level: :error)

      Telemetry.execute(
        Telemetry.event_transport_error(),
        %{system_time: System.system_time()},
        %{transport: :websocket, error: :connection_down, reason: reason}
      )

      {:stop, {:websocket_down, reason}, %{state | socket: nil, socket_monitor: nil}}
    end

    def handle_info(message, state) do
      Logging.transport_event("unexpected_message", %{message: message})
      {:noreply, state}
    end

    @impl GenServer
    def handle_cast(:close_connection, state) do
      reason = if state.socket, do: :client_closed, else: :client_closed_before_connected

      Telemetry.execute(
        Telemetry.event_transport_disconnect(),
        %{system_time: System.system_time()},
        %{transport: :websocket, reason: reason}
      )

      close_socket(state.socket)
      {:stop, :normal, clear_socket(state)}
    end

    @impl GenServer
    def terminate(reason, state) do
      Telemetry.execute(
        Telemetry.event_transport_terminate(),
        %{system_time: System.system_time()},
        %{transport: :websocket, reason: reason}
      )

      Telemetry.execute(
        Telemetry.event_transport_disconnect(),
        %{system_time: System.system_time()},
        %{transport: :websocket, reason: reason}
      )

      close_socket(state.socket)
      :ok
    end

    defp websocket_options(options, headers) when is_map(options) or is_list(options) do
      with :ok <- validate_websocket_options(options) do
        options =
          Enum.reject(options, fn {key, _value} ->
            key in [:owner, "owner", :headers, "headers", :mode, "mode", :delivery, "delivery"]
          end)

        {:ok,
         [owner: self(), headers: Map.to_list(headers), mode: :browser, delivery: :legacy] ++
           options}
      end
    end

    defp websocket_options(_options, _headers), do: {:error, :invalid_transport_options}

    defp validate_websocket_options(options) do
      Enum.reduce_while(options, :ok, fn
        {key, value}, :ok
        when key in [:delivery, "delivery"] and value not in [:legacy, "legacy"] ->
          {:halt, {:error, {:unsupported_transport_option, :delivery}}}

        {key, value}, :ok when key in [:mode, "mode"] and value not in [:browser, "browser"] ->
          {:halt, {:error, {:unsupported_transport_option, :mode}}}

        {key, _value}, :ok when is_atom(key) or is_binary(key) ->
          {:cont, :ok}

        _option, :ok ->
          {:halt, {:error, :invalid_transport_options}}
      end)
    end

    defp normalize_websocket_scheme(%URI{scheme: "http"} = uri), do: %{uri | scheme: "ws"}
    defp normalize_websocket_scheme(%URI{scheme: "https"} = uri), do: %{uri | scheme: "wss"}

    defp normalize_websocket_scheme(%URI{} = uri), do: uri

    defp clear_socket(%{socket_monitor: monitor} = state) when is_reference(monitor) do
      Process.demonitor(monitor, [:flush])
      %{state | socket: nil, socket_monitor: nil}
    end

    defp clear_socket(state), do: %{state | socket: nil, socket_monitor: nil}

    defp close_socket(%HttpWebSocket{} = socket) do
      HttpWebSocket.close(socket)
      :ok
    end

    defp close_socket(nil), do: :ok
  end
end
