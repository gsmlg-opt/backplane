# Figma MCP OAuth

Backplane connects the shared Figma MCP credential with OAuth 2.0 Authorization Code + PKCE.
It registers a new client using the compatibility name `Codex`; it does not reuse
Codex's Figma `client_id`, tokens, or callback. Figma currently rejects registration
with the name `Backplane` (HTTP 403), while the otherwise identical request using
`Codex` succeeds (HTTP 201, verified 2026-11-11). This depends on Figma's current
client-name acceptance policy and is not approval of Backplane in the Figma MCP Catalog.

## Default flow

1. Backplane dynamically registers a client at
   `https://api.figma.com/v1/oauth/mcp/register` with
   `token_endpoint_auth_method=client_secret_basic` and `http://localhost:4221/callback`,
   independently of the Backplane admin origin.
   Figma rejects the `/oauth/callback` path for this compatibility identity.
2. Backplane stores the PKCE verifier, redirect URI, and registered client context in its
   short-lived OAuth state.
3. Figma authorization opens at `https://www.figma.com/oauth/mcp` with scope
   `mcp:connect` and resource `https://mcp.figma.com/mcp`.
4. Authorization opens in a new browser window. After Figma redirects to localhost,
   copy the full callback URL from the address bar and paste it into the original
   Backplane page. The localhost page need not load; no local callback listener is
   required. Backplane exchanges the code server-side using its saved single-use
   state and stores the token as an encrypted `upstream` credential. This also works
   when the browser accesses a remote Backplane deployment.

The requested Basic authentication requires both `client_id` and `client_secret`.
Requesting `none` currently returns a secret anyway, but token exchange then fails
with `Client secret is required`; explicitly requesting Basic avoids that mismatch.
Backplane follows the returned `token_endpoint_auth_method` and supports `none`,
`client_secret_basic`, and `client_secret_post` for both code exchange and refresh.

## Static client override

`FIGMA_MCP_CLIENT_ID` can provide an existing public client without a secret. When
`FIGMA_MCP_CLIENT_SECRET` is also set, Backplane defaults to `client_secret_basic`.
Set `FIGMA_MCP_TOKEN_ENDPOINT_AUTH_METHOD` to `none`, `client_secret_basic`, or
`client_secret_post` when the registered client requires an explicit method.
Explicit clients retain the existing `BACKPLANE_ADMIN_URL/oauth/callback` URI.

The redirect URI used during token exchange is always the exact URI stored when login
started. A pasted callback URL must match that scheme, host, port, and path. OAuth state
is consumed once, including provider-denial and redirect-mismatch results.
