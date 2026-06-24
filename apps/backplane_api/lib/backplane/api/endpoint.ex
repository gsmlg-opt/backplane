defmodule Backplane.Api.Endpoint do
  use Phoenix.Endpoint, otp_app: :backplane_api

  @session_options [
    store: :cookie,
    key: "_backplane_api_key",
    signing_salt: "bkpln_api_salt",
    same_site: "Lax"
  ]

  socket("/host-agent/socket", Backplane.Api.HostAgentSocket,
    websocket: [connect_info: [:x_headers, :peer_data]],
    longpoll: false
  )

  plug(Plug.Static,
    at: "/",
    from: :backplane_api,
    gzip: false,
    only: Backplane.Api.static_paths()
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Backplane.LLM.ProxyPlug)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  # Short-circuit HEAD on the MCP endpoint before Plug.Head rewrites it to GET.
  # Otherwise a HEAD hits the SSE stream handler and never completes, pinning the
  # upstream connection a reverse proxy may reuse for the next request.
  plug(:mcp_head_no_content)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(Backplane.Api.Router)

  defp mcp_head_no_content(%Plug.Conn{method: "HEAD", path_info: ["mcp" | _]} = conn, _opts) do
    conn |> send_resp(204, "") |> halt()
  end

  defp mcp_head_no_content(conn, _opts), do: conn
end
