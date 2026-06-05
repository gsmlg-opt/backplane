# Claude Code OAuth (PKCE) — Implementation Spec

Implement the Claude Code subscription OAuth flow **without** the `claude` CLI.
This is a standard OAuth 2.0 **Authorization Code grant with PKCE**, using Claude
Code's **public client** (no client secret). Authorization uses the `code=true`
manual copy-paste variant — there is **no** localhost redirect server.

The resulting access token works as a `Bearer` token against the Anthropic API
and against `GET /api/oauth/usage`.

---

## Constants

| Name           | Value                                                      |
|----------------|------------------------------------------------------------|
| `client_id`    | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (public, no secret) |
| Authorize URL  | `https://claude.ai/oauth/authorize`                        |
| Token URL      | `https://platform.claude.com/v1/oauth/token`               |
| API Key URL    | `https://api.anthropic.com/api/oauth/claude_cli/create_api_key` |
| Redirect URI   | `https://platform.claude.com/oauth/code/callback`          |

> Legacy token alias `https://console.anthropic.com/v1/oauth/token` still works,
> but match the `platform.claude.com` domain to the redirect URI above.

> Claude Code 2.1.165 still contains `https://claude.com/cai/oauth/authorize`
> as `CLAUDE_AI_AUTHORIZE_URL`, but the consent page observed during Backplane
> testing opened through `https://claude.ai/oauth/authorize`.

**Scopes** (space-separated, URL-encoded in the query):

```
org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload
```

`user:profile` is required for the usage endpoint. `user:inference` is required
for API calls. Request least privilege if you don't need the rest.

---

## PKCE values (generate fresh per flow)

- **code_verifier** — 32 random bytes, encoded as base64url **without padding**.
- **code_challenge** — `SHA-256(code_verifier)`, encoded as base64url **without padding**.
- **code_challenge_method** — the literal string `S256`.
- **state** — a *separate* 32-random-byte base64url value (CSRF). Do **not**
  reuse the verifier as the state.

Retain `code_verifier` and `state` in memory until the token exchange completes.

---

## Step 1 — Build the authorize URL

Construct `Authorize URL` + a URL-encoded query string with these params:

| Param                   | Value                          |
|-------------------------|--------------------------------|
| `code`                  | `true`                         |
| `client_id`             | the constant above             |
| `response_type`         | `code`                         |
| `redirect_uri`          | the redirect constant above    |
| `scope`                 | the scope string above         |
| `code_challenge`        | computed PKCE challenge         |
| `code_challenge_method` | `S256`                         |
| `state`                 | the random state               |

Present this URL to the user (print it / open browser). They sign in, approve,
and the callback page **displays a code to copy** — it is not POSTed anywhere.

---

## Step 2 — Receive the pasted code

The user pastes a single string in the form:

```
<authorization_code>#<state_fragment>
```

**Split on the first `#`.** The part **before** `#` is the authorization code;
the part **after** `#` is the state to forward to the exchange. They are two
distinct values — do not send the whole string as the code.

(Optionally verify the returned state fragment matches the `state` you sent.)

---

## Step 3 — Exchange code for tokens

`POST` to the **Token URL** with a **JSON** body
(`Content-Type: application/json`):

Backplane currently sends Claude Code-like client headers on token exchange and
refresh:

```
User-Agent: claude-cli/2.1.165 (external, cli)
x-app: cli
anthropic-client-platform: claude_code_cli
```

These headers alone did **not** resolve the manual Backplane exchange failure:
the token endpoint still returned `403` with
`{"error":{"type":"forbidden","message":"Request not allowed"}}`.

```json
{
  "grant_type": "authorization_code",
  "code": "<part before #>",
  "state": "<part after #>",
  "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
  "redirect_uri": "https://platform.claude.com/oauth/code/callback",
  "code_verifier": "<retained verifier>"
}
```

**Critical:** `redirect_uri` here must be byte-for-byte identical to the one in
Step 1. Any mismatch (including a localhost URI) returns `invalid_grant`.

To request a long-lived (~1 year) token, also include
`"expires_in": 31536000` in the body.

### Successful response

```json
{
  "access_token": "sk-ant-oat01-...",
  "refresh_token": "...",
  "expires_in": 31536000,
  "token_type": "bearer"
}
```

Store `access_token`, `refresh_token`, and an absolute `expires_at`
(= now + `expires_in`).

---

## Current Backplane Status

Backplane's `/admin/system/credentials/new/anthropic_oauth` flow currently:

- Generates fresh PKCE `code_verifier`, `code_challenge`, and `state`.
- Opens `https://claude.ai/oauth/authorize` with `code=true`.
- Accepts either `code#state` or the full callback URL:
  `https://platform.claude.com/oauth/code/callback?code=...&state=...`.
- Strips whitespace from pasted callback values.
- Verifies the returned state against the generated state.
- Posts JSON to `https://platform.claude.com/v1/oauth/token`.
- Does **not** send `expires_in` for the normal Claude Plan login path.
- Shows redacted request/response details in the UI on exchange failure.

Observed failure after those changes:

```elixir
%{
  status: 403,
  request: %{
    url: "https://platform.claude.com/v1/oauth/token",
    body_keys: ["client_id", "code", "code_verifier", "grant_type", "redirect_uri", "state"],
    has_expires_in: false,
    redirect_uri: "https://platform.claude.com/oauth/code/callback",
    code_length: 48,
    state_length: 43,
    verifier_length: 43
  },
  response: %{
    "error" => %{"message" => "Request not allowed", "type" => "forbidden"}
  }
}
```

Do not keep guessing at this browser exchange without comparing against a known
successful Claude Code login.

---

## Known-Success Claude Code Paths

Claude Code 2.1.165 has two relevant success paths.

### Import Existing Claude Code OAuth

Claude Code stores successful OAuth tokens in:

```
~/.claude/.credentials.json
```

Backplane already supports this format through
`Backplane.Settings.Credentials.import_cli_auth/2`. Importing the file stores the
raw JSON encrypted with metadata `auth_type=anthropic_oauth`.

Local import command:

```sh
mix run -e 'Backplane.Settings.Credentials.import_cli_auth("claude-plan", File.read!(Path.expand("~/.claude/.credentials.json")))'
```

`Credentials.fetch/1` then returns the cached `claudeAiOauth.accessToken` while
it is valid, and refreshes from `claudeAiOauth.refreshToken` when expired.
`Credentials.fetch_with_meta/1` also adds:

```
anthropic-beta: oauth-2025-04-20
```

Use this import path first when Claude Code is already logged in locally.

### Create API Key From OAuth Access Token

Claude Code also has a helper equivalent to:

```http
POST https://api.anthropic.com/api/oauth/claude_cli/create_api_key
Authorization: Bearer <access_token>
```

The successful response includes:

```json
{
  "raw_key": "sk-ant-..."
}
```

That API key creation is separate from the OAuth token exchange. Use it only
after a known-good OAuth access token exists. Do not print `raw_key`; store it
directly in the encrypted credential vault if Backplane needs an API-key-shaped
credential instead of an OAuth bearer token.

---

## Refresh

When the access token is near/after expiry, `POST` to the same Token URL:

```json
{
  "grant_type": "refresh_token",
  "refresh_token": "<stored refresh token>",
  "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
}
```

Returns a new `access_token` (and usually a rotated `refresh_token`). Handle
`429`/`5xx` with simple backoff.

---

## Using the token

Send on every API / usage request:

```
Authorization: Bearer <access_token>
anthropic-beta: oauth-2025-04-20
```

Verify with:

```
GET https://api.anthropic.com/api/oauth/usage
```

A `permission_error` for `user:profile` means the token was minted without that
scope (e.g. a `setup-token`, which only grants `user:inference`). Re-run the full
flow above with the profile scope.

---

## Suggested structure (language-agnostic)

- **Pure functions** for: PKCE generation, authorize-URL building, code splitting.
- **One stateful holder** owning the token record: persist it, expose a "get
  valid access token" call that checks `expires_at` and refreshes lazily.
- Keep the HTTP exchange behind a single function used by both grant types.
- Persistence: a simple credentials store (e.g. a JSON file). If interop with
  the `claude` CLI is desired, write under the `claudeAiOauth` key of
  `~/.claude/.credentials.json`; otherwise any local store is fine.

## Acceptance checks

1. `start` yields a URL that opens the Anthropic consent screen.
2. Pasting `code#state` exchanges successfully and returns an access token.
3. The token returns valid JSON from `/api/oauth/usage` (no scope error).
4. After forcing expiry, the holder refreshes transparently on next use.
5. A wrong/mismatched `redirect_uri` is shown to fail with `invalid_grant`
   (sanity test of the validation).
