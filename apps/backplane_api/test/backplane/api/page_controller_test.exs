defmodule Backplane.Api.PageControllerTest do
  use Backplane.Api.ConnCase, async: false

  test "GET / renders the public gateway overview with docs links", %{conn: conn} do
    conn = get(conn, "/")
    html = html_response(conn, 200)

    assert html =~ "Backplane"
    assert html =~ "Gateway overview"
    assert html =~ "Docs now own the endpoint catalog"

    for docs_path <- [
          "/docs/llama",
          "/docs/mcp",
          "/docs/skills",
          "/docs/agents",
          "/docs/auth"
        ] do
      assert html =~ ~s(href="#{docs_path}")
    end

    assert html =~ ~s(src="/images/backplane-icon.png")
    assert html =~ "appbar"
    assert html =~ ~s(aria-label="Docs")
    assert html =~ ~s(href="/docs")
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

    refute html =~ "All API endpoints"
    refute html =~ "Complete catalog"
    refute html =~ "MCP session API"
    refute html =~ "LLM proxy API"
    refute html =~ "Skills API"
    refute html =~ "Host-agent endpoint"
    refute html =~ "Client configuration"
    refute html =~ "Claude Code"
    refute html =~ "Codex"
    refute html =~ "ANTHROPIC_BASE_URL"
    refute html =~ "openai_base_url"
    refute html =~ "~/.codex/config.toml"
    refute html =~ "POST /mcp"
    refute html =~ "GET /v1/models"
    refute html =~ "/host-agent/socket"
    refute html =~ ~s(href="/#endpoints")
    refute html =~ ~s(href="/#clients")
    refute html =~ "Admin"
    refute html =~ "admin"
    refute html =~ "/dashboard"
    refute html =~ "/system/credentials"
    refute html =~ "/llama/providers"
    refute html =~ "/mcp/upstreams"
    refute html =~ "/system/clients"
    refute html =~ "Provider API"
    refute html =~ "LLM provider API"
    refute html =~ "Health check"
    refute html =~ ~s(aria-label="Health")
    refute html =~ "/llm/providers"
    refute html =~ "/llm/aliases"
    refute html =~ "/health"
    refute html =~ "/metrics"
    refute html =~ "/api"
    refute html =~ "/anthropic"
    refute html =~ "w-auto px-3 rounded-md whitespace-nowrap"
  end

  test "GET /docs renders the public docs index", %{conn: conn} do
    conn = get(conn, "/docs")
    html = html_response(conn, 200)

    assert html =~ "Backplane Docs"
    assert html =~ "Choose a guide"
    assert html =~ ~s(aria-label="Docs")

    for {path, label} <- [
          {"/docs/llama", "LLM proxy"},
          {"/docs/mcp", "MCP hub"},
          {"/docs/skills", "Skills library"},
          {"/docs/agents", "Agent setup"},
          {"/docs/auth", "Authentication"}
        ] do
      assert html =~ ~s(href="#{path}")
      assert html =~ label
    end

    for marker <- [
          "OpenAI-compatible endpoint",
          "GET /v1/models",
          "JSON-RPC requests: initialize, tools/list, tools/call, ping.",
          "POST /mcp",
          "Skill archive routes",
          "GET /skills/export",
          "Claude Code",
          "ANTHROPIC_BASE_URL",
          "Bearer token",
          "Authorization: Bearer"
        ] do
      assert html =~ marker
    end
  end

  test "GET /docs/:section renders public docs sections", %{conn: conn} do
    for {path, heading, markers} <- [
          {"/docs/llama", "LLM proxy",
           [
             "OpenAI-format list of exposed models and aliases",
             "POST /v1/chat/completions",
             "POST /v1/responses",
             "POST /v1/embeddings"
           ]},
          {"/docs/mcp", "MCP hub",
           [
             "JSON-RPC requests: initialize, tools/list, tools/call, ping.",
             "Server-sent event stream for MCP notifications.",
             "DELETE /mcp"
           ]},
          {"/docs/skills", "Skills library",
           [
             "GET /skills/export",
             "POST /skills/import",
             "GET /skills/:slug/archive",
             "DELETE /skills/:slug"
           ]},
          {"/docs/agents", "Agent setup",
           [
             "Claude Code",
             "ANTHROPIC_BASE_URL",
             "claude mcp add --transport http",
             "~/.codex/config.toml",
             "openai_base_url",
             "mcp_servers.backplane"
           ]},
          {"/docs/auth", "Authentication",
           [
             "Bearer token",
             "Authorization: Bearer",
             "GET /oauth/authorize",
             "POST /oauth/token"
           ]}
        ] do
      html =
        conn
        |> recycle()
        |> get(path)
        |> html_response(200)

      assert html =~ "Backplane Docs"
      assert html =~ heading
      assert html =~ ~s(href="/docs")

      for marker <- markers do
        assert html =~ marker
      end
    end
  end

  test "GET /docs/:section returns not found for unknown docs sections", %{conn: conn} do
    conn = get(conn, "/docs/unknown")

    assert response(conn, 404)
  end
end
