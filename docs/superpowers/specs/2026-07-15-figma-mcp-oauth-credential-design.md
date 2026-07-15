# Shared Figma MCP OAuth Credential — Design

**Date:** 2026-07-15
**Status:** Approved (pending written-spec review)
**Scope:** Add a Figma OAuth credential type to System → Credentials for use by
the existing global upstream MCP model.

## Goal

An administrator can authorize one Figma account from Backplane's Credentials
page. Backplane stores the resulting OAuth tokens as one encrypted upstream
credential and uses that credential for every caller routed through a Figma MCP
upstream.

The feature must preserve Backplane's current ownership model: OAuth identifies
the upstream service account, not the individual Backplane caller.

## External prerequisite

Figma currently restricts its remote MCP server to approved clients in the
Figma MCP Catalog. Backplane must be registered with Figma before its OAuth
client credentials can authorize against the production server.

The deployment provides:

- `FIGMA_MCP_CLIENT_ID`
- `FIGMA_MCP_CLIENT_SECRET`
- `BACKPLANE_ADMIN_URL`, whose `/oauth/callback` URL must be registered with
  Figma byte-for-byte and be publicly reachable over HTTPS

Backplane must not embed, copy, or impersonate another approved MCP client's
identity. Missing Figma client configuration prevents the authorization flow
from starting and produces an actionable admin error.

## User experience

System → Credentials gains a **Connect Figma MCP** action beside the existing
vendor OAuth actions.

Selecting it opens the existing OAuth authorization form with:

- provider label **Figma MCP**;
- default credential name `figma-mcp`;
- an editable credential name;
- the existing connect, retry, reconnect, renew, status, and delete behavior.

Successful authorization creates a row with:

- `kind = "upstream"`;
- `metadata.auth_type = "figma_oauth"`;
- encrypted access and refresh tokens;
- the normal OAuth status badge on the edit page.

Multiple named Figma credentials remain possible; no database singleton
constraint is added. Each named credential is nevertheless global, and every
caller of an upstream selecting that credential uses the same Figma account.

The generic secret-entry form remains unchanged. Figma OAuth is initiated
through the vendor connect action so an administrator cannot accidentally save
an empty or pasted token as `figma_oauth`.

## OAuth protocol

Backplane uses Figma's MCP-specific OAuth endpoints and values:

- authorization endpoint: `https://www.figma.com/oauth/mcp`;
- token endpoint: `https://api.figma.com/v1/oauth/token`;
- protected resource: `https://mcp.figma.com/mcp`;
- scope: `mcp:connect`;
- grant types: authorization code and refresh token;
- PKCE method: `S256`.

The authorization request includes `response_type=code`, the configured client
ID, the exact callback URI, scope, state, PKCE challenge, challenge method, and
the protected-resource indicator.

The callback consumes the one-time state from `OAuthStateStore` before exchanging
the code. State retains the store's existing ten-minute lifetime and cannot be
replayed. The token request is form encoded, includes the code, callback URI,
PKCE verifier, grant type, and protected-resource indicator, and authenticates
the OAuth client with `client_secret_basic` HTTP authentication.

A successful code exchange must contain non-empty access and refresh tokens and
a positive expiry. Because this is a long-lived shared upstream identity,
Backplane rejects an incomplete response instead of saving a credential that
cannot renew itself.

The refresh request is also form encoded, uses HTTP Basic client authentication,
and includes the refresh token, `grant_type=refresh_token`, and protected-resource
indicator. A rotated refresh token replaces the previous value.

## Components and responsibilities

### Admin LiveView

`Backplane.Admin.SettingsLive` adds Figma to the existing vendor OAuth dispatch:

- render the connect action and Figma labels;
- default the credential name to `figma-mcp`;
- generate state and PKCE values through the existing helpers;
- store the callback state through `OAuthStateStore`;
- construct the Figma authorization URL;
- fail before redirecting when the client ID or secret is missing.

No new LiveView route is required because
`/system/credentials/new/:vendor` already handles vendor OAuth flows.

### OAuth callback

`Backplane.Admin.OAuthCallbackController` adds a `figma_oauth` code-exchange
branch. It normalizes the successful response to Backplane's flat token shape:

```json
{
  "access_token": "...",
  "refresh_token": "...",
  "expires_at": 1780000000000
}
```

The callback stores this token set with credential kind `upstream`. Existing
vendors continue to default to kind `llm`.

### Credential store

`Backplane.Settings.Credentials` recognizes `figma_oauth` as a refreshable OAuth
vendor. A new `store_oauth_token/5` helper accepts an explicit credential kind;
the existing `store_device_token/4` delegates to it with kind `llm`, preserving
all current callers. The Figma callback calls the generic helper with kind
`upstream`.

The existing flat-token fetch path, token cache, row lock, refresh-token
extraction, rotated-token persistence, and OAuth status calculation are reused.
Successful authorization or reconnection invalidates the named token-cache entry
so a previous access token cannot survive an upsert. No schema migration is
required. The Figma client secret is never stored in credential metadata or the
encrypted token blob.

### Token refresher

`Backplane.Settings.OAuthRefresher` adds `:figma_oauth` while retaining its
existing public refresh contract. Figma client credentials come from runtime
environment variables, with application configuration overrides available for
isolated tests only. Production endpoints, resource, and scope remain pinned to
Figma's published MCP metadata. The refresher must never include client
credentials or token values in logs or returned errors.

`Backplane.Settings.OAuthTokenRefreshWorker` includes `figma_oauth` in its
default scan. Figma expiry checks cap the worker-provided window at ten minutes;
the existing two-hour window remains unchanged for Claude Plan credentials.
Named refresh jobs and row-level locking continue to isolate failures and prevent
duplicate refreshes.

### MCP upstream

No MCP upstream schema or transport change is required. A Figma upstream uses:

```text
URL: https://mcp.figma.com/mcp
Auth scheme: bearer
Credential: figma-mcp
```

`Backplane.Proxy.AuthInjector` already resolves credentials per request through
`Credentials.fetch/1`. It therefore receives a current Figma access token and
injects `Authorization: Bearer <token>` for both HTTP and SSE transports.
Existing inbound Backplane client scopes still decide which callers may invoke
the namespaced Figma tools; OAuth does not widen caller authorization.

## Data flow

1. An administrator selects **Connect Figma MCP** and submits a credential name.
2. Backplane validates deployment configuration, creates PKCE and one-time state,
   and opens Figma's authorization page.
3. The administrator authorizes the shared Figma account.
4. Figma redirects to the admin callback with a code and state.
5. Backplane consumes state, exchanges the code, and encrypts the token set as an
   upstream `figma_oauth` credential.
6. A configured Figma upstream resolves that named credential for every request.
7. A valid access token is returned from the cache; an expiring token is refreshed
   under a database row lock and the rotated token set is persisted.
8. Every authenticated Backplane caller reaches Figma as the same authorized
   Figma account.

## Error handling and security

- Missing client ID or secret: do not open Figma; show a configuration error.
- Missing or expired callback state: reject the callback without exchanging a
  code.
- User denial: preserve the existing authorization-denied flash behavior.
- Token endpoint non-2xx or transport failure: show a sanitized failure and log
  only status/reason, never request authorization or token values.
- Missing access token, refresh token, or valid expiry in a successful exchange:
  reject the connection without replacing any usable credential.
- Refresh failure: retain the previously encrypted token blob; once it is no
  longer usable, upstream calls continue returning the existing
  credential-unavailable result without exposing provider details.
- Catalog rejection or unapproved client: surface Figma's authorization/token
  failure; do not fall back to a personal access token or another client's OAuth
  identity.
- State is one-time and PKCE uses a cryptographically random verifier with S256.
- Access tokens, refresh tokens, and any returned ID token remain encrypted at
  rest and are never placed in metadata.
- Deleting the credential removes Backplane's local encrypted tokens only; this
  version does not claim to revoke the Figma grant remotely.

## Testing

Focused tests cover:

- Credentials UI renders **Connect Figma MCP**, defaults to `figma-mcp`, labels
  the credential, and recognizes it as a managed OAuth type.
- Starting authorization includes the exact Figma endpoint, client ID, callback,
  scope, state, PKCE, and resource parameters.
- Missing client configuration produces an admin error without redirecting.
- Callback exchange sends form data and HTTP Basic client authentication, then
  stores an encrypted `kind = "upstream"`, `auth_type = "figma_oauth"` row.
- Malformed successful responses and responses without a refresh token are
  rejected without overwriting an existing credential.
- `Credentials.fetch/1` returns a fresh Figma access token and refreshes an
  expired token through the existing locked path.
- Figma refresh sends the correct grant and persists rotated access and refresh
  tokens.
- Reauthorizing the same name invalidates any previously cached access token.
- The refresh worker includes due Figma credentials in its default scan without
  applying the Claude-specific two-hour due window.
- `AuthInjector` consumes the Figma credential through the unchanged Bearer path.
- Anthropic, OpenAI, Google, xAI, API-key, and OAuth2 client-credentials behavior
  remains unchanged through focused regression tests.

Tests run through `devenv shell -- mix test` against the affected test files.
External Figma authorization is not exercised in automated tests; local HTTP
test servers verify request shape and token handling. Live-connect acceptance
remains pending until Figma approves Backplane's MCP client registration.

## Documentation

The deployment guide documents `FIGMA_MCP_CLIENT_ID`,
`FIGMA_MCP_CLIENT_SECRET`, the required callback URL, the Figma catalog approval
prerequisite, and the upstream's Bearer/credential settings.

## Non-goals

- Per-caller or per-client Figma identities.
- A generic OAuth discovery engine for all MCP upstreams.
- Dynamic client registration with Figma.
- Reusing a Figma REST personal access token or REST API scopes for MCP.
- Automatically creating or modifying an MCP upstream when the credential is
  authorized.
- Account-profile discovery or account-detail UI.
- Remote token revocation on local credential deletion.
- Changing inbound Backplane authentication, authorization, or tool scopes.

## Success criteria

- With approved Figma client credentials configured, an administrator can
  authorize one Figma account from System → Credentials.
- The resulting encrypted row is an upstream `figma_oauth` credential.
- A Figma upstream configured for Bearer authentication can list and call tools
  using that credential for every Backplane caller.
- Expired access tokens refresh and rotated refresh tokens persist without
  exposing secrets.
- Existing credential and upstream authentication behavior remains compatible.

## References

- [Figma remote MCP setup](https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/)
- [Figma MCP Catalog](https://www.figma.com/mcp-catalog/)
- [Figma OAuth protected-resource metadata](https://mcp.figma.com/.well-known/oauth-protected-resource)
- [Figma OAuth authorization-server metadata](https://api.figma.com/.well-known/oauth-authorization-server)
- [MCP authorization specification](https://modelcontextprotocol.io/specification/draft/basic/authorization)
