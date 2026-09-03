defmodule Backplane.Transport.McpPlug do
  @moduledoc """
  Plug that handles MCP JSON-RPC requests.
  When forwarded from Phoenix Router at /mcp, handles POST/GET/DELETE at root.
  """

  use Plug.Router

  require Logger

  alias Backplane.MCP.{Info, ModernServer, SSE}
  alias Backplane.McpProtocol.Server.Transport.StreamableHTTP.ModernRequest
  alias Backplane.MCP.AccessEvent
  alias Backplane.Transport.{
    CacheBodyReader,
    McpEraRouter,
    McpHandler,
    McpObservability,
    Session,
    VersionHeader
  }

  @modern_protocol_version "2026-07-28"
  @modern_request_timeout 30_000

  plug Backplane.Transport.VersionHeader
  plug :assign_protocol_version_hint
  plug Backplane.Transport.CORS
  plug :short_circuit_head_root
  plug :match
  plug Backplane.Transport.Compression
  plug Backplane.Transport.RateLimiter
  plug Backplane.Auth.ResourceAuthPlug, resource: :mcp

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 1_000_000,
    body_reader: {CacheBodyReader, :read_body, []}

  plug :assign_mcp_route
  # Composite idempotency keys depend on trusted auth, parsed/raw body, and the assigned MCP era.
  plug Backplane.Transport.Idempotency
  plug :dispatch

  post "/" do
    case conn.assigns.mcp_route do
      {:ok, :legacy} -> McpHandler.handle(conn)
      {:ok, {:modern, _profile}} -> dispatch_modern(conn)
      {:error, _error} -> dispatch_modern(conn)
    end
  end

  delete "/" do
    if McpEraRouter.modern_header?(conn.req_headers) do
      method_not_allowed(conn)
    else
      case get_req_header(conn, "mcp-session-id") do
        [session_id | _] -> Session.delete(session_id)
        [] -> :ok
      end

      send_resp(conn, 200, "")
    end
  end

  get "/" do
    if McpEraRouter.modern_header?(conn.req_headers) do
      method_not_allowed(conn)
    else
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)
      |> sse_notification_loop()
    end
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end

  @sse_keepalive_ms 30_000

  defp short_circuit_head_root(%{method: "HEAD", path_info: []} = conn, _opts) do
    conn
    |> Plug.Conn.send_resp(204, "")
    |> Plug.Conn.halt()
  end

  defp short_circuit_head_root(conn, _opts), do: conn

  defp assign_protocol_version_hint(conn, _opts) do
    version =
      if McpEraRouter.modern_header?(conn.req_headers),
        do: @modern_protocol_version,
        else: stored_session_version(conn)

    Plug.Conn.assign(conn, :mcp_protocol_version, version)
  end

  defp stored_session_version(conn) do
    with [session_id] when is_binary(session_id) and session_id != "" <-
           get_req_header(conn, "mcp-session-id"),
         %{protocol_version: version} when is_binary(version) <- Session.get(session_id),
         true <- version in Info.supported_versions() do
      version
    else
      _invalid_or_unknown -> Info.protocol_version()
    end
  rescue
    ArgumentError -> Info.protocol_version()
  end

  defp assign_mcp_route(conn, _opts) do
    route = McpEraRouter.route(conn.body_params, conn.req_headers)
    era = McpEraRouter.era(route)

    conn =
      conn
      |> Plug.Conn.assign(:mcp_route, route)
      |> Plug.Conn.assign(:mcp_era, era)

    if era == :modern,
      do: Plug.Conn.assign(conn, :mcp_protocol_version, @modern_protocol_version),
      else: conn
  end

  defp dispatch_modern(conn) do
    assigns =
      conn.assigns
      |> Map.take([:resource_auth, :tool_scopes, :client])
      |> Map.put(:observability, Backplane.MCP.ObservabilityContext.from_conn(conn))

    transport_context = %{
      type: :http,
      req_headers: conn.req_headers,
      remote_ip: conn.remote_ip,
      auth: assigns[:resource_auth],
      assigns: assigns,
      connection_era: if(get_req_header(conn, "mcp-session-id") == [], do: nil, else: :legacy)
    }

    ModernRequest.call(conn, conn.body_params, transport_context,
      server: ModernServer,
      task_supervisor: Backplane.MCP.ModernTaskSupervisor,
      timeout: @modern_request_timeout,
      subscriptions: nil
    )
  end

  defp method_not_allowed(conn), do: send_resp(conn, 405, "")

  defp sse_notification_loop(conn) do
    Phoenix.PubSub.subscribe(Backplane.PubSub, "mcp:notifications")

    # Probe the connection immediately. A peer that has already gone away
    # is detected on this first write instead of after a full keepalive
    # interval, so the upstream connection isn't pinned needlessly.
    case Plug.Conn.chunk(conn, ": connected\n\n") do
      {:ok, conn} -> sse_loop(conn)
      {:error, _} -> conn
    end
  after
    Phoenix.PubSub.unsubscribe(Backplane.PubSub, "mcp:notifications")
  end

  defp sse_loop(conn) do
    receive do
      {:mcp_notification, notification} ->
        chunk_data = SSE.encode("message", notification)

        case Plug.Conn.chunk(conn, chunk_data) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    after
      @sse_keepalive_ms ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  @doc false
  def call(conn, opts) do
    conn = McpObservability.call(conn, McpObservability.init([]))
    super(conn, opts)
  rescue
    e in Plug.Parsers.ParseError ->
      Logger.warning("Malformed request body: #{Exception.message(e)}")

      conn =
        conn
        |> VersionHeader.call([])
        |> assign_protocol_version_hint([])
        |> put_resp_content_type("application/json")

      body = Jason.encode!(%{error: "Malformed request body"})

      conn =
        if McpEraRouter.modern_header?(conn.req_headers) do
          ModernRequest.parse_error(conn)
        else
          finalize_parser_error(conn, 400, body, :error,
            error_kind: "validation",
            error_message: "Malformed request body"
          )
        end

      conn

    e in Plug.Parsers.RequestTooLargeError ->
      Logger.warning("Request body too large: #{Exception.message(e)}")

      body = Jason.encode!(%{error: "Request body too large"})

      conn
      |> VersionHeader.call([])
      |> assign_protocol_version_hint([])
      |> put_resp_content_type("application/json")
      |> finalize_parser_error(413, body, :error,
        error_kind: "validation",
        error_message: "Request body too large"
      )
  end

  defp finalize_parser_error(conn, status, body, outcome, opts) do
    access = Map.get(conn.assigns, :mcp_access_event) || AccessEvent.start(conn)

    :ok =
      AccessEvent.finalize(
        access,
        %{conn | status: status, resp_body: body},
        outcome,
        Keyword.merge([status: status], opts)
      )

    conn
    |> Plug.Conn.assign(:mcp_access_finalized, true)
    |> send_resp(status, body)
  end
end
