defmodule Backplane.Skills.HostAgentApiRouter do
  @moduledoc """
  Retired HTTP API namespace for host agents.

  Host-agent identity and bundle transfer now happen through the WebSocket
  manager channel. The router remains mounted so old URLs fail with a stable
  404 instead of falling through to Phoenix browser routes.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  match _ do
    send_resp(conn, 404, "not found")
  end
end
