defmodule Backplane.Transport.Router do
  @moduledoc """
  Plug.Router handling the MCP endpoint and webhook endpoints.
  """

  use Plug.Router

  alias Backplane.Jobs.WebhookHandler
  alias Backplane.Transport.{HealthCheck, McpHandler}

  plug(:match)
  plug(Backplane.Transport.AuthPlug)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  post "/mcp" do
    McpHandler.handle(conn)
  end

  post "/webhook/github" do
    handle_webhook(conn, :github)
  end

  post "/webhook/gitlab" do
    handle_webhook(conn, :gitlab)
  end

  get "/health" do
    health = HealthCheck.check()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(health))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end

  defp handle_webhook(conn, provider) do
    case validate_webhook(conn, provider) do
      :ok ->
        case WebhookHandler.enqueue(provider, conn.body_params) do
          {:ok, _} ->
            send_resp(conn, 202, Jason.encode!(%{status: "accepted"}))

          {:error, reason} ->
            send_resp(conn, 422, Jason.encode!(%{error: inspect(reason)}))
        end

      {:error, :no_secret} ->
        # No webhook secret configured — accept without validation
        case WebhookHandler.enqueue(provider, conn.body_params) do
          {:ok, _} ->
            send_resp(conn, 202, Jason.encode!(%{status: "accepted"}))

          {:error, reason} ->
            send_resp(conn, 422, Jason.encode!(%{error: inspect(reason)}))
        end

      {:error, :invalid_signature} ->
        send_resp(conn, 401, Jason.encode!(%{error: "Invalid webhook signature"}))
    end
  end

  defp validate_webhook(conn, :github) do
    with secret when not is_nil(secret) <-
           Application.get_env(:backplane, :github_webhook_secret),
         payload = Jason.encode!(conn.body_params),
         [signature] <- Plug.Conn.get_req_header(conn, "x-hub-signature-256"),
         true <- WebhookHandler.validate_github_signature(payload, signature, secret) do
      :ok
    else
      nil -> {:error, :no_secret}
      _ -> {:error, :invalid_signature}
    end
  end

  defp validate_webhook(conn, :gitlab) do
    with expected when not is_nil(expected) <-
           Application.get_env(:backplane, :gitlab_webhook_token),
         [token] <- Plug.Conn.get_req_header(conn, "x-gitlab-token"),
         true <- WebhookHandler.validate_gitlab_token(token, expected) do
      :ok
    else
      nil -> {:error, :no_secret}
      _ -> {:error, :invalid_signature}
    end
  end
end
