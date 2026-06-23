defmodule Backplane.Api.Endpoint do
  use Phoenix.Endpoint, otp_app: :backplane_api

  @session_options [
    store: :cookie,
    key: "_backplane_api_key",
    signing_salt: "bkpln_salt",
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
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(Backplane.Api.Router)
end
