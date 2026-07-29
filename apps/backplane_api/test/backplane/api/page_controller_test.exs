defmodule Backplane.Api.PageControllerTest do
  use Backplane.Api.ConnCase, async: false

  alias Backplane.Auth
  alias Boruta.Ecto.Admin

  @base_url "https://gateway.example.test"
  @stored_oauth_secret "docs-regression-secret-must-never-render"
  @canonical_guides [
    {"/docs/mcp", "MCP hub"},
    {"/docs/llm", "LLM proxy"},
    {"/docs/agents", "Agent setup"},
    {"/docs/authentication", "Authentication"}
  ]

  setup do
    old_url = Application.get_env(:backplane, :api_url)
    Application.put_env(:backplane, :api_url, @base_url <> "/")

    on_exit(fn -> restore_env(:api_url, old_url) end)

    :ok
  end

  test "GET / renders the public gateway overview with canonical docs links", %{conn: conn} do
    html = conn |> get("/") |> html_response(200)

    assert html =~ "Backplane"
    assert html =~ "Gateway overview"
    assert html =~ "Docs-first contract"
    assert html =~ "Docs now own the endpoint catalog"
    assert html =~ "Routed centrally"
    assert html =~ "Namespaced access"

    for {docs_path, _label} <- @canonical_guides do
      assert html =~ ~s(href="#{docs_path}")
    end

    assert html =~ ~s(href="/docs/skills")
    refute html =~ ~s(href="/docs/llama")
    refute html =~ ~s(href="/docs/auth")

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
    assert html =~ "bg-surface-container-high text-on-surface"
    assert html =~ "Public gateway contract"
    assert html =~ ~s(aria-label="Footer docs")
    assert html =~ "Docs own route details"
    assert html =~ ~s(id="home-body")
    assert html =~ "max-w-6xl"

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
    refute html =~ "bg-secondary text-secondary-content"
    refute html =~ "w-auto px-3 rounded-md whitespace-nowrap"
  end

  test "GET /docs renders the concise canonical guide overview", %{conn: conn} do
    html = conn |> get("/docs") |> html_response(200)

    assert html =~ "Backplane Docs"
    assert html =~ "Choose a guide"
    assert html =~ ~s(aria-label="Docs")

    for {path, label} <- @canonical_guides do
      assert html =~ ~s(href="#{path}")
      assert html =~ label
    end

    assert html =~ ~s(href="/docs/skills")
    assert html =~ "Skills library"
    refute html =~ ~s(href="/docs/llama")
    refute html =~ ~s(href="/docs/auth")
    refute html =~ "<ol"
    refute html =~ "<pre"
    refute html =~ "curl "
    refute html =~ "$CLIENT_SECRET"
  end

  test "canonical guides and legacy aliases render canonical content", %{conn: conn} do
    for {canonical_path, alias_path, heading, marker} <- [
          {"/docs/llm", "/docs/llama", "LLM proxy",
           @base_url <> "/.well-known/oauth-protected-resource/v1"},
          {"/docs/authentication", "/docs/auth", "Authentication", "separate OAuth audiences"}
        ] do
      canonical_html = conn |> recycle() |> get(canonical_path) |> html_response(200)
      alias_html = conn |> recycle() |> get(alias_path) |> html_response(200)

      assert canonical_html =~ heading
      assert canonical_html =~ marker
      assert alias_html =~ heading
      assert alias_html =~ marker
    end

    for {path, heading} <- @canonical_guides do
      html = conn |> recycle() |> get(path) |> html_response(200)

      assert html =~ "Backplane Docs"
      assert html =~ heading
      assert html =~ ~s(href="/docs")
      refute html =~ ~s(href="/docs/llama")
      refute html =~ ~s(href="/docs/auth")
    end
  end

  test "skills guide remains available without OAuth setup blocks", %{conn: conn} do
    html = conn |> get("/docs/skills") |> html_response(200)

    assert html =~ "Skills library"
    assert html =~ "GET /skills/export"
    assert html =~ "POST /skills/import"
    assert html =~ "GET /skills/:slug/archive"
    refute html =~ "<ol"
    refute html =~ "<pre"
  end

  test "every canonical guide uses the configured origin without exposing stored secrets", %{
    conn: conn
  } do
    seed_known_oauth_secret!()

    for {path, _heading} <- @canonical_guides do
      html = conn |> recycle() |> get(path) |> html_response(200)

      assert html =~ @base_url
      refute html =~ @base_url <> "//"
      refute html =~ @stored_oauth_secret
    end
  end

  test "selected guides render ordered steps and safe copyable examples", %{conn: conn} do
    for {path, _heading} <- @canonical_guides do
      html = conn |> recycle() |> get(path) |> html_response(200)

      assert html =~ "<ol"
      assert html =~ "<pre"
      assert html =~ "<code"
      assert html =~ "overflow-x-auto"
      assert html =~ "select-all"
    end

    mcp = conn |> recycle() |> get("/docs/mcp") |> html_response(200)

    assert mcp =~ "https://chatgpt.com/connector/oauth/&lt;callback_id&gt;"
    refute mcp =~ "https://chatgpt.com/connector/oauth/<callback_id>"

    assert_in_order(mcp, [
      "Copy the exact callback",
      "Create a predefined confidential Backplane OAuth client",
      "Enable MCP (/mcp)",
      "Configure ChatGPT"
    ])
  end

  test "selected guides constrain long examples to the content column", %{conn: conn} do
    html = conn |> get("/docs/llm") |> html_response(200)

    assert html =~ "lg:grid-cols-[16rem_minmax(0,1fr)]"
    assert html =~ ~s(<section class="min-w-0">)
    assert html =~ "grid-cols-[minmax(0,1fr)]"
    assert html =~ ~s(class="min-w-0 overflow-hidden")
    assert html =~ "max-w-full overflow-x-auto"
    assert html =~ "break-words"
  end

  test "MCP guide documents the current ChatGPT OAuth app flow", %{conn: conn} do
    html = conn |> get("/docs/mcp") |> html_response(200)

    for marker <- [
          "ChatGPT",
          "https://chatgpt.com/connector/oauth/&lt;callback_id&gt;",
          "Do not change the callback ID or add a trailing slash",
          "predefined confidential Backplane OAuth client",
          "PKCE S256",
          "one-time client secret",
          "Enable MCP (/mcp)",
          "matching tool scopes",
          "matching scopes to the signing-in user",
          @base_url <> "/mcp",
          "WWW-Authenticate",
          @base_url <> "/.well-known/oauth-protected-resource/mcp",
          "$CLIENT_ID",
          "$CLIENT_SECRET"
        ] do
      assert html =~ marker
    end

    refute html =~ "offline_access"
  end

  test "LLM guide documents resource-bound discovery authorization and bearer use", %{conn: conn} do
    html = conn |> get("/docs/llm") |> html_response(200)

    for marker <- [
          @base_url <> "/.well-known/oauth-protected-resource/v1",
          "GET " <> @base_url <> "/v1",
          "resource=" <> @base_url <> "/v1",
          "llm::models",
          "llm::invoke",
          "Authorization: Bearer $ACCESS_TOKEN",
          "$CLIENT_ID",
          "$CLIENT_SECRET",
          "$CODE",
          "PAT",
          "legacy bearer",
          "additive compatibility"
        ] do
      assert html =~ marker
    end

    authorize_example =
      html
      |> String.split("Authorize with PKCE", parts: 2)
      |> List.last()
      |> String.split("</pre>", parts: 2)
      |> hd()

    refute authorize_example =~ "client_secret"
    refute authorize_example =~ "$CLIENT_SECRET"
  end

  test "agents guide has distinct ChatGPT Claude Code and Codex configurations", %{conn: conn} do
    html = conn |> get("/docs/agents") |> html_response(200)

    for marker <- [
          "ChatGPT",
          "Claude Code",
          "Codex",
          "ChatGPT MCP configuration",
          "Claude Code configuration",
          "Codex configuration",
          @base_url <> "/mcp",
          @base_url <> "/v1",
          "claude mcp add --transport http",
          "ANTHROPIC_BASE_URL",
          "[model_providers.backplane]",
          "[mcp_servers.backplane]",
          "$MCP_ACCESS_TOKEN",
          "$LLM_ACCESS_TOKEN"
        ] do
      assert html =~ marker
    end

    refute html =~ ~s(ANTHROPIC_API_KEY="$ACCESS_TOKEN")
    refute html =~ ~s(bearer_token_env_var = "BACKPLANE_ACCESS_TOKEN")

    example_text = String.replace(html, "&quot;", "\"")
    assert example_text =~ ~s(ANTHROPIC_BASE_URL="#{@base_url}")
    refute example_text =~ ~s(ANTHROPIC_BASE_URL="#{@base_url}/v1")
  end

  test "Claude Code uses the Anthropic auth token at the API origin", %{conn: conn} do
    example_text =
      conn
      |> get("/docs/agents")
      |> html_response(200)
      |> String.replace("&quot;", "\"")

    assert example_text =~ ~s(ANTHROPIC_BASE_URL="#{@base_url}")
    refute example_text =~ ~s(ANTHROPIC_BASE_URL="#{@base_url}/v1")
    assert example_text =~ ~s(ANTHROPIC_AUTH_TOKEN="$LLM_ACCESS_TOKEN")
    refute example_text =~ "ANTHROPIC_API_KEY"
  end

  test "Codex configuration selects the Backplane provider and model alias", %{conn: conn} do
    example_text =
      conn
      |> get("/docs/agents")
      |> html_response(200)
      |> String.replace("&quot;", "\"")

    for marker <- [
          "# Replace this placeholder with a model alias exposed by Backplane.",
          ~s(model = "your-backplane-model-alias"),
          ~s(model_provider = "backplane"),
          "[model_providers.backplane]"
        ] do
      assert example_text =~ marker
    end

    assert_in_order(example_text, [
      "# Replace this placeholder with a model alias exposed by Backplane.",
      ~s(model = "your-backplane-model-alias"),
      ~s(model_provider = "backplane"),
      "[model_providers.backplane]"
    ])
  end

  test "resource OAuth audience isolation preserves PAT and legacy compatibility", %{conn: conn} do
    for path <- ["/docs/agents", "/docs/authentication"] do
      html = conn |> recycle() |> get(path) |> html_response(200)

      assert html =~ "Resource-bound OAuth access tokens are audience-specific"
      assert html =~ "PAT and legacy credentials follow the configured compatibility policy"
    end
  end

  test "authentication guide explains resource lifecycle security and troubleshooting", %{
    conn: conn
  } do
    html = conn |> get("/docs/authentication") |> html_response(200)

    for marker <- [
          @base_url <> "/mcp",
          @base_url <> "/v1",
          "separate OAuth audiences",
          "predefined OAuth clients",
          "confidential client",
          "PKCE S256",
          "refresh token",
          "inherits its original resource",
          "durable ChatGPT connectivity",
          @base_url <> "/oauth/revoke",
          "HTTPS",
          "invalid_target",
          "invalid_token",
          "insufficient_scope"
        ] do
      assert html =~ marker
    end

    refute html =~ "offline_access"
  end

  test "GET /docs/:section returns not found for unknown docs sections", %{conn: conn} do
    conn = get(conn, "/docs/unknown")

    assert response(conn, 404)
  end

  defp seed_known_oauth_secret! do
    assert {:ok, %{client: client}} =
             Auth.OAuth.create_client(%{
               name: "Docs Secret Regression",
               redirect_uris: ["https://client.example.test/callback"],
               scopes: ["openid"],
               confidential: true,
               pkce: true
             })

    assert {:ok, _client} = Admin.regenerate_client_secret(client, @stored_oauth_secret)
  end

  defp assert_in_order(text, markers) do
    Enum.reduce(markers, 0, fn marker, offset ->
      {index, _length} =
        text
        |> binary_part(offset, byte_size(text) - offset)
        |> :binary.match(marker)

      offset + index + byte_size(marker)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)
end
