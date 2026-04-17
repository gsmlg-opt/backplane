# CLI OAuth Credentials Import — Design

**Date:** 2026-04-17
**Status:** Approved (pending user review)
**Scope:** Allow admins to import Anthropic Claude Code (`~/.claude/.credentials.json`)
and OpenAI Codex (`~/.codex/auth.json`) OAuth tokens into the credentials store
and have the LLM proxy use them transparently with auto-refresh.

## Goal

Today the credential store supports `api_key` and `oauth2_client_credentials`.
Neither matches the OAuth user-token format used by the Claude Code CLI and the
Codex CLI, both of which ship a JSON file containing `{access_token, refresh_token,
expires_at}` plus subscription metadata. We want the LLM proxy to be able to
route requests through these personal tokens (e.g. a Claude Max subscription)
instead of API-key billing.

## Non-goals

- Initiating an OAuth login flow inside Backplane. Admins still log in via the
  CLIs themselves and import the resulting file.
- Per-user / per-client token isolation. A credential is shared across all
  consumers of a provider, same as today.
- Auto-detecting changes to the source file on disk. Re-import is manual.

## File shapes (reference)

**`~/.claude/.credentials.json`**

```json
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-…",
    "refreshToken": "sk-ant-ort01-…",
    "expiresAt": 1776417713649,
    "scopes": ["user:inference", "user:profile", "…"],
    "subscriptionType": "max",
    "rateLimitTier": "default_claude_max_20x"
  },
  "organizationUuid": "3112f8a8-…"
}
```

`expiresAt` is unix-millis.

**`~/.codex/auth.json`** (representative)

```json
{
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token": "…",
    "access_token": "…",
    "refresh_token": "…",
    "account_id": "…"
  },
  "last_refresh": "2026-04-15T12:34:56Z"
}
```

Codex stores no explicit `expires_at`; access tokens are short-lived (~1h).
We treat absence as "refresh on every fetch unless cached" and rely on the
existing `TokenCache` TTL.

## Storage model

Use the existing `credentials` table. No schema migration.

- `kind` stays `llm`.
- `metadata.auth_type` is the dispatch key:
  - `"anthropic_oauth"` — Claude Code file
  - `"openai_oauth"` — Codex file
- `encrypted_value` stores **the raw original JSON file content**, encrypted
  with the existing `Backplane.Settings.Encryption` (AES-256-GCM).
  - On refresh, the JSON is updated in place (new `access_token`, new
    `refresh_token`, new `expires_at` / `last_refresh`) and re-encrypted.
  - Format follows each vendor's existing shape so a debug export round-trips.
- `metadata` may optionally carry non-secret hints for the UI
  (`subscription_type`, `organization_uuid`, `account_id`) populated at import
  time, but the source of truth remains the encrypted JSON.

## Module changes

### New: `Backplane.Settings.OAuthRefresher`

```elixir
@anthropic_client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
@anthropic_token_url "https://console.anthropic.com/v1/oauth/token"

@openai_client_id "app_EMoamEEZ73f0CkXaXp7hrann"
@openai_token_url "https://auth.openai.com/oauth/token"

@spec refresh(:anthropic_oauth | :openai_oauth, refresh_token :: String.t()) ::
        {:ok, %{access_token: String.t(), refresh_token: String.t(), expires_at: integer() | nil}}
        | {:error, term()}
```

Both client IDs are public values shipped with the CLIs, not secrets. They
live as module attributes — no per-credential override.

Anthropic request body:

```json
{"grant_type": "refresh_token",
 "refresh_token": "...",
 "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"}
```

OpenAI request body (same JSON shape with `client_id` set to the Codex public
client). Implementation step zero is to call both endpoints from `iex` with a
known refresh token, capture the exact request shape and required headers (in
particular whether `auth.openai.com` requires `application/x-www-form-urlencoded`
vs JSON), and codify that into the refresher with one passing test before any
other module is touched.

HTTP via `Req`. The refresher is a pure function — it does not touch the DB
or cache; the caller (`Credentials`) is responsible for persistence.

### `Backplane.Settings.Credentials`

Two new clauses inside `fetch/1`, dispatching on `metadata["auth_type"]`:

```elixir
def fetch(name) do
  case Repo.get_by(Credential, name: name) do
    nil -> {:error, :not_found}
    %Credential{metadata: %{"auth_type" => "oauth2_client_credentials"}} = c -> fetch_oauth_token(c)
    %Credential{metadata: %{"auth_type" => "anthropic_oauth"}} = c -> fetch_cli_oauth(c, :anthropic_oauth)
    %Credential{metadata: %{"auth_type" => "openai_oauth"}} = c   -> fetch_cli_oauth(c, :openai_oauth)
    %Credential{encrypted_value: encrypted} -> Encryption.decrypt(encrypted)
  end
end
```

`fetch_cli_oauth/2`:

1. Check `TokenCache.get(name)` — return cached access token on hit.
2. Decrypt `encrypted_value`, parse JSON.
3. If `access_token` is present and `expires_at > now + 60s` (Anthropic only;
   Codex has no expiry stored — skip check), cache and return it.
4. Else call `OAuthRefresher.refresh/2` with the refresh token.
5. On success: rebuild the JSON blob in the same vendor shape, re-encrypt,
   update the row in a transaction, cache the new access token until expiry,
   return it.
6. On failure: invalidate cache, surface `{:error, reason}`. The LLM proxy
   already returns 503 in this case.

New helper `fetch_with_meta/1`:

```elixir
@spec fetch_with_meta(String.t()) ::
        {:ok, String.t(), %{auth_type: String.t(), extra_headers: [{String.t(), String.t()}]}}
        | {:error, term()}
```

Used by `CredentialPlug` to know which header style to apply. `extra_headers`
holds `[{"anthropic-beta", "oauth-2025-04-20"}]` for `anthropic_oauth`, empty
for the rest. Existing `fetch/1` keeps its current contract — anything other
than `CredentialPlug` is unaffected.

New helper `import_cli_auth/2`:

```elixir
@spec import_cli_auth(name :: String.t(), raw_json :: String.t()) ::
        {:ok, Credential.t()} | {:error, :invalid_json | :unrecognized_format | term()}
```

Parses the JSON, detects shape, builds `metadata`, calls `store/4` with
`kind = "llm"`. Detection rules:

- Top-level key `"claudeAiOauth"` and nested `"refreshToken"` → `anthropic_oauth`.
- Top-level key `"tokens"` with a `"refresh_token"` inside → `openai_oauth`.
- Anything else → `{:error, :unrecognized_format}`.

`fetch_hint/1` updated: when the credential's auth_type is `anthropic_oauth`
or `openai_oauth`, parse the JSON and return the last 4 chars of the access
token instead of the JSON closing brace.

### `Backplane.LLM.CredentialPlug`

Replace the `resolve_api_key/1` call with `Credentials.fetch_with_meta/1` and
branch on `auth_type` when constructing headers:

- `api_key` (or unset auth_type, for backward compat):
  - Anthropic provider → `x-api-key: <token>`, plus `anthropic-version`
  - OpenAI provider   → `Authorization: Bearer <token>`
- `oauth2_client_credentials`: same as `api_key` (the existing token-exchange
  path produces a Bearer-style access token suited to whichever provider is
  configured).
- `anthropic_oauth`: drop `x-api-key`, set `Authorization: Bearer <token>`,
  add `anthropic-beta: oauth-2025-04-20`, plus `anthropic-version`.
- `openai_oauth`: `Authorization: Bearer <token>` (same as the OpenAI
  api_key path).

`build_auth_headers/1` follows the same branching for callers that build
headers without a `conn`.

A `Provider`'s `api_type` and the credential's `auth_type` should be
compatible. We don't enforce that at the plug — the proxy will fail with the
upstream's own error if you point an OpenAI provider at an Anthropic OAuth
credential. We can add validation in `Backplane.LLM.Provider` later if it
becomes a recurring footgun.

### `BackplaneWeb.SettingsLive` (Credentials tab)

Add a second action button next to **Add Credential**: **Import CLI Auth File**.

It opens a new form (separate from the existing add/edit/rotate form):

- **Name** — text input. Pre-filled with `claude-code-oauth` initially; once
  the user pastes JSON we client-side detect Anthropic vs OpenAI? No — keep
  it simple: leave the default name as-is, server detects on submit, surface
  detected type in the success flash.
- **Auth JSON** — textarea (mono font, 12 rows).
- Help text: "Paste the contents of `~/.claude/.credentials.json` or
  `~/.codex/auth.json`. The file is encrypted at rest and refreshed
  automatically."
- Submit → `phx-submit="import_cli_auth"` → `Credentials.import_cli_auth/2`.

Existing list table gains a small **type badge** column (or extends the
existing `Kind` column rendering) so admins can tell `anthropic_oauth` /
`openai_oauth` rows apart from plain `api_key` rows. Edit on these rows
opens a read-only metadata view plus a **Re-import** button (which reuses
the import form pre-populated with the existing name, expecting a fresh
JSON paste). No "Rotate" button for OAuth credentials — refresh is
automatic, and re-import handles a stolen-refresh-token scenario.

## Concurrency

Two requests hitting an expired token simultaneously must not both refresh
and race on the DB write. The refresh path is wrapped in
`Repo.transaction/1` with `Repo.get_by(..., lock: "FOR UPDATE")`. After the
second waiter acquires the lock the row already has a fresh access token, so
it short-circuits without making a second HTTP call.

`TokenCache` continues to act as the fast path for non-expired tokens.

## Test plan

- `Backplane.Settings.CredentialsTest`
  - `import_cli_auth/2` parses Anthropic shape → stores with
    `auth_type = "anthropic_oauth"`.
  - `import_cli_auth/2` parses OpenAI shape → stores with
    `auth_type = "openai_oauth"`.
  - `import_cli_auth/2` rejects malformed and unrecognized JSON.
  - `fetch/1` returns cached access token when not expired.
  - `fetch/1` calls refresher (Mox'd) when expired and persists rotated blob.
  - `fetch_hint/1` returns last 4 of access_token for OAuth credentials.

- `Backplane.Settings.OAuthRefresherTest`
  - Anthropic refresh: correct URL, body, headers; parses success response.
  - OpenAI refresh: correct URL, body, headers; parses success response.
  - Surfaces non-2xx with structured error.

- `Backplane.LLM.CredentialPlugTest`
  - `anthropic_oauth` → injects `Authorization: Bearer …` + `anthropic-beta`,
    no `x-api-key`.
  - `openai_oauth` → injects `Authorization: Bearer …`.
  - `api_key` paths unchanged (regression).

- `BackplaneWeb.SettingsLiveTest` (LiveView)
  - Import form happy path renders, submits, shows success flash with
    detected type.
  - Import form surfaces error on invalid JSON.

## Out of scope / follow-ups

- Per-credential subscription badges in the LLM Providers UI.
- Background pre-emptive refresh (refresh N seconds before expiry on a
  schedule, not lazily on fetch).
- Detecting the file on disk and offering a one-click import when the user
  is also the admin.
