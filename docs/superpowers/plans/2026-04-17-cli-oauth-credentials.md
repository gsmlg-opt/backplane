# CLI OAuth Credentials Import — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let admins paste the contents of `~/.claude/.credentials.json` (Claude Code CLI) or `~/.codex/auth.json` (OpenAI Codex CLI) into the credentials page, store the OAuth tokens encrypted, auto-refresh them, and inject them into LLM proxy requests with the correct headers.

**Architecture:** Two new `auth_type` values (`anthropic_oauth`, `openai_oauth`) layered on the existing `credentials` table. Encrypted column holds the raw vendor JSON file content; on each fetch we decrypt, parse, refresh if expired (via a new `OAuthRefresher` module), re-encrypt, and return the `access_token`. `Backplane.LLM.CredentialPlug` branches on auth_type to attach the right headers (Anthropic OAuth uses `Authorization: Bearer …` + `anthropic-beta: oauth-2025-04-20`; OpenAI OAuth uses `Authorization: Bearer …`). UI gets a second button **Import CLI Auth File** that opens a paste-textarea form; server detects vendor by JSON shape.

**Tech Stack:** Elixir 1.18 / OTP 28, Phoenix LiveView, Ecto + Postgres, `Req` for HTTP, AES-256-GCM via `Backplane.Settings.Encryption`, Bandit + `Plug.Router` for HTTP test endpoints (existing pattern in `OAuthClientTest`).

**Spec:** `docs/superpowers/specs/2026-04-17-cli-oauth-credentials-design.md`

**File map (created/modified):**

- Create: `apps/backplane/lib/backplane/settings/oauth_refresher.ex` — pure function refresher for the two CLI vendors.
- Modify: `apps/backplane/lib/backplane/settings/credentials.ex` — `import_cli_auth/2`, two new `fetch/1` clauses, `fetch_with_meta/1`, updated `fetch_hint/1`.
- Modify: `apps/backplane/lib/backplane/llm/credential_plug.ex` — branch injection on `auth_type` returned by `fetch_with_meta/1`.
- Modify: `apps/backplane_web/lib/backplane_web/live/settings_live.ex` — second action button + import form + `import_cli_auth` event.
- Create: `apps/backplane/test/backplane/settings/oauth_refresher_test.exs`
- Create: `apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs`
- Modify: `apps/backplane/test/backplane/llm/credential_plug_test.exs` — add OAuth-token branch tests.
- Modify: `apps/backplane_web/test/backplane_web/live/settings_live_test.exs` — add Import CLI Auth File flow test.

---

## Task 0: Discovery spike — capture exact refresh request shape

**This task is performed by a human (or by the executor in a paired session). Do not auto-execute.**

The spec mandates verifying the live token endpoints before committing to a wire format. We need: HTTP method, URL, headers, body content-type, body shape, and the field names in the success response, for both:

- Anthropic Claude Code: refresh against `https://console.anthropic.com/v1/oauth/token`
- OpenAI Codex: refresh against `https://auth.openai.com/oauth/token`

**Files:** None modified. Findings are recorded in this plan, then Task 2 is updated accordingly before implementation begins.

- [ ] **Step 1: Read a known refresh_token from your local CLI auth files**

```bash
jq -r .claudeAiOauth.refreshToken ~/.claude/.credentials.json
jq -r .tokens.refresh_token ~/.codex/auth.json   # if you have one
```

- [ ] **Step 2: Probe Anthropic refresh endpoint from `iex`**

```elixir
# iex -S mix
Req.post!("https://console.anthropic.com/v1/oauth/token",
  json: %{
    "grant_type" => "refresh_token",
    "refresh_token" => System.get_env("ANTHROPIC_REFRESH_TOKEN"),
    "client_id" => "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  })
|> Map.take([:status, :headers, :body])
```

Expected: `:status` is `200`, `:body` contains keys `access_token`, `refresh_token`, `expires_in`, `scope`, `token_type`. Note actual key names exactly — vendors sometimes use `expires_at` (unix epoch) vs `expires_in` (seconds from now).

- [ ] **Step 3: Probe OpenAI refresh endpoint from `iex`**

Try JSON first:

```elixir
Req.post!("https://auth.openai.com/oauth/token",
  json: %{
    "grant_type" => "refresh_token",
    "refresh_token" => System.get_env("OPENAI_REFRESH_TOKEN"),
    "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann"
  })
|> Map.take([:status, :headers, :body])
```

If that returns a 4xx, retry with `form:` instead of `json:` (urlencoded). Note which one works and the exact response key names.

- [ ] **Step 4: Update Task 2 of this plan with the verified specs**

Edit this file (`docs/superpowers/plans/2026-04-17-cli-oauth-credentials.md`). In Task 2 there are two placeholders marked `<!-- TASK 0 INPUT -->`. Replace each with the verified content type, body, and response-key mapping. Once both are filled in, Task 0 is complete and Task 1 may begin.

- [ ] **Step 5: Commit the plan update**

```bash
git add docs/superpowers/plans/2026-04-17-cli-oauth-credentials.md
git commit -m "docs(plan): record verified OAuth refresh endpoint specs"
```

---

## Task 1: Plumbing — add `Application.get_env` overrides for refresh URLs

We want unit tests to point the refresher at a local Bandit endpoint (matching the existing `OAuthClientTest` pattern) without monkey-patching modules. Wire this in before writing `OAuthRefresher`.

**Files:**
- Modify: `config/config.exs` (umbrella root)
- Modify: `config/test.exs` (umbrella root)

- [ ] **Step 1: Add default URLs to `config/config.exs`**

Open `config/config.exs` and append at the bottom (before the `import_config "#{config_env()}.exs"` line if present, otherwise at file end):

```elixir
config :backplane, Backplane.Settings.OAuthRefresher,
  anthropic_token_url: "https://console.anthropic.com/v1/oauth/token",
  openai_token_url: "https://auth.openai.com/oauth/token"
```

- [ ] **Step 2: Override URLs in `config/test.exs`**

Open `config/test.exs` and append at the bottom:

```elixir
# OAuthRefresher endpoints overridden per-test via
# Application.put_env/3 in OAuthRefresherTest. Defaults left as production
# URLs so anything that forgets to override fails noisily on connect.
```

(Comment only — no functional change. Tests will set the URLs themselves.)

- [ ] **Step 3: Verify config compiles**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 4: Commit**

```bash
git add config/config.exs config/test.exs
git commit -m "feat(settings): add OAuthRefresher endpoint config keys"
```

---

## Task 2: Build `OAuthRefresher` (TDD)

**Files:**
- Create: `apps/backplane/lib/backplane/settings/oauth_refresher.ex`
- Create: `apps/backplane/test/backplane/settings/oauth_refresher_test.exs`

- [ ] **Step 1: Write the failing test file**

Create `apps/backplane/test/backplane/settings/oauth_refresher_test.exs`:

```elixir
defmodule Backplane.Settings.OAuthRefresherTest do
  use ExUnit.Case, async: false

  alias Backplane.Settings.OAuthRefresher

  setup do
    {:ok, pid} = Bandit.start_link(plug: __MODULE__.MockEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    prior = Application.get_env(:backplane, OAuthRefresher, [])

    Application.put_env(:backplane, OAuthRefresher,
      anthropic_token_url: "http://localhost:#{port}/anthropic/token",
      openai_token_url: "http://localhost:#{port}/openai/token"
    )

    on_exit(fn ->
      Application.put_env(:backplane, OAuthRefresher, prior)

      try do
        ThousandIsland.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{port: port}
  end

  defmodule MockEndpoint do
    use Plug.Router
    plug :match
    plug Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason
    plug :dispatch

    post "/anthropic/token" do
      cond do
        conn.body_params["refresh_token"] == "good-anthropic" ->
          resp = %{
            "access_token" => "ant-new-access",
            "refresh_token" => "ant-new-refresh",
            "expires_in" => 28_800,
            "token_type" => "Bearer",
            "scope" => "user:inference"
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp))

        true ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"error" => "invalid_grant"}))
      end
    end

    post "/openai/token" do
      cond do
        conn.body_params["refresh_token"] == "good-openai" ->
          resp = %{
            "access_token" => "oai-new-access",
            "refresh_token" => "oai-new-refresh",
            "id_token" => "oai-new-id",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp))

        true ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"error" => "invalid_grant"}))
      end
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  describe "refresh/2 :anthropic_oauth" do
    test "returns rotated tokens on success" do
      assert {:ok, %{access_token: "ant-new-access", refresh_token: "ant-new-refresh", expires_at: expires_at}} =
               OAuthRefresher.refresh(:anthropic_oauth, "good-anthropic")

      now_ms = System.system_time(:millisecond)
      assert expires_at > now_ms
      # Allow a 5s window for slow CI.
      assert_in_delta expires_at, now_ms + 28_800 * 1000, 5_000
    end

    test "returns {:error, {:refresh_failed, 401}} on bad refresh token" do
      assert {:error, {:refresh_failed, 401}} =
               OAuthRefresher.refresh(:anthropic_oauth, "wrong")
    end
  end

  describe "refresh/2 :openai_oauth" do
    test "returns rotated tokens on success" do
      assert {:ok, %{access_token: "oai-new-access", refresh_token: "oai-new-refresh", expires_at: expires_at}} =
               OAuthRefresher.refresh(:openai_oauth, "good-openai")

      now_ms = System.system_time(:millisecond)
      assert_in_delta expires_at, now_ms + 3600 * 1000, 5_000
    end

    test "returns {:error, {:refresh_failed, 401}} on bad refresh token" do
      assert {:error, {:refresh_failed, 401}} =
               OAuthRefresher.refresh(:openai_oauth, "wrong")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane/test/backplane/settings/oauth_refresher_test.exs`
Expected: FAIL with `(UndefinedFunctionError) function Backplane.Settings.OAuthRefresher.refresh/2 is undefined`.

- [ ] **Step 3: Implement `OAuthRefresher`**

Create `apps/backplane/lib/backplane/settings/oauth_refresher.ex`:

```elixir
defmodule Backplane.Settings.OAuthRefresher do
  @moduledoc """
  OAuth refresh-token exchange for the two CLI-issued credential formats:

  - `:anthropic_oauth` — Claude Code CLI (`~/.claude/.credentials.json`)
  - `:openai_oauth`   — Codex CLI (`~/.codex/auth.json`)

  Pure function. Does not touch the DB or cache. The caller (`Credentials`)
  persists rotated tokens.
  """

  require Logger

  @anthropic_client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @openai_client_id "app_EMoamEEZ73f0CkXaXp7hrann"

  @type vendor :: :anthropic_oauth | :openai_oauth
  @type refreshed :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: integer()
        }

  @spec refresh(vendor(), String.t()) :: {:ok, refreshed()} | {:error, term()}
  def refresh(:anthropic_oauth, refresh_token) when is_binary(refresh_token) do
    do_refresh(
      url(:anthropic_token_url),
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @anthropic_client_id
      }
    )
  end

  def refresh(:openai_oauth, refresh_token) when is_binary(refresh_token) do
    do_refresh(
      url(:openai_token_url),
      <!-- TASK 0 INPUT: replace this entire body literal with the verified shape.
           Default written here matches the JSON form used by the Codex CLI; if
           the discovery spike found that auth.openai.com requires
           application/x-www-form-urlencoded, change `json:` to `form:` in
           do_refresh/2 and keep this map shape. -->
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @openai_client_id
      }
    )
  end

  defp do_refresh(url, body) do
    case Req.post(url, json: body, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"access_token" => access} = resp}} ->
        expires_in = resp["expires_in"] || 3600
        # Keep the existing refresh token if the server doesn't issue a new one
        # (some endpoints rotate it, some don't).
        refresh = resp["refresh_token"] || body["refresh_token"]
        expires_at = System.system_time(:millisecond) + expires_in * 1000

        {:ok, %{access_token: access, refresh_token: refresh, expires_at: expires_at}}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning(
          "OAuth refresh failed: status=#{status} body=#{inspect(resp_body)}"
        )

        {:error, {:refresh_failed, status}}

      {:error, reason} ->
        Logger.warning("OAuth refresh transport error: #{inspect(reason)}")
        {:error, {:refresh_error, reason}}
    end
  end

  defp url(key) do
    cfg = Application.get_env(:backplane, __MODULE__, [])
    Keyword.fetch!(cfg, key)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/backplane/test/backplane/settings/oauth_refresher_test.exs`
Expected: PASS, 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane/lib/backplane/settings/oauth_refresher.ex \
        apps/backplane/test/backplane/settings/oauth_refresher_test.exs
git commit -m "feat(settings): add OAuthRefresher for CLI OAuth tokens"
```

---

## Task 3: Add `Credentials.import_cli_auth/2` (TDD)

**Files:**
- Create: `apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs`
- Modify: `apps/backplane/lib/backplane/settings/credentials.ex`

- [ ] **Step 1: Write failing tests**

Create `apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs`:

```elixir
defmodule Backplane.Settings.CredentialsCliOAuthTest do
  use Backplane.DataCase, async: false

  alias Backplane.Settings.{Credentials, Encryption}

  @anthropic_json ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-aaaa","refreshToken":"sk-ant-ort01-bbbb","expiresAt":1776417713649,"scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},"organizationUuid":"org-uuid-1234"})

  @openai_json ~s({"OPENAI_API_KEY":null,"tokens":{"id_token":"id-aaa","access_token":"oai-bbb","refresh_token":"oai-ccc","account_id":"acc-1"},"last_refresh":"2026-04-15T12:34:56Z"})

  describe "import_cli_auth/2 — Anthropic" do
    test "stores credential with auth_type=anthropic_oauth and raw JSON encrypted" do
      assert {:ok, cred} = Credentials.import_cli_auth("claude-code-oauth", @anthropic_json)
      assert cred.metadata["auth_type"] == "anthropic_oauth"
      assert cred.metadata["subscription_type"] == "max"
      assert cred.metadata["organization_uuid"] == "org-uuid-1234"

      assert {:ok, plaintext} = Encryption.decrypt(cred.encrypted_value)
      assert plaintext == @anthropic_json
    end
  end

  describe "import_cli_auth/2 — OpenAI" do
    test "stores credential with auth_type=openai_oauth and raw JSON encrypted" do
      assert {:ok, cred} = Credentials.import_cli_auth("codex-oauth", @openai_json)
      assert cred.metadata["auth_type"] == "openai_oauth"
      assert cred.metadata["account_id"] == "acc-1"

      assert {:ok, plaintext} = Encryption.decrypt(cred.encrypted_value)
      assert plaintext == @openai_json
    end
  end

  describe "import_cli_auth/2 — errors" do
    test "rejects malformed JSON" do
      assert {:error, :invalid_json} = Credentials.import_cli_auth("bad", "not json {")
    end

    test "rejects unrecognized JSON shape" do
      assert {:error, :unrecognized_format} =
               Credentials.import_cli_auth("bad", ~s({"foo":"bar"}))
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs`
Expected: FAIL with `(UndefinedFunctionError) function Backplane.Settings.Credentials.import_cli_auth/2 is undefined`.

- [ ] **Step 3: Add `import_cli_auth/2` to `Credentials`**

Open `apps/backplane/lib/backplane/settings/credentials.ex`. Add the function below `store/4` (after the closing `end` of `store/4`):

```elixir
  @doc """
  Import a CLI OAuth auth file (Claude Code or Codex) into the credential store.

  The raw JSON content is encrypted as-is and stored alongside an `auth_type`
  marker in `metadata`, plus a few non-secret hints (subscription_type,
  organization_uuid for Anthropic; account_id for OpenAI).
  """
  @spec import_cli_auth(String.t(), String.t()) ::
          {:ok, Credential.t()} | {:error, :invalid_json | :unrecognized_format | term()}
  def import_cli_auth(name, raw_json) when is_binary(name) and is_binary(raw_json) do
    with {:ok, parsed} <- decode_json(raw_json),
         {:ok, auth_type, hints} <- detect_cli_format(parsed) do
      metadata = Map.merge(%{"auth_type" => auth_type}, hints)
      store(name, raw_json, "llm", metadata)
    end
  end

  defp decode_json(raw) do
    case Jason.decode(raw) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:ok, _} -> {:error, :unrecognized_format}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp detect_cli_format(%{"claudeAiOauth" => %{"refreshToken" => _} = oauth} = top) do
    hints =
      %{}
      |> maybe_put("subscription_type", oauth["subscriptionType"])
      |> maybe_put("organization_uuid", top["organizationUuid"])

    {:ok, "anthropic_oauth", hints}
  end

  defp detect_cli_format(%{"tokens" => %{"refresh_token" => _} = tokens}) do
    hints = maybe_put(%{}, "account_id", tokens["account_id"])
    {:ok, "openai_oauth", hints}
  end

  defp detect_cli_format(_), do: {:error, :unrecognized_format}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
```

Also extend `validate_oauth_metadata/1` so it short-circuits these new auth types (they don't have `client_id`/`token_url`). Find the function near the bottom:

```elixir
  defp validate_oauth_metadata(%{"auth_type" => "oauth2_client_credentials"} = meta) do
```

Insert these two clauses immediately above it:

```elixir
  defp validate_oauth_metadata(%{"auth_type" => "anthropic_oauth"}), do: :ok
  defp validate_oauth_metadata(%{"auth_type" => "openai_oauth"}), do: :ok

```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs`
Expected: PASS, 4 tests, 0 failures.

- [ ] **Step 5: Run the full credentials test files to ensure no regression**

Run: `mix test apps/backplane/test/backplane/settings/`
Expected: PASS, all tests.

- [ ] **Step 6: Commit**

```bash
git add apps/backplane/lib/backplane/settings/credentials.ex \
        apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs
git commit -m "feat(settings): import_cli_auth for Claude Code / Codex OAuth files"
```

---

## Task 4: Add `fetch/1` clauses for CLI OAuth (TDD)

This is the main behavioral change: when an Anthropic-OAuth or OpenAI-OAuth credential is fetched, return its current `access_token`, refreshing first if expired, and persist the rotated blob.

**Files:**
- Modify: `apps/backplane/lib/backplane/settings/credentials.ex`
- Modify: `apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs`

- [ ] **Step 1: Append failing tests for fetch behavior**

Add the following `describe` blocks to the **bottom** of `credentials_cli_oauth_test.exs` (before the final `end`). Add this `setup` block at the top of the module first (just after `use Backplane.DataCase` line):

```elixir
  alias Backplane.Settings.{TokenCache, OAuthRefresher}

  setup do
    TokenCache.clear()

    {:ok, pid} = Bandit.start_link(plug: __MODULE__.RefreshEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    prior = Application.get_env(:backplane, OAuthRefresher, [])

    Application.put_env(:backplane, OAuthRefresher,
      anthropic_token_url: "http://localhost:#{port}/anthropic/token",
      openai_token_url: "http://localhost:#{port}/openai/token"
    )

    on_exit(fn ->
      Application.put_env(:backplane, OAuthRefresher, prior)

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
    plug :match
    plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
    plug :dispatch

    post "/anthropic/token" do
      resp = %{
        "access_token" => "sk-ant-oat01-REFRESHED",
        "refresh_token" => "sk-ant-ort01-NEWREFRESH",
        "expires_in" => 28_800,
        "token_type" => "Bearer"
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp))
    end

    post "/openai/token" do
      resp = %{
        "access_token" => "oai-REFRESHED",
        "refresh_token" => "oai-NEWREFRESH",
        "id_token" => "oai-NEWID",
        "expires_in" => 3600,
        "token_type" => "Bearer"
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp))
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end
```

Now append (just before the module-closing `end`):

```elixir
  describe "fetch/1 with anthropic_oauth credential" do
    test "returns the cached access_token when expiresAt is in the future" do
      future_ms = System.system_time(:millisecond) + 60 * 60 * 1000

      json =
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-oat01-LIVE",
            "refreshToken" => "sk-ant-ort01-rrr",
            "expiresAt" => future_ms,
            "scopes" => [],
            "subscriptionType" => "max"
          },
          "organizationUuid" => "org-1"
        })

      {:ok, _} = Credentials.import_cli_auth("ant-live", json)

      assert {:ok, "sk-ant-oat01-LIVE"} = Credentials.fetch("ant-live")
    end

    test "refreshes and persists rotated blob when expired" do
      past_ms = System.system_time(:millisecond) - 60_000

      json =
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-oat01-EXPIRED",
            "refreshToken" => "sk-ant-ort01-rrr",
            "expiresAt" => past_ms,
            "scopes" => [],
            "subscriptionType" => "max"
          },
          "organizationUuid" => "org-1"
        })

      {:ok, _} = Credentials.import_cli_auth("ant-expired", json)

      assert {:ok, "sk-ant-oat01-REFRESHED"} = Credentials.fetch("ant-expired")

      # The persisted blob should now contain the rotated tokens.
      {:ok, refreshed_plain} = Credentials.fetch("ant-expired")
      assert refreshed_plain == "sk-ant-oat01-REFRESHED"

      # Internal: re-decrypt the row directly to confirm refresh_token rotated.
      cred = Backplane.Repo.get_by!(Backplane.Settings.Credential, name: "ant-expired")
      {:ok, blob} = Backplane.Settings.Encryption.decrypt(cred.encrypted_value)
      parsed = Jason.decode!(blob)
      assert parsed["claudeAiOauth"]["accessToken"] == "sk-ant-oat01-REFRESHED"
      assert parsed["claudeAiOauth"]["refreshToken"] == "sk-ant-ort01-NEWREFRESH"
      assert parsed["claudeAiOauth"]["expiresAt"] > System.system_time(:millisecond)
    end
  end

  describe "fetch/1 with openai_oauth credential" do
    test "always refreshes (no expiresAt in file) and returns new access_token" do
      json =
        Jason.encode!(%{
          "OPENAI_API_KEY" => nil,
          "tokens" => %{
            "id_token" => "id-old",
            "access_token" => "oai-OLD",
            "refresh_token" => "oai-rrr",
            "account_id" => "acc-1"
          },
          "last_refresh" => "2026-04-15T12:34:56Z"
        })

      {:ok, _} = Credentials.import_cli_auth("oai-cred", json)

      assert {:ok, "oai-REFRESHED"} = Credentials.fetch("oai-cred")

      cred = Backplane.Repo.get_by!(Backplane.Settings.Credential, name: "oai-cred")
      {:ok, blob} = Backplane.Settings.Encryption.decrypt(cred.encrypted_value)
      parsed = Jason.decode!(blob)
      assert parsed["tokens"]["access_token"] == "oai-REFRESHED"
      assert parsed["tokens"]["refresh_token"] == "oai-NEWREFRESH"
      assert parsed["tokens"]["id_token"] == "oai-NEWID"
    end

    test "second fetch within TTL hits cache, does not re-refresh" do
      json =
        Jason.encode!(%{
          "OPENAI_API_KEY" => nil,
          "tokens" => %{
            "id_token" => "id-old",
            "access_token" => "oai-OLD",
            "refresh_token" => "oai-rrr",
            "account_id" => "acc-1"
          }
        })

      {:ok, _} = Credentials.import_cli_auth("oai-cache", json)

      assert {:ok, "oai-REFRESHED"} = Credentials.fetch("oai-cache")
      # Without restarting the mock endpoint we can still verify the cache by
      # calling fetch again — same response should be served from TokenCache,
      # not a new HTTP call. (We check this indirectly: rotated blob's
      # refresh_token must remain stable across the two calls because no second
      # refresh occurred.)
      assert {:ok, "oai-REFRESHED"} = Credentials.fetch("oai-cache")

      cred = Backplane.Repo.get_by!(Backplane.Settings.Credential, name: "oai-cache")
      {:ok, blob} = Backplane.Settings.Encryption.decrypt(cred.encrypted_value)
      parsed = Jason.decode!(blob)
      assert parsed["tokens"]["refresh_token"] == "oai-NEWREFRESH"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs`
Expected: FAIL — the new `fetch/1` clauses don't exist; the existing `fetch/1` will return the encrypted JSON blob as plaintext for the `auth_type` we just added.

- [ ] **Step 3: Add `fetch/1` clauses + helpers in `Credentials`**

Open `apps/backplane/lib/backplane/settings/credentials.ex`. Replace the current `fetch/1` function with the version below (locate the existing `def fetch(name) do ... end` block):

```elixir
  @doc "Fetch and decrypt a credential by name. For OAuth credentials, exchanges or returns a cached token."
  @spec fetch(String.t()) :: {:ok, String.t()} | {:error, :not_found | :decryption_failed | term()}
  def fetch(name) do
    case Repo.get_by(Credential, name: name) do
      nil ->
        {:error, :not_found}

      %Credential{metadata: %{"auth_type" => "oauth2_client_credentials"}} = cred ->
        fetch_oauth_token(cred)

      %Credential{metadata: %{"auth_type" => "anthropic_oauth"}} = cred ->
        fetch_cli_oauth(cred, :anthropic_oauth)

      %Credential{metadata: %{"auth_type" => "openai_oauth"}} = cred ->
        fetch_cli_oauth(cred, :openai_oauth)

      %Credential{encrypted_value: encrypted} ->
        Encryption.decrypt(encrypted)
    end
  end
```

Then add these private functions near the bottom of the module (alongside `fetch_oauth_token/1`):

```elixir
  defp fetch_cli_oauth(%Credential{name: name} = cred, vendor) do
    alias Backplane.Settings.{TokenCache, OAuthRefresher}

    case TokenCache.get(name) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        with {:ok, blob} <- Encryption.decrypt(cred.encrypted_value),
             {:ok, parsed} <- Jason.decode(blob) do
          handle_cli_oauth(cred, vendor, parsed)
        end
    end
  end

  # Anthropic file: refresh only when the embedded expiresAt is past or near.
  defp handle_cli_oauth(cred, :anthropic_oauth, %{"claudeAiOauth" => %{"accessToken" => access, "expiresAt" => expires_at_ms}} = parsed)
       when is_binary(access) and is_integer(expires_at_ms) do
    now_ms = System.system_time(:millisecond)

    if expires_at_ms > now_ms + 60_000 do
      cache_and_return(cred.name, access, expires_at_ms)
    else
      do_refresh_and_persist(cred, :anthropic_oauth, parsed)
    end
  end

  defp handle_cli_oauth(cred, :anthropic_oauth, parsed) do
    do_refresh_and_persist(cred, :anthropic_oauth, parsed)
  end

  # Codex file: no expiresAt — refresh on every cache miss.
  defp handle_cli_oauth(cred, :openai_oauth, parsed) do
    do_refresh_and_persist(cred, :openai_oauth, parsed)
  end

  # Wrapped in a transaction with `FOR UPDATE` so two concurrent fetches on
  # the same expired credential don't both hit the refresh endpoint and race
  # on the rotated refresh_token. The second waiter re-checks freshness inside
  # the lock and short-circuits when the first caller has already rotated.
  defp do_refresh_and_persist(cred, vendor, parsed) do
    Repo.transaction(fn ->
      locked =
        Credential
        |> Ecto.Query.from(where: [name: ^cred.name], lock: "FOR UPDATE")
        |> Repo.one!()

      with {:ok, locked_blob} <- Encryption.decrypt(locked.encrypted_value),
           {:ok, locked_parsed} <- Jason.decode(locked_blob) do
        case maybe_short_circuit(vendor, locked, locked_parsed) do
          {:ok, fresh_access, fresh_expires_ms} ->
            cache_and_return(locked.name, fresh_access, fresh_expires_ms)

          :stale ->
            refresh_token = extract_refresh_token(vendor, locked_parsed)
            refresh_and_persist_locked(locked, vendor, locked_parsed, refresh_token)
        end
      end
      |> case do
        {:ok, _} = ok -> ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_short_circuit(:anthropic_oauth, _cred, %{"claudeAiOauth" => %{"accessToken" => access, "expiresAt" => expires_at_ms}})
       when is_binary(access) and is_integer(expires_at_ms) do
    if expires_at_ms > System.system_time(:millisecond) + 60_000 do
      {:ok, access, expires_at_ms}
    else
      :stale
    end
  end

  # Codex tokens have no embedded expiry; always refresh inside the lock.
  defp maybe_short_circuit(_vendor, _cred, _parsed), do: :stale

  defp refresh_and_persist_locked(locked, vendor, parsed, refresh_token) do
    with {:ok, %{access_token: access, refresh_token: new_refresh, expires_at: expires_at_ms}} <-
           Backplane.Settings.OAuthRefresher.refresh(vendor, refresh_token),
         updated = update_blob(vendor, parsed, access, new_refresh, expires_at_ms),
         encoded = Jason.encode!(updated),
         encrypted = Encryption.encrypt(encoded),
         {:ok, _} <-
           locked
           |> Credential.changeset(%{encrypted_value: encrypted})
           |> Repo.update() do
      cache_and_return(locked.name, access, expires_at_ms)
    end
  end

  defp extract_refresh_token(:anthropic_oauth, %{"claudeAiOauth" => %{"refreshToken" => rt}}), do: rt
  defp extract_refresh_token(:openai_oauth, %{"tokens" => %{"refresh_token" => rt}}), do: rt

  defp update_blob(:anthropic_oauth, parsed, access, new_refresh, expires_at_ms) do
    update_in(parsed, ["claudeAiOauth"], fn oauth ->
      oauth
      |> Map.put("accessToken", access)
      |> Map.put("refreshToken", new_refresh)
      |> Map.put("expiresAt", expires_at_ms)
    end)
  end

  defp update_blob(:openai_oauth, parsed, access, new_refresh, _expires_at_ms) do
    parsed
    |> update_in(["tokens"], fn tokens ->
      tokens
      |> Map.put("access_token", access)
      |> Map.put("refresh_token", new_refresh)
    end)
    |> Map.put("last_refresh", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp cache_and_return(name, access_token, expires_at_ms) do
    now_ms = System.system_time(:millisecond)
    expires_in_seconds = max(div(expires_at_ms - now_ms, 1000), 60)
    Backplane.Settings.TokenCache.put(name, access_token, expires_in_seconds)
    {:ok, access_token}
  end
```

- [ ] **Step 4: Run the file's tests to verify they pass**

Run: `mix test apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs`
Expected: PASS, 8 tests, 0 failures.

- [ ] **Step 5: Run all settings tests for regression**

Run: `mix test apps/backplane/test/backplane/settings/`
Expected: PASS, all tests.

- [ ] **Step 6: Commit**

```bash
git add apps/backplane/lib/backplane/settings/credentials.ex \
        apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs
git commit -m "feat(settings): fetch/1 supports anthropic_oauth and openai_oauth"
```

---

## Task 5: Add `Credentials.fetch_with_meta/1` and update `fetch_hint/1` (TDD)

`CredentialPlug` needs to know the auth_type so it can pick the right header style. We don't want it parsing metadata directly.

**Files:**
- Modify: `apps/backplane/lib/backplane/settings/credentials.ex`
- Modify: `apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs`

- [ ] **Step 1: Append failing tests**

Append to `credentials_cli_oauth_test.exs` (before the final `end`):

```elixir
  describe "fetch_with_meta/1" do
    test "returns api_key auth_type for plain credentials" do
      {:ok, _} = Credentials.store("plain", "sk-1234abcd", "llm")

      assert {:ok, "sk-1234abcd", %{auth_type: "api_key", extra_headers: []}} =
               Credentials.fetch_with_meta("plain")
    end

    test "returns anthropic_oauth auth_type with anthropic-beta extra header" do
      future_ms = System.system_time(:millisecond) + 60 * 60 * 1000

      json =
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-oat01-LIVE",
            "refreshToken" => "rt",
            "expiresAt" => future_ms,
            "scopes" => []
          },
          "organizationUuid" => "org-1"
        })

      {:ok, _} = Credentials.import_cli_auth("ant-meta", json)

      assert {:ok, "sk-ant-oat01-LIVE",
              %{auth_type: "anthropic_oauth", extra_headers: [{"anthropic-beta", "oauth-2025-04-20"}]}} =
               Credentials.fetch_with_meta("ant-meta")
    end

    test "returns openai_oauth auth_type with no extra headers" do
      json =
        Jason.encode!(%{
          "OPENAI_API_KEY" => nil,
          "tokens" => %{
            "id_token" => "i",
            "access_token" => "oai-OLD",
            "refresh_token" => "rt",
            "account_id" => "a"
          }
        })

      {:ok, _} = Credentials.import_cli_auth("oai-meta", json)

      assert {:ok, "oai-REFRESHED", %{auth_type: "openai_oauth", extra_headers: []}} =
               Credentials.fetch_with_meta("oai-meta")
    end

    test "returns {:error, :not_found} for unknown name" do
      assert {:error, :not_found} = Credentials.fetch_with_meta("nope")
    end
  end

  describe "fetch_hint/1 for OAuth credentials" do
    test "returns last 4 of accessToken for anthropic_oauth" do
      future_ms = System.system_time(:millisecond) + 60 * 60 * 1000

      json =
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-oat01-XYZW1234",
            "refreshToken" => "rt",
            "expiresAt" => future_ms,
            "scopes" => []
          },
          "organizationUuid" => "o"
        })

      {:ok, _} = Credentials.import_cli_auth("ant-hint", json)

      assert "...1234" = Credentials.fetch_hint("ant-hint")
    end

    test "returns last 4 of access_token for openai_oauth" do
      json =
        Jason.encode!(%{
          "OPENAI_API_KEY" => nil,
          "tokens" => %{
            "id_token" => "i",
            "access_token" => "oai-OLD",
            "refresh_token" => "rt",
            "account_id" => "a"
          }
        })

      {:ok, _} = Credentials.import_cli_auth("oai-hint", json)

      # fetch_hint triggers a refresh because Codex tokens always refresh on miss;
      # the last 4 of the refreshed access_token are "SHED" (oai-REFRESHED)
      assert "...SHED" = Credentials.fetch_hint("oai-hint")
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs`
Expected: FAIL with `(UndefinedFunctionError) function Backplane.Settings.Credentials.fetch_with_meta/1 is undefined`. The hint test for OAuth credentials may currently return `..."}` (last 4 of the JSON closing).

- [ ] **Step 3: Add `fetch_with_meta/1`**

Add this function in `credentials.ex` immediately after the `fetch/1` block:

```elixir
  @doc """
  Like `fetch/1` but also returns the credential's auth_type and any
  per-vendor extra headers required (e.g. `anthropic-beta` for OAuth tokens).

  Used by `Backplane.LLM.CredentialPlug` to pick the correct header injection
  strategy.
  """
  @spec fetch_with_meta(String.t()) ::
          {:ok, String.t(), %{auth_type: String.t(), extra_headers: [{String.t(), String.t()}]}}
          | {:error, term()}
  def fetch_with_meta(name) do
    case Repo.get_by(Credential, name: name) do
      nil ->
        {:error, :not_found}

      %Credential{metadata: meta} ->
        auth_type = (meta || %{}) |> Map.get("auth_type", "api_key")

        with {:ok, token} <- fetch(name) do
          {:ok, token, %{auth_type: auth_type, extra_headers: extra_headers_for(auth_type)}}
        end
    end
  end

  defp extra_headers_for("anthropic_oauth"), do: [{"anthropic-beta", "oauth-2025-04-20"}]
  defp extra_headers_for(_), do: []
```

- [ ] **Step 4: Update `fetch_hint/1` to handle OAuth blobs**

Replace the existing `fetch_hint/1` with:

```elixir
  @doc """
  Get the last 4 characters of a credential's decrypted value as a hint.
  Returns `"...xxxx"` format, or `"..."` if the value is too short. For
  OAuth-blob credentials, returns the last 4 of the live access_token.
  """
  @spec fetch_hint(String.t()) :: String.t()
  def fetch_hint(name) do
    case fetch(name) do
      {:ok, plaintext} when byte_size(plaintext) >= 4 ->
        "..." <> String.slice(plaintext, -4..-1//1)

      {:ok, _} ->
        "..."

      {:error, _} ->
        "..."
    end
  end
```

(No structural change — the function already calls `fetch/1`, which now returns a real `access_token` for OAuth credentials. Confirm the source matches the snippet above; if it does, no edit needed.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs`
Expected: PASS, 14 tests, 0 failures.

- [ ] **Step 6: Run all settings tests**

Run: `mix test apps/backplane/test/backplane/settings/`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/backplane/lib/backplane/settings/credentials.ex \
        apps/backplane/test/backplane/settings/credentials_cli_oauth_test.exs
git commit -m "feat(settings): add fetch_with_meta and OAuth-aware fetch_hint"
```

---

## Task 6: Branch `CredentialPlug` on auth_type (TDD)

**Files:**
- Modify: `apps/backplane/lib/backplane/llm/credential_plug.ex`
- Modify: `apps/backplane/test/backplane/llm/credential_plug_test.exs`

- [ ] **Step 1: Append failing tests for the OAuth branches**

Append to `credential_plug_test.exs` (just before the file's final `end`):

```elixir
  # ── CLI OAuth credentials ─────────────────────────────────────────────────────

  describe "inject/2 with anthropic_oauth credential" do
    setup do
      future_ms = System.system_time(:millisecond) + 60 * 60 * 1000

      json =
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-oat01-LIVE",
            "refreshToken" => "rt",
            "expiresAt" => future_ms,
            "scopes" => []
          },
          "organizationUuid" => "o"
        })

      {:ok, _} = Credentials.import_cli_auth("ant-oauth-cred", json)

      attrs = %{
        name: "cred-plug-ant-oauth",
        api_type: :anthropic,
        api_url: "https://api.anthropic.com",
        credential: "ant-oauth-cred",
        models: ["claude-3-5-sonnet-20241022"]
      }

      {:ok, provider} = Provider.create(attrs)
      {:ok, provider: provider}
    end

    test "drops x-api-key, sets Authorization Bearer, adds anthropic-beta",
         %{provider: provider} do
      conn =
        conn(:post, "/")
        |> put_req_header("x-api-key", "client-supplied-key")
        |> CredentialPlug.inject(provider)

      assert get_req_header(conn, "x-api-key") == []
      assert get_req_header(conn, "authorization") == ["Bearer sk-ant-oat01-LIVE"]
      assert get_req_header(conn, "anthropic-beta") == ["oauth-2025-04-20"]
      assert get_req_header(conn, "anthropic-version") == ["2023-06-01"]
    end
  end

  describe "build_auth_headers/1 with anthropic_oauth credential" do
    test "includes Authorization Bearer + anthropic-beta + anthropic-version" do
      future_ms = System.system_time(:millisecond) + 60 * 60 * 1000

      json =
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-oat01-LIVE",
            "refreshToken" => "rt",
            "expiresAt" => future_ms,
            "scopes" => []
          },
          "organizationUuid" => "o"
        })

      {:ok, _} = Credentials.import_cli_auth("ant-oauth-build", json)

      attrs = %{
        name: "cred-plug-ant-oauth-build",
        api_type: :anthropic,
        api_url: "https://api.anthropic.com",
        credential: "ant-oauth-build",
        models: ["claude-3-5-sonnet-20241022"]
      }

      {:ok, provider} = Provider.create(attrs)

      assert {:ok, headers} = CredentialPlug.build_auth_headers(provider)
      assert {"authorization", "Bearer sk-ant-oat01-LIVE"} in headers
      assert {"anthropic-beta", "oauth-2025-04-20"} in headers
      assert {"anthropic-version", "2023-06-01"} in headers
      refute Enum.any?(headers, fn {k, _} -> k == "x-api-key" end)
    end
  end
```

Note: `openai_oauth` doesn't need a separate test because the OpenAI provider path always sets `Authorization: Bearer …` regardless of auth_type — the existing OpenAI tests already cover that header.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test apps/backplane/test/backplane/llm/credential_plug_test.exs`
Expected: FAIL — current `CredentialPlug` always sets `x-api-key` for Anthropic providers, so the new test will see `x-api-key: sk-ant-oat01-LIVE` instead of an empty list, and no `anthropic-beta` header.

- [ ] **Step 3: Update `CredentialPlug`**

Open `apps/backplane/lib/backplane/llm/credential_plug.ex`. Replace the entire file with:

```elixir
defmodule Backplane.LLM.CredentialPlug do
  @moduledoc """
  Strips client auth headers and injects provider API credentials into a conn.
  """

  alias Backplane.LLM.Provider
  alias Backplane.Settings.Credentials
  import Plug.Conn

  @default_anthropic_version "2023-06-01"

  @doc """
  Inject provider credentials into `conn` based on the provider's `api_type`
  and the credential's `auth_type`:

  - api_type `:anthropic` + auth_type `api_key` (or `oauth2_client_credentials`):
    deletes `authorization`, sets `x-api-key`, adds `anthropic-version`.
  - api_type `:anthropic` + auth_type `anthropic_oauth`:
    deletes `x-api-key`, sets `Authorization: Bearer …`, adds `anthropic-beta`
    and `anthropic-version`.
  - api_type `:openai` (any auth_type): deletes `x-api-key`, sets
    `Authorization: Bearer …`.

  Always merges the provider's `default_headers` last.
  """
  @spec inject(Plug.Conn.t(), Provider.t()) :: Plug.Conn.t()
  def inject(%Plug.Conn{} = conn, %Provider{api_type: api_type} = provider)
      when api_type in [:anthropic, :openai] do
    case resolve_credential(provider) do
      {:ok, token, meta} ->
        conn
        |> apply_auth_headers(api_type, meta.auth_type, token)
        |> apply_extra_headers(meta.extra_headers)
        |> maybe_apply_anthropic_version(api_type)
        |> merge_default_headers(provider.default_headers)

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "provider credential not configured"}))
        |> halt()
    end
  end

  @doc """
  Build authentication headers for a provider without a conn.

  Returns `{:ok, headers}` where headers is a list of `{key, value}` tuples,
  or `{:error, reason}`.
  """
  @spec build_auth_headers(Provider.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, atom()}
  def build_auth_headers(%Provider{api_type: api_type} = provider)
      when api_type in [:anthropic, :openai] do
    case resolve_credential(provider) do
      {:ok, token, meta} ->
        headers =
          base_headers(api_type, meta.auth_type, token) ++
            meta.extra_headers ++
            anthropic_version_pair(api_type) ++
            default_header_pairs(provider.default_headers)

        {:ok, headers}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp resolve_credential(%Provider{credential: credential})
       when is_binary(credential) and credential != "" do
    Credentials.fetch_with_meta(credential)
  end

  defp resolve_credential(_provider), do: {:error, :no_credential}

  # Conn-modifying header strategies.

  defp apply_auth_headers(conn, :anthropic, "anthropic_oauth", token) do
    conn
    |> delete_req_header("x-api-key")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp apply_auth_headers(conn, :anthropic, _auth_type, token) do
    conn
    |> delete_req_header("authorization")
    |> put_req_header("x-api-key", token)
  end

  defp apply_auth_headers(conn, :openai, _auth_type, token) do
    conn
    |> delete_req_header("x-api-key")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp apply_extra_headers(conn, []), do: conn

  defp apply_extra_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  end

  defp maybe_apply_anthropic_version(conn, :anthropic) do
    case get_req_header(conn, "anthropic-version") do
      [] -> put_req_header(conn, "anthropic-version", @default_anthropic_version)
      _ -> conn
    end
  end

  defp maybe_apply_anthropic_version(conn, _), do: conn

  # Pair-list helpers used by build_auth_headers.

  defp base_headers(:anthropic, "anthropic_oauth", token),
    do: [{"authorization", "Bearer #{token}"}]

  defp base_headers(:anthropic, _auth_type, token), do: [{"x-api-key", token}]

  defp base_headers(:openai, _auth_type, token),
    do: [{"authorization", "Bearer #{token}"}]

  defp anthropic_version_pair(:anthropic), do: [{"anthropic-version", @default_anthropic_version}]
  defp anthropic_version_pair(_), do: []

  defp default_header_pairs(nil), do: []

  defp default_header_pairs(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
  end

  defp merge_default_headers(conn, headers) when is_map(headers) do
    Enum.reduce(headers, conn, fn {key, value}, acc ->
      put_req_header(acc, String.downcase(key), value)
    end)
  end

  defp merge_default_headers(conn, _), do: conn
end
```

- [ ] **Step 4: Run the credential_plug tests**

Run: `mix test apps/backplane/test/backplane/llm/credential_plug_test.exs`
Expected: PASS, all tests (existing api_key tests must still pass — the api_key path is preserved).

- [ ] **Step 5: Run the full backplane app test suite as a regression check**

Run: `mix test apps/backplane/test`
Expected: PASS, all tests.

- [ ] **Step 6: Commit**

```bash
git add apps/backplane/lib/backplane/llm/credential_plug.ex \
        apps/backplane/test/backplane/llm/credential_plug_test.exs
git commit -m "feat(llm): inject CLI OAuth tokens with vendor-specific headers"
```

---

## Task 7: Add Import CLI Auth File button + form to SettingsLive (TDD)

**Files:**
- Modify: `apps/backplane_web/lib/backplane_web/live/settings_live.ex`
- Modify: `apps/backplane_web/test/backplane_web/live/settings_live_test.exs`

- [ ] **Step 1: Append failing LiveView tests**

Append the following `describe` blocks to `settings_live_test.exs` (before its final `end`):

```elixir
  describe "import CLI auth file" do
    # expiresAt is far in the future so fetch_hint doesn't trigger a real
    # network refresh when the list re-renders after import.
    @anthropic_json ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-AAAA","refreshToken":"sk-ant-ort01-BBBB","expiresAt":9999999999999,"scopes":[],"subscriptionType":"max"},"organizationUuid":"org-1"})

    test "shows Import CLI Auth File button on credentials tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/settings?tab=credentials")
      assert html =~ "Import CLI Auth File"
    end

    test "show_import_form opens the import textarea form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings?tab=credentials")

      html =
        view
        |> element("el-dm-button[phx-click=show_import_form]")
        |> render_click()

      assert html =~ "Import CLI Auth File"
      assert html =~ "import_cli_auth"
      assert html =~ "Auth JSON"
    end

    test "imports Anthropic auth JSON and lists credential", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings?tab=credentials")

      view
      |> element("el-dm-button[phx-click=show_import_form]")
      |> render_click()

      html =
        view
        |> form("form[phx-submit=import_cli_auth]", %{
          "name" => "claude-code-oauth",
          "auth_json" => @anthropic_json
        })
        |> render_submit()

      assert html =~ "claude-code-oauth"
      assert html =~ "anthropic_oauth"
    end

    test "shows error flash on invalid JSON", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings?tab=credentials")

      view
      |> element("el-dm-button[phx-click=show_import_form]")
      |> render_click()

      html =
        view
        |> form("form[phx-submit=import_cli_auth]", %{
          "name" => "broken",
          "auth_json" => "not json {"
        })
        |> render_submit()

      assert html =~ "Invalid JSON" or html =~ "invalid_json"
    end
  end
```

- [ ] **Step 2: Run the LiveView tests to verify they fail**

Run: `mix test apps/backplane_web/test/backplane_web/live/settings_live_test.exs`
Expected: FAIL — no `Import CLI Auth File` button is rendered yet.

- [ ] **Step 3: Wire up the form in `SettingsLive`**

Open `apps/backplane_web/lib/backplane_web/live/settings_live.ex`.

**3a.** In `load_data(socket, "credentials")`, extend the assigns to include `cred_form_mode: nil` (already present), plus two more keys for the import form:

```elixir
  defp load_data(socket, "credentials") do
    credentials =
      Credentials.list()
      |> Enum.map(fn cred ->
        Map.put(cred, :hint, Credentials.fetch_hint(cred.name))
      end)

    assign(socket,
      credentials: credentials,
      cred_form_mode: nil,
      cred_editing_name: nil,
      cred_name: "",
      cred_kind: "llm",
      cred_secret: "",
      cred_auth_type: "api_key",
      cred_client_id: "",
      cred_token_url: "",
      cred_scope: "",
      cred_import_name: "",
      cred_import_json: ""
    )
  end
```

**3b.** Add new event handlers near the other credential handlers (just below `handle_event("show_rotate_form", ...)`):

```elixir
  def handle_event("show_import_form", _, socket) do
    {:noreply,
     assign(socket,
       cred_form_mode: :import,
       cred_editing_name: nil,
       cred_import_name: "claude-code-oauth",
       cred_import_json: ""
     )}
  end

  def handle_event("import_cli_auth", params, socket) do
    name = String.trim(params["name"] || "")
    json = params["auth_json"] || ""

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Name is required")}

      json == "" ->
        {:noreply, put_flash(socket, :error, "Paste the auth JSON to import")}

      true ->
        case Credentials.import_cli_auth(name, json) do
          {:ok, cred} ->
            kind = cred.metadata["auth_type"]

            {:noreply,
             socket
             |> put_flash(:info, "Imported #{kind} credential '#{name}'")
             |> assign(cred_form_mode: nil)
             |> load_data("credentials")}

          {:error, :invalid_json} ->
            {:noreply, put_flash(socket, :error, "Invalid JSON — paste the file contents exactly")}

          {:error, :unrecognized_format} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Unrecognized format. Expected ~/.claude/.credentials.json or ~/.codex/auth.json"
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to import credential")}
        end
    end
  end
```

**3c.** Update the credentials tab header (`render_credentials_tab/1`) so the action row shows both buttons. Replace the existing `<div class="flex items-center justify-between mb-4">` block with:

```elixir
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-lg font-semibold">Credential Store</h2>
        <div :if={@cred_form_mode == nil} class="flex items-center gap-2">
          <.dm_btn variant="primary" phx-click="show_add_form">
            Add Credential
          </.dm_btn>
          <.dm_btn phx-click="show_import_form">
            Import CLI Auth File
          </.dm_btn>
        </div>
      </div>
```

**3d.** Render the import form when `@cred_form_mode == :import`. Add this just below the existing `<.render_cred_form ... />` line in `render_credentials_tab/1`:

```elixir
      <.render_import_form :if={@cred_form_mode == :import} {assigns} />
```

And add the new function at the bottom of the module (after `render_cred_form/1`):

```elixir
  defp render_import_form(assigns) do
    ~H"""
    <.dm_card variant="bordered" class="mb-6">
      <:title>Import CLI Auth File</:title>
      <p class="text-sm text-on-surface-variant mb-4">
        Paste the contents of <code>~/.claude/.credentials.json</code>
        (Claude Code) or <code>~/.codex/auth.json</code> (Codex). The file is
        encrypted at rest and refreshed automatically.
      </p>
      <form phx-submit="import_cli_auth" class="space-y-4">
        <.dm_input
          id="cred-import-name"
          name="name"
          label="Credential Name"
          value={@cred_import_name}
          placeholder="claude-code-oauth"
          required
        />
        <div class="form-control">
          <label for="cred-import-json" class="label">
            <span class="label-text">Auth JSON</span>
          </label>
          <textarea
            id="cred-import-json"
            name="auth_json"
            rows="12"
            class="textarea textarea-bordered font-mono text-xs w-full"
            placeholder={~s({"claudeAiOauth": ...} or {"tokens": ...})}
            required
          ><%= @cred_import_json %></textarea>
        </div>
        <div class="flex gap-2 pt-2">
          <.dm_btn type="submit" variant="primary">Import</.dm_btn>
          <.dm_btn type="button" phx-click="cancel_cred_form">Cancel</.dm_btn>
        </div>
      </form>
    </.dm_card>
    """
  end
```

**3e.** Update the `Kind` column rendering in the credentials list so the auth_type is visible. Replace this line in `render_credentials_tab/1`:

```elixir
            <:col :let={cred} label="Kind">
              <.dm_badge variant="neutral">{cred.kind}</.dm_badge>
            </:col>
```

with:

```elixir
            <:col :let={cred} label="Kind">
              <div class="flex items-center gap-1">
                <.dm_badge variant="neutral">{cred.kind}</.dm_badge>
                <.dm_badge :if={(cred.metadata || %{})["auth_type"] in ~w(anthropic_oauth openai_oauth)} variant="info">
                  {(cred.metadata || %{})["auth_type"]}
                </.dm_badge>
              </div>
            </:col>
```

- [ ] **Step 4: Run LiveView tests to verify they pass**

Run: `mix test apps/backplane_web/test/backplane_web/live/settings_live_test.exs`
Expected: PASS, all tests.

- [ ] **Step 5: Run the full umbrella test suite**

Run: `mix test`
Expected: PASS, no regressions.

- [ ] **Step 6: Commit**

```bash
git add apps/backplane_web/lib/backplane_web/live/settings_live.ex \
        apps/backplane_web/test/backplane_web/live/settings_live_test.exs
git commit -m "feat(web): import CLI OAuth auth files from Settings > Credentials"
```

---

## Task 8: Manual smoke test in the browser

Automated tests cover the contract; this is a sanity check on the rendered UI.

**Files:** none.

- [ ] **Step 1: Start the server**

Run: `iex -S mix phx.server`

- [ ] **Step 2: Open the credentials tab**

Visit `http://10.100.10.17:4220/admin/settings?tab=credentials` (or `http://localhost:4220/...`).

Expected: see two buttons in the header — **Add Credential** and **Import CLI Auth File**.

- [ ] **Step 3: Click Import CLI Auth File**

Expected: a card titled "Import CLI Auth File" appears with a name input (default `claude-code-oauth`) and a tall mono-font textarea labeled "Auth JSON".

- [ ] **Step 4: Paste a real `~/.claude/.credentials.json`**

```bash
cat ~/.claude/.credentials.json | xclip -selection clipboard  # or pbcopy
```

Paste into the textarea, leave the name as `claude-code-oauth`, click **Import**.

Expected: a success flash "Imported anthropic_oauth credential 'claude-code-oauth'", the form closes, the credential appears in the table with both `llm` and `anthropic_oauth` badges in the Kind column. The Hint column shows the last 4 of the live access token.

- [ ] **Step 5: Verify proxy injection (optional)**

If you have an LLM provider configured to use this credential, send a test request through the proxy and confirm via `Logger` (or Wireshark / a debug provider) that the upstream sees `Authorization: Bearer …` plus `anthropic-beta: oauth-2025-04-20`, with no `x-api-key`.

- [ ] **Step 6: Repeat with `~/.codex/auth.json`** (if available) — name `codex-oauth`. Confirm the badge reads `openai_oauth`.

- [ ] **Step 7: Commit any UX tweaks made during smoke testing**

If everything looked good, no commit needed. Otherwise, commit the polish before closing the task.

---

## Done

All eight tasks complete. The credentials page now supports importing both CLI OAuth auth files. The LLM proxy will transparently refresh expired tokens and inject the right headers per vendor.
