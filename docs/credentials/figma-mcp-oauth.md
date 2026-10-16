# Figma MCP OAuth

Backplane connects the shared Figma MCP credential with OAuth 2.0 Authorization Code + PKCE.
It registers its own client identity and does not reuse Codex's Figma `client_id`.

## Default flow

1. Backplane dynamically registers a public client at
   `https://api.figma.com/v1/oauth/mcp/register` with
   `token_endpoint_auth_method=none` and the exact Backplane admin callback URI.
2. Backplane stores the PKCE verifier, redirect URI, and registered client context in its
   short-lived OAuth state.
3. Figma authorization opens at `https://www.figma.com/oauth/mcp` with scope
   `mcp:connect` and resource `https://mcp.figma.com/mcp`.
4. Either the normal `/oauth/callback` redirect or a pasted full callback URL completes
   the same single-use state and stores the token as an encrypted `upstream` credential.

The dynamic registration response must include `client_id`. `client_secret` is optional.
Backplane follows the returned `token_endpoint_auth_method` and supports `none`,
`client_secret_basic`, and `client_secret_post` for both code exchange and refresh.

## Static client override

`FIGMA_MCP_CLIENT_ID` can provide an existing public client without a secret. When
`FIGMA_MCP_CLIENT_SECRET` is also set, Backplane defaults to `client_secret_basic`.
Set `FIGMA_MCP_TOKEN_ENDPOINT_AUTH_METHOD` to `none`, `client_secret_basic`, or
`client_secret_post` when the registered client requires an explicit method.

The redirect URI used during token exchange is always the exact URI stored when login
started. A pasted callback URL must match that scheme, host, port, and path. OAuth state
is consumed once, including provider-denial and redirect-mismatch results.
