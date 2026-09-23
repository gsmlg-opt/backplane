defmodule Backplane.LLM.Google.Error do
  @moduledoc false

  import Plug.Conn

  @status_names %{
    400 => "INVALID_ARGUMENT",
    401 => "UNAUTHENTICATED",
    403 => "PERMISSION_DENIED",
    404 => "NOT_FOUND",
    405 => "METHOD_NOT_ALLOWED",
    413 => "RESOURCE_EXHAUSTED",
    429 => "RESOURCE_EXHAUSTED",
    500 => "INTERNAL",
    502 => "UNAVAILABLE",
    503 => "UNAVAILABLE",
    504 => "DEADLINE_EXCEEDED"
  }

  def send(conn, status, message, details \\ []) do
    error = %{
      "code" => status,
      "message" => message,
      "status" => Map.get(@status_names, status, "UNKNOWN")
    }

    error = if details == [], do: error, else: Map.put(error, "details", details)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => error}))
    |> halt()
  end

  def proxy(conn, reason) do
    case reason do
      :request_too_large -> send(conn, 413, "Request body too large")
      :upstream_timeout -> send(conn, 504, "Upstream request timed out")
      :response_too_large -> send(conn, 502, "Upstream response exceeded the configured limit")
      _ -> send(conn, 502, "Google upstream is unavailable")
    end
  end
end
