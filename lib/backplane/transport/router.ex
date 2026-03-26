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
    length: 1_000_000,
    body_reader: {Backplane.Transport.CacheBodyReader, :read_body, []}
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
    case find_webhook_secret(conn.body_params, :github) do
      nil ->
        {:error, :no_secret}

      secret ->
        with raw_body when is_binary(raw_body) <- conn.assigns[:raw_body],
             [signature] <- Plug.Conn.get_req_header(conn, "x-hub-signature-256"),
             true <- WebhookHandler.validate_github_signature(raw_body, signature, secret) do
          :ok
        else
          _ -> {:error, :invalid_signature}
        end
    end
  end

  defp validate_webhook(conn, :gitlab) do
    case find_webhook_secret(conn.body_params, :gitlab) do
      nil ->
        {:error, :no_secret}

      expected ->
        with [token] <- Plug.Conn.get_req_header(conn, "x-gitlab-token"),
             true <- WebhookHandler.validate_gitlab_token(token, expected) do
          :ok
        else
          _ -> {:error, :invalid_signature}
        end
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
    normalized_url = normalize_repo_url(repo_url)

    Application.get_env(:backplane, :projects, [])
    |> Enum.find_value(fn project ->
      if repo_url_matches?(project.repo, normalized_url), do: project[:webhook_secret]
    end)
  end

  # Project repo is "github:owner/repo" or "gitlab:owner/repo" format.
  # Webhook repo_url is a full URL like "https://github.com/owner/repo.git".
  # Compare by extracting owner/repo from both.
  defp repo_url_matches?(project_repo, normalized_webhook_url) do
    case String.split(project_repo, ":", parts: 2) do
      [_provider, repo_id] -> normalize_repo_url(repo_id) == normalized_webhook_url
      _ -> false
    end
  end

  # Extract "owner/repo" from various URL formats, stripping .git suffix
  defp normalize_repo_url(url) do
    url
    |> String.replace(~r{^https?://[^/]+/}, "")
    |> String.trim_trailing(".git")
    |> String.trim_trailing("/")
    |> String.downcase()
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
