defmodule Backplane.Transport.Router do
  @moduledoc """
  Plug.Router handling the MCP endpoint and webhook endpoints.
  """

  use Plug.Router

  require Logger

  alias Backplane.Metrics
  alias Backplane.Transport.{HealthCheck, McpHandler}

  plug(Plug.RequestId)
  plug(Backplane.Transport.VersionHeader)
  plug(Backplane.Transport.CORS)
  plug(:match)
  plug(Backplane.Transport.Compression)
  plug(Backplane.Transport.RequestLogger)
  plug(Backplane.Transport.RateLimiter)
  plug(Backplane.Transport.AuthPlug)
  plug(Backplane.Transport.Idempotency)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 1_000_000,
    body_reader: {Backplane.Transport.CacheBodyReader, :read_body, []}
  )

  plug(:dispatch)

  post "/mcp" do
    McpHandler.handle(conn)
  end

  delete "/mcp" do
    # MCP Streamable HTTP session termination
    # Backplane is stateless per-request, so we just acknowledge
    send_resp(conn, 200, "")
  end

  get "/mcp" do
    # MCP Streamable HTTP server-to-client SSE stream
    # Holds the connection open and forwards server-initiated notifications
    # (tools/list_changed, resources/list_changed, prompts/list_changed)
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
    |> sse_notification_loop()
  end

  get "/health" do
    health = HealthCheck.check()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(health))
  end

  get "/metrics" do
    metrics = Metrics.snapshot()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(metrics))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end

  # Hold SSE connection open, forwarding server notifications until client disconnects.
  # Uses a 30s keepalive ping to detect dead connections.
  @sse_keepalive_ms 30_000

  defp sse_notification_loop(conn) do
    Phoenix.PubSub.subscribe(Backplane.PubSub, "mcp:notifications")
    sse_loop(conn)
  after
    Phoenix.PubSub.unsubscribe(Backplane.PubSub, "mcp:notifications")
  end

  defp sse_loop(conn) do
    receive do
      {:mcp_notification, notification} ->
        data = Jason.encode!(notification)
        chunk_data = "event: message\ndata: #{data}\n\n"

        case Plug.Conn.chunk(conn, chunk_data) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    after
      @sse_keepalive_ms ->
        # Send SSE comment as keepalive
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  @doc false
  def call(conn, opts) do
    super(conn, opts)
  rescue
    e in Plug.Parsers.ParseError ->
      Logger.warning("Malformed request body: #{Exception.message(e)}")
      send_resp(conn, 400, Jason.encode!(%{error: "Malformed request body"}))

    e in Plug.Parsers.RequestTooLargeError ->
      Logger.warning("Request body too large: #{Exception.message(e)}")
      send_resp(conn, 413, Jason.encode!(%{error: "Request body too large"}))
  end
end
