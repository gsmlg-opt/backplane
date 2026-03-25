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

  post "/webhook/github" do
    handle_webhook(conn, :github)
  end

  post "/webhook/gitlab" do
    handle_webhook(conn, :gitlab)
  end

  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end

  defp handle_webhook(conn, provider) do
    case Backplane.Jobs.WebhookHandler.enqueue(provider, conn.body_params) do
      {:ok, _} ->
        send_resp(conn, 202, Jason.encode!(%{status: "accepted"}))

      {:error, reason} ->
        send_resp(conn, 422, Jason.encode!(%{error: inspect(reason)}))
    end
  end
end
