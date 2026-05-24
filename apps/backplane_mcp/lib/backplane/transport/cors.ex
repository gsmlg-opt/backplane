defmodule Backplane.Transport.CORS do
  @moduledoc """
  CORS plug for browser-based MCP clients.

  Handles preflight OPTIONS requests and adds Access-Control headers.

  ## Configuration

      config :backplane, Backplane.Transport.CORS,
        allowed_origins: ["*"]

  Default: allow all origins.
  """

  import Plug.Conn
  @behaviour Plug

  @default_allowed_origins ["*"]
  @allowed_methods "GET, POST, DELETE, OPTIONS"
  @allowed_headers "Content-Type, Authorization, Accept, Mcp-Session-Id"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "OPTIONS"} = conn, _opts) do
    conn
    |> add_cors_headers()
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, _opts) do
    Plug.Conn.register_before_send(conn, &add_cors_headers/1)
  end

  defp add_cors_headers(conn) do
    case get_allowed_origin(conn) do
      nil ->
        conn

      origin ->
        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("access-control-allow-methods", @allowed_methods)
        |> put_resp_header("access-control-allow-headers", @allowed_headers)
        |> put_resp_header("access-control-max-age", "86400")
    end
  end

  defp get_allowed_origin(conn) do
    allowed = config(:allowed_origins, @default_allowed_origins)

    if "*" in allowed do
      "*"
    else
      request_origin =
        conn
        |> get_req_header("origin")
        |> List.first("")

      if request_origin in allowed, do: request_origin, else: nil
    end
  end

  defp config(key, default) do
    :backplane
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
