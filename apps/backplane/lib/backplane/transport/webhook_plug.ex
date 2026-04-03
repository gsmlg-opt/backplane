defmodule Backplane.Transport.WebhookPlug do
  @moduledoc """
  Plug that handles webhook requests from GitHub and GitLab.
  Forwards to the appropriate handler based on path.
  """

  use Plug.Router

  alias Backplane.Jobs.WebhookHandler

  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    body_reader: {Backplane.Transport.CacheBodyReader, :read_body, []}

  plug :dispatch

  post "/github" do
    handle_webhook(conn, :github)
  end

  post "/gitlab" do
    handle_webhook(conn, :gitlab)
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end

  defp handle_webhook(conn, provider) do
    case WebhookHandler.enqueue(provider, conn.body_params) do
      {:ok, _} ->
        send_resp(conn, 202, Jason.encode!(%{status: "accepted"}))

      {:error, reason} ->
        send_resp(conn, 422, Jason.encode!(%{error: inspect(reason)}))
    end
  end
end
