# Backplane Auth Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `backplane_auth` as a standalone OAuth/OIDC issuer inside the Backplane umbrella, exposed through `backplane_api`, for first-party applications such as `gsmlg_umbrella` and `gsmlg_app_backend`.

**Architecture:** `backplane_auth` owns the Auth domain, schemas, token lifecycle, roles, scopes, sessions, and audit events. `backplane_api` owns OAuth/OIDC HTTP routes and login pages. `backplane_admin` owns operator management UI. Existing Backplane MCP, LLM, skills, and host-agent authentication behavior remains unchanged in this release.

**Tech Stack:** Elixir umbrella, Phoenix/Plug, Ecto/PostgreSQL, Boruta 2.3, Bcrypt, JOSE/Joken, ExUnit, Phoenix LiveView, Phoenix DuskMoon, `devenv shell -- mix ...`.

---

## Source Spec

Implement against:

- `docs/superpowers/specs/2026-06-30-backplane-auth-service-design.md`

Treat the older MCP-centered documents as superseded for this first release:

- `docs/oauth-design.md`
- `docs/superpowers/plans/2026-06-26-oauth-rbac-full-roadmap.md`
- `docs/superpowers/plans/2026-06-26-oauth-rbac-phase-*.md`

## Scope Boundaries

- Do not protect `/mcp`, `/v1/*`, `/skills/*`, `/host-agent/*`, or the Backplane admin endpoint with the new Auth service.
- Do not add dynamic client registration.
- Do not add external IdP federation, SAML, SCIM, LDAP, or multi-tenant organization management.
- Do not expand `Backplane.Accounts`; new Auth work belongs under `Backplane.Auth`.
- Keep existing `AGENTS.md` and `CLAUDE.md` local edits out of this work unless the user explicitly asks for them.

## File Structure

Create:

- `apps/backplane_auth/mix.exs` - Auth app dependencies and test paths.
- `apps/backplane_auth/lib/backplane_auth/application.ex` - Auth app supervision entrypoint.
- `apps/backplane_auth/lib/backplane/auth.ex` - public facade.
- `apps/backplane_auth/lib/backplane/auth/accounts.ex` - users, password credentials, login sessions.
- `apps/backplane_auth/lib/backplane/auth/oauth.ex` - clients, scopes, authorization requests, token exchange.
- `apps/backplane_auth/lib/backplane/auth/rbac.ex` - roles, role scopes, user roles.
- `apps/backplane_auth/lib/backplane/auth/tokens.ex` - signing keys, JWT claims, refresh-token family state.
- `apps/backplane_auth/lib/backplane/auth/audit.ex` - append-only event recording and queries.
- `apps/backplane_auth/lib/backplane/auth/resource_owners.ex` - Boruta resource-owner callback.
- `apps/backplane_auth/lib/backplane/auth/schemas/*.ex` - Ecto schemas for `auth_*` tables.
- `apps/backplane_auth/priv/repo/migrations/*.exs` - Auth-owned migrations.
- `apps/backplane_auth/test/backplane/auth/**/*_test.exs` - domain tests.
- `apps/backplane_auth/test/support/fixtures.ex` - Auth fixtures.

Modify:

- `mix.exs` - include `:backplane_auth` in the `backplane` release.
- `config/config.exs` - configure Boruta resource owners as `Backplane.Auth.ResourceOwners`.
- `config/test.exs` - Auth test issuer and bootstrap admin config.
- `config/runtime.exs` - Auth issuer derives from the existing API URL.
- `apps/backplane_api/mix.exs` - depend on `:backplane_auth`.
- `apps/backplane_api/lib/backplane/api/router.ex` - add OAuth/OIDC and login routes.
- `apps/backplane_api/lib/backplane/api/controllers/auth/*.ex` - OAuth/OIDC controllers.
- `apps/backplane_api/test/backplane/api/auth/**/*_test.exs` - route and protocol tests.
- `apps/backplane_admin/mix.exs` - depend on `:backplane_auth`.
- `apps/backplane_admin/lib/backplane/admin/live/auth_oauth_live.ex` - replace fake OAuth cards.
- `apps/backplane_admin/lib/backplane/admin/live/auth_rbac_live.ex` - replace fake RBAC cards.
- `apps/backplane_admin/lib/backplane/admin/live/auth_audit_live.ex` - replace fake audit status.
- `apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs` - admin UI tests.
- `docs/integrations/auth-gsmlg-umbrella.md` - integration example.
- `docs/integrations/auth-gsmlg-app-backend.md` - integration example.

Do not modify existing `Backplane.Transport.AuthPlug` in v1 except to add regression tests proving it is unchanged.

## Phase 0: Worktree And Baseline

**Files:**
- No source edits in this phase.

- [ ] **Step 1: Create the implementation worktree**

Run:

```bash
git worktree add .trees/codex-backplane-auth-service -b codex/backplane-auth-service
cd .trees/codex-backplane-auth-service
```

Expected: a clean worktree on branch `codex/backplane-auth-service`.

- [ ] **Step 2: Verify baseline status**

Run:

```bash
git status --short --branch
```

Expected: no modified files in the implementation worktree.

- [ ] **Step 3: Refresh GitNexus index**

Run:

```bash
npx gitnexus analyze
```

Expected: repository indexed successfully.

- [ ] **Step 4: Run baseline scoped tests**

Run:

```bash
devenv shell -- mix test \
  apps/backplane_system/test/backplane/transport/auth_plug_test.exs \
  apps/backplane_api/test/backplane/api/page_controller_test.exs \
  apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

Expected: tests pass before Auth service work begins. If an unrelated existing failure appears, record it and stop for user direction.

## Phase 1: Auth App Skeleton

**Files:**
- Create: `apps/backplane_auth/mix.exs`
- Create: `apps/backplane_auth/lib/backplane_auth/application.ex`
- Create: `apps/backplane_auth/lib/backplane/auth.ex`
- Create: `apps/backplane_auth/test/test_helper.exs`
- Modify: `mix.exs`
- Modify: `apps/backplane_api/mix.exs`
- Modify: `apps/backplane_admin/mix.exs`

- [ ] **Step 1: Run impact checks before editing umbrella/release symbols**

Run:

```bash
npx gitnexus impact --target releases --direction upstream
npx gitnexus impact --target deps --direction upstream
```

Expected: record risk. If GitNexus cannot resolve these symbols, record that and continue with direct diff review.

- [ ] **Step 2: Add the `backplane_auth` Mix project**

Create `apps/backplane_auth/mix.exs` with app `:backplane_auth`, shared umbrella paths, `elixir: "~> 1.18"`, `elixirc_paths/1`, and dependencies:

```elixir
[
  {:backplane_system, in_umbrella: true},
  {:backplane_data_case, in_umbrella: true, only: :test},
  {:ecto_sql, "~> 3.12"},
  {:bcrypt_elixir, "~> 3.0"},
  {:boruta, "~> 2.3"},
  {:joken, "~> 2.6"},
  {:jose, "~> 1.11"},
  {:jason, "~> 1.4"}
]
```

- [ ] **Step 3: Add the Auth application module**

Create `apps/backplane_auth/lib/backplane_auth/application.ex` with an empty one-for-one supervisor named `BackplaneAuth.Supervisor`. Auth domain state is database-backed; do not add per-user GenServers.

- [ ] **Step 4: Add the public facade**

Create `apps/backplane_auth/lib/backplane/auth.ex` as the stable facade that subsequent phase tasks extend. Start it with:

```elixir
defmodule Backplane.Auth do
  @moduledoc "Standalone OAuth/OIDC Auth service domain for Backplane."
end
```

- [ ] **Step 5: Wire umbrella dependencies**

Modify:

- root `mix.exs`: add `backplane_auth: :permanent` to the `backplane` release applications before `backplane_api`.
- `apps/backplane_api/mix.exs`: add `{:backplane_auth, in_umbrella: true}`.
- `apps/backplane_admin/mix.exs`: add `{:backplane_auth, in_umbrella: true}`.

- [ ] **Step 6: Compile**

Run:

```bash
devenv shell -- mix compile
```

Expected: compilation succeeds.

- [ ] **Step 7: Commit phase 1**

Run:

```bash
git add mix.exs apps/backplane_api/mix.exs apps/backplane_admin/mix.exs apps/backplane_auth
git commit -m "feat(auth): add backplane auth umbrella app"
```

## Phase 2: Auth Domain Storage And Accounts

**Files:**
- Create: `apps/backplane_auth/priv/repo/migrations/20260701000001_create_auth_accounts.exs`
- Create: `apps/backplane_auth/lib/backplane/auth/schemas/user.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/schemas/password_credential.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/schemas/session.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/accounts.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/audit.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/schemas/audit_event.ex`
- Create: `apps/backplane_auth/test/support/fixtures.ex`
- Create: `apps/backplane_auth/test/backplane/auth/accounts_test.exs`
- Create: `apps/backplane_auth/test/backplane/auth/audit_test.exs`

- [ ] **Step 1: Write failing account tests**

Create tests covering:

- creates a local user with normalized unique email
- stores password hash, never plaintext
- authenticates with correct password
- rejects wrong password
- disables inactive users
- creates and revokes browser sessions
- writes audit events for login success, login failure, user disable, session revoke

Run:

```bash
devenv shell -- mix test apps/backplane_auth/test/backplane/auth/accounts_test.exs
```

Expected: failure because schemas and context do not exist.

- [ ] **Step 2: Add account and audit migrations**

Create `auth_users`, `auth_password_credentials`, `auth_sessions`, and `auth_audit_events`.

Required constraints:

- `auth_users.email` unique lower-case index.
- `auth_password_credentials.user_id` unique foreign key.
- `auth_sessions.token_hash` unique index.
- `auth_sessions.expires_at` index.
- `auth_audit_events.inserted_at` index.

- [ ] **Step 3: Add schemas**

Add Ecto schemas under `Backplane.Auth.Schemas` for user, password credential, session, and audit event. Mark password hashes, token hashes, and audit metadata as redacted when applicable.

- [ ] **Step 4: Add `Backplane.Auth.Accounts`**

Implement:

```elixir
create_user(attrs)
set_password(user, password)
authenticate(email, password)
disable_user(user)
create_session(user, attrs)
get_session_by_token(token)
revoke_session(session)
list_users(opts \\ [])
```

Use `Bcrypt.hash_pwd_salt/1` and `Bcrypt.verify_pass/2`. Hash session tokens before storage.

- [ ] **Step 5: Add `Backplane.Auth.Audit`**

Implement:

```elixir
record(event_type, actor, attrs \\ %{})
list_events(opts \\ [])
```

Audit payloads must not contain plaintext passwords, refresh tokens, client secrets, authorization codes, or session tokens.

- [ ] **Step 6: Run migrations and tests**

Run:

```bash
MIX_ENV=test devenv shell -- mix ecto.migrate
devenv shell -- mix test apps/backplane_auth/test/backplane/auth/accounts_test.exs apps/backplane_auth/test/backplane/auth/audit_test.exs
```

Expected: tests pass.

- [ ] **Step 7: Commit phase 2**

Run:

```bash
git add apps/backplane_auth
git commit -m "feat(auth): add local users and sessions"
```

## Phase 3: Clients, Scopes, RBAC, And Resource Owners

**Files:**
- Create: `apps/backplane_auth/priv/repo/migrations/20260701000002_create_auth_rbac.exs`
- Create: `apps/backplane_auth/lib/backplane/auth/oauth.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/rbac.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/resource_owners.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/schemas/role.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/schemas/role_scope.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/schemas/user_role.ex`
- Create: `apps/backplane_auth/test/backplane/auth/oauth_test.exs`
- Create: `apps/backplane_auth/test/backplane/auth/rbac_test.exs`
- Create: `apps/backplane_auth/test/backplane/auth/resource_owners_test.exs`
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`

- [ ] **Step 1: Write failing RBAC and client tests**

Cover:

- creates a confidential OAuth client with generated secret
- creates a public PKCE-only client without secret
- validates exact redirect URI match
- rejects wildcard redirect URI
- creates scopes and assigns them to clients
- creates roles and role scopes
- assigns roles to users
- computes user effective scopes as a union
- `Backplane.Auth.ResourceOwners.authorized_scopes/1` returns Boruta scope structs for the user

Run:

```bash
devenv shell -- mix test apps/backplane_auth/test/backplane/auth/oauth_test.exs apps/backplane_auth/test/backplane/auth/rbac_test.exs apps/backplane_auth/test/backplane/auth/resource_owners_test.exs
```

Expected: failure because contexts do not exist.

- [ ] **Step 2: Add RBAC migration**

Create `auth_roles`, `auth_role_scopes`, and `auth_user_roles`.

Use existing Boruta `oauth_clients`, `oauth_scopes`, `oauth_clients_scopes`, and `oauth_tokens` tables for protocol storage. Wrap those tables through `Backplane.Auth.OAuth`; do not expose Boruta structs from public Auth contexts except in adapter modules required by Boruta callbacks.

- [ ] **Step 3: Implement `Backplane.Auth.OAuth`**

Implement:

```elixir
create_client(attrs)
rotate_client_secret(client)
disable_client(client)
list_clients(opts \\ [])
get_client(id)
create_scope(attrs)
list_scopes(opts \\ [])
assign_client_scopes(client, scope_names)
validate_redirect_uri(client, redirect_uri)
```

Store confidential client secrets according to Boruta requirements and expose plaintext only once at creation/rotation.

- [ ] **Step 4: Implement `Backplane.Auth.RBAC`**

Implement:

```elixir
create_role(attrs)
delete_role(role)
assign_role_scope(role, scope_name)
assign_user_role(user, role)
revoke_user_role(user, role)
effective_scope_names(user)
seed_system_roles()
```

Seed at least `admin`, `member`, and `viewer`. System roles cannot be deleted.

- [ ] **Step 5: Replace Boruta resource-owner config**

Modify Boruta config:

```elixir
config :boruta, Boruta.Oauth,
  repo: Backplane.Repo,
  issuer: "http://localhost:4220",
  contexts: [
    resource_owners: Backplane.Auth.ResourceOwners
  ]
```

Runtime issuer continues to use the existing API URL.

- [ ] **Step 6: Run scoped tests**

Run:

```bash
devenv shell -- mix test apps/backplane_auth/test/backplane/auth
```

Expected: all Auth domain tests pass.

- [ ] **Step 7: Run legacy Accounts tests**

Run:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/accounts
```

Expected: existing historical `Backplane.Accounts` tests still pass. If failures are caused only by the Boruta resource-owner config change, update the tests to assert the new `Backplane.Auth.ResourceOwners` boundary.

- [ ] **Step 8: Commit phase 3**

Run:

```bash
git add apps/backplane_auth config/config.exs config/test.exs config/runtime.exs
git commit -m "feat(auth): add clients scopes and roles"
```

## Phase 4: API Login And OAuth Authorization Code Flow

**Files:**
- Create: `apps/backplane_api/lib/backplane/api/controllers/auth/login_controller.ex`
- Create: `apps/backplane_api/lib/backplane/api/controllers/auth/authorize_controller.ex`
- Create: `apps/backplane_api/lib/backplane/api/controllers/auth/token_controller.ex`
- Create: `apps/backplane_api/lib/backplane/api/controllers/auth/oauth_json.ex`
- Create: `apps/backplane_api/lib/backplane/api/controllers/auth/login_html.ex`
- Create: `apps/backplane_api/lib/backplane/api/controllers/auth/login_html/login.html.heex`
- Create: `apps/backplane_api/test/backplane/api/auth/login_controller_test.exs`
- Create: `apps/backplane_api/test/backplane/api/auth/authorize_controller_test.exs`
- Create: `apps/backplane_api/test/backplane/api/auth/token_controller_test.exs`
- Modify: `apps/backplane_api/lib/backplane/api/router.ex`

- [ ] **Step 1: Run API route impact check**

Run:

```bash
npx gitnexus api-impact --route /oauth/authorize
npx gitnexus impact --target Backplane.Api.Router --direction upstream
```

Expected: record risk. If routes are not indexed yet, continue with direct router diff review.

- [ ] **Step 2: Write failing API tests**

Cover:

- `GET /oauth/authorize` redirects unauthenticated user to `/oauth/login`
- login with valid credentials resumes the authorization request
- invalid login re-renders the login page without leaking account existence
- authorization code is single-use
- token exchange requires PKCE verifier
- `plain` PKCE is rejected
- implicit, password, device-code, and dynamic registration requests are rejected

Run:

```bash
devenv shell -- mix test apps/backplane_api/test/backplane/api/auth
```

Expected: failure because routes/controllers do not exist.

- [ ] **Step 3: Add API router scopes**

Add browser routes:

```elixir
get("/oauth/authorize", Auth.AuthorizeController, :authorize)
get("/oauth/login", Auth.LoginController, :new)
post("/oauth/login", Auth.LoginController, :create)
post("/oauth/logout", Auth.LoginController, :delete)
```

Add API routes:

```elixir
post("/oauth/token", Auth.TokenController, :token)
```

Use the existing `backplane_api` endpoint and session stack. Do not add a new endpoint or port.

- [ ] **Step 4: Implement login controller**

Use `Backplane.Auth.Accounts.authenticate/2`, rotate the session on successful login, store the Auth user id in the browser session, and write audit events through `Backplane.Auth.Audit`.

- [ ] **Step 5: Implement authorize and token controllers**

Use Boruta callback contracts where they fit. The controllers should call `Backplane.Auth` contexts and render JSON/HTML through `Auth.OAuthJSON` and `Auth.LoginHTML`.

- [ ] **Step 6: Run API Auth tests**

Run:

```bash
devenv shell -- mix test apps/backplane_api/test/backplane/api/auth
```

Expected: tests pass.

- [ ] **Step 7: Run route-boundary regression tests**

Run:

```bash
devenv shell -- mix test \
  apps/backplane_system/test/backplane/transport/auth_plug_test.exs \
  apps/backplane_api/test/backplane/api/page_controller_test.exs
```

Expected: existing Backplane route behavior remains unchanged.

- [ ] **Step 8: Commit phase 4**

Run:

```bash
git add apps/backplane_api apps/backplane_auth
git commit -m "feat(auth): expose authorization code flow"
```

## Phase 5: OIDC Discovery, JWKS, Userinfo, Introspection, Revocation

**Files:**
- Create: `apps/backplane_auth/lib/backplane/auth/tokens.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/schemas/signing_key.ex`
- Create: `apps/backplane_auth/priv/repo/migrations/20260701000003_create_auth_signing_keys.exs`
- Create: `apps/backplane_auth/test/backplane/auth/tokens_test.exs`
- Create: `apps/backplane_api/lib/backplane/api/controllers/auth/discovery_controller.ex`
- Create: `apps/backplane_api/lib/backplane/api/controllers/auth/jwks_controller.ex`
- Create: `apps/backplane_api/lib/backplane/api/controllers/auth/userinfo_controller.ex`
- Create: `apps/backplane_api/lib/backplane/api/controllers/auth/introspect_controller.ex`
- Create: `apps/backplane_api/lib/backplane/api/controllers/auth/revoke_controller.ex`
- Create: `apps/backplane_api/test/backplane/api/auth/discovery_controller_test.exs`
- Create: `apps/backplane_api/test/backplane/api/auth/jwks_controller_test.exs`
- Create: `apps/backplane_api/test/backplane/api/auth/userinfo_controller_test.exs`
- Create: `apps/backplane_api/test/backplane/api/auth/introspect_controller_test.exs`
- Create: `apps/backplane_api/test/backplane/api/auth/revoke_controller_test.exs`
- Modify: `apps/backplane_api/lib/backplane/api/router.ex`

- [ ] **Step 1: Write failing token and OIDC tests**

Cover:

- discovery document issuer equals `Backplane.WebOrigins.api_base_url()`
- discovery advertises supported endpoints and rejects unsupported grant types by omission
- JWKS contains active public keys with `kid`
- access token contains issuer, subject, audience, client id, scope, issued-at, expiration, and token id
- ID token is returned when `openid` scope is requested
- `/oauth/userinfo` returns stable profile claims for a valid bearer token
- introspection returns active false for revoked/expired tokens
- revocation invalidates access token and refresh-token family
- refresh-token reuse revokes the family and records high-severity audit event

Run:

```bash
devenv shell -- mix test apps/backplane_auth/test/backplane/auth/tokens_test.exs apps/backplane_api/test/backplane/api/auth
```

Expected: failure because endpoints and signing keys do not exist.

- [ ] **Step 2: Add signing key storage**

Create `auth_signing_keys` with `kid`, encrypted private JWK, public JWK, active flag, retired timestamp, and timestamps. Use JOSE for key generation and signing.

- [ ] **Step 3: Implement `Backplane.Auth.Tokens`**

Implement:

```elixir
ensure_active_signing_key()
jwks()
issue_access_token(user, client, scopes, opts)
issue_id_token(user, client, opts)
verify_access_token(token, opts \\ [])
introspect(token, client)
revoke(token, client)
rotate_refresh_token(refresh_token, client)
```

- [ ] **Step 4: Add OIDC/API routes**

Add:

```elixir
get("/.well-known/openid-configuration", Auth.DiscoveryController, :show)
get("/oauth/jwks", Auth.JwksController, :index)
get("/oauth/userinfo", Auth.UserinfoController, :show)
post("/oauth/introspect", Auth.IntrospectController, :introspect)
post("/oauth/revoke", Auth.RevokeController, :revoke)
```

- [ ] **Step 5: Run scoped tests**

Run:

```bash
devenv shell -- mix test apps/backplane_auth/test/backplane/auth/tokens_test.exs apps/backplane_api/test/backplane/api/auth
```

Expected: tests pass.

- [ ] **Step 6: Commit phase 5**

Run:

```bash
git add apps/backplane_auth apps/backplane_api
git commit -m "feat(auth): add oidc tokens and lifecycle endpoints"
```

## Phase 6: Real Admin UI

**Files:**
- Modify: `apps/backplane_admin/lib/backplane/admin/live/auth_oauth_live.ex`
- Modify: `apps/backplane_admin/lib/backplane/admin/live/auth_rbac_live.ex`
- Modify: `apps/backplane_admin/lib/backplane/admin/live/auth_audit_live.ex`
- Modify: `apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs`

- [ ] **Step 1: Write failing LiveView tests**

Update tests to require real data/actions:

- clients page lists real Auth clients
- clients page creates, disables, and rotates a client secret
- scopes page lists real Auth scopes
- users page lists real Auth users
- roles page creates roles and assigns scopes
- assignments page assigns roles to users and previews effective scopes
- sessions/tokens page revokes sessions or refresh-token families
- audit page lists real `auth_audit_events`
- fake readiness copy is absent from final v1 pages

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

Expected: failure until LiveViews call `Backplane.Auth`.

- [ ] **Step 2: Replace OAuth pages**

Update `AuthOAuthLive` to use `Backplane.Auth.OAuth` and `Backplane.Auth.Tokens` for overview, clients, scopes, tokens, protocol status, client creation, client disable, and secret rotation.

- [ ] **Step 3: Replace RBAC pages**

Update `AuthRbacLive` to use `Backplane.Auth.Accounts` and `Backplane.Auth.RBAC` for users, roles, assignments, and effective scope previews.

- [ ] **Step 4: Replace audit page**

Update `AuthAuditLive` to use `Backplane.Auth.Audit.list_events/1` with filters for login, token, client, role, and session events.

- [ ] **Step 5: Run admin tests**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

Expected: tests pass.

- [ ] **Step 6: Run assets checks**

Run:

```bash
devenv shell -- mix assets.build
```

Expected: API and admin assets build successfully.

- [ ] **Step 7: Commit phase 6**

Run:

```bash
git add apps/backplane_admin
git commit -m "feat(auth): replace auth admin placeholders"
```

## Phase 7: Integration Docs And Release Verification

**Files:**
- Create: `docs/integrations/auth-gsmlg-umbrella.md`
- Create: `docs/integrations/auth-gsmlg-app-backend.md`
- Modify: `docs/oauth-design.md`
- Modify: `docs/superpowers/plans/2026-06-26-oauth-rbac-full-roadmap.md`
- Create: `apps/backplane_api/test/backplane/api/auth/backplane_route_regression_test.exs`

- [ ] **Step 1: Add route regression tests**

Write tests proving Auth service routes do not change existing public contracts:

- `/mcp` still uses existing MCP auth behavior
- `/v1/models` continues through LLM proxy routing behavior
- `/skills` routes continue to use skills API behavior
- `/host-agent` routes continue to use host-agent behavior

Use focused assertions matching current route expectations rather than introducing new Auth behavior into those routes.

- [ ] **Step 2: Mark older OAuth docs superseded**

Add a short banner at the top of `docs/oauth-design.md` and `docs/superpowers/plans/2026-06-26-oauth-rbac-full-roadmap.md`:

```markdown
> Superseded for v1 by `docs/superpowers/specs/2026-06-30-backplane-auth-service-design.md`.
> The first Auth release exposes a reusable OAuth/OIDC service through `backplane_api`
> and does not protect `/mcp`.
```

- [ ] **Step 3: Add first-party integration docs**

Create docs showing:

- issuer URL
- discovery URL
- redirect URI registration
- PKCE authorization-code flow
- JWKS verification
- required scopes
- local development callback examples for `gsmlg_umbrella` and `gsmlg_app_backend`

- [ ] **Step 4: Run scoped verification**

Run:

```bash
devenv shell -- mix test apps/backplane_auth/test apps/backplane_api/test/backplane/api/auth apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
devenv shell -- mix test apps/backplane_system/test/backplane/transport/auth_plug_test.exs
devenv shell -- mix format --check-formatted
git diff --check
```

Expected: all pass.

- [ ] **Step 5: Run full verification**

Run:

```bash
devenv shell -- mix test
```

Expected: full test suite passes. If an unrelated pre-existing failure appears, reproduce it on `main`, record the evidence, and stop for user direction before fixing outside Auth scope.

- [ ] **Step 6: Run GitNexus detect changes**

Run:

```bash
npx gitnexus detect-changes
```

Expected: affected symbols and flows are limited to Auth, API Auth routes, and Auth admin pages. If GitNexus misses visible git changes, use `git status`, `git diff --stat`, and focused tests as the source of truth.

- [ ] **Step 7: Commit phase 7**

Run:

```bash
git add docs apps/backplane_api/test/backplane/api/auth/backplane_route_regression_test.exs
git commit -m "docs(auth): add first-party integration guidance"
```

## Final Acceptance

- [ ] `backplane_auth` is included in the Backplane release.
- [ ] `backplane_api` exposes OIDC discovery, authorize, token, JWKS, userinfo, introspection, revocation, login, and logout routes.
- [ ] A test client completes authorization code + PKCE login and receives access token, refresh token, and ID token.
- [ ] JWTs verify against `/oauth/jwks`.
- [ ] Operators manage real users, clients, roles, scopes, sessions, and audit events from `/auth/*` admin pages.
- [ ] Existing Backplane MCP, LLM, skills, and host-agent auth behavior is unchanged.
- [ ] Integration docs exist for `gsmlg_umbrella` and `gsmlg_app_backend`.
- [ ] Scoped tests and full verification are recorded in the final implementation summary.
