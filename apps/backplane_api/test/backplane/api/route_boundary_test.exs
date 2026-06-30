defmodule Backplane.Api.RouteBoundaryTest do
  use Backplane.Api.ConnCase, async: false

  alias Backplane.Auth

  test "serves public home page", %{conn: conn} do
    conn = get(conn, "/")

    assert html_response(conn, 200) =~ "One public surface for agents, tools, and model traffic"
  end

  test "does not serve admin routes", %{conn: conn} do
    assert get(conn, "/dashboard/overview") |> response(404)
    assert get(conn, "/admin/dashboard/overview") |> response(404)
  end

  test "does not serve provider or operational routes", %{conn: conn} do
    assert get(conn, "/llm/providers") |> response(404)
    assert post(conn, "/llm/providers", %{}) |> response(404)
    assert get(conn, "/llm/aliases") |> response(404)
    assert post(conn, "/llm/aliases", %{}) |> response(404)
    assert get(conn, "/health") |> response(404)
    assert get(conn, "/metrics") |> response(404)
    assert get(conn, "/metrics/prometheus") |> response(404)
  end

  @tag timeout: 5_000
  test "HEAD /mcp returns 204 without opening the SSE stream", %{conn: conn} do
    # Runs through the full endpoint (incl. Plug.Head). Without the short-circuit
    # the HEAD would reach the SSE handler and stream forever, so dispatch in a
    # task and fail fast instead of hanging if that regresses.
    task = Task.async(fn -> head(conn, "/mcp") end)

    conn =
      case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, conn} -> conn
        nil -> flunk("HEAD /mcp opened the SSE stream instead of returning immediately")
      end

    assert response(conn, 204) == ""
  end

  test "does not serve retired /api-prefixed public routes", %{conn: conn} do
    assert post(conn, "/api/mcp", %{}) |> response(404)
    assert get(conn, "/api/v1/models") |> response(404)
    assert post(conn, "/api/anthropic/v1/messages", %{}) |> response(404)
    assert get(conn, "/api/skills") |> response(404)
    assert get(conn, "/api/host-agent/skills/repo-review/download") |> response(404)
  end

  test "Backplane Auth tokens do not change existing service route auth behavior", %{conn: conn} do
    access_token = issue_auth_access_token!()

    mcp_conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1}))

    assert json_response(mcp_conn, 200)["result"]["serverInfo"]["name"] == "backplane"
    assert get_resp_header(mcp_conn, "location") == []
    assert get_resp_header(mcp_conn, "www-authenticate") == []

    models_conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> get("/v1/models")

    assert json_response(models_conn, 200)["object"] == "list"
    assert get_resp_header(models_conn, "location") == []
    assert get_resp_header(models_conn, "www-authenticate") == []

    skills_conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> get("/skills")

    assert json_response(skills_conn, 200)["data"] == []
    assert get_resp_header(skills_conn, "location") == []
    assert get_resp_header(skills_conn, "www-authenticate") == []

    host_agent_conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> get("/host-agent/skills/repo-review/download")

    assert response(host_agent_conn, 404) == "not found"
    assert get_resp_header(host_agent_conn, "location") == []
    assert get_resp_header(host_agent_conn, "www-authenticate") == []
  end

  defp issue_auth_access_token! do
    {:ok, user} =
      Auth.Accounts.create_user(%{
        email: "route-boundary-#{System.unique_integer([:positive])}@example.com",
        name: "Route Boundary"
      })

    {:ok, %{client: client}} =
      Auth.OAuth.create_client(%{
        name: "Route Boundary App",
        redirect_uris: ["https://app.example.test/auth/callback"],
        scopes: ["openid", "profile", "email"],
        confidential: true,
        pkce: true
      })

    {:ok, tokens} = Auth.Tokens.issue_access_token(user, client, ["openid", "profile", "email"])
    tokens.access_token
  end
end
