defmodule Backplane.Transport.Router do
  @moduledoc """
  Plug.Router handling the MCP endpoint and webhook endpoints.
  """

  use Plug.Router

  plug(:match)
  plug(Backplane.Transport.AuthPlug)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  post "/mcp" do
    Backplane.Transport.McpHandler.handle(conn)
  end

  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end
end
