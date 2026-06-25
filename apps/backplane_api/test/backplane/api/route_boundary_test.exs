defmodule Backplane.Api.RouteBoundaryTest do
  use Backplane.Api.ConnCase, async: false

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
end
