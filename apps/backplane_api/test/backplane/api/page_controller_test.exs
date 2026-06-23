defmodule Backplane.Api.PageControllerTest do
  use Backplane.Api.ConnCase, async: false

  test "GET / renders public project setup documentation without admin auth", %{conn: conn} do
    conn = get(conn, "/")

    assert html_response(conn, 200) =~ "Backplane"
    assert html_response(conn, 200) =~ "LLM API setup"
    assert html_response(conn, 200) =~ "MCP server setup"
    assert html_response(conn, 200) =~ "/admin/llama/providers"
    assert html_response(conn, 200) =~ "/admin/mcp/upstreams"
    assert html_response(conn, 200) =~ "el-dm-button"
    assert html_response(conn, 200) =~ "badge"
    assert html_response(conn, 200) =~ "Claude Code setup"
    assert html_response(conn, 200) =~ "Codex setup"
    assert html_response(conn, 200) =~ "ANTHROPIC_BASE_URL"
    assert html_response(conn, 200) =~ "openai_base_url"
    assert html_response(conn, 200) =~ "~/.codex/config.toml"
    assert html_response(conn, 200) =~ "/api/anthropic"
    assert html_response(conn, 200) =~ "/api/v1"
    assert html_response(conn, 200) =~ "/api/anthropic/v1/models"
    assert html_response(conn, 200) =~ "/api/v1/responses"
    assert html_response(conn, 200) =~ "/api/mcp"
    assert html_response(conn, 200) =~ "appbar"
    assert html_response(conn, 200) =~ "theme-controller-dropdown"
    assert html_response(conn, 200) =~ ~s(phx-hook="ThemeSwitcher")
    assert html_response(conn, 200) =~ "Documentation"
    assert html_response(conn, 200) =~ "Agent setup"
    assert html_response(conn, 200) =~ "<footer"
    assert html_response(conn, 200) =~ "bg-secondary text-secondary-content"
    assert html_response(conn, 200) =~ "Operations first, public by default"
    assert html_response(conn, 200) =~ ~s(id="home-body")
    assert html_response(conn, 200) =~ "max-w-7xl"
  end
end
