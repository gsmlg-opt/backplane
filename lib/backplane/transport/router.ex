defmodule Backplane.Transport.Router do
  @moduledoc """
  Plug.Router handling the MCP endpoint and webhook endpoints.
  """

  use Plug.Router

  require Logger

  alias Backplane.Jobs.WebhookHandler
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
    length: 1_000_000
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
    # Used for server-initiated notifications (e.g., tools/list_changed)
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_resp(200, "")
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

  get "/metrics" do
    metrics = Metrics.snapshot()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(metrics))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end

  defp handle_webhook(conn, provider) do
    case validate_webhook(conn, provider) do
      result when result in [:ok, {:error, :no_secret}] ->
        # :no_secret means no webhook secret configured — accept without validation
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
    secret = find_webhook_secret(conn.body_params, :github)

    with secret when not is_nil(secret) <- secret,
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
    secret = find_webhook_secret(conn.body_params, :gitlab)

    with expected when not is_nil(expected) <- secret,
         [token] <- Plug.Conn.get_req_header(conn, "x-gitlab-token"),
         true <- WebhookHandler.validate_gitlab_token(token, expected) do
      :ok
    else
      nil -> {:error, :no_secret}
      _ -> {:error, :invalid_signature}
    end
  end

  # Look up the webhook secret for this event's repository.
  # First checks per-project config, then falls back to the global secret.
  defp find_webhook_secret(params, provider) do
    repo_url = extract_repo_url(params, provider)
    project_secret = repo_url && find_project_secret(repo_url)

    project_secret || global_webhook_secret(provider)
  end

  defp extract_repo_url(%{"repository" => %{"clone_url" => url}}, :github), do: url
  defp extract_repo_url(%{"repository" => %{"html_url" => url}}, :github), do: url <> ".git"
  defp extract_repo_url(%{"project" => %{"git_http_url" => url}}, :gitlab), do: url
  defp extract_repo_url(_, _), do: nil

  defp find_project_secret(repo_url) do
    Application.get_env(:backplane, :projects, [])
    |> Enum.find_value(fn project ->
      if project.repo == repo_url, do: project[:webhook_secret]
    end)
  end

  defp global_webhook_secret(:github),
    do: Application.get_env(:backplane, :github_webhook_secret)

  defp global_webhook_secret(:gitlab),
    do: Application.get_env(:backplane, :gitlab_webhook_token)

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
