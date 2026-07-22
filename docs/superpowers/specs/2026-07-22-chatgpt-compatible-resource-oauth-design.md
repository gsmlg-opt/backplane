# ChatGPT-Compatible OAuth Resources Design

**Status:** Written specification pending final user review

**Date:** 2026-07-22
**Scope:** OAuth discovery and resource-server authorization for `/mcp` and `/v1`

## Summary

Backplane will expose `/mcp` and `/v1` as two distinct OAuth protected resources behind its existing authorization server. Each resource will publish RFC 9728 metadata, issue RFC 6750 bearer challenges, and accept Backplane OAuth access tokens whose audience exactly matches that resource. Because RFC 9728 binds challenge-driven metadata to the exact challenged URL, `/v1` is the canonical discovery probe for the otherwise nested `/v1/*` API.

OAuth is additive. Existing Backplane client tokens and legacy bearer tokens continue to work, and local open mode remains available when a surface has no authentication configured. MCP protocol framing, LLM proxy routing, and outbound provider-credential injection remain unchanged; authentication failures gain the status and challenge behavior defined below.

ChatGPT connects through its documented flow:

1. Call `/mcp` without credentials.
2. Receive `401` with `WWW-Authenticate` pointing to protected-resource metadata.
3. Discover Backplane's authorization server.
4. Run authorization code with PKCE S256 and a resource indicator.
5. Exchange the code for a resource-bound access token.
6. Retry `/mcp` with that token.

The same resource-bound issuance protocol applies independently to `/v1` clients. They discover it from the deterministic metadata URL or by probing `GET /v1` before calling a nested API operation.

## Motivation

Backplane currently has two separate authentication systems:

- `/mcp` and `/v1` share `Backplane.Transport.AuthPlug`, which accepts database-backed Backplane client tokens, legacy configured tokens, or open mode.
- Backplane Auth provides an OAuth/OIDC authorization server with authorization code, PKCE, refresh tokens, JWT access tokens, JWKS, userinfo, introspection, and revocation.

The OAuth server is not currently connected to either resource surface. Its access tokens use the OAuth client ID as the audience, `/mcp` and `/v1` do not verify them, and failures do not advertise protected-resource metadata.

The result is that ChatGPT cannot discover or complete OAuth for Backplane's MCP endpoint, and API clients cannot obtain a token explicitly bound to `/v1`.

## Goals

- Make ChatGPT's documented OAuth discovery flow work end to end for `/mcp`.
- Expose `/v1` as a separate OAuth protected resource using the same authorization server.
- Prevent a token for one resource from being replayed against the other.
- Reuse the existing OAuth client, user, RBAC, PKCE, JWT, refresh, revocation, and admin foundations.
- Reuse the existing MCP tool-scope vocabulary.
- Add narrowly scoped LLM API permissions.
- Preserve existing Backplane client tokens, legacy tokens, and intentional open mode.
- Preserve identity-only OIDC clients that do not request a resource.
- Keep inbound credentials separate from outbound LLM provider credentials.
- Document predefined-client setup for ChatGPT and ordinary API clients.

## Non-goals

- `/.well-known/mcp` or any private MCP server-card convention.
- A root `/.well-known/oauth-protected-resource` document that ambiguously describes both resources.
- Dynamic Client Registration (DCR).
- Client ID Metadata Documents (CIMD).
- Migrating production `/mcp` to `Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug`.
- Replacing existing Backplane client tokens or legacy bearer tokens.
- Adding inbound `x-api-key` authentication to `/v1`.
- Applying OAuth to `/skills`, `/host-agent`, the admin endpoint, or other public routes.
- Multi-audience access tokens.
- Changing LLM provider credential storage or injection.
- Adding new `/v1` restrictions to existing client or legacy tokens.

## Standards and compatibility targets

- RFC 6750: bearer token challenges and error responses.
- RFC 7636: authorization code flow with PKCE S256.
- RFC 8414: authorization-server metadata.
- RFC 8707: OAuth resource indicators.
- RFC 9728: OAuth protected-resource metadata.
- MCP authorization specification 2025-11-25.
- OpenAI Apps SDK authentication behavior for ChatGPT apps.

References:

- <https://developers.openai.com/apps-sdk/build/auth>
- <https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization>
- <https://www.rfc-editor.org/rfc/rfc6750.html>
- <https://www.rfc-editor.org/rfc/rfc8414.html>
- <https://www.rfc-editor.org/rfc/rfc8707.html>
- <https://www.rfc-editor.org/rfc/rfc9728.html>

## Resource model

Backplane has one authorization-server issuer and two protected resources:

| Resource key | Canonical resource identifier | Protected-resource metadata |
|---|---|---|
| `mcp` | `<api-origin>/mcp` | `<api-origin>/.well-known/oauth-protected-resource/mcp` |
| `v1` | `<api-origin>/v1` | `<api-origin>/.well-known/oauth-protected-resource/v1` |

All absolute URLs are built through `Backplane.WebOrigins`; they are never assembled from request headers. Resource keys are stored in the database so a deployment hostname change does not invalidate configuration. The canonical absolute URI is resolved when metadata is rendered, an authorization request is validated, or a token is issued.

One access token has exactly one resource audience. A client that uses both surfaces completes two authorization flows and receives two tokens.

Standards-compliant resource OAuth requires an HTTPS public API origin. Enabling an OAuth resource assignment is rejected in production when `Backplane.WebOrigins.api_base_url/0` is not HTTPS. An explicit development or test override may permit local HTTP probes, but that mode is not advertised as ChatGPT-compatible and must never be enabled in production.

## Discovery endpoints

The public API router exposes three unauthenticated metadata routes:

```text
GET /.well-known/oauth-protected-resource/mcp
GET /.well-known/oauth-protected-resource/v1
GET /.well-known/oauth-authorization-server
```

The existing route remains:

```text
GET /.well-known/openid-configuration
```

The RFC 8414 and OIDC documents use one shared builder so endpoints, issuer, grant types, token authentication methods, and PKCE methods cannot drift.

The MCP protected-resource document has this shape:

```json
{
  "resource": "https://backplane.example.com/mcp",
  "authorization_servers": ["https://backplane.example.com"],
  "bearer_methods_supported": ["header"],
  "resource_name": "Backplane MCP Hub",
  "resource_documentation": "https://backplane.example.com/docs/mcp"
}
```

The `/v1` document has this shape:

```json
{
  "resource": "https://backplane.example.com/v1",
  "authorization_servers": ["https://backplane.example.com"],
  "scopes_supported": ["llm::models", "llm::invoke"],
  "bearer_methods_supported": ["header"],
  "resource_name": "Backplane LLM API",
  "resource_documentation": "https://backplane.example.com/docs/llm"
}
```

MCP metadata deliberately omits `scopes_supported`, and the initial `/mcp` challenge deliberately omits `scope`. Under the MCP scope-selection rules, the client then omits `scope` from its first authorization request. Backplane selects the predefined client's default MCP scopes as described below. This avoids making a general-purpose client request every dynamically registered tool scope and avoids adding a second scope vocabulary.

The `/v1` document advertises the two least-privilege operation scopes. The convenience wildcards `llm::*` and `*` remain accepted when an administrator explicitly assigns them to both the client and user; they are not advertised. An omitted-scope default may include a wildcard only because those two assignments make it part of the configured intersection.

Both the RFC 8414 and OIDC authorization-server documents deliberately omit `scopes_supported`, preserving current behavior and preventing a shared document from causing MCP and LLM scopes to bleed into one another. Resource-specific scopes are advertised only by the applicable protected-resource document. Both authorization-server documents include RFC 9728's `protected_resources` array with the canonical `/mcp` and `/v1` identifiers.

The authorization-server metadata does not advertise `registration_endpoint` or `client_id_metadata_document_supported` in this release.

### Canonical `/v1` discovery probe

Backplane adds `GET /v1` as a non-proxy resource descriptor. In open mode or with a valid credential it returns `200 application/json` with the canonical resource URI and documentation URL. In protected mode without a credential it returns the `/v1` protected-resource challenge.

Only a request whose URL is exactly the canonical resource URI may receive a `resource_metadata` link:

- Requests to `/mcp` use the exact MCP resource URI and include its metadata link in `401` and single-request `403` challenges.
- `GET /v1` includes the `/v1` metadata link.
- Nested requests such as `/v1/models` and `/v1/chat/completions` return ordinary RFC 6750 challenges with `error` and, when applicable, `scope`, but omit `resource_metadata`.
- A request with a noncanonical query component likewise omits `resource_metadata`.

This satisfies RFC 9728 section 3.3 while retaining one `/v1` audience. API clients may also fetch `/.well-known/oauth-protected-resource/v1` directly because its location is deterministic.

## Client configuration and activation

Existing Boruta OAuth clients gain an allowlist stored in their metadata:

```json
{
  "backplane_resources": ["mcp", "v1"]
}
```

The Auth OAuth Clients admin create and edit forms expose `MCP (/mcp)` and `LLM API (/v1)` checkboxes. Existing clients have an empty resource allowlist and remain identity-only. `Backplane.Auth.OAuth.update_client_resources/2` merges this allowlist into existing metadata, preserving keys such as `disabled`, and updates through `Boruta.Ecto.Admin.update_client/2` so Boruta's client cache is invalidated.

For ChatGPT, an administrator:

1. Reads the exact callback URI from the ChatGPT app-management page.
2. Creates a confidential Backplane OAuth client with PKCE enabled.
3. Registers that exact callback URI.
4. Enables the `mcp` resource, or both resources when the same app also uses `/v1`.
5. Assigns the client scopes and grants matching scopes to the authenticating users through RBAC.
6. Copies the client ID and secret into ChatGPT's OAuth configuration.
7. Configures the MCP server URL as `<api-origin>/mcp`.

A surface is protected when any of these conditions is true:

- At least one existing Backplane client-token row exists. This preserves current client mode.
- A legacy bearer token is configured. This preserves current legacy mode.
- At least one enabled OAuth client allows that resource key.

If none applies, that surface remains open. Adding the first OAuth client for a resource therefore activates authentication for that resource; removing the final resource assignment returns it to the remaining PAT, legacy, or open-mode policy.

## Authorization request validation

Resource-enabled flows use one exact `resource` parameter on the authorization request and authorization-code token request. A refresh request may omit `resource`, in which case Backplane infers the refresh token's original single resource; if supplied, it must be the same exact value.

The authorization endpoint always validates:

- The OAuth client exists and is enabled.
- The redirect URI exactly matches a registered URI.
- `response_type=code`.
- PKCE uses S256 with a non-empty challenge.
- At most one resource indicator is present.

When `resource` is present, it additionally validates:

- The resource URI exactly equals the current canonical `/mcp` or `/v1` identifier.
- The client's `backplane_resources` allowlist contains the corresponding resource key.
- Requested scopes are allowed for the client, the user, and the selected resource.

Duplicate detection occurs before normal parameter maps can collapse repeated keys. Authorization validation inspects `conn.query_string`; the API endpoint configures a duplicate-preserving `Plug.Parsers` body reader for form-encoded `/oauth/token` requests and stores the raw form pairs in `conn.private` for token validation. More than one `resource` pair is rejected even when the values are identical.

Resource-specific scope rules are:

- `mcp`: `*`, tool scopes, plus optional OIDC identity scopes.
- `v1`: `llm::models`, `llm::invoke`, `llm::*`, `*`, plus optional OIDC identity scopes.
- Identity scopes do not grant resource operations.
- Every `system`-namespaced scope whose name begins with `system::` is rejected for either protected resource, including exact names such as `system::admin` and wildcard names such as `system::*`.

For this design, OIDC identity scopes are `openid`, `profile`, and `email`. Existing custom scopes outside the MCP and LLM resource vocabularies remain non-resource scopes and retain their current client-ID audience behavior.

Scope meaning is resource-relative. With the MCP resource selected, any otherwise-valid `prefix::*` or `prefix::tool` value—including an existing upstream whose prefix is `llm`—is an MCP tool scope. With `/v1` selected, only `llm::models`, `llm::invoke`, and `llm::*` have LLM API meaning. Exact audience validation prevents either interpretation from crossing resources.

If `resource` is present and `scope` is absent or blank, Backplane selects the default resource scope set by intersecting the client's configured scopes with the authenticating user's current RBAC grants, then retaining only scopes valid for that resource and excluding identity, other-resource, and `system::...` scopes. An empty intersection fails with `invalid_scope`. Before invoking Boruta, Backplane writes that effective set into the normalized authorization parameters so the authorization grant, code, token, and token response all carry the same explicit scope.

When `scope` is supplied, existing strict behavior remains: every requested scope must be authorized for the client and user and valid for the selected resource. Backplane does not silently expand an explicit request.

For a client with at least one `backplane_resources` assignment, any request containing a resource-operation scope—an MCP tool scope, an `llm::...` scope, or global `*`—must include `resource`. A request with no resource may continue using existing non-resource OAuth/OIDC scopes and receives the existing client-ID audience. Clients with an empty resource allowlist retain all existing no-resource scope behavior, including scopes that happen to resemble the new vocabularies. A present resource always makes the flow resource-bound, even if the explicitly requested scopes happen to be identity-only.

The existing login-resume flow already stores the authorization parameters in the browser session, so `resource` survives authentication without a second state mechanism.

Identity-only OIDC and other existing non-resource flows may omit `resource`. They retain existing behavior and cannot produce a token accepted by `/mcp` or `/v1`.

## Resource persistence

Boruta 2.3 does not model RFC 8707 resource indicators in its token schema. Backplane will not patch or fork the dependency. Instead, it adds a local one-to-one mapping table:

```text
oauth_token_resources
  id                 uuid primary key
  oauth_token_id     uuid not null references oauth_tokens(id) on delete cascade
  resource           text not null check resource in ('mcp', 'v1')
  inserted_at        utc datetime
  updated_at         utc datetime
```

`oauth_token_id` has a unique index. The mapping attaches to both authorization-code rows and access-token rows in Boruta's shared `oauth_tokens` table.

Boruta callbacks do not expose Ecto row IDs. Each callback therefore locates the just-created row by its unique response/request tuple—token type, client ID, and code or token value—before creating the mapping.

The lifecycle is:

1. `authorize_success` locates and binds the newly created authorization-code row to the validated resource before redirecting.
2. Before code exchange, the token controller loads the code binding and requires the token request's `resource` to match.
3. `Backplane.Auth.AccessTokenGenerator` resolves the resource from `previous_code` and uses its canonical URI as the JWT audience.
4. `token_success` locates and binds the newly created access-token row to the same resource before returning JSON.
5. Before refresh, the token controller resolves the stored access-token binding through the presented refresh token. An omitted `resource` inherits that binding; a supplied value must match it.
6. The generator resolves refresh issuance from `previous_token`, preserving the audience.
7. The new access-token row receives the inherited binding.

Issuance is fail-closed using compensating cleanup rather than a cross-callback transaction. Boruta creates and caches its row—and may consume the prior code or refresh token—before invoking Backplane's callback. If mapping fails, Backplane makes a best-effort revocation of the newly created row, converts that Ecto row to the `Boruta.Oauth.Token` shape required by `TokenStore.invalidate/1`, invalidates the cache entry, and fails before returning the redirect or token response. Even if cleanup itself fails, an orphaned unmapped row was never disclosed to the client and is rejected by resource-server validation. A resource-enabled flow never silently falls back to a client-ID audience.

For an identity-only flow, no mapping is created and access-token audience behavior remains the OAuth client ID. ID-token audience always remains the OAuth client ID.

## Access-token claims and validation

A resource-enabled access token contains:

```json
{
  "iss": "https://backplane.example.com",
  "sub": "user-id",
  "aud": "https://backplane.example.com/mcp",
  "client_id": "oauth-client-id",
  "scope": "github::* skills::list",
  "iat": 1784700000,
  "exp": 1784703600,
  "jti": "token-id"
}
```

Resource-server validation checks all of the following:

- JWT signature against Backplane's active and retained public keys.
- Exact issuer.
- Integer expiry in the future.
- `nbf`, when present, is not in the future.
- Persisted access-token row exists and is not revoked.
- Resource mapping exists and matches the expected resource key.
- JWT audience exactly equals the current canonical resource URI.
- JWT `client_id` matches the persisted OAuth token's client.
- OAuth client is enabled and allows the resource.
- Resource owner exists and is active.
- Granted scopes come from the token, not from current role expansion.

Revocation and client/user disablement therefore take effect immediately even though the access token is a signed JWT.

For a mapped access token, RFC 7662 introspection adds a top-level string field `aud` whose value is the same canonical resource URI used in the JWT. Identity-only introspection retains its current response shape and omits `aud`.

## Shared resource authentication layer

The current MCP and LLM routers retain their routing and protocol framing but use one resource-aware authentication plug from `backplane_auth`. The only intentional transport-status change is the single-request MCP insufficient-scope response defined below. The MCP and LLM apps add an umbrella dependency on `backplane_auth`; `backplane_auth` adds a direct `:plug` dependency for the shared plug. This does not create a cycle because `backplane_auth` already depends only on `backplane_system` and lower-level libraries.

The plug is configured with `resource: :mcp` or `resource: :v1`. It normalizes successful authentication into an assign containing:

```elixir
%{
  kind: :oauth | :client_token | :legacy | :open,
  subject: user_id_or_nil,
  client_id: client_id_or_nil,
  resource: :mcp | :v1,
  scopes: ["..."]
}
```

For compatibility, OAuth and opaque credentials are classified without weakening either path:

- A bearer token with a valid Backplane JWT signature is handled exclusively as OAuth. Expiry, revocation, issuer, audience, or scope failure cannot fall through to another credential type.
- A token without a valid Backplane JWT signature is checked for an exact database-backed client-token match.
- It is then checked for an exact configured legacy-token match.
- A supplied credential that fails every configured method is rejected; it never falls through to open mode.
- A missing credential passes as `:open` only when the selected resource has no configured authentication method.

For `/mcp`, OAuth scopes populate the existing `conn.assigns[:tool_scopes]`; tool listing and tool calls continue using current `*`, `prefix::*`, and `prefix::tool` matching. Existing client and legacy tokens retain their current scope behavior.

For `/v1`, OAuth requests are authorized by route:

| Request | Required OAuth scope |
|---|---|
| `GET /v1` resource descriptor | no operation scope; authentication only when protected |
| `GET /v1/models` | `llm::models` or `llm::*` |
| Any `POST /v1/*` | `llm::invoke` or `llm::*` |

The global `*` scope also grants either operation. Existing client tokens, legacy tokens, and open mode retain full `/v1` access because adding LLM scope checks to them would be a breaking change.

For MCP OAuth requests, `tools/list` continues filtering its result. A single out-of-scope `tools/call` keeps its JSON-RPC error body but uses HTTP 403 and adds the insufficient-scope challenge below. Any JSON-RPC batch retains HTTP 200 with per-item JSON-RPC authorization errors because a batch can contain different outcomes and required scopes. Existing client and legacy tokens retain their current JSON-RPC denial behavior.

After inbound authorization, `/v1` continues deleting inbound `authorization` and `x-api-key` headers before Relayixir forwards the request. Provider credentials are then injected from Backplane's credential vault exactly as they are today.

## Challenges and errors

Protected resources use RFC 6750 responses.

Challenge advertisement distinguishes authentication requirement from OAuth availability. PAT rows and a legacy token can require authentication without enabling a usable OAuth client. A canonical response includes `resource_metadata` only when at least one enabled OAuth client allows that resource; otherwise the existing PAT/legacy bearer response is preserved. Nested `/v1/*` responses always omit it. This prevents Backplane from advertising an OAuth path that no configured client can complete.

Missing credential:

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://backplane.example.com/.well-known/oauth-protected-resource/mcp"
```

The initial MCP challenge has no `scope`. The equivalent challenge from canonical `GET /v1` points to `/.well-known/oauth-protected-resource/v1`. Nested `/v1/*` challenges omit `resource_metadata`; for example, `GET /v1/models` may return `WWW-Authenticate: Bearer scope="llm::models"`.

Invalid, expired, revoked, wrong-issuer, or wrong-audience credential:

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer error="invalid_token", resource_metadata="https://backplane.example.com/.well-known/oauth-protected-resource/mcp"
```

Valid OAuth token without permission on a nested `/v1` operation:

```http
HTTP/1.1 403 Forbidden
WWW-Authenticate: Bearer error="insufficient_scope", scope="llm::invoke"
```

For a resource-enabled client, missing resource indicators fail with `invalid_target` only when the request asks for protected-resource scopes. Repeated, unsupported, client-disallowed, or grant-mismatched indicators also fail with `invalid_target`. A refresh request without `resource` inherits its original binding and is valid; a supplied mismatched or repeated value fails. Before the redirect URI is trusted, the authorization endpoint returns a direct HTTP 400 response. After client and redirect validation, it returns the error through the registered redirect URI. The token endpoint returns a JSON HTTP 400 response. A wrong-resource bearer token fails as `invalid_token`; it does not fall back to PAT, legacy, or open mode.

For a single MCP tool denial, the `403` challenge includes the MCP `resource_metadata` URL and the minimum exact scope (`prefix::tool`) that would permit the operation. Batch denials stay in their individual JSON-RPC error objects and do not claim one batch-wide required scope.

OAuth HTTP authentication-error bodies are JSON and identify the OAuth error without exposing validation internals. Existing PAT/legacy error bodies remain compatible. The single-request MCP `403` deliberately retains its existing JSON-RPC scope-error body while the header carries the RFC 6750 error. Authentication logging may include resource key, credential kind, principal ID, and normalized failure reason. It never includes authorization codes, access tokens, refresh tokens, client secrets, or credential hashes.

## Documentation

No `/.well-known/mcp` route is created. Human setup instructions stay on ordinary documentation routes:

- `/docs/mcp`: MCP endpoint, discovery sequence, scopes, ChatGPT setup, and curl probes.
- `/docs/llm`: `/v1` resource, LLM scopes, OAuth API-client example, and legacy-token compatibility.
- `/docs/agents`: complete ChatGPT, Claude, and Codex configuration examples.
- `/docs/authentication`: protected resources, predefined OAuth clients, PKCE, refresh, revocation, and troubleshooting.

All examples derive URLs from `Backplane.WebOrigins`. Examples use placeholders and never render stored secrets.

## Verification strategy

### Metadata tests

- Both RFC 9728 routes are public and return `200 application/json`.
- Each document has the exact configured resource identifier.
- Each has a non-empty `authorization_servers` list and header bearer method.
- MCP metadata omits `scopes_supported`; `/v1` advertises only `llm::models` and `llm::invoke`.
- RFC 8414 and OIDC metadata use one issuer and matching endpoint URLs.
- RFC 8414 and OIDC metadata deliberately omit `scopes_supported`.
- RFC 8414 and OIDC metadata advertise both exact canonical resource identifiers in `protected_resources`.
- PKCE advertises only S256.
- DCR and CIMD fields are absent.
- Production resource activation rejects a non-HTTPS API origin; the explicit dev/test override is isolated from production.
- OAuth-enabled canonical `/mcp` and `/v1` challenges contain the matching metadata link, while nested `/v1/*` and query-bearing noncanonical requests omit it.
- PAT/legacy-only protection does not advertise `resource_metadata`; adding the first enabled OAuth client for the resource does.

### OAuth flow tests

- A resource-enabled client can authorize only an allowed exact resource.
- Protected-resource scopes without `resource`, repeated resources, unsupported resources, and client-disallowed resources fail.
- Existing clients with an empty resource allowlist retain their no-resource scope behavior and client-ID audience.
- Raw query and form tests prove repeated `resource` values cannot be hidden by parameter-map collapse.
- S256 remains mandatory.
- Code exchange requires the same resource used at authorization.
- Access-token `aud` equals the canonical resource and `client_id` remains separate.
- Refresh may omit `resource` and then inherits the original resource.
- Refresh with the same explicit resource succeeds and preserves it.
- Cross-resource refresh is rejected.
- An omitted initial scope defaults to the client/user intersection for that resource, and an empty intersection fails.
- Explicit scopes remain strict; wildcards are accepted only when assigned to both client and user, whether explicitly requested or selected by the omitted-scope default.
- Exact and wildcard `system::...` scopes are rejected for both resources.
- Identity-only OIDC authorization, token, userinfo, introspection, and revoke flows remain unchanged.
- Introspection returns `aud` equal to the canonical resource for resource-bound access tokens.
- Identity-only introspection retains its current fields and omits `aud`.
- Wrong issuer, invalid signature, expiry, future `nbf`, missing mapping, and disabled client or user each reject the token.
- Mapping persistence failure revokes the orphaned row, invalidates its cache entry, and returns no usable code or token.

### `/mcp` end-to-end tests

- Missing credentials in OAuth-enabled protected mode receive the MCP metadata challenge.
- A valid MCP-audience token initializes a session and lists only allowed tools.
- A single disallowed OAuth tool call returns its JSON-RPC error body with HTTP 403 and an exact insufficient-scope challenge; all batches retain HTTP 200 and per-item JSON-RPC authorization errors.
- A `/v1` token receives `401 invalid_token`.
- Revoked tokens and disabled users or clients fail immediately.

### `/v1` end-to-end tests

- Missing credentials on OAuth-enabled canonical `GET /v1` receive the `/v1` metadata challenge.
- Missing or invalid credentials on nested `/v1/*` receive operation-appropriate challenges without `resource_metadata`.
- `llm::models` permits model listing but not invocation.
- `llm::invoke` permits proxy calls but not model listing unless also granted.
- `llm::*` and `*` permit both.
- An MCP token receives `401 invalid_token`.
- Inbound OAuth, PAT, and legacy credentials are stripped before provider credential injection.

### Compatibility tests

- Existing Backplane client tokens retain MCP tool filtering.
- Existing Backplane client tokens retain full `/v1` access.
- Legacy tokens retain full access.
- A surface with no PAT, legacy token, or resource-enabled OAuth client remains open.
- A supplied invalid credential is rejected even when the surface would otherwise be open.
- With no PAT or legacy token, configuring the first OAuth client for a resource changes a missing-credential request from open success to the correct challenge.
- Existing OAuth clients with no resource metadata remain non-resource clients with their existing audience behavior.
- Creating and editing client resource assignments preserves unrelated metadata, invalidates the client cache, and updates activation immediately.

### Documentation tests

- Configured origins appear in all endpoint examples.
- ChatGPT setup includes the exact MCP endpoint and callback-registration guidance.
- `/v1` examples request the API resource and appropriate LLM scopes.
- `/v1` examples explain direct metadata retrieval and the canonical `GET /v1` discovery probe.
- Pages contain no real access token, refresh token, client secret, or legacy secret.

## Rollout and rollback

The database migration is additive. Existing `oauth_tokens` rows have no mapping and remain identity-only. Existing OAuth clients have no allowed resource keys until an administrator updates them.

Discovery routes may ship before any client is configured because they do not activate protection by themselves. Assigning `mcp` or `v1` to the first enabled OAuth client activates that resource's OAuth challenge while preserving PAT and legacy credentials.

Rollback does not require deleting data. Removing resource assignments from OAuth clients disables OAuth activation for that surface, after which existing PAT, legacy, or open-mode behavior determines access. The resource-mapping table may remain until the release is fully rolled back.

## Success criteria

The feature is complete when:

1. ChatGPT can discover Backplane OAuth from an unauthenticated `/mcp` request, complete predefined-client authorization code with PKCE, and call an allowed MCP tool.
2. An API client can complete the same flow for `/v1` and call only operations permitted by its LLM scopes.
3. MCP and `/v1` tokens are not interchangeable.
4. Refresh, revocation, client disablement, and user disablement preserve resource enforcement.
5. Existing client tokens, legacy tokens, open mode, and identity-only OIDC clients pass their compatibility tests.
6. Inbound credentials never reach an upstream LLM provider.
7. Public documentation explains both setup paths without adding `/.well-known/mcp`.
