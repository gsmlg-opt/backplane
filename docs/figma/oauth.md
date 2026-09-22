# Figma MCP OAuth

Backplane connects to Figma's remote MCP server at
`https://mcp.figma.com/mcp`. The OAuth grant identifies one shared Figma
account for the Backplane credential. Callers routed through that credential
reuse the account; they do not receive separate Figma identities.

## Endpoints and scope

Backplane uses the OAuth metadata currently published by Figma:

| Purpose | URL |
| --- | --- |
| MCP resource | `https://mcp.figma.com/mcp` |
| Authorization | `https://www.figma.com/oauth/mcp` |
| Token | `https://api.figma.com/v1/oauth/token` |
| Dynamic registration | `https://api.figma.com/v1/oauth/mcp/register` |
| Scope | `mcp:connect` |

The authorization code flow uses PKCE with `S256`, a state value, and the MCP
resource parameter. The token exchange uses HTTP Basic authentication with the
Figma OAuth client ID and secret.

## How the Backplane flow works

1. An administrator opens **System → Credentials → Connect Figma MCP**.
2. Backplane builds the callback URL from `BACKPLANE_ADMIN_URL`:
   `BACKPLANE_ADMIN_URL/oauth/callback`.
3. If both explicit client variables are present, Backplane uses that client.
   If both are absent, it attempts Figma Dynamic Client Registration with this
   callback URL and the `mcp:connect` scope.
4. Backplane opens Figma's authorization page with the client ID, callback,
   PKCE challenge, state, scope, and resource.
5. Figma redirects to the callback. Backplane exchanges the authorization code,
   encrypts the access token, refresh token, and any dynamically registered
   client material, then stores the credential as an upstream OAuth credential.
6. The MCP upstream sends the resulting access token as a Bearer token.
   Refreshes continue using the same client identity that obtained the token.

The client secret is never stored in credential metadata or rendered in the
admin UI. Dynamically registered credentials are kept inside the encrypted
credential value so a later refresh does not silently switch clients.

## Obtaining `FIGMA_MCP_CLIENT_ID` and `FIGMA_MCP_CLIENT_SECRET`

Figma currently restricts the remote MCP server to clients approved through the
[Figma MCP Catalog](https://www.figma.com/mcp-catalog/). Backplane cannot reuse
Codex's client ID, secret, callback, or OAuth session. Apply for Backplane as
its own MCP client:

1. Prepare a public HTTPS admin origin for Backplane. For example:
   `https://admin.example.com`.
2. Use the exact redirect URI
   `https://admin.example.com/oauth/callback`. The scheme, host, path, and
   trailing slash must match the registered value exactly.
3. Submit Backplane through the Figma MCP Catalog or the current Figma MCP
   developer approval process. Include the MCP server URL, the redirect URI,
   and the requested `mcp:connect` scope.
4. After Figma approves the client, obtain the issued OAuth **client ID** and
   **client secret** from the Figma developer contact or client registration
   workflow. The exact approval screens and delivery process are controlled by
   Figma and may change.
5. Store both values as deployment secrets:

   ```sh
   FIGMA_MCP_CLIENT_ID=<Figma-issued-client-id>
   FIGMA_MCP_CLIENT_SECRET=<Figma-issued-client-secret>
   BACKPLANE_ADMIN_URL=https://admin.example.com
   ```

6. Restart Backplane and select **Connect Figma MCP** again.

Set both client variables or set neither. A partial pair is rejected. The
explicit pair is the recommended production configuration because it makes the
approved Figma client identity and callback registration stable across
restarts.

## Automatic registration and HTTP 403

Backplane supports automatic registration for environments where Figma permits
Dynamic Client Registration. This does not bypass Figma's MCP Catalog policy.
If registration returns HTTP 403, Figma is refusing the Backplane client as an
unapproved client. Apply for approval and configure the issued client ID and
secret instead.

Other common causes are:

- `BACKPLANE_ADMIN_URL` is missing, points to localhost, or is not reachable
  from the browser.
- The callback URI registered with Figma differs from
  `BACKPLANE_ADMIN_URL/oauth/callback`.
- Only one of `FIGMA_MCP_CLIENT_ID` and `FIGMA_MCP_CLIENT_SECRET` is set.
- The deployment is using a client issued for a different callback or Figma
  environment.

Do not copy Codex credentials, use a personal access token as an OAuth client
secret, or commit either Backplane secret to the repository.

## References

- [Figma MCP server](https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/)
- [Figma MCP Catalog](https://www.figma.com/mcp-catalog/)
- [Figma OAuth authorization-server metadata](https://mcp.figma.com/.well-known/oauth-authorization-server)
- [Backplane deployment guide](../deploy/backplane.md#figma-remote-mcp-oauth)
