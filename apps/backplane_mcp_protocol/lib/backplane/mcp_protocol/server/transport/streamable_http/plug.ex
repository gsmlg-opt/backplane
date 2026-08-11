if Code.ensure_loaded?(Plug) do
  defmodule Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug do
    @moduledoc """
    A Plug implementation for the Streamable HTTP transport.

    This plug serves both MCP lifecycle eras on one endpoint:

    - Modern `2026-07-28` requests are session-free and POST-only. Responses use
      JSON or a request-scoped SSE stream and never create or return a session ID.
    - Legacy requests retain their session-oriented behavior: POST dispatches
      through a session, GET opens the session SSE stream, and DELETE closes it.

    POST requests are decoded once and routed by their protocol markers before
    either the stateless modern executor or the legacy session path is selected.

    ## Usage in Phoenix Router

        pipeline :mcp do
          plug :accepts, ["json"]
        end

        scope "/mcp" do
          pipe_through :mcp
          forward "/", to: Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug, server: :your_server_name
        end

    ## Configuration Options

    - `:server` - The server process name (required)
    - `:session_header` - Custom header name for session ID (default: "mcp-session-id")
    - `:request_timeout` - Request timeout in milliseconds (default: 30000)
    - `:allowed_origins` - Origins accepted when the `Origin` header is present (default: [])
    """

    @behaviour Plug

    use Backplane.McpProtocol.Logging

    import Plug.Conn

    alias Backplane.McpProtocol.MCP.Error
    alias Backplane.McpProtocol.MCP.ID
    alias Backplane.McpProtocol.MCP.Message
    alias Backplane.McpProtocol.Protocol.Profile
    alias Backplane.McpProtocol.Protocol.Registry, as: ProtocolRegistry
    alias Backplane.McpProtocol.Server.Authorization
    alias Backplane.McpProtocol.Server.Modern.Executor
    alias Backplane.McpProtocol.Server.ProfileRouter
    alias Backplane.McpProtocol.Server.Registry
    alias Backplane.McpProtocol.Server.Session
    alias Backplane.McpProtocol.Server.Supervisor, as: ServerSupervisor
    alias Backplane.McpProtocol.Server.Transport.StreamableHTTP
    alias Backplane.McpProtocol.Server.Transport.StreamableHTTP.ModernSubscription
    alias Backplane.McpProtocol.SSE.Event
    alias Backplane.McpProtocol.SSE.Streaming
    alias Backplane.McpProtocol.Telemetry
    alias Plug.Conn.Unfetched

    require Message

    @default_session_header "mcp-session-id"
    @default_timeout 30_000
    @max_session_id_bytes 1024

    # Plug callbacks

    @impl Plug
    def init(opts) do
      server = Keyword.fetch!(opts, :server)
      session_header = Keyword.get(opts, :session_header, @default_session_header)
      request_timeout = Keyword.get(opts, :request_timeout, @default_timeout)
      allowed_origins = Keyword.get(opts, :allowed_origins, [])

      %{
        server: server,
        session_header: session_header,
        timeout: request_timeout,
        allowed_origins: allowed_origins
      }
    end

    @impl Plug
    def call(conn, opts) do
      opts = resolve_runtime_config(opts)

      with :ok <- validate_origin(conn, opts.allowed_origins) do
        if conn.request_path == "/.well-known/oauth-protected-resource" do
          handle_well_known(conn, opts)
        else
          case authorize(conn, opts) do
            {:ok, conn, claims} ->
              opts
              |> Map.put(:auth_claims, claims)
              |> then(&handle_request(conn, &1))

            {:halt, conn} ->
              conn
          end
        end
      else
        {:error, :invalid_origin} -> send_error(conn, 403, "Forbidden origin")
      end
    end

    defp handle_request(conn, opts) do
      if conn.method in ["GET", "DELETE"] and modern_protocol_version_marker?(conn) do
        conn
        |> put_resp_header("allow", "POST")
        |> send_resp(405, "")
      else
        case conn.method do
          "GET" -> handle_get(conn, opts)
          "POST" -> handle_post(conn, opts)
          "DELETE" -> handle_delete(conn, opts)
          _ -> send_error(conn, 405, "Method not allowed")
        end
      end
    end

    defp resolve_runtime_config(%{server: server} = opts) do
      session_config = ServerSupervisor.get_session_config(server)
      auth_config = ServerSupervisor.get_authorization_config(server)

      Map.merge(opts, %{
        registry_mod: session_config.registry_mod,
        registry_name: Registry.registry_name(server),
        transport: Registry.transport_name(server, :streamable_http),
        task_supervisor: session_config.task_supervisor,
        subscriptions: Registry.subscriptions_name(server),
        authorization: auth_config
      })
    end

    # GET request handler - establishes SSE connection

    defp handle_get(conn, %{transport: transport, session_header: session_header} = opts) do
      with true <- wants_sse?(conn),
           :ok <- validate_protocol_version(conn, opts.server),
           {:ok, session_id} <- require_session_id(conn, session_header),
           {:ok, session_pid} <- find_session(opts, session_id),
           :ok <- validate_session_protocol(conn, session_pid),
           :ok <- require_initialized_session(session_pid) do
        case StreamableHTTP.register_sse_handler(transport, session_id) do
          :ok ->
            start_sse_streaming(conn, Map.put(opts, :session_id, session_id))

          {:error, reason} ->
            Logging.transport_event("sse_registration_failed", %{reason: reason}, level: :error)

            send_error(conn, 500, "Could not establish SSE connection")
        end
      else
        false ->
          send_error(conn, 406, "Accept header must include text/event-stream")

        {:error, :missing_session_id} ->
          send_error(conn, 400, "Session ID required")

        {:error, :invalid_session_id} ->
          send_error(conn, 400, "Invalid session ID")

        {:error, :unsupported_protocol_version} ->
          send_error(conn, 400, "Unsupported MCP protocol version")

        {:error, :protocol_version_mismatch} ->
          send_error(conn, 400, "MCP protocol version does not match session")

        {:error, :not_initialized} ->
          send_error(conn, 400, "Session not initialized")

        {:error, :not_found} ->
          send_error(conn, 404, "Session not found")
      end
    end

    # POST request handler - routes modern requests statelessly and legacy messages to Session

    defp handle_post(conn, opts) do
      with :ok <- validate_accept_header(conn),
           :ok <- validate_known_legacy_protocol_version(conn, opts.server),
           {:ok, body, conn} <- maybe_read_request_body(conn, opts),
           {:ok, message} <- maybe_decode_post_message(body) do
        context = build_request_context(conn, Map.get(opts, :auth_claims))
        dispatch_post(conn, message, context, opts)
      else
        {:error, :invalid_accept_header} ->
          send_error(
            conn,
            406,
            "Not Acceptable: Client must accept application/json and text/event-stream"
          )

        {:error, :unsupported_protocol_version} ->
          send_error(conn, 400, "Unsupported MCP protocol version")

        {:error, :invalid_json} ->
          error = Error.protocol(:parse_error, %{message: "Invalid JSON"})

          if modern_protocol_version_marker?(conn) do
            send_modern_response(conn, Error.build_json_rpc(error, nil))
          else
            send_jsonrpc_error(conn, error, nil)
          end

        {:error, :invalid_request} ->
          if modern_protocol_version_marker?(conn) do
            send_modern_response(
              conn,
              Error.build_json_rpc(Error.protocol(:invalid_request), nil)
            )
          else
            send_jsonrpc_error(
              conn,
              Error.protocol(:parse_error, %{message: "Invalid JSON"}),
              nil
            )
          end

        {:error, reason} ->
          Logging.transport_event("request_error", %{reason: reason}, level: :error)

          send_jsonrpc_error(
            conn,
            Error.protocol(:parse_error, %{reason: reason}),
            nil
          )
      end
    end

    defp dispatch_post(conn, message, context, opts) do
      routing_context =
        Map.merge(context, %{
          task_supervisor: opts.task_supervisor,
          request_timeout: opts.timeout
        })

      case ProfileRouter.route(message, routing_context) do
        {:ok, :legacy} ->
          dispatch_legacy(conn, message, context, opts)

        {:ok, {:modern, %Profile{}}} ->
          dispatch_modern(conn, message, routing_context, opts)

        {:error, %Error{}} ->
          dispatch_modern(conn, message, routing_context, opts)
      end
    end

    defp dispatch_modern(conn, message, context, opts) do
      case {validate_modern_request(message), message["method"]} do
        {:ok, "subscriptions/listen"} ->
          ModernSubscription.call(conn, message, context, opts)

        {:ok, _method} ->
          {:response, response} =
            Executor.execute(opts.server, message, context,
              task_supervisor: opts.task_supervisor,
              timeout: opts.timeout
            )

          send_modern_response(conn, response)

        {{:error, %Error{} = error}, _method} ->
          send_modern_response(conn, Error.build_json_rpc(error, nil))
      end
    end

    defp dispatch_legacy(conn, message, context, %{session_header: session_header} = opts) do
      with :ok <- validate_protocol_version(conn, opts.server),
           {:ok, message} <- validate_legacy_message(message),
           {:ok, session_id} <- determine_session_id(conn, session_header, message) do
        Logging.transport_event("parsed_messages", %{
          message: message,
          session_id: session_id
        })

        process_message(conn, message, session_id, context, opts)
      else
        {:error, :unsupported_protocol_version} ->
          send_error(conn, 400, "Unsupported MCP protocol version")

        {:error, :missing_session_id} ->
          send_error(conn, 400, "Session ID required")

        {:error, :invalid_session_id} ->
          send_error(conn, 400, "Invalid session ID")

        {:error, :invalid_json} ->
          send_jsonrpc_error(
            conn,
            Error.protocol(:parse_error, %{message: "Invalid JSON"}),
            nil
          )
      end
    end

    defp process_message(conn, message, session_id, context, opts) do
      with :ok <- validate_negotiated_protocol(conn, message, session_id, opts) do
        cond do
          Message.is_notification(message) ->
            handle_notification_message(conn, message, session_id, context, opts)

          Message.is_response(message) or Message.is_error(message) ->
            handle_response_message(conn, message, session_id, context, opts)

          Message.is_request(message) ->
            handle_request_message(conn, message, session_id, context, opts)

          true ->
            send_jsonrpc_error(
              conn,
              Error.protocol(:invalid_request, %{message: "Invalid message type"}),
              nil
            )
        end
      else
        {:error, :not_found} ->
          send_error(conn, 404, "Session not found")

        {:error, :protocol_version_mismatch} ->
          send_error(conn, 400, "MCP protocol version does not match session")
      end
    end

    defp handle_notification_message(conn, message, session_id, context, opts) do
      case find_session(opts, session_id) do
        {:ok, session_pid} ->
          if Message.is_initialize_lifecycle(message) do
            :ok = Session.notify(session_pid, message, context, opts.timeout)
          else
            GenServer.cast(session_pid, {:mcp_notification, message, context})
          end

          send_resp(conn, 202, "")

        {:error, :not_found} ->
          send_error(conn, 404, "Session not found")
      end
    end

    defp handle_response_message(conn, message, session_id, context, opts) do
      case find_session(opts, session_id) do
        {:ok, session_pid} ->
          GenServer.cast(session_pid, {:mcp_response, message, context})
          send_resp(conn, 202, "")

        {:error, :not_found} ->
          send_error(conn, 404, "Session not found")
      end
    end

    defp handle_request_message(conn, message, session_id, context, opts) do
      case find_or_create_session(opts, session_id, message) do
        {:ok, session_pid} ->
          if wants_sse?(conn) do
            handle_sse_request(conn, session_pid, message, session_id, context, opts)
          else
            handle_json_request(conn, session_pid, message, session_id, context, opts)
          end

        {:error, :not_found} ->
          send_error(conn, 404, "Session not found")

        {:error, reason} ->
          send_jsonrpc_error(
            conn,
            Error.protocol(:internal_error, %{reason: reason}),
            extract_request_id(message)
          )
      end
    end

    defp handle_json_request(
           conn,
           session_pid,
           message,
           session_id,
           context,
           %{session_header: session_header} = opts
         ) do
      case GenServer.call(session_pid, {:mcp_request, message, context}, opts.timeout) do
        {:ok, response} when is_binary(response) ->
          conn
          |> put_resp_content_type("application/json")
          |> maybe_add_session_header(session_header, session_id)
          |> send_resp(200, response)

        {:ok, nil} ->
          conn
          |> put_resp_content_type("application/json")
          |> maybe_add_session_header(session_header, session_id)
          |> send_resp(200, "{}")

        {:error, error} ->
          handle_request_error(conn, error, message)
      end
    catch
      :exit, reason ->
        Logging.transport_event("session_call_failed", %{reason: reason}, level: :error)

        send_jsonrpc_error(
          conn,
          Error.protocol(:internal_error, %{message: "Server unavailable"}),
          extract_request_id(message)
        )
    end

    defp handle_sse_request(conn, session_pid, message, session_id, context, opts) do
      %{session_header: session_header} = opts

      case GenServer.call(session_pid, {:mcp_request, message, context}, opts.timeout) do
        {:ok, response} when is_binary(response) ->
          stream_response_on_conn(conn, response, session_id, session_header)

        {:ok, nil} ->
          conn
          |> put_resp_content_type("application/json")
          |> maybe_add_session_header(session_header, session_id)
          |> send_resp(200, "{}")

        {:error, error} ->
          handle_request_error(conn, error, message)
      end
    catch
      :exit, reason ->
        Logging.transport_event("session_call_failed", %{reason: reason}, level: :error)

        send_jsonrpc_error(
          conn,
          Error.protocol(:internal_error, %{message: "Server unavailable"}),
          extract_request_id(message)
        )
    end

    # Per MCP 2025-06-18 Streamable HTTP: a POST that opts into SSE response
    # gets its OWN stream on its OWN HTTP connection, scoped to that request.
    # Stream the response chunk on this conn and let Plug finalize the chunked
    # response. Never reuse the session-wide SSE handler (GET stream).
    defp stream_response_on_conn(conn, response, session_id, session_header) do
      conn = put_resp_header(conn, session_header, session_id)
      conn = Streaming.prepare_connection(conn)

      case Streaming.send_event(conn, response, 0) do
        {:ok, conn} ->
          conn

        {:error, reason} ->
          Logging.transport_event(
            "sse_post_send_failed",
            %{session_id: session_id, reason: inspect(reason)},
            level: :warning
          )

          conn
      end
    end

    defp send_modern_response(conn, response) do
      encoded = JSON.encode!(response)
      status = modern_http_status(response)

      if status == 200 and wants_sse?(conn) do
        stream_modern_response_on_conn(conn, encoded)
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, encoded)
      end
    end

    defp stream_modern_response_on_conn(conn, response) do
      conn = Streaming.prepare_connection(conn)
      event = Event.encode(%Event{event: "message", data: response})

      case Plug.Conn.chunk(conn, event) do
        {:ok, conn} ->
          conn

        {:error, reason} ->
          Logging.transport_event(
            "modern_sse_post_send_failed",
            %{reason: inspect(reason)},
            level: :warning
          )

          conn
      end
    end

    defp modern_http_status(%{"error" => %{"code" => -32_601}}), do: 404

    defp modern_http_status(%{"error" => %{"code" => code}})
         when code in [-32_700, -32_600, -32_602, -32_020, -32_021, -32_022],
         do: 400

    defp modern_http_status(_response), do: 200

    defp handle_delete(conn, %{transport: transport, session_header: session_header} = opts) do
      with :ok <- validate_protocol_version(conn, opts.server),
           {:ok, session_id} <- require_session_id(conn, session_header),
           {:ok, session_pid} <- find_session(opts, session_id),
           :ok <- validate_session_protocol(conn, session_pid) do
        StreamableHTTP.unregister_sse_handler(transport, session_id)
        delete_session_from_store(session_id)
        stop_session_process(opts, session_id)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, "{}")
      else
        {:error, :missing_session_id} ->
          send_error(conn, 400, "Session ID required")

        {:error, :invalid_session_id} ->
          send_error(conn, 400, "Invalid session ID")

        {:error, :unsupported_protocol_version} ->
          send_error(conn, 400, "Unsupported MCP protocol version")

        {:error, :protocol_version_mismatch} ->
          send_error(conn, 400, "MCP protocol version does not match session")

        {:error, :not_found} ->
          send_error(conn, 404, "Session not found")
      end
    end

    # Session management

    defp find_session(%{registry_mod: mod, registry_name: name}, session_id) do
      mod.lookup_session(name, session_id)
    end

    defp find_or_create_session(opts, session_id, message) do
      case find_session(opts, session_id) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, :not_found} when Message.is_initialize(message) ->
          start_new_session(opts, session_id)

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end

    defp start_new_session(
           %{server: server, registry_mod: registry_mod, registry_name: registry_name} = opts,
           session_id
         ) do
      session_config = ServerSupervisor.get_session_config(server)
      session_name = Registry.resolve_session_name(registry_mod, registry_name, session_id)

      session_opts = [
        session_id: session_id,
        server_module: server,
        name: session_name,
        transport: session_config.transport,
        session_idle_timeout: session_config.session_idle_timeout || 1_800_000,
        timeout: opts.timeout,
        task_supervisor: session_config.task_supervisor,
        task_store: Map.get(session_config, :task_store),
        max_concurrency: Map.get(session_config, :max_concurrency, 1)
      ]

      case ServerSupervisor.start_session(server, session_opts) do
        {:ok, pid} ->
          registry_mod.register_session(registry_name, session_id, pid)
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          {:ok, pid}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # Helper functions

    defp wants_sse?(conn) do
      conn
      |> get_req_header("accept")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> List.first("")
      |> String.starts_with?("text/event-stream")
    end

    defp validate_accept_header(conn) do
      media_types =
        conn
        |> get_req_header("accept")
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(fn media_range ->
          media_range
          |> String.split(";", parts: 2)
          |> hd()
          |> String.trim()
          |> String.downcase()
        end)

      if "application/json" in media_types and "text/event-stream" in media_types do
        :ok
      else
        {:error, :invalid_accept_header}
      end
    end

    defp require_session_id(conn, session_header) do
      case get_req_header(conn, session_header) do
        [session_id] -> validate_session_id(session_id)
        _ -> {:error, :missing_session_id}
      end
    end

    defp determine_session_id(conn, session_header, message)
         when Message.is_initialize(message) do
      case get_req_header(conn, session_header) do
        [] -> {:ok, ID.generate_session_id()}
        _ -> {:error, :invalid_session_id}
      end
    end

    defp determine_session_id(conn, session_header, _message) do
      require_session_id(conn, session_header)
    end

    defp validate_session_id(session_id)
         when is_binary(session_id) and byte_size(session_id) in 1..@max_session_id_bytes do
      if Enum.all?(:binary.bin_to_list(session_id), &(&1 in 0x21..0x7E)) do
        {:ok, session_id}
      else
        {:error, :invalid_session_id}
      end
    end

    defp validate_session_id(_session_id), do: {:error, :invalid_session_id}

    defp require_initialized_session(session_pid) do
      if Session.initialized?(session_pid), do: :ok, else: {:error, :not_initialized}
    end

    defp validate_protocol_version(conn, server) do
      case get_req_header(conn, "mcp-protocol-version") do
        [] ->
          :ok

        [version] ->
          if(version in server.supported_protocol_versions(),
            do: :ok,
            else: {:error, :unsupported_protocol_version}
          )

        _ ->
          {:error, :unsupported_protocol_version}
      end
    end

    defp modern_protocol_version_marker?(conn) do
      case get_req_header(conn, "mcp-protocol-version") do
        [version] ->
          match?({:ok, %Profile{era: :modern}}, ProtocolRegistry.profile(version))

        _other ->
          false
      end
    end

    defp validate_known_legacy_protocol_version(conn, server) do
      case get_req_header(conn, "mcp-protocol-version") do
        [version] ->
          case ProtocolRegistry.profile(version) do
            {:ok, %Profile{era: :legacy}} -> validate_protocol_version(conn, server)
            _modern_or_unknown -> :ok
          end

        _missing_or_duplicate ->
          :ok
      end
    end

    defp validate_negotiated_protocol(_conn, message, _session_id, _opts)
         when Message.is_initialize(message),
         do: :ok

    defp validate_negotiated_protocol(conn, _message, session_id, opts) do
      with {:ok, session_pid} <- find_session(opts, session_id) do
        validate_session_protocol(conn, session_pid)
      end
    end

    defp validate_session_protocol(conn, session_pid) do
      case get_req_header(conn, "mcp-protocol-version") do
        [] ->
          :ok

        [version] ->
          if(version == Session.protocol_version(session_pid),
            do: :ok,
            else: {:error, :protocol_version_mismatch}
          )

        _ ->
          {:error, :protocol_version_mismatch}
      end
    end

    defp validate_origin(conn, allowed_origins) do
      case get_req_header(conn, "origin") do
        [] -> :ok
        [origin] -> if(origin in allowed_origins, do: :ok, else: {:error, :invalid_origin})
        _ -> {:error, :invalid_origin}
      end
    end

    defp maybe_decode_post_message(body) when is_binary(body) do
      case JSON.decode(body) do
        {:ok, message} when is_map(message) ->
          {:ok, message}

        {:ok, _invalid} ->
          {:error, :invalid_request}

        {:error, reason} ->
          log_invalid_post_body(body, reason)
      end
    end

    defp maybe_decode_post_message(body) when is_map(body), do: {:ok, body}
    defp maybe_decode_post_message(_body), do: {:error, :invalid_request}

    defp log_invalid_post_body(body, reason) do
      Logging.transport_event(
        "parse_error",
        %{body: body, reason: inspect(reason)},
        level: :error
      )

      {:error, :invalid_json}
    end

    defp validate_legacy_message(message) do
      case Message.validate_message(message) do
        {:ok, validated} -> {:ok, validated}
        {:error, _reason} -> {:error, :invalid_json}
      end
    end

    defp validate_modern_request(message) when is_map(message) do
      id = message["id"]

      if message["jsonrpc"] == "2.0" and
           is_binary(message["method"]) and
           (is_binary(id) or is_integer(id)) and
           is_map(message["params"]) and
           not Map.has_key?(message, "result") and
           not Map.has_key?(message, "error") do
        :ok
      else
        {:error, Error.protocol(:invalid_request)}
      end
    end

    defp maybe_add_session_header(conn, session_header, session_id) do
      if get_req_header(conn, session_header) == [] do
        put_resp_header(conn, session_header, session_id)
      else
        conn
      end
    end

    defp maybe_read_request_body(%{body_params: %Unfetched{aspect: :body_params}} = conn, %{
           timeout: timeout
         }) do
      case Plug.Conn.read_body(conn, read_timeout: timeout) do
        {:ok, body, conn} -> {:ok, body, conn}
        {:error, reason} -> {:error, reason}
      end
    end

    defp maybe_read_request_body(%{body_params: body} = conn, _), do: {:ok, body, conn}

    defp send_error(conn, status, message) do
      data = %{data: %{message: message, http_status: status}}

      mcp_error =
        case status do
          404 -> Error.protocol(:invalid_request, data)
          405 -> Error.protocol(:method_not_found, data)
          406 -> Error.protocol(:invalid_request, data)
          status when status in [400, 403] -> Error.protocol(:invalid_request, data)
          _ -> Error.protocol(:internal_error, data)
        end

      {:ok, error_response} = Error.to_json_rpc(mcp_error, ID.generate_error_id())

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, error_response)
    end

    defp send_jsonrpc_error(conn, %Error{} = error, id) do
      error_id = id || ID.generate_error_id()
      {:ok, encoded_error} = Error.to_json_rpc(error, error_id)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, encoded_error)
    end

    defp handle_request_error(conn, %Error{} = error, body) do
      send_jsonrpc_error(conn, error, extract_request_id(body))
    end

    defp handle_request_error(conn, reason, body) do
      Logging.transport_event("request_error", %{reason: reason}, level: :error)

      send_jsonrpc_error(
        conn,
        Error.protocol(:internal_error, %{reason: reason}),
        extract_request_id(body)
      )
    end

    defp extract_request_id(%{"id" => request_id}), do: request_id
    defp extract_request_id(_), do: nil

    defp build_request_context(conn, auth_claims) do
      %{
        assigns: conn.assigns,
        type: :http,
        req_headers: conn.req_headers,
        query_params: fetch_query_params_safe(conn),
        remote_ip: conn.remote_ip,
        scheme: conn.scheme,
        host: conn.host,
        port: conn.port,
        request_path: conn.request_path,
        auth: auth_claims
      }
    end

    defp handle_well_known(conn, %{authorization: nil}) do
      send_error(conn, 404, "Not found")
    end

    defp handle_well_known(conn, %{authorization: auth_config}) do
      metadata = Authorization.build_resource_metadata(auth_config)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(metadata))
    end

    defp authorize(conn, %{authorization: nil}), do: {:ok, conn, nil}

    defp authorize(conn, %{authorization: auth_config}) do
      case extract_bearer_token(conn) do
        {:ok, token} ->
          validate_bearer_token(conn, token, auth_config)

        {:error, :missing_token} ->
          www_auth = Authorization.build_www_authenticate(auth_config, :unauthorized)

          conn =
            conn
            |> put_resp_header("www-authenticate", www_auth)
            |> put_resp_content_type("application/json")
            |> send_resp(401, JSON.encode!(%{"error" => "unauthorized"}))
            |> halt()

          {:halt, conn}
      end
    end

    defp validate_bearer_token(conn, token, auth_config) do
      {validator_mod, validator_opts} = auth_config.validator
      _ = validator_opts

      Telemetry.execute(
        [:server, :authorization, :validate],
        %{system_time: System.system_time()},
        %{validator: validator_mod}
      )

      case validator_mod.validate_token(token, auth_config) do
        {:ok, raw_claims} ->
          claims = Authorization.normalize_claims(raw_claims)

          with :ok <- Authorization.validate_expiry(claims),
               :ok <- Authorization.validate_audience(claims, auth_config) do
            {:ok, conn, claims}
          else
            {:error, :token_expired} ->
              send_auth_error(conn, auth_config, 401, :unauthorized)

            {:error, :invalid_audience} ->
              send_auth_error(conn, auth_config, 401, :unauthorized)
          end

        {:error, _reason} ->
          send_auth_error(conn, auth_config, 401, :unauthorized)
      end
    end

    defp send_auth_error(conn, auth_config, 401, :unauthorized) do
      www_auth = Authorization.build_www_authenticate(auth_config, :unauthorized)

      conn =
        conn
        |> put_resp_header("www-authenticate", www_auth)
        |> put_resp_content_type("application/json")
        |> send_resp(401, JSON.encode!(%{"error" => "unauthorized"}))
        |> halt()

      {:halt, conn}
    end

    defp extract_bearer_token(conn) do
      conn
      |> get_req_header("authorization")
      |> List.first()
      |> parse_bearer_header()
    end

    defp parse_bearer_header(header) when is_binary(header) do
      case String.split(header, ~r/\s+/, parts: 2) do
        [scheme, token] ->
          if String.downcase(scheme) == "bearer" and token != "" do
            {:ok, String.trim(token)}
          else
            {:error, :missing_token}
          end

        _ ->
          {:error, :missing_token}
      end
    end

    defp parse_bearer_header(_), do: {:error, :missing_token}

    defp fetch_query_params_safe(conn) do
      case conn.query_params do
        %Unfetched{} -> nil
        params -> params
      end
    end

    defp start_sse_streaming(conn, params) do
      %{transport: transport, session_id: session_id, session_header: session_header} = params
      handler_pid = self()

      conn
      |> put_resp_header(session_header, session_id)
      |> Streaming.prepare_connection()
      |> Streaming.start(transport, session_id,
        on_close: fn ->
          StreamableHTTP.unregister_sse_handler(transport, session_id, handler_pid)
        end
      )
    end

    defp delete_session_from_store(session_id) do
      if store = Backplane.McpProtocol.get_session_store_adapter() do
        store.delete(session_id, [])
      end
    end

    defp stop_session_process(%{server: server, registry_mod: registry_mod}, session_id) do
      ServerSupervisor.stop_session(server, registry_mod, session_id)
    end
  end
end
