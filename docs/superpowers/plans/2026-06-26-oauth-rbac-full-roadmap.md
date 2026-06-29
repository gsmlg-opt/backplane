# OAuth RBAC Full Roadmap

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement each phase plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `docs/oauth-design.md` end to end: Backplane becomes an
OAuth-protected MCP server with human identity, RBAC, DCR, MCP authorization
metadata, opaque token introspection, admin management, and hardening.

**Architecture:** The design is intentionally split into hard-stop phases. Each
phase must produce a working, independently tested layer before the next phase
adds public behavior on top of it. `backplane_system` owns data and domain
contexts; `backplane_mcp` owns MCP compliance details; `backplane_api` owns the
authorization-server HTTP surface; `backplane_admin` owns management UI.

**Tech Stack:** Elixir umbrella, Phoenix/Plug, Ecto/PostgreSQL, Boruta `2.3.6`,
Oban, ExUnit, `devenv shell -- mix ...`.

---

## Current Status

- [x] Phase 1 Boruta foundation is implemented in
      `docs/superpowers/plans/2026-06-26-oauth-rbac-phase-1-boruta-foundation.md`.
- [x] Phase 1 scoped verification passes.
- [x] Full umbrella verification currently exits `139` in
      `apps/backplane_monitor/test/backplane/monitor/providers/claude_code_test.exs`.
- [x] The full-suite blocker is tracked upstream as
      `gsmlg-dev/denox#3`, with GitHub issue type `Bug`, label
      `internal request`, and a required callsite TODO in Backplane.
- [x] Phase 2A identity-domain foundation is implemented in
      `docs/superpowers/plans/2026-06-26-oauth-rbac-phase-2a-identity-domain.md`.
- [x] Phase 2B federated-login domain engine is implemented in
      `docs/superpowers/plans/2026-06-26-oauth-rbac-phase-2b-federated-login.md`.
- [x] Phase 2B scoped and affected verification passes.
- [ ] Full goal completion is not proven until the full design is implemented
      and `devenv shell -- mix test` passes.

## Design Corrections From Source Inspection

- Boruta `2.3.6` has the `Boruta.Oauth.ResourceOwners` behaviour needed for
  resource-owner lookup and authorized scopes.
- Boruta `2.3.6` does not appear to persist or validate RFC 8707 `resource`
  values in its request structs or `oauth_tokens` schema. Phase 4 must treat
  audience binding as Backplane-owned storage/validation work rather than
  relying on Boruta to carry it.
- Boruta's initial migration generator creates unprefixed historical tables
  before renaming to `oauth_*`; Backplane uses a squashed migration instead
  because it already owns `clients`.

## Phase Plan

### Phase 1: Boruta Foundation

**Plan:** `2026-06-26-oauth-rbac-phase-1-boruta-foundation.md`

- [x] Add Boruta dependency.
- [x] Configure Boruta on `Backplane.Repo`.
- [x] Add squashed `oauth_*` tables.
- [x] Prove Boruta Ecto scopes and clients can persist.
- [ ] Full-suite verification passes. Blocked by `gsmlg-dev/denox#3`.

### Phase 2: Identity And Federated Login Domain

**Phase 2A Plan:**
`docs/superpowers/plans/2026-06-26-oauth-rbac-phase-2a-identity-domain.md`.

**Phase 2B Plan:**
`docs/superpowers/plans/2026-06-26-oauth-rbac-phase-2b-federated-login.md`.

Acceptance:

- [x] `Backplane.Accounts` exists with users, identities, and auth providers.
- [x] Provider secrets are encrypted with `Backplane.Settings.Encryption` and
      never returned in plaintext by listing/get APIs.
- [x] Identity linking uses `(provider_id, subject)`, never email alone.
- [x] `Backplane.Accounts.ResourceOwners` implements
      `Boruta.Oauth.ResourceOwners`.
- [x] A configured session user can be converted into a
      `Boruta.Oauth.ResourceOwner`.
- [x] Bootstrap-admin helpers exist.
- [x] Federated login builds state/PKCE/nonce data using the existing
      single-use state-store pattern.

### Phase 3: RBAC

Acceptance:

- [ ] Roles, role scopes, and user roles exist.
- [ ] Built-in `admin`, `member`, and `viewer` roles are seeded idempotently.
- [ ] System roles are protected from delete.
- [ ] Scope strings reuse the existing `*`, `prefix::*`, and `prefix::tool`
      vocabulary plus `system::*`.
- [ ] Effective user scopes are the union of assigned roles.
- [ ] Effective scopes are mirrored into Boruta `oauth_scopes` records.
- [ ] `ResourceOwners.authorized_scopes/1` returns Boruta scope structs.

### Phase 4: MCP Compliance And Introspection

Acceptance:

- [ ] `/.well-known/oauth-protected-resource` describes `<api>/mcp`.
- [ ] `/.well-known/oauth-authorization-server` advertises authorization,
      token, registration endpoints, `S256`, and supported scopes.
- [ ] Unauthenticated `/mcp` returns `401` with `WWW-Authenticate: Bearer`
      and `resource_metadata`.
- [ ] `AuthPlug` resolution order is Backplane OAuth token, PAT, legacy token.
- [ ] OAuth-token audience mismatch, expiry, or revocation returns `401`.
- [ ] OAuth success assigns only `:tool_scopes` plus OAuth-specific assigns,
      not a PAT `:client`.
- [ ] Introspection uses `Backplane.Settings.TokenCache` with bounded TTL.
- [ ] RFC 8707 resource binding is stored and validated by Backplane-owned code.

### Phase 5: Authorization Server HTTP Surface

Acceptance:

- [ ] `GET /authorize` enforces logged-in session and PKCE S256.
- [ ] `POST /token` exchanges authorization codes and refresh tokens.
- [ ] `POST /register` implements DCR for loopback and HTTPS redirect URIs.
- [ ] `GET /auth/:provider/callback` completes upstream IdP login and resumes
      the original authorization request.
- [ ] `POST /logout` clears browser session state.
- [ ] No upstream IdP token is ever accepted as an MCP bearer token.

### Phase 6: Admin UI

Acceptance:

- [ ] `/system/auth/providers` manages auth providers with write-only secrets.
- [ ] `/system/auth/roles` manages roles and scope assignments.
- [ ] `/system/auth/users` lists users/identities and assigns roles.
- [ ] `/system/auth/clients` lists and revokes DCR OAuth clients.
- [ ] Admin OAuth/RBAC gating is additive and preserves Basic-auth break-glass.

### Phase 7: Hardening

Acceptance:

- [ ] Telemetry events cover login, token issue, token introspection, revoke,
      and permission denials.
- [ ] Oban cleanup prunes stale OAuth registrations, authorization codes,
      expired tokens, and expired sessions/state.
- [ ] `host-agent-design.md` is updated to retire the multi-user non-goal.
- [ ] End-to-end acceptance is verified with Claude Code, ChatGPT, and Codex:
      discovery -> DCR -> login -> token -> authorized `/mcp` call.

## Verification Gates

Run after every phase:

```bash
devenv shell -- mix format --check-formatted <changed files>
git diff --check
devenv shell -- mix test <phase-scoped tests>
devenv shell -- mix test <affected existing tests>
devenv shell -- mix test
```

If the full suite still exits in the pre-existing Denox crash, keep the goal
active, record the scoped evidence, and do not claim full completion.
