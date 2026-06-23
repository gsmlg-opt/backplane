defmodule Backplane.Api.PageControllerTest do
  use Backplane.Api.ConnCase, async: false

  test "GET / renders the public gateway reference", %{conn: conn} do
    conn = get(conn, "/")
    html = html_response(conn, 200)

    assert html =~ "Backplane"
    assert html =~ "All API endpoints"
    assert html =~ "Complete catalog"
    assert html =~ "MCP session API"
    assert html =~ "LLM proxy API"
    assert html =~ "LLM provider API"
    assert html =~ "Skills API"
    assert html =~ "Host-agent and runtime endpoints"
    assert html =~ "Client configuration"
    assert html =~ "Health check"
    assert html =~ "Claude Code"
    assert html =~ "Codex"
    assert html =~ "ANTHROPIC_BASE_URL"
    assert html =~ "openai_base_url"
    assert html =~ "~/.codex/config.toml"

    for endpoint <- [
          "POST /mcp",
          "GET /mcp",
          "DELETE /mcp",
          "GET /v1/models",
          "POST /v1/messages",
          "POST /v1/chat/completions",
          "POST /v1/responses",
          "POST /v1/embeddings",
          "/v1/*",
          "/llm/providers",
          "/llm/providers/:id",
          "/llm/aliases",
          "/llm/aliases/:id",
          "/skills",
          "/skills/export",
          "/skills/import",
          "/skills/:slug",
          "/skills/:slug/archive",
          "/host-agent/socket",
          "/health",
          "/metrics",
          "/metrics/prometheus"
        ] do
      assert html =~ endpoint
    end

    assert html =~ "PATCH"
    assert html =~ "WS"
    assert html =~ ~s(src="/images/backplane-icon.png")
    assert html =~ "appbar"
    assert html =~ ~s(aria-label="Endpoints")
    assert html =~ ~s(aria-label="Clients")
    assert html =~ ~s(aria-label="Health")
    assert html =~ "theme-controller-dropdown"
    assert html =~ "theme-controller-dropdown-icon"
    assert html =~ ~s(aria-label="Select theme")
    assert html =~ ~s(<span class="sr-only">Theme</span>)
    assert html =~ ~s(<svg xmlns="http://www.w3.org/2000/svg")
    assert html =~ ~s(phx-hook="ThemeSwitcher")
    assert html =~ "<footer"
    assert html =~ "bg-secondary text-secondary-content"
    assert html =~ "Public gateway contract"
    assert html =~ ~s(id="home-body")
    assert html =~ "max-w-7xl"

    refute html =~ "Admin"
    refute html =~ "admin"
    refute html =~ "/dashboard"
    refute html =~ "/system/credentials"
    refute html =~ "/llama/providers"
    refute html =~ "/mcp/upstreams"
    refute html =~ "/system/clients"
    refute html =~ "/api"
    refute html =~ "/anthropic"
    refute html =~ "w-auto px-3 rounded-md whitespace-nowrap"
  end
end
