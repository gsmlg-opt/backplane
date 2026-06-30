# Backplane OAuth & RBAC — Design Spec (v1)

> Superseded implementation note: this document is an older MCP OAuth/RBAC design sketch.
> The current first release implements Backplane Auth as a standalone OAuth/OIDC provider
> inside the Backplane umbrella, exposed through `backplane_api`, for first-party GSMLG
> applications such as `gsmlg_umbrella` and `gsmlg_app_backend`. Do not treat the endpoint,
> app-boundary, or MCP-specific assumptions below as the current release contract.

Status: design, pre-implementation. Targets MCP Authorization spec **2025-11-25**.

## 1. Goal

Make backplane's `/mcp` endpoint an OAuth-protected MCP server that Claude Code, ChatGPT,
and Codex can connect to using their built-in remote-MCP OAuth support, backed by a real
user-identity and role-based access-control layer. Humans authenticate through an upstream
identity provider; backplane issues its own MCP access tokens; roles govern both which tools
a token may call and who may administer the system.

## 2. Critical framing — this is a third auth system

Backplane already has two authentication mechanisms. The new work is a distinct third, and
the naming collision with the first is the main source of confusion.

| System | Namespace | Direction | Purpose |
|---|---|---|---|
| Provider OAuth | `Backplane.Settings.OAuth*`, `Admin.OAuthCallbackController` | **outbound** | backplane as *client*, obtaining Anthropic/OpenAI/Google upstream tokens |
| Machine auth | `Backplane.Transport.AuthPlug` + `Backplane.Clients` | **inbound, non-interactive** | bearer PATs for agents/MCP, hashed in `clients`, scoped |
| **This work** | `Backplane.Accounts` + boruta | **inbound, interactive** | human SSO + MCP client OAuth + RBAC |

The outbound provider-OAuth machinery is unrelated and must not be reused or extended for
this. The machine-PAT mechanism is retained and coexists (see §9).

Two non-obvious facts fixed the architecture:

1. **Backplane must run its own Authorization Server.** The spec requires access tokens be
   audience-bound to the MCP server (RFC 8707) and forbids clients from sending the server any
   token not issued by that server's own AS. Upstream IdP tokens (Google/GitHub) are not
   audience-scoped to backplane and are non-compliant by construction. The upstream IdP can
   only sit *behind* `/authorize` as the login step.
2. **Dynamic Client Registration is required in practice.** Codex's OAuth login path requires
   DCR with no static-client fallback; Claude Code's pre-configured-client path has open bugs
   and still attempts DCR. DCR (RFC 7591) is the common denominator the three clients reliably
   support. CIMD is the new 2025-11-25 default but client support is still rolling out and is
   not yet sufficient alone.

## 3. Non-goals (v1)

- Multi-tenant isolation. Single trusted organization; users are colleagues, not tenants.
  (This reverses the multi-user non-goal in `host-agent-design.md`, which must be updated.)
- Fine-grained per-tool consent UI. Trusted first-party deployment auto-approves authorized users.
- CIMD client registration. DCR only for v1; CIMD when client support matures.
- OIDC ID tokens to MCP clients. boruta runs OAuth-only; `openid` is not advertised.
- Stateless JWT access tokens. Opaque + introspection is chosen deliberately (see §9, §11).
- Replacing machine PATs. `clients` PATs remain for non-interactive agents.
- Federation across backplane instances; external-IdP-as-AS delegation.

## 4. High-level architecture

```
MCP client (Claude Code / ChatGPT / Codex)
  │  1. GET /mcp  → 401 + WWW-Authenticate(resource_metadata)
  │  2. discover  → /.well-known/oauth-protected-resource → /.well-known/oauth-authorization-server
  │  3. POST /register (DCR)
  │  4. GET /authorize (PKCE S256, resource=<base>/mcp)
  ▼
backplane_api endpoint (same origin as /mcp)
  │  /authorize delegates to boruta, but first requires a logged-in human:
  │    → no session ⇒ run upstream-IdP code flow (Backplane.Accounts.FederatedLogin)
  │    → JIT create/link user, establish browser session, resume authorize
  │  resource-owner = session user; granted scopes = user's RBAC scope set
  │  /token (PKCE verify) → opaque access token bound to resource=<base>/mcp
  ▼
boruta (in backplane_system, on Backplane.Repo) issues + stores token
  ▼
MCP client calls /mcp with Bearer <token>
  ▼
Backplane.Transport.AuthPlug → introspect (in-process, cached) → tool_scopes → existing gating
```

Layering:

- **Domain → `backplane_system`** (lowest app, owns `Backplane.Repo` + `Encryption`):
  `Backplane.Accounts` (users, identities, roles, assignments, scope resolution, federated
  login, boruta resource-owner provider) and boruta's Ecto adapter.
- **MCP compliance → `backplane_mcp`**: PRM document endpoint, 401 challenge, and the
  `AuthPlug` introspection branch.
- **Shared web plugs → root `backplane` app** (`Backplane.Web.*`, beside the existing
  `AdminAuthPlug`): current-user fetch, require-authenticated, require-permission.
- **AS HTTP surface → `backplane_api` endpoint**: the two `.well-known` documents and
  `/authorize` `/token` `/register` controllers (same origin as `/mcp`).
- **Config UI → `backplane_admin`**: providers, roles+scopes, users+assignments, registered
  clients — data-only management over the shared Repo.

## 5. Data model

### 5.1 New backplane-owned tables

| Table | Key fields | Invariant |
|---|---|---|
| `users` | email, name, active | identity, not auth material |
| `user_identities` | provider_id, **subject** (IdP `sub`), raw_claims, → user_id | **unique (provider_id, subject)**; link by stable subject, never email alone |
| `auth_providers` | slug, kind (`oidc`/`oauth2`), issuer or {auth/token/userinfo URLs}, client_id, **client_secret (encrypted)**, scopes, allowed_email_domains, enabled | secret encrypted via `Backplane.Settings.Encryption`; write-only in UI |
| `roles` | slug, name, description, system (bool) | admin-definable at runtime; `system` flag marks built-ins |
| `role_scopes` | role_id, scope (string) | scope strings drawn from the shared vocabulary (§8) |
| `user_roles` | user_id, role_id | a user's effective scopes = union over assigned roles |

### 5.2 boruta-owned tables (via its Ecto adapter, on `Backplane.Repo`)

`oauth_clients`, `oauth_tokens`, `scopes`, `clients_scopes`, `authorization_requests`. No
collision with the existing `clients` table (boruta's is `oauth_clients`). `scopes` is the
canonical scope registry (§8).

### 5.3 Unchanged

`clients` (MCP PATs) and `Backplane.Transport.AuthPlug`'s legacy/PAT paths are untouched.

## 6. Authorization flow (end to end)

1. **Discovery.** Unauthenticated `/mcp` returns `401` with
   `WWW-Authenticate: Bearer …resource_metadata="<base>/.well-known/oauth-protected-resource"`.
   The PRM document lists `<base>/mcp` as the resource and points to the AS metadata. The AS
   metadata (RFC 8414) advertises `authorization_endpoint`, `token_endpoint`,
   `registration_endpoint`, `code_challenge_methods_supported: ["S256"]`, and `scopes_supported`.
2. **Registration (DCR).** Client POSTs to `/register` with its redirect URIs; backplane
   validates them (loopback or `https` only) and returns a `client_id`. Stored in `oauth_clients`.
3. **Authorize.** Client redirects the human to `/authorize` with PKCE (`code_challenge`,
   `S256`), `state`, and `resource=<base>/mcp`. The controller requires a logged-in session:
   - **No session** → start the upstream-IdP code flow (§7). On return, JIT create/link the
     user, establish the browser session, and resume the original authorize request.
   - **Session present** → proceed.
4. **Consent.** Auto-approved for authenticated + authorized users; no consent screen.
5. **Issue.** boruta resolves the resource owner from the session, sets granted scopes to the
   user's RBAC scope set (§8), and issues an authorization code.
6. **Token.** Client exchanges the code at `/token` with `code_verifier` and the same
   `resource`. boruta verifies PKCE and mints an **opaque access token** (with the granted
   scopes and `resource` recorded) plus a rotating refresh token.
7. **Call.** Client sends `Authorization: Bearer <token>` to `/mcp`. `AuthPlug` introspects
   in-process (cached), verifies `resource == <base>/mcp`, maps the token's scopes to
   `conn.assigns[:tool_scopes]`, and the existing scope gating in `mcp_handler` runs unchanged.

## 7. Federated login & identity

The upstream IdP is the only outward dependency and authenticates the human at `/authorize`.

- `Backplane.Accounts.FederatedLogin` runs a standard OIDC/OAuth2 authorization-code flow
  against the configured provider, reusing `Req`, the `Backplane.Settings.OAuthStateStore`
  pattern (state + PKCE + nonce, short TTL, single-use), and `Encryption` for the stored
  client secret. Required claim checks: `iss`, `aud`, `exp`, `nonce`. Generic OIDC first
  (covers Google and most providers); GitHub supported as an OAuth2 variant.
- **JIT provisioning** links on `(provider_id, subject)`, never email. New subjects create a
  `users` row; existing subjects resolve to their user.
- **Bootstrap admin.** An env-listed set of admin emails receives the admin role on first
  login, so the system is administrable before any role assignment exists. The existing
  `AdminAuthPlug` (HTTP Basic) remains as break-glass.
- **Resource-owner provider.** `Backplane.Accounts.ResourceOwners` implements boruta's
  resource-owner behaviour: `get_by` resolves the session user; `authorized_scopes` returns
  the user's RBAC scope set; `claims` exposes identity claims if needed. This is the single
  seam joining federated login → boruta → token issuance.

## 8. RBAC model

The platform already enforces a scope vocabulary at `/mcp`: `conn.assigns[:tool_scopes]`
matched against `*`, `prefix::*`, `prefix::tool` (the `clients.scopes` regex). RBAC reuses it
rather than inventing a parallel permission system.

- A **role** is a named bundle of scope strings (`role_scopes`).
- A **user's effective scopes** = union of the scope strings across assigned roles.
- That set is injected as the boruta token's **granted scopes**; the token's scope claim is
  the single source of truth at `/mcp`. **OAuth-user tokens and machine PATs resolve through
  the same enforcement path.**
- The canonical scope registry is boruta's `scopes` table, mirroring the tool-scope patterns
  plus a small **system-administration** set used only for admin-surface authorization:
  e.g. `system::admin`, `system::providers`, `system::roles`, `system::clients`.
- **Two authorization planes**: tool/resource access (scope-pattern-based, enforced at `/mcp`)
  and system administration (coarse `system::*` permissions, enforced at the admin endpoint via
  `Backplane.Web.RequirePermission`).
- Roles are **admin-definable at runtime**. Built-in seed roles are marked `system` and cannot
  be deleted: `admin` (`*` + all `system::*`), `member` (a default tool-scope set), `viewer`
  (read-only subset).

## 9. Token lifecycle & coexistence

- **Format: opaque + in-process introspection.** boruta stores tokens in `oauth_tokens`;
  validation is a Repo lookup, consistent with how `AuthPlug` already resolves machine PATs.
  Chosen over JWT because it gives **immediate revocation** (revoke the row) — the right
  property for an admin-controlled RBAC system — and needs no JWKS or key rotation.
- **Caching.** Introspection results are cached (reuse `Backplane.Settings.TokenCache`) with a
  short TTL so the hot path stays cheap; revocation invalidates on next cache expiry (bounded).
- **TTLs.** Short access-token lifetime (~30 min) + rotating refresh tokens. Refresh rotation
  detects reuse.
- **`AuthPlug` gains a third branch.** Resolution order: backplane-issued OAuth token
  (introspect → scopes + audience check) → `clients` PAT → legacy shared token. The first
  matching path wins; audience mismatch or revocation yields `401`.
- **PATs retained.** Non-interactive agents (host-agent, CI) that cannot perform an interactive
  redirect keep using `clients` PATs. Two credential types, one enforcement vocabulary.

## 10. MCP compliance layer

boruta covers authorize/token/register/introspect/revoke, PKCE, the `resource` parameter, and
the resource-owner seam. The MCP-specific additions are small and well-bounded:

- **PRM document** at `/.well-known/oauth-protected-resource` (RFC 9728): resource =
  `<base>/mcp` (from `Backplane.WebOrigins.api_base_url()`), `authorization_servers`, and
  `scopes_supported`.
- **401 challenge** on `/mcp`: `WWW-Authenticate: Bearer` with `resource_metadata` pointing to
  the PRM document.
- **S256 enforcement**: reject `plain` PKCE and absent `code_challenge`.
- **RFC 8707 audience binding**: require `resource` on authorize and token; record it on the
  token; verify it at `/mcp`.
- **DCR redirect-URI policy**: accept loopback (`127.0.0.1`/`localhost`, any port — required by
  Claude Code and Codex) and `https`; reject everything else. The real gate is login + RBAC at
  `/authorize`, not the registration endpoint.

## 11. HTTP surface

On the **api endpoint** (same origin as `/mcp`):

| Route | Purpose |
|---|---|
| `GET /.well-known/oauth-protected-resource` | PRM document (RFC 9728) |
| `GET /.well-known/oauth-authorization-server` | AS metadata (RFC 8414) |
| `GET /authorize` | authorization endpoint (login gate + boruta) |
| `POST /token` | token endpoint (PKCE verify, opaque token) |
| `POST /register` | dynamic client registration (RFC 7591) |
| `GET /auth/:provider/callback` | upstream-IdP callback for the login step |
| `POST /logout` | clears the browser session |

`/mcp`, `/v1/*`, `/skills`, `/host-agent/*` are unchanged except for the `AuthPlug` branch and
the 401 challenge on `/mcp`.

## 12. Admin UI (backplane_admin)

Config-only LiveViews, gated on the relevant `system::*` permission, mirroring the existing
`SettingsLive` credential UX:

- **Providers** (`/system/auth/providers`) — CRUD over `auth_providers`; client secret
  write-only (set / rotate / "configured"); OIDC discovery vs manual URL entry.
- **Roles** (`/system/auth/roles`) — CRUD over `roles` + scope assignment from the registry;
  `system` roles read-only.
- **Users** (`/system/auth/users`) — list users + identities, assign/revoke roles, deactivate.
- **Clients** (`/system/auth/clients`) — view DCR-registered OAuth clients; revoke.

## 13. Security invariants & failure modes

- State + PKCE + nonce on the upstream login step are single-use and TTL-bounded (replay defense).
- Identity links on `(provider_id, subject)`, never email — two providers asserting the same
  email must not auto-merge.
- Issued tokens are audience-bound to `<base>/mcp`; `/mcp` rejects any token whose `resource`
  does not match (confused-deputy / token-replay defense).
- Upstream tokens are **never** passed through to `/mcp` or to upstreams — backplane issues its own.
- DCR redirect URIs restricted to loopback + `https`; exact-match validation at authorize time.
- Browser session token rotated on login (fixation defense); logout deletes server state.
- **Bootstrap/lockout**: admin endpoint cannot hard-require OAuth before a provider and admin
  role exist — env-seeded admin emails + Basic-auth break-glass prevent self-lockout.
- Disabled provider blocks new logins; existing tokens unaffected until expiry or explicit revoke.
- Revocation is immediate at the token row, bounded only by the introspection cache TTL.
- Post-login redirects validated as local paths (reuse `Backplane.WebOrigins`) — open-redirect defense.

## 14. Implementation phasing

PR-scoped task documents follow the repo convention
`docs/superpowers/plans/YYYY-MM-DD-<name>.md` with checkbox tasks, per-PR acceptance criteria,
and file anchors. Hard stops between phases.

1. **boruta foundation** — install, Ecto adapter on `Backplane.Repo`, migrations; authorize/token
   smoke test with a stub resource owner. No web surface.
2. **Identity + federated login** — `Backplane.Accounts` context, `users`/`user_identities`,
   `auth_providers`, `FederatedLogin` (OIDC/OAuth2 exchange), `ResourceOwners` provider,
   bootstrap-admin seed.
3. **RBAC** — `roles`/`user_roles`/`role_scopes`, scope registry mirrored into boruta `scopes`,
   role→scope injection into granted scopes, `system::*` vocabulary, seed roles.
4. **MCP compliance** — PRM document + 401 challenge on `/mcp`, S256 enforcement, RFC 8707
   audience binding, `AuthPlug` introspection branch + `TokenCache`.
5. **AS surface** — authorize/token/register controllers, auto-consent, DCR redirect policy,
   Oban cleanup of stale registrations.
6. **Admin UIs** — providers, roles+scopes, users+assignments, clients; admin endpoint gated on
   `system::admin` with Basic-auth break-glass.
7. **Hardening** — telemetry (`[:backplane, :accounts, :login | :token, …]`), token/session
   pruning via Oban, and retire the multi-user non-goal in `host-agent-design.md`.

End-to-end acceptance: a fresh Claude Code, ChatGPT, and Codex client each completes
discovery → DCR → login → token → authorized `/mcp` call, and an admin can define a role,
assign it, and observe the scope change take effect on the next token.

## 15. Risks & mitigations

| Risk | Mitigation |
|---|---|
| MCP auth spec / client behavior drifts (fast-moving, past training cutoff) | Target 2025-11-25 explicitly; re-verify client registration behavior before each phase; CIMD path kept as future work |
| boruta lacks a needed MCP detail (PRM, S256-only) | Confirmed: hand-add PRM + 401 + S256 enforcement; boruta already threads the `resource` param |
| DCR registration growth / spoofed-client consent | Trusted network; login + RBAC gate at `/authorize`; Oban prunes unused clients; loopback/https redirect restriction |
| Introspection on the `/mcp` hot path | In-process Repo lookup (same class as existing PAT lookup) + `TokenCache`; bounded cache TTL |
| Self-lockout when gating admin behind OAuth | Env-seeded admin emails + Basic-auth break-glass; OAuth-gating of admin is additive |
| Scope-vocabulary fragmentation (boruta scopes vs RBAC vs PAT scopes) | Single registry in boruta `scopes`; token scope claim is the only source of truth at `/mcp` |

## 16. Resolved decisions (grill log)

- **Q1 — What does OAuth protect?** Token-issuance bridge: humans authenticate via OAuth to
  obtain the tokens that gate the (otherwise non-interactive) machine endpoints. Reinterpreted
  for MCP: backplane's AS issues the MCP access tokens; PATs coexist for non-interactive agents.
- **Q2 — Allowlist gate vs identity.** Originally allowlist-only; **overturned by Q5**. The
  allowlist survives as the bootstrap-admin seed.
- **Q3 — Build vs external AS.** Build in-app (Elixir), federating login to one upstream IdP —
  consistent with the self-hosted single-tenant, no-premature-dependency stance.
- **Q4 — boruta vs hand-roll.** boruta, after verifying it covers DCR, the `resource` parameter,
  PKCE, the pluggable resource owner, and Ecto integration on `Backplane.Repo`. Hand-write only
  the thin MCP layer (§10) and the federated-login provider (§7).
- **Q5 — RBAC shape.** Hybrid, runtime-definable roles: permission vocabulary anchored on the
  existing scope patterns + a small `system::*` set; roles and assignments as data managed in
  admin. Token format follow-on: **opaque + introspection**, not JWT (immediate revocation;
  consistent with the existing PAT path).
