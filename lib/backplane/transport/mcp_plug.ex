defmodule Backplane.Transport.McpPlug do
  @moduledoc """
  Plug that handles MCP JSON-RPC requests.
  When forwarded from Phoenix Router at /mcp, handles POST/GET/DELETE at root.
  """

  use Plug.Router

  require Logger

  alias Backplane.Notifications
  alias Backplane.Transport.{McpHandler, CacheBodyReader}

  plug Backplane.Transport.VersionHeader
  plug Backplane.Transport.CORS
  plug :match
  plug Backplane.Transport.Compression
  plug Backplane.Transport.RequestLogger
  plug Backplane.Transport.RateLimiter
  plug Backplane.Transport.AuthPlug
  plug Backplane.Transport.Idempotency

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 1_000_000,
    body_reader: {CacheBodyReader, :read_body, []}

  plug :dispatch

  post "/" do
    McpHandler.handle(conn)
  end

  delete "/" do
    send_resp(conn, 200, "")
  end

  get "/" do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
    |> sse_notification_loop()
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end

  @sse_keepalive_ms 30_000

  defp sse_notification_loop(conn) do
    Notifications.subscribe()
    sse_loop(conn)
  after
    Notifications.unsubscribe()
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
