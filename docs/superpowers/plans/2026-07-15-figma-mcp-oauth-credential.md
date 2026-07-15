# Shared Figma MCP OAuth Credential Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an administrator authorize one shared Figma account, store its OAuth tokens as an encrypted upstream credential, refresh them safely, and use the current Bearer upstream path for every Backplane caller.

**Architecture:** Add `figma_oauth` to the existing vendor OAuth dispatch without changing the upstream schema or transport. The admin LiveView creates a PKCE authorization request, the existing callback exchanges the code, `Credentials` stores a flat encrypted token blob with kind `upstream`, and `OAuthRefresher` plus the existing worker rotate the token. `AuthInjector` remains unchanged and resolves the shared credential per request.

**Tech Stack:** Elixir 1.18 / OTP 28, Phoenix LiveView and controller tests, Ecto/PostgreSQL, Oban, Req, AES-256-GCM through `Backplane.Settings.Encryption`, Bandit and `Plug.Router` test endpoints, DuskMoon Phoenix components.

**Spec:** `docs/superpowers/specs/2026-07-15-figma-mcp-oauth-credential-design.md`

**Worktree:** `/home/gao/Workspace/gsmlg-opt/backplane/.trees/codex/figma-mcp-oauth` on branch `codex/figma-mcp-oauth`

**External acceptance boundary:** Automated tests use local token endpoints. A live Figma login remains pending until Figma approves Backplane for the MCP Catalog and supplies the deployment client credentials.

## File map

- Modify `apps/backplane_system/lib/backplane/settings/credentials.ex` — generic OAuth token storage, Figma vendor dispatch, cache invalidation, and the ten-minute Figma refresh window.
- Modify `apps/backplane_system/lib/backplane/settings/oauth_refresher.ex` — Figma client configuration, Basic authentication, and refresh-token exchange.
- Modify `apps/backplane_system/lib/backplane/settings/oauth_token_refresh_worker.ex` — include Figma in the default proactive scan.
- Create `apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs` — isolated storage, fetch, refresh, status, failure-preservation, and worker coverage.
- Modify `apps/backplane_system/test/backplane/settings/oauth_refresher_test.exs` — Figma request-shape and configuration tests.
- Modify `apps/backplane_admin/lib/backplane/admin/live/settings_live.ex` — Figma connect UI, shared-account copy, PKCE authorization URL, and missing-config preflight.
- Modify `apps/backplane_admin/test/backplane/admin/live/settings_live_test.exs` — UI and authorization-request tests.
- Modify `apps/backplane_admin/lib/backplane/admin/controllers/oauth_callback_controller.ex` — Figma code exchange, response validation, sanitized errors, and upstream-kind storage.
- Create `apps/backplane_admin/test/backplane/admin/controllers/oauth_callback_controller_test.exs` — callback success, replay, denial, and incomplete-token tests.
- Modify `apps/backplane_mcp/test/backplane/proxy/auth_injector_test.exs` — prove the existing Bearer path consumes a fresh Figma OAuth token.
- Modify `docs/deploy/backplane.md` — deployment variables, registered callback, catalog prerequisite, and upstream settings.

---

## Task 0: Prepare the isolated worktree and record impact

**Files:** None.

- [ ] **Step 1: Confirm the worktree and branch**

Run:

```bash
git branch --show-current
git status --short --branch
```

Expected: branch `codex/figma-mcp-oauth`; only the approved spec status and this plan may be modified.

- [ ] **Step 2: Fetch the worktree dependencies**

Run:

```bash
devenv shell -- mix deps.get
```

Expected: dependencies are available without changing `mix.lock`.

- [ ] **Step 3: Run required GitNexus impact checks before production edits**

Call `gitnexus_impact` with `direction: "upstream"` for these symbols and paths:

```json
[
  {"target":"store_device_token","file_path":"apps/backplane_system/lib/backplane/settings/credentials.ex"},
  {"target":"fetch","file_path":"apps/backplane_system/lib/backplane/settings/credentials.ex"},
  {"target":"oauth_refresh_due?","file_path":"apps/backplane_system/lib/backplane/settings/credentials.ex"},
  {"target":"refresh","file_path":"apps/backplane_system/lib/backplane/settings/oauth_refresher.ex"},
  {"target":"perform","file_path":"apps/backplane_system/lib/backplane/settings/oauth_token_refresh_worker.ex"},
  {"target":"start_device_auth","file_path":"apps/backplane_admin/lib/backplane/admin/live/settings_live.ex"},
  {"target":"callback","file_path":"apps/backplane_admin/lib/backplane/admin/controllers/oauth_callback_controller.ex"}
]
```

The current GitNexus index does not expose these Elixir functions as symbol nodes. If a symbol lookup still reports `Target not found`, repeat the check using the filename as `target`, `kind: "File"`, and the exact `file_path`. The 2026-07-15 file-level audit returned LOW risk and zero indexed callers. Report the incomplete index result, then use the direct caller trace in the next step. If any check instead reports HIGH or CRITICAL, warn the user and stop before editing.

- [ ] **Step 4: Record the direct source blast radius**

Run:

```bash
rg -n "store_device_token|Credentials.fetch\(|OAuthRefresher.refresh|OAuthTokenRefreshWorker|start_device_auth|OAuthCallbackController" apps
```

Expected: existing OAuth vendors have many callers; preserve `store_device_token/3,4`, `Credentials.fetch/1`, and `OAuthRefresher.refresh/2,3` contracts. No production change is required in `AuthInjector` or `McpUpstream`.

- [ ] **Step 5: Run the focused baseline**

Run:

```bash
devenv shell -- mix test \
  apps/backplane_system/test/backplane/settings/oauth_refresher_test.exs \
  apps/backplane_system/test/backplane/settings/credentials_cli_oauth_test.exs \
  apps/backplane_admin/test/backplane/admin/live/settings_live_test.exs \
  apps/backplane_mcp/test/backplane/proxy/auth_injector_test.exs
```

Expected: PASS before feature code is added. If an unrelated baseline test fails, report it and stop rather than widening scope.

---

## Task 1: Add Figma-aware encrypted credential storage

**Files:**

- Create `apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs`
- Modify `apps/backplane_system/lib/backplane/settings/credentials.ex`

- [ ] **Step 1: Write the failing storage and cache tests**

Create `apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs`:

```elixir
defmodule Backplane.Settings.CredentialsFigmaOAuthTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Repo
  alias Backplane.Settings.{Credential, Credentials, Encryption, TokenCache}

  setup do
    TokenCache.clear()
    on_exit(&TokenCache.clear/0)
    :ok
  end

  test "stores a Figma token as an encrypted upstream OAuth credential" do
    expires_at = System.system_time(:millisecond) + 3_600_000

    assert {:ok, credential} =
             Credentials.store_oauth_token(
               "figma-mcp",
               "figma_oauth",
               %{
                 "access_token" => "figma-access",
                 "refresh_token" => "figma-refresh",
                 "expires_at" => expires_at
               },
               "upstream",
               %{}
             )

    assert credential.kind == "upstream"
    assert credential.metadata == %{"auth_type" => "figma_oauth"}
    refute Map.has_key?(credential.metadata, "client_id")
    refute Map.has_key?(credential.metadata, "client_secret")

    assert {:ok, plaintext} = Encryption.decrypt(credential.encrypted_value)
    assert %{
             "access_token" => "figma-access",
             "refresh_token" => "figma-refresh",
             "expires_at" => ^expires_at
           } = Jason.decode!(plaintext)

    assert {:ok, "figma-access"} = Credentials.fetch("figma-mcp")
  end

  test "reauthorizing the same name invalidates the cached access token" do
    expires_at = System.system_time(:millisecond) + 3_600_000

    assert {:ok, _} =
             Credentials.store_oauth_token(
               "figma-reconnect",
               "figma_oauth",
               %{
                 "access_token" => "old-access",
                 "refresh_token" => "old-refresh",
                 "expires_at" => expires_at
               },
               "upstream",
               %{}
             )

    assert {:ok, "old-access"} = Credentials.fetch("figma-reconnect")
    assert {:ok, "old-access"} = TokenCache.get("figma-reconnect")

    assert {:ok, _} =
             Credentials.store_oauth_token(
               "figma-reconnect",
               "figma_oauth",
               %{
                 "access_token" => "new-access",
                 "refresh_token" => "new-refresh",
                 "expires_at" => expires_at
               },
               "upstream",
               %{}
             )

    assert :miss = TokenCache.get("figma-reconnect")
    assert {:ok, "new-access"} = Credentials.fetch("figma-reconnect")

    stored = Repo.get_by!(Credential, name: "figma-reconnect")
    assert stored.kind == "upstream"
  end

  test "existing device OAuth storage keeps the llm kind" do
    assert {:ok, credential} =
             Credentials.store_device_token(
               "legacy-google",
               "google_oauth",
               %{
                 "access_token" => "google-access",
                 "refresh_token" => "google-refresh",
                 "expires_at" => System.system_time(:millisecond) + 3_600_000
               },
               %{}
             )

    assert credential.kind == "llm"
    assert credential.metadata["auth_type"] == "google_oauth"
  end
end
```

- [ ] **Step 2: Run the new test and verify the red state**

Run:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs
```

Expected: FAIL because `Credentials.store_oauth_token/5` is undefined.

- [ ] **Step 3: Implement the backward-compatible storage contract**

In `apps/backplane_system/lib/backplane/settings/credentials.ex`, add Figma to the vendor map, add `store_oauth_token/5`, delegate the existing helper, and dispatch Figma fetches:

```elixir
@device_oauth_vendors %{
  "anthropic_oauth" => :anthropic_oauth,
  "openai_oauth" => :openai_oauth,
  "google_oauth" => :google_oauth,
  "xai_oauth" => :xai_oauth,
  "figma_oauth" => :figma_oauth
}

@doc "Store an OAuth token set under an explicit credential kind."
@spec store_oauth_token(String.t(), String.t(), map(), String.t(), map()) ::
        {:ok, Credential.t()} | {:error, term()}
def store_oauth_token(name, auth_type, tokens, kind, hints) do
  blob = Jason.encode!(tokens)
  metadata = Map.merge(%{"auth_type" => auth_type}, hints)

  case store(name, blob, kind, metadata) do
    {:ok, _credential} = result ->
      Backplane.Settings.TokenCache.invalidate(name)
      result

    {:error, _reason} = error ->
      error
  end
end

@spec store_device_token(String.t(), String.t(), map(), map()) ::
        {:ok, Credential.t()} | {:error, term()}
def store_device_token(name, auth_type, tokens, hints \\ %{}) do
  store_oauth_token(name, auth_type, tokens, "llm", hints)
end
```

Add this `fetch/1` branch before the raw encrypted-value fallback:

```elixir
%Credential{metadata: %{"auth_type" => "figma_oauth"}} = cred ->
  fetch_device_oauth(cred, :figma_oauth)
```

Add this validation clause beside the other managed OAuth types:

```elixir
defp validate_oauth_metadata(%{"auth_type" => "figma_oauth"}), do: :ok
```

Also add `store_oauth_token/5` to the module documentation list. Do not invalidate cache inside generic `store/4`; the new helper owns managed-OAuth replacement semantics without changing API-key storage.

- [ ] **Step 4: Format and run storage regressions**

Run:

```bash
devenv shell -- mix format \
  apps/backplane_system/lib/backplane/settings/credentials.ex \
  apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs
devenv shell -- mix test \
  apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs \
  apps/backplane_system/test/backplane/settings/credentials_cli_oauth_test.exs
```

Expected: PASS; legacy OAuth rows still use kind `llm`.

- [ ] **Step 5: Audit changed scope before committing**

Call `gitnexus_detect_changes` with `repo: "backplane"` and `scope: "unstaged"`, then run:

```bash
git diff --check
git diff -- apps/backplane_system/lib/backplane/settings/credentials.ex \
  apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs
```

Expected: only storage/vendor dispatch and its focused tests changed. GitNexus may report no Elixir symbols; record that limitation rather than treating it as proof of no impact.

- [ ] **Step 6: Commit the storage slice**

```bash
git add apps/backplane_system/lib/backplane/settings/credentials.ex \
  apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs
git commit -m "feat(credentials): store Figma upstream OAuth tokens"
```

---

## Task 2: Add the Figma refresh-token exchange

**Files:**

- Modify `apps/backplane_system/test/backplane/settings/oauth_refresher_test.exs`
- Modify `apps/backplane_system/lib/backplane/settings/oauth_refresher.ex`

- [ ] **Step 1: Extend the local token endpoint and configuration fixture**

In the existing test `setup`, include Figma environment variables in `prior_env`, then add these keys to the existing `Application.put_env/3` call:

```elixir
prior_env =
  snapshot_env(
    ~w[HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy FIGMA_MCP_CLIENT_ID FIGMA_MCP_CLIENT_SECRET]
  )

Application.put_env(:backplane, OAuthRefresher,
  anthropic_token_url: "http://localhost:#{port}/anthropic/token",
  openai_token_url: "http://localhost:#{port}/openai/token",
  google_token_url: "http://localhost:#{port}/google/token",
  xai_token_url: "http://localhost:#{port}/xai/token",
  figma_token_url: "http://localhost:#{port}/figma/token",
  figma_mcp_client_id: "test-figma-client",
  figma_mcp_client_secret: "test-figma-secret"
)
```

Add this route to `OAuthRefresherTest.MockEndpoint`:

```elixir
post "/figma/token" do
  expected_auth = "Basic " <> Base.encode64("test-figma-client:test-figma-secret")

  valid_request? =
    conn.body_params["grant_type"] == "refresh_token" and
      conn.body_params["resource"] == "https://mcp.figma.com/mcp" and
      get_req_header(conn, "authorization") == [expected_auth]

  case {valid_request?, conn.body_params["refresh_token"]} do
    {true, "good-figma"} ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "figma-new-access",
          "refresh_token" => "figma-new-refresh",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        })
      )

    {true, "keep-figma-refresh"} ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "figma-new-access",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        })
      )

    _ ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{"error" => "invalid_request"}))
  end
end
```

- [ ] **Step 2: Write the failing Figma refresher tests**

Add this describe block:

```elixir
describe "refresh/2 :figma_oauth" do
  test "uses Basic client authentication and the MCP resource" do
    assert {:ok,
            %{
              access_token: "figma-new-access",
              refresh_token: "figma-new-refresh",
              expires_at: expires_at
            }} = OAuthRefresher.refresh(:figma_oauth, "good-figma")

    now_ms = System.system_time(:millisecond)
    assert_in_delta expires_at, now_ms + 3_600_000, 5_000
  end

  test "retains the previous refresh token when Figma does not rotate it" do
    assert {:ok, %{refresh_token: "keep-figma-refresh"}} =
             OAuthRefresher.refresh(:figma_oauth, "keep-figma-refresh")
  end

  test "requires both configured client credentials", %{port: port} do
    configured = Application.get_env(:backplane, OAuthRefresher, [])
    System.delete_env("FIGMA_MCP_CLIENT_ID")
    System.delete_env("FIGMA_MCP_CLIENT_SECRET")

    Application.put_env(:backplane, OAuthRefresher,
      figma_token_url: "http://localhost:#{port}/figma/token"
    )

    assert {:error, :missing_figma_mcp_client_id} =
             OAuthRefresher.refresh(:figma_oauth, "good-figma")

    Application.put_env(:backplane, OAuthRefresher,
      figma_token_url: "http://localhost:#{port}/figma/token",
      figma_mcp_client_id: "test-figma-client"
    )

    assert {:error, :missing_figma_mcp_client_secret} =
             OAuthRefresher.refresh(:figma_oauth, "good-figma")

    Application.put_env(:backplane, OAuthRefresher, configured)
  end

  test "returns a sanitized status error for a rejected refresh" do
    assert {:error, {:refresh_failed, 401}} =
             OAuthRefresher.refresh(:figma_oauth, "rejected-figma")
  end
end
```

- [ ] **Step 3: Run the refresher test and verify the red state**

Run:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/settings/oauth_refresher_test.exs
```

Expected: FAIL because `:figma_oauth` has no `refresh/3` clause or client configuration helpers.

- [ ] **Step 4: Implement Figma configuration and refresh**

In `OAuthRefresher`, extend the module documentation and vendor type, then add:

```elixir
@figma_token_url "https://api.figma.com/v1/oauth/token"
@figma_authorize_url "https://www.figma.com/oauth/mcp"
@figma_resource "https://mcp.figma.com/mcp"
@figma_scope "mcp:connect"

@type vendor ::
        :anthropic_oauth
        | :openai_oauth
        | :google_oauth
        | :xai_oauth
        | :figma_oauth

@spec figma_mcp_client_credentials(keyword()) ::
        {:ok, String.t(), String.t()}
        | {:error, :missing_figma_mcp_client_id | :missing_figma_mcp_client_secret}
def figma_mcp_client_credentials(opts \\ []) do
  client_id = option_or_config(opts, :figma_mcp_client_id, "FIGMA_MCP_CLIENT_ID")
  client_secret = option_or_config(opts, :figma_mcp_client_secret, "FIGMA_MCP_CLIENT_SECRET")

  cond do
    is_nil(client_id) -> {:error, :missing_figma_mcp_client_id}
    is_nil(client_secret) -> {:error, :missing_figma_mcp_client_secret}
    true -> {:ok, client_id, client_secret}
  end
end

@spec figma_mcp_client_auth_headers(keyword()) ::
        {:ok, [{String.t(), String.t()}]}
        | {:error, :missing_figma_mcp_client_id | :missing_figma_mcp_client_secret}
def figma_mcp_client_auth_headers(opts \\ []) do
  with {:ok, client_id, client_secret} <- figma_mcp_client_credentials(opts) do
    encoded =
      Base.encode64(
        URI.encode_www_form(client_id) <> ":" <> URI.encode_www_form(client_secret)
      )

    {:ok, [{"authorization", "Basic " <> encoded}]}
  end
end

def figma_authorize_url, do: @figma_authorize_url
def figma_token_url, do: url(:figma_token_url)
def figma_resource, do: @figma_resource
def figma_scope, do: @figma_scope

def refresh(:figma_oauth, refresh_token, opts) when is_binary(refresh_token) do
  with {:ok, headers} <- figma_mcp_client_auth_headers(opts) do
    do_refresh(
      figma_token_url(),
      :form,
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "resource" => @figma_resource
      },
      headers
    )
  end
end
```

Add the default URL clause:

```elixir
defp default_url(:figma_token_url), do: @figma_token_url
```

Do not edit runtime configuration files. `figma_token_url/0` pins the published endpoint through `default_url/1`, while tests can override `:figma_token_url` and deployments provide only the client ID and secret through environment variables.

- [ ] **Step 5: Format and run the refresher suite**

Run:

```bash
devenv shell -- mix format \
  apps/backplane_system/lib/backplane/settings/oauth_refresher.ex \
  apps/backplane_system/test/backplane/settings/oauth_refresher_test.exs
devenv shell -- mix test apps/backplane_system/test/backplane/settings/oauth_refresher_test.exs
```

Expected: PASS, including Basic-auth, resource, rotation, missing-config, and non-2xx cases.

- [ ] **Step 6: Audit changed scope before committing**

Call `gitnexus_detect_changes` with `repo: "backplane"` and `scope: "unstaged"`, then run:

```bash
git diff --check
git diff -- apps/backplane_system/lib/backplane/settings/oauth_refresher.ex \
  apps/backplane_system/test/backplane/settings/oauth_refresher_test.exs
```

Expected: only the Figma refresh profile and its test endpoint changed.

- [ ] **Step 7: Commit the refresh slice**

```bash
git add apps/backplane_system/lib/backplane/settings/oauth_refresher.ex \
  apps/backplane_system/test/backplane/settings/oauth_refresher_test.exs
git commit -m "feat(credentials): refresh Figma MCP OAuth tokens"
```

---

## Task 3: Integrate Figma expiry handling and proactive refresh

**Files:**

- Modify `apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs`
- Modify `apps/backplane_system/lib/backplane/settings/credentials.ex`
- Modify `apps/backplane_system/lib/backplane/settings/oauth_token_refresh_worker.ex`

- [ ] **Step 1: Add an isolated Figma refresh endpoint to the credential test**

Replace the test setup with this complete setup and add the nested endpoint module:

```elixir
setup do
  TokenCache.clear()
  {:ok, pid} = Bandit.start_link(plug: __MODULE__.RefreshEndpoint, port: 0)
  {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
  previous = Application.get_env(:backplane, OAuthRefresher, [])

  Application.put_env(
    :backplane,
    OAuthRefresher,
    Keyword.merge(previous,
      figma_token_url: "http://localhost:#{port}/figma/token",
      figma_mcp_client_id: "test-figma-client",
      figma_mcp_client_secret: "test-figma-secret"
    )
  )

  on_exit(fn ->
    TokenCache.clear()
    Application.put_env(:backplane, OAuthRefresher, previous)

    try do
      ThousandIsland.stop(pid)
    catch
      :exit, _ -> :ok
    end
  end)

  :ok
end

defmodule RefreshEndpoint do
  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
  plug(:dispatch)

  post "/figma/token" do
    expected_auth = "Basic " <> Base.encode64("test-figma-client:test-figma-secret")

    valid? =
      conn.body_params["grant_type"] == "refresh_token" and
        conn.body_params["resource"] == "https://mcp.figma.com/mcp" and
        get_req_header(conn, "authorization") == [expected_auth]

    cond do
      valid? and conn.body_params["refresh_token"] == "good-figma" ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "figma-refreshed-access",
            "refresh_token" => "figma-refreshed-refresh",
            "expires_in" => 3600
          })
        )

      true ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "invalid_grant"}))
    end
  end
end
```

Add `OAuthRefresher` and `OAuthTokenRefreshWorker` to the alias list.

- [ ] **Step 2: Write failing lifecycle tests**

Add these tests:

```elixir
test "fetch refreshes and persists an expired Figma token" do
  assert {:ok, _} =
           Credentials.store_oauth_token(
             "figma-expired",
             "figma_oauth",
             %{
               "access_token" => "figma-old-access",
               "refresh_token" => "good-figma",
               "expires_at" => System.system_time(:millisecond) - 60_000
             },
             "upstream",
             %{}
           )

  assert {:ok, "figma-refreshed-access"} = Credentials.fetch("figma-expired")

  stored = decrypt_credential_json("figma-expired")
  assert stored["access_token"] == "figma-refreshed-access"
  assert stored["refresh_token"] == "figma-refreshed-refresh"
  assert is_binary(stored["last_refresh"])
end

test "failed refresh preserves the encrypted token blob" do
  old = %{
    "access_token" => "figma-old-access",
    "refresh_token" => "rejected-figma",
    "expires_at" => System.system_time(:millisecond) - 60_000
  }

  assert {:ok, _} =
           Credentials.store_oauth_token(
             "figma-refresh-failure",
             "figma_oauth",
             old,
             "upstream",
             %{}
           )

  assert {:error, {:refresh_failed, 401}} = Credentials.fetch("figma-refresh-failure")
  assert decrypt_credential_json("figma-refresh-failure") == old
end

test "caps the Figma proactive refresh window at ten minutes" do
  now_ms = System.system_time(:millisecond)

  for {name, minutes} <- [{"figma-nine", 9}, {"figma-eleven", 11}] do
    assert {:ok, _} =
             Credentials.store_oauth_token(
               name,
               "figma_oauth",
               %{
                 "access_token" => name <> "-access",
                 "refresh_token" => "good-figma",
                 "expires_at" => now_ms + minutes * 60_000
               },
               "upstream",
               %{}
             )
  end

  assert ["figma-nine"] =
           Credentials.oauth_credentials_due_for_refresh(
             auth_types: ["figma_oauth"],
             now_ms: now_ms,
             refresh_window_ms: 2 * 60 * 60 * 1000
           )

  assert {:ok, :fresh} =
           Credentials.refresh_oauth_token(
             "figma-eleven",
             now_ms: now_ms,
             refresh_window_ms: 2 * 60 * 60 * 1000
           )
end

test "default worker scan refreshes only due Figma credentials" do
  now_ms = System.system_time(:millisecond)

  for {name, minutes} <- [{"figma-worker-due", 9}, {"figma-worker-fresh", 11}] do
    assert {:ok, _} =
             Credentials.store_oauth_token(
               name,
               "figma_oauth",
               %{
                 "access_token" => name <> "-old",
                 "refresh_token" => "good-figma",
                 "expires_at" => now_ms + minutes * 60_000
               },
               "upstream",
               %{}
             )
  end

  assert :ok = OAuthTokenRefreshWorker.perform(%Oban.Job{args: %{}})

  assert decrypt_credential_json("figma-worker-due")["access_token"] ==
           "figma-refreshed-access"

  assert decrypt_credential_json("figma-worker-fresh")["access_token"] ==
           "figma-worker-fresh-old"
end

test "OAuth status exposes lifecycle state without secrets" do
  expires_at = System.system_time(:millisecond) + 3_600_000

  assert {:ok, _} =
           Credentials.store_oauth_token(
             "figma-status",
             "figma_oauth",
             %{
               "access_token" => "figma-status-access",
               "refresh_token" => "figma-status-refresh",
               "expires_at" => expires_at
             },
             "upstream",
             %{}
           )

  assert {:ok, status} = Credentials.oauth_status("figma-status")
  assert status.auth_type == "figma_oauth"
  assert status.status == :active
  assert status.expires_at_ms == expires_at
  refute Map.has_key?(status, :access_token)
  refute Map.has_key?(status, :refresh_token)
end

defp decrypt_credential_json(name) do
  credential = Repo.get_by!(Credential, name: name)
  {:ok, plaintext} = Encryption.decrypt(credential.encrypted_value)
  Jason.decode!(plaintext)
end
```

- [ ] **Step 3: Run the lifecycle tests and verify the red state**

Run:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs
```

Expected: the expiry-cap and default-worker tests fail because Figma currently inherits the two-hour generic window and is absent from the worker defaults.

- [ ] **Step 4: Add the Figma-specific due window and worker default**

In `Credentials`, add the module attribute:

```elixir
@figma_max_refresh_window_ms 10 * 60 * 1000
```

Add this clause immediately before the generic flat-token `oauth_refresh_due?/5` clause:

```elixir
defp oauth_refresh_due?(
       :figma_oauth,
       %{"expires_at" => expires_at_ms},
       now_ms,
       refresh_window_ms,
       _refresh_interval_ms
     )
     when is_integer(expires_at_ms) do
  capped_window_ms = min(refresh_window_ms, @figma_max_refresh_window_ms)
  expires_at_ms <= now_ms + capped_window_ms
end
```

In `OAuthTokenRefreshWorker`, change only the default vendor list:

```elixir
@default_auth_types ["openai_oauth", "anthropic_oauth", "figma_oauth"]
```

Do not change the worker's two-hour default; Claude keeps that behavior, while the Credentials clause caps Figma scans and named jobs at ten minutes.

- [ ] **Step 5: Format and run system OAuth regressions**

Run:

```bash
devenv shell -- mix format \
  apps/backplane_system/lib/backplane/settings/credentials.ex \
  apps/backplane_system/lib/backplane/settings/oauth_token_refresh_worker.ex \
  apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs
devenv shell -- mix test \
  apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs \
  apps/backplane_system/test/backplane/settings/oauth_refresher_test.exs \
  apps/backplane_system/test/backplane/settings/credentials_cli_oauth_test.exs \
  apps/backplane_system/test/backplane/settings/credentials_oauth_test.exs
```

Expected: PASS; Claude's existing two-hour worker test remains green.

- [ ] **Step 6: Audit changed scope before committing**

Call `gitnexus_detect_changes` with `repo: "backplane"` and `scope: "unstaged"`, then run:

```bash
git diff --check
git diff -- apps/backplane_system/lib/backplane/settings/credentials.ex \
  apps/backplane_system/lib/backplane/settings/oauth_token_refresh_worker.ex \
  apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs
```

Expected: only Figma expiry behavior, worker inclusion, and lifecycle tests changed.

- [ ] **Step 7: Commit the lifecycle slice**

```bash
git add apps/backplane_system/lib/backplane/settings/credentials.ex \
  apps/backplane_system/lib/backplane/settings/oauth_token_refresh_worker.ex \
  apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs
git commit -m "feat(credentials): maintain Figma OAuth lifecycle"
```

---

## Task 4: Add the shared Figma connect action and PKCE authorization request

**Files:**

- Modify `apps/backplane_admin/test/backplane/admin/live/settings_live_test.exs`
- Modify `apps/backplane_admin/lib/backplane/admin/live/settings_live.ex`

- [ ] **Step 1: Extend the credentials LiveView fixture**

In `settings_live_test.exs`, change the settings aliases to:

```elixir
alias Backplane.Settings.{Credentials, OAuthRefresher, OAuthStateStore}
```

At the start of the existing credentials-tab `setup`, call `OAuthStateStore.clear/0`. Add the Figma overrides to the existing refresher configuration:

```elixir
Keyword.merge(prior_refresher,
  anthropic_token_url: "http://localhost:#{port}/anthropic/token",
  google_token_url: "http://localhost:#{port}/google/token",
  google_client_id: "test-google-client",
  google_client_secret: "test-google-secret",
  xai_token_url: "http://localhost:#{port}/xai/token",
  xai_client_id: "test-xai-client",
  figma_token_url: "http://localhost:#{port}/figma/token",
  figma_mcp_client_id: "test-figma-client",
  figma_mcp_client_secret: "test-figma-secret"
)
```

Clear `OAuthStateStore` again in the existing `on_exit` callback. The LiveView never calls the Figma token endpoint, but using the same fixture keys as the system and controller tests prevents configuration-name drift.

- [ ] **Step 2: Write the failing action, shared-account, and authorization tests**

Add these tests inside `describe "credentials tab"`:

```elixir
test "renders the Figma MCP shared-account OAuth action", %{conn: conn} do
  {:ok, view, _html} = live(conn, "/system/credentials")

  assert has_element?(
           view,
           ~s(a[href="/system/credentials/new/figma_oauth"]),
           "Connect Figma MCP"
         )

  html =
    view
    |> element(~s(a[href="/system/credentials/new/figma_oauth"]))
    |> render_click()

  assert_patched(view, "/system/credentials/new/figma_oauth")
  assert html =~ "Connect Figma MCP"
  assert html =~ "one shared Figma account for every Backplane caller"
  assert has_element?(view, ~s(#device-cred-name[value="figma-mcp"]))
end

test "starts Figma MCP authorization with PKCE and the MCP resource", %{conn: conn} do
  {:ok, view, _html} = live(conn, "/system/credentials/new/figma_oauth")

  view
  |> form("form[phx-submit=start_device_auth]", %{"cred_name" => "shared-figma"})
  |> render_submit()

  assert_push_event(view, "open_external_oauth", %{url: auth_url})
  assert_patched(view, "/system/credentials")

  uri = URI.parse(auth_url)
  query = URI.decode_query(uri.query)

  assert {uri.scheme, uri.host, uri.path} == {"https", "www.figma.com", "/oauth/mcp"}
  assert query["response_type"] == "code"
  assert query["client_id"] == "test-figma-client"
  assert query["redirect_uri"] == Backplane.WebOrigins.admin_url("/oauth/callback")
  assert query["scope"] == "mcp:connect"
  assert query["resource"] == "https://mcp.figma.com/mcp"
  assert query["code_challenge_method"] == "S256"

  assert {:ok, attrs} = OAuthStateStore.pop(query["state"])
  assert attrs["vendor"] == "figma_oauth"
  assert attrs["cred_name"] == "shared-figma"
  assert attrs["redirect_uri"] == query["redirect_uri"]

  expected_challenge =
    :crypto.hash(:sha256, attrs["code_verifier"])
    |> Base.url_encode64(padding: false)

  assert query["code_challenge"] == expected_challenge
end

test "keeps the Figma connect form open when the client ID is missing", %{conn: conn} do
  configured = Application.get_env(:backplane, OAuthRefresher, [])
  prior_env = snapshot_env(~w[FIGMA_MCP_CLIENT_ID FIGMA_MCP_CLIENT_SECRET])

  Application.put_env(
    :backplane,
    OAuthRefresher,
    Keyword.drop(configured, [:figma_mcp_client_id, :figma_mcp_client_secret])
  )

  System.delete_env("FIGMA_MCP_CLIENT_ID")
  System.delete_env("FIGMA_MCP_CLIENT_SECRET")

  on_exit(fn ->
    Application.put_env(:backplane, OAuthRefresher, configured)
    restore_env(prior_env)
  end)

  {:ok, view, _html} = live(conn, "/system/credentials/new/figma_oauth")

  html =
    view
    |> form("form[phx-submit=start_device_auth]", %{"cred_name" => "shared-figma"})
    |> render_submit()

  assert html =~ "Set FIGMA_MCP_CLIENT_ID before connecting Figma MCP"
  assert has_element?(view, "form[phx-submit=start_device_auth]")
end

test "keeps the Figma connect form open when the client secret is missing", %{conn: conn} do
  configured = Application.get_env(:backplane, OAuthRefresher, [])
  prior_env = snapshot_env(~w[FIGMA_MCP_CLIENT_SECRET])

  Application.put_env(
    :backplane,
    OAuthRefresher,
    configured
    |> Keyword.put(:figma_mcp_client_id, "test-figma-client")
    |> Keyword.delete(:figma_mcp_client_secret)
  )

  System.delete_env("FIGMA_MCP_CLIENT_SECRET")

  on_exit(fn ->
    Application.put_env(:backplane, OAuthRefresher, configured)
    restore_env(prior_env)
  end)

  {:ok, view, _html} = live(conn, "/system/credentials/new/figma_oauth")

  html =
    view
    |> form("form[phx-submit=start_device_auth]", %{"cred_name" => "shared-figma"})
    |> render_submit()

  assert html =~ "Set FIGMA_MCP_CLIENT_SECRET before connecting Figma MCP"
  assert has_element?(view, "form[phx-submit=start_device_auth]")
end
```

- [ ] **Step 3: Run the LiveView file and verify the red state**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/settings_live_test.exs
```

Expected: the Figma link/default-name tests fail, and direct Figma form submission has no URL builder.

- [ ] **Step 4: Add the Figma UI and browser-flow dispatch**

In `SettingsLive`:

1. Add the default name:

   ```elixir
   "figma_oauth" -> "figma-mcp"
   ```

2. Add `"figma_oauth"` to `device_oauth_auth_type?/1` and the credentials-table OAuth badge list.

3. Add the split-dropdown action after xAI:

   ```heex
   <.link
     patch={~p"/system/credentials/new/figma_oauth"}
     class="popover-menu-item"
   >
     Connect Figma MCP
   </.link>
   ```

4. Add the shared-account explanation directly above the form:

   ```heex
   <p
     :if={@device_flow_vendor == "figma_oauth"}
     id="figma-shared-account-note"
     class="text-sm text-on-surface-variant mb-4"
   >
     This credential authorizes one shared Figma account for every Backplane caller.
   </p>
   ```

5. Add the label:

   ```elixir
   defp device_flow_label("figma_oauth"), do: "Figma MCP"
   ```

6. Add this explicit `cond` branch immediately before the generic `true` branch in `start_device_auth/3`. The configuration check must happen before `OAuthStateStore.put/1`:

   ```elixir
   vendor == "figma_oauth" ->
     case OAuthRefresher.figma_mcp_client_credentials() do
       {:ok, _client_id, _client_secret} ->
         redirect_uri = Backplane.WebOrigins.admin_url("/oauth/callback")
         {verifier, challenge} = pkce_pair()

         state =
           OAuthStateStore.put(%{
             "vendor" => vendor,
             "cred_name" => name,
             "code_verifier" => verifier,
             "redirect_uri" => redirect_uri
           })

         auth_url = build_auth_url(vendor, state, challenge, redirect_uri)

         {:noreply,
          socket
          |> push_event("open_external_oauth", %{url: auth_url})
          |> push_patch(to: ~p"/system/credentials")}

       {:error, reason} ->
         {:noreply, put_flash(socket, :error, format_figma_oauth_config_error(reason))}
     end
   ```

7. Add the authorization URL builder and configuration messages:

   ```elixir
   defp build_auth_url("figma_oauth", state, challenge, redirect_uri) do
     {:ok, client_id, _client_secret} = OAuthRefresher.figma_mcp_client_credentials()

     params = %{
       "response_type" => "code",
       "client_id" => client_id,
       "redirect_uri" => redirect_uri,
       "scope" => OAuthRefresher.figma_scope(),
       "state" => state,
       "code_challenge" => challenge,
       "code_challenge_method" => "S256",
       "resource" => OAuthRefresher.figma_resource()
     }

     OAuthRefresher.figma_authorize_url() <> "?" <> URI.encode_query(params)
   end

   defp format_figma_oauth_config_error(:missing_figma_mcp_client_id),
     do: "Set FIGMA_MCP_CLIENT_ID before connecting Figma MCP"

   defp format_figma_oauth_config_error(:missing_figma_mcp_client_secret),
     do: "Set FIGMA_MCP_CLIENT_SECRET before connecting Figma MCP"
   ```

Do not add `figma_oauth` to the generic API-key auth selector. It is a managed connect action whose credential kind is fixed later by the callback.

- [ ] **Step 5: Format and run the LiveView suite**

Run:

```bash
devenv shell -- mix format \
  apps/backplane_admin/lib/backplane/admin/live/settings_live.ex \
  apps/backplane_admin/test/backplane/admin/live/settings_live_test.exs
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/settings_live_test.exs
```

Expected: PASS; the exact callback URL comes from `BACKPLANE_ADMIN_URL` through `Backplane.WebOrigins`.

- [ ] **Step 6: Audit changed scope before committing**

Call `gitnexus_detect_changes` with `repo: "backplane"` and `scope: "unstaged"`, then run:

```bash
git diff --check
git diff -- apps/backplane_admin/lib/backplane/admin/live/settings_live.ex \
  apps/backplane_admin/test/backplane/admin/live/settings_live_test.exs
```

Expected: only the Figma action, shared-account copy, authorization request, and focused tests changed.

- [ ] **Step 7: Commit the authorization slice**

```bash
git add apps/backplane_admin/lib/backplane/admin/live/settings_live.ex \
  apps/backplane_admin/test/backplane/admin/live/settings_live_test.exs
git commit -m "feat(admin): add Figma MCP OAuth connect flow"
```

---

## Task 5: Exchange the Figma callback and preserve upstream ownership

**Files:**

- Create `apps/backplane_admin/test/backplane/admin/controllers/oauth_callback_controller_test.exs`
- Modify `apps/backplane_admin/lib/backplane/admin/controllers/oauth_callback_controller.ex`

- [ ] **Step 1: Create the focused controller fixture**

Create the missing `controllers` test directory and `oauth_callback_controller_test.exs` with this scaffold:

```elixir
defmodule Backplane.Admin.OAuthCallbackControllerTest do
  use Backplane.Admin.LiveCase, async: false

  import ExUnit.CaptureLog

  alias Backplane.Repo
  alias Backplane.Settings.{Credential, Credentials, OAuthRefresher, OAuthStateStore}

  @redirect_uri "http://localhost:4003/oauth/callback"

  setup do
    OAuthStateStore.clear()

    {:ok, pid} = Bandit.start_link(plug: __MODULE__.FigmaTokenEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    previous = Application.get_env(:backplane, OAuthRefresher, [])

    Application.put_env(
      :backplane,
      OAuthRefresher,
      Keyword.merge(previous,
        figma_token_url: "http://localhost:#{port}/figma/token",
        figma_mcp_client_id: "figma client",
        figma_mcp_client_secret: "secret:with/slash"
      )
    )

    on_exit(fn ->
      OAuthStateStore.clear()
      Application.put_env(:backplane, OAuthRefresher, previous)

      try do
        ThousandIsland.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp put_figma_state(name) do
    OAuthStateStore.put(%{
      "vendor" => "figma_oauth",
      "cred_name" => name,
      "code_verifier" => "test-code-verifier",
      "redirect_uri" => @redirect_uri
    })
  end

  defp store_existing(name) do
    Credentials.store_oauth_token(
      name,
      "figma_oauth",
      %{
        access_token: "existing-access-token",
        refresh_token: "existing-refresh-token",
        expires_at: System.system_time(:millisecond) + 3_600_000
      },
      "upstream",
      %{}
    )
  end
end
```

The client ID and secret deliberately contain reserved characters so a raw `client_id:client_secret` Base64 implementation cannot pass the request assertion.

- [ ] **Step 2: Add failing success, validation, replay, denial, and sanitization tests**

Add these tests before the helper functions:

```elixir
test "exchanges a Figma code with Basic auth and stores an upstream credential", %{conn: conn} do
  state = put_figma_state("shared-figma")

  conn = get(conn, "/oauth/callback", %{"code" => "valid-code", "state" => state})

  assert redirected_to(conn) == "/system/credentials"

  credential = Repo.get_by!(Credential, name: "shared-figma")
  assert credential.kind == "upstream"
  assert credential.metadata == %{"auth_type" => "figma_oauth"}
  assert {:ok, "figma-access-token"} = Credentials.fetch("shared-figma")
end

test "rejects incomplete successful responses without replacing the usable token", %{conn: conn} do
  assert {:ok, _} = store_existing("shared-figma")

  for code <- ["missing-refresh", "zero-expiry", "blank-access"] do
    state = put_figma_state("shared-figma")
    response = get(build_conn(), "/oauth/callback", %{"code" => code, "state" => state})

    assert redirected_to(response) == "/system/credentials"
    assert {:ok, "existing-access-token"} = Credentials.fetch("shared-figma")
  end
end

test "consumes callback state exactly once", %{conn: conn} do
  state = put_figma_state("shared-figma")

  first = get(conn, "/oauth/callback", %{"code" => "valid-code", "state" => state})
  assert redirected_to(first) == "/system/credentials"

  replay = get(build_conn(), "/oauth/callback", %{"code" => "valid-code", "state" => state})
  assert redirected_to(replay) == "/system/credentials"
  assert Phoenix.Flash.get(replay.assigns.flash, :error) =~ "state expired or invalid"
end

test "rejects an unknown state without calling the token endpoint", %{conn: conn} do
  response =
    get(conn, "/oauth/callback", %{
      "code" => "valid-code",
      "state" => "not-a-stored-state"
    })

  assert redirected_to(response) == "/system/credentials"
  assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "state expired or invalid"
  refute Credentials.exists?("shared-figma")
end

test "reports provider denial without creating a credential", %{conn: conn} do
  response =
    get(conn, "/oauth/callback", %{
      "error" => "access_denied",
      "error_description" => "The owner cancelled authorization"
    })

  assert redirected_to(response) == "/system/credentials"
  assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "owner cancelled"
  refute Credentials.exists?("shared-figma")
end

test "does not expose unrelated provider response fields or the client secret", %{conn: conn} do
  state = put_figma_state("shared-figma")

  log =
    capture_log(fn ->
      response =
        get(conn, "/oauth/callback", %{"code" => "rejected-code", "state" => state})

      assert redirected_to(response) == "/system/credentials"
      flash = Phoenix.Flash.get(response.assigns.flash, :error)
      assert flash =~ "expired authorization code"
      refute flash =~ "provider-access-token"
      refute flash =~ "provider-client-secret"
    end)

  refute log =~ "provider-access-token"
  refute log =~ "provider-client-secret"
  refute log =~ "secret:with/slash"
end
```

Add the local token endpoint below the test module helpers:

```elixir
defmodule FigmaTokenEndpoint do
  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
  plug(:dispatch)

  post "/figma/token" do
    expected_auth =
      "Basic " <> Base.encode64("figma+client:secret%3Awith%2Fslash")

    valid_request? =
      get_req_header(conn, "authorization") == [expected_auth] and
        conn.body_params["grant_type"] == "authorization_code" and
        conn.body_params["redirect_uri"] == @redirect_uri and
        conn.body_params["code_verifier"] == "test-code-verifier" and
        conn.body_params["resource"] == "https://mcp.figma.com/mcp"

    cond do
      not valid_request? ->
        json(conn, 400, %{"error" => "invalid_request"})

      conn.body_params["code"] == "valid-code" ->
        json(conn, 200, %{
          "access_token" => "figma-access-token",
          "refresh_token" => "figma-refresh-token",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        })

      conn.body_params["code"] == "missing-refresh" ->
        json(conn, 200, %{"access_token" => "replacement-access", "expires_in" => 3600})

      conn.body_params["code"] == "zero-expiry" ->
        json(conn, 200, %{
          "access_token" => "replacement-access",
          "refresh_token" => "replacement-refresh",
          "expires_in" => 0
        })

      conn.body_params["code"] == "blank-access" ->
        json(conn, 200, %{
          "access_token" => " ",
          "refresh_token" => "replacement-refresh",
          "expires_in" => 3600
        })

      conn.body_params["code"] == "rejected-code" ->
        json(conn, 401, %{
          "error" => "invalid_grant",
          "error_description" => "expired authorization code",
          "access_token" => "provider-access-token",
          "client_secret" => "provider-client-secret"
        })

      true ->
        json(conn, 400, %{"error" => "unknown_code"})
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
```

Because nested modules do not inherit the outer module attribute, define the same `@redirect_uri "http://localhost:4003/oauth/callback"` inside `FigmaTokenEndpoint`.

- [ ] **Step 3: Run the new controller test and verify the red state**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/controllers/oauth_callback_controller_test.exs
```

Expected: FAIL because `figma_oauth` is unsupported and the callback still stores every vendor as kind `llm`.

- [ ] **Step 4: Add Figma-specific exchange and storage dispatch**

Update the controller module documentation to include Figma. Replace the direct `Credentials.store_device_token/4` call in `callback/2` with `store_callback_tokens/4`, then add:

```elixir
defp store_callback_tokens(name, "figma_oauth", tokens, hints) do
  Credentials.store_oauth_token(name, "figma_oauth", tokens, "upstream", hints)
end

defp store_callback_tokens(name, vendor, tokens, hints) do
  Credentials.store_device_token(name, vendor, tokens, hints)
end
```

Add the Figma clause before the unsupported-vendor clause:

```elixir
defp exchange_code("figma_oauth", code, code_verifier, redirect_uri, _attrs) do
  with {:ok, headers} <- OAuthRefresher.figma_mcp_client_auth_headers() do
    token_url = OAuthRefresher.figma_token_url()

    body = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "code_verifier" => code_verifier,
      "resource" => OAuthRefresher.figma_resource()
    }

    request_options =
      token_url
      |> OAuthRefresher.request_options()
      |> Keyword.merge(form: body, headers: headers, receive_timeout: 15_000)

    case Req.post(token_url, request_options) do
      {:ok, %{status: 200, body: response}} ->
        normalize_figma_tokens(response)

      {:ok, %{status: status, body: response}} ->
        {:error, {:http, status, sanitized_oauth_error(response)}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end
end
```

Add strict success normalization. A response missing a non-blank access token, a non-blank refresh token, or a positive integer expiry never reaches storage:

```elixir
defp normalize_figma_tokens(
       %{
         "access_token" => access_token,
         "refresh_token" => refresh_token,
         "expires_in" => expires_in
       }
     )
     when is_binary(access_token) and is_binary(refresh_token) and
            is_integer(expires_in) and expires_in > 0 do
  if String.trim(access_token) == "" or String.trim(refresh_token) == "" do
    {:error, :invalid_figma_token_response}
  else
    {:ok,
     %{
       access_token: access_token,
       refresh_token: refresh_token,
       expires_at: System.system_time(:millisecond) + expires_in * 1_000
     }, %{}}
  end
end

defp normalize_figma_tokens(_response), do: {:error, :invalid_figma_token_response}

defp sanitized_oauth_error(response) when is_map(response) do
  Map.take(response, ["error", "error_description"])
end

defp sanitized_oauth_error(_response), do: %{}
```

Add the user-facing dispatch clauses:

```elixir
defp vendor_label("figma_oauth"), do: "Figma MCP"

defp format_error(:missing_figma_mcp_client_id),
  do: "FIGMA_MCP_CLIENT_ID is not configured"

defp format_error(:missing_figma_mcp_client_secret),
  do: "FIGMA_MCP_CLIENT_SECRET is not configured"

defp format_error(:invalid_figma_token_response),
  do: "Figma returned an incomplete token response"
```

The controller must reuse `OAuthRefresher.figma_mcp_client_auth_headers/0`; do not duplicate or persist the client secret.

- [ ] **Step 5: Format and run admin OAuth regressions**

Run:

```bash
devenv shell -- mix format \
  apps/backplane_admin/lib/backplane/admin/controllers/oauth_callback_controller.ex \
  apps/backplane_admin/test/backplane/admin/controllers/oauth_callback_controller_test.exs
devenv shell -- mix test \
  apps/backplane_admin/test/backplane/admin/controllers/oauth_callback_controller_test.exs \
  apps/backplane_admin/test/backplane/admin/live/settings_live_test.exs
```

Expected: PASS; successful callbacks persist `kind: "upstream"`, malformed callbacks preserve the prior token, and only sanitized provider fields reach logs and flash.

- [ ] **Step 6: Audit changed scope before committing**

Call `gitnexus_detect_changes` with `repo: "backplane"` and `scope: "unstaged"`, then run:

```bash
git diff --check
git diff -- apps/backplane_admin/lib/backplane/admin/controllers/oauth_callback_controller.ex \
  apps/backplane_admin/test/backplane/admin/controllers/oauth_callback_controller_test.exs
```

Expected: only Figma callback exchange/storage behavior and its controller tests changed; Anthropic, OpenAI, and Google still delegate to `store_device_token/4`.

- [ ] **Step 7: Commit the callback slice**

```bash
git add apps/backplane_admin/lib/backplane/admin/controllers/oauth_callback_controller.ex \
  apps/backplane_admin/test/backplane/admin/controllers/oauth_callback_controller_test.exs
git commit -m "feat(admin): exchange Figma MCP OAuth callbacks"
```

---

## Task 6: Prove the existing upstream Bearer path uses the shared token

**Files:**

- Modify `apps/backplane_mcp/test/backplane/proxy/auth_injector_test.exs`

- [ ] **Step 1: Add the Figma AuthInjector regression test**

Add this test inside `describe "inject/4"`:

```elixir
test "injects one shared Figma OAuth token for every upstream request" do
  assert {:ok, _credential} =
           Credentials.store_oauth_token(
             "figma-mcp",
             "figma_oauth",
             %{
               access_token: "figma-shared-access",
               refresh_token: "figma-shared-refresh",
               expires_at: System.system_time(:millisecond) + 3_600_000
             },
             "upstream",
             %{}
           )

  for caller_header <- ["backplane-caller-a", "backplane-caller-b"] do
    assert {:ok, headers} =
             AuthInjector.inject(
               [{"x-test-caller", caller_header}],
               "bearer",
               nil,
               "figma-mcp"
             )

    assert {"x-test-caller", caller_header} in headers
    assert {"authorization", "Bearer figma-shared-access"} in headers
  end
end
```

This is intentionally a test-only change. `AuthInjector` already resolves the named credential on every HTTP request, and the HTTP upstream uses the same request path for Streamable HTTP/event-stream responses.

- [ ] **Step 2: Run the AuthInjector test**

Run:

```bash
devenv shell -- mix format apps/backplane_mcp/test/backplane/proxy/auth_injector_test.exs
devenv shell -- mix test apps/backplane_mcp/test/backplane/proxy/auth_injector_test.exs
```

Expected: PASS without any production MCP transport or upstream-schema change.

- [ ] **Step 3: Audit changed scope before committing**

Call `gitnexus_detect_changes` with `repo: "backplane"` and `scope: "unstaged"`, then run:

```bash
git diff --check
git diff -- apps/backplane_mcp/test/backplane/proxy/auth_injector_test.exs
```

Expected: one focused regression test changed.

- [ ] **Step 4: Commit the transport proof**

```bash
git add apps/backplane_mcp/test/backplane/proxy/auth_injector_test.exs
git commit -m "test(mcp): verify Figma OAuth bearer injection"
```

---

## Task 7: Document deployment and run the final audit

**Files:**

- Modify `docs/deploy/backplane.md`

- [ ] **Step 1: Add deployment variables and the Figma runbook**

Add these rows to the environment-variable table:

```markdown
| `BACKPLANE_ADMIN_URL` | Public admin origin used to build OAuth callbacks, for example `https://admin.backplane.example.com` |
| `FIGMA_MCP_CLIENT_ID` | Figma-issued OAuth client ID for the shared remote MCP connection |
| `FIGMA_MCP_CLIENT_SECRET` | Figma-issued OAuth client secret; keep it only in deployment secrets |
```

Add this section after “After first boot”:

````markdown
### Figma remote MCP OAuth

Backplane must be approved for the [Figma MCP server catalog](https://www.figma.com/mcp-catalog/) before a live connection can complete. Register this exact public HTTPS redirect URI for the approved OAuth client:

```text
${BACKPLANE_ADMIN_URL}/oauth/callback
```

Set `FIGMA_MCP_CLIENT_ID` and `FIGMA_MCP_CLIENT_SECRET`, restart Backplane, then open **Settings → Credentials → Connect Figma MCP**. The default credential name is `figma-mcp`. Authorizing it stores one shared Figma account for every Backplane caller; create a differently named credential only when another global upstream should use another shared account.

Configure the remote upstream in **MCP Hub → Upstreams** with:

```text
URL: https://mcp.figma.com/mcp
Auth scheme: bearer
Credential: figma-mcp
```

Backplane requests `mcp:connect`, refreshes the encrypted token before expiry, and never stores the OAuth client secret in the credential row.
````

- [ ] **Step 2: Format all changed source and tests**

Run:

```bash
devenv shell -- mix format \
  apps/backplane_system/lib/backplane/settings/credentials.ex \
  apps/backplane_system/lib/backplane/settings/oauth_refresher.ex \
  apps/backplane_system/lib/backplane/settings/oauth_token_refresh_worker.ex \
  apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs \
  apps/backplane_system/test/backplane/settings/oauth_refresher_test.exs \
  apps/backplane_admin/lib/backplane/admin/live/settings_live.ex \
  apps/backplane_admin/lib/backplane/admin/controllers/oauth_callback_controller.ex \
  apps/backplane_admin/test/backplane/admin/live/settings_live_test.exs \
  apps/backplane_admin/test/backplane/admin/controllers/oauth_callback_controller_test.exs \
  apps/backplane_mcp/test/backplane/proxy/auth_injector_test.exs
```

Expected: no changes on a second run.

- [ ] **Step 3: Run the complete focused verification matrix**

Run:

```bash
devenv shell -- mix test \
  apps/backplane_system/test/backplane/settings/credentials_figma_oauth_test.exs \
  apps/backplane_system/test/backplane/settings/oauth_refresher_test.exs \
  apps/backplane_system/test/backplane/settings/credentials_cli_oauth_test.exs \
  apps/backplane_system/test/backplane/settings/credentials_oauth_test.exs

devenv shell -- mix test \
  apps/backplane_admin/test/backplane/admin/controllers/oauth_callback_controller_test.exs \
  apps/backplane_admin/test/backplane/admin/live/settings_live_test.exs

devenv shell -- mix test \
  apps/backplane_mcp/test/backplane/proxy/auth_injector_test.exs

devenv shell -- mix compile --warnings-as-errors
```

Expected: all focused tests pass and the umbrella compiles without warnings. Do not attempt a live Figma login until catalog approval and deployment credentials exist.

- [ ] **Step 4: Audit the full feature diff before the documentation commit**

Call `gitnexus_detect_changes` with `repo: "backplane"` and `scope: "unstaged"`, then run:

```bash
git diff --check
git diff -- docs/deploy/backplane.md
git diff --stat e4ff2cf..HEAD
git status --short
```

Expected: only `docs/deploy/backplane.md` remains uncommitted; the committed source/test diff matches the file map. GitNexus may still show only file nodes because its Elixir index is sparse.

- [ ] **Step 5: Commit the deployment documentation**

```bash
git add docs/deploy/backplane.md
git commit -m "docs(deploy): document Figma MCP OAuth"
```

- [ ] **Step 6: Run the post-commit repository audit**

Call `gitnexus_detect_changes` with `repo: "backplane"` and `scope: "all"`, then run:

```bash
git diff --check e4ff2cf..HEAD
git status --short --branch
git log --oneline --decorate e4ff2cf..HEAD
```

Expected: the worktree is clean, the feature consists of the planned conventional commits, and no user-owned changes from the main checkout appear in this branch.

- [ ] **Step 7: Report the external acceptance gate**

Hand off:

- the focused test commands and passing counts;
- the exact callback `${BACKPLANE_ADMIN_URL}/oauth/callback`;
- the upstream URL/auth/credential triplet;
- the fact that the credential is one shared global Figma account;
- the remaining live-only step: catalog approval, deployment client credentials, and one real authorization/refresh smoke test.
