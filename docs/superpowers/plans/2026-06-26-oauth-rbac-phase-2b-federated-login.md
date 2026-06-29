# OAuth RBAC Phase 2B Federated Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the Backplane-owned federated-login domain engine for upstream OIDC/OAuth2 login without adding public OAuth routes, MCP OAuth behavior, RBAC role tables, or admin UI.

**Architecture:** `backplane_system` owns a plain-function `Backplane.Accounts.FederatedLogin` module. It uses the existing `Backplane.Settings.OAuthStateStore` for short-lived single-use state, `Req` for token/userinfo/JWKS calls, `Joken`/`JOSE` for signed OIDC ID token verification, and existing `Backplane.Accounts` APIs for encrypted provider secrets and JIT user provisioning.

**Tech Stack:** Elixir, Ecto/PostgreSQL, Req + Req.Test, Joken, JOSE, `Backplane.Settings.OAuthStateStore`, ExUnit, `devenv shell -- mix ...`.

---

## Scope Boundary

Implement:

- `Backplane.Accounts.FederatedLogin.start/3`
- `Backplane.Accounts.FederatedLogin.complete/3`
- Signed OIDC ID-token validation for `iss`, `aud`, `exp`, `nonce`, and `sub`
- OAuth2/userinfo fallback for providers without `id_token`
- Bootstrap-admin email predicate helpers on `Backplane.Accounts`
- Test isolation helper for `OAuthStateStore`

Do not implement:

- `/authorize`, `/token`, `/register`, callbacks, logout routes
- Browser session establishment
- `/mcp` challenge or OAuth-token introspection
- Role/RBAC tables, role assignment, or Boruta scope mirroring
- Admin UI

## Files

- Create: `apps/backplane_system/lib/backplane/accounts/federated_login.ex`
- Modify: `apps/backplane_system/lib/backplane/accounts.ex`
- Modify: `apps/backplane_system/lib/backplane/settings/oauth_state_store.ex`
- Modify: `apps/backplane_system/mix.exs`
- Modify: `config/config.exs`
- Modify: `config/runtime.exs`
- Create: `apps/backplane_system/test/backplane/accounts/federated_login_test.exs`
- Modify: `apps/backplane_system/test/backplane/accounts/accounts_test.exs`
- Create: `apps/backplane_system/test/backplane/settings/oauth_state_store_test.exs`
- Modify: `docs/superpowers/plans/2026-06-26-oauth-rbac-full-roadmap.md`

## Acceptance Criteria

- [x] `start/3` rejects missing or disabled providers.
- [x] `start/3` builds an authorization URL containing `response_type=code`, `client_id`, `redirect_uri`, `scope`, `state`, `code_challenge`, `code_challenge_method=S256`, and OIDC `nonce`.
- [x] State attributes store purpose, provider slug/id, redirect URI, PKCE verifier, nonce, and resume params.
- [x] `OAuthStateStore.pop/1` remains single-use and tests can clear state between runs.
- [x] `complete/3` rejects invalid, expired, or provider-mismatched state.
- [x] `complete/3` exchanges the authorization code with the decrypted provider secret.
- [x] OIDC completion verifies ID-token signature using provider JWKS before trusting claims.
- [x] OIDC completion rejects issuer mismatch, audience mismatch, expired token, nonce mismatch, invalid signature, missing `sub`, and disallowed email domain.
- [x] OAuth2 completion can fetch userinfo with the access token and map `sub`/`id`, `email`, and `name`.
- [x] Successful completion provisions or updates a user via `Accounts.provision_federated_user/2` and returns `resume_params`.
- [x] Bootstrap-admin helpers normalize configured emails and login emails case-insensitively, returning a boolean only.
- [x] No public HTTP route, admin route, role table, or `AuthPlug` behavior changes.

## Task 1: Add State-Store And Bootstrap Tests

**Files:**

- Create: `apps/backplane_system/test/backplane/settings/oauth_state_store_test.exs`
- Modify: `apps/backplane_system/test/backplane/accounts/accounts_test.exs`

- [x] Write a failing state-store test:

```elixir
test "pop consumes state only once" do
  state = OAuthStateStore.put(%{"purpose" => "test"})

  assert {:ok, %{"purpose" => "test"}} = OAuthStateStore.pop(state)
  assert :error = OAuthStateStore.pop(state)
end
```

- [x] Write a failing clear-helper test:

```elixir
test "clear removes stored states" do
  state = OAuthStateStore.put(%{"purpose" => "test"})

  OAuthStateStore.clear()

  assert :error = OAuthStateStore.pop(state)
end
```

- [x] Write failing bootstrap predicate tests:

```elixir
test "bootstrap_admin? matches configured emails case-insensitively" do
  Application.put_env(:backplane, :bootstrap_admin_emails, ["Admin@Example.COM", " ops@example.com "])

  assert Accounts.bootstrap_admin?("admin@example.com")
  assert Accounts.bootstrap_admin?(%User{email: "OPS@example.com"})
  refute Accounts.bootstrap_admin?("member@example.com")
end
```

- [x] Run:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/settings/oauth_state_store_test.exs apps/backplane_system/test/backplane/accounts/accounts_test.exs
```

Expected before implementation: compile failures for `OAuthStateStore.clear/0` and `Accounts.bootstrap_admin?/1`.

## Task 2: Implement State-Store Clear And Bootstrap Predicate

**Files:**

- Modify: `apps/backplane_system/lib/backplane/settings/oauth_state_store.ex`
- Modify: `apps/backplane_system/lib/backplane/accounts.ex`
- Modify: `config/config.exs`
- Modify: `config/runtime.exs`

- [x] Add `OAuthStateStore.clear/0` using `:ets.delete_all_objects/1`.
- [x] Add `config :backplane, bootstrap_admin_emails: []`.
- [x] Parse `BACKPLANE_BOOTSTRAP_ADMIN_EMAILS` in `config/runtime.exs` as a comma-separated list.
- [x] Add `Accounts.bootstrap_admin_emails/0` and `Accounts.bootstrap_admin?/1`.
- [x] Keep helpers boolean-only; do not persist role-like flags in `users.metadata`.
- [x] Run the Task 1 command and keep it green.

## Task 3: Add FederatedLogin Start Tests

**Files:**

- Create: `apps/backplane_system/test/backplane/accounts/federated_login_test.exs`

- [x] Write a failing test that `start/3` builds an OIDC authorization URL with S256 PKCE and nonce.
- [x] Write failing tests that `start/3` rejects disabled or unknown providers.
- [x] Run:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/accounts/federated_login_test.exs
```

Expected before implementation: compile failure for `Backplane.Accounts.FederatedLogin`.

## Task 4: Implement FederatedLogin.start/3

**Files:**

- Create: `apps/backplane_system/lib/backplane/accounts/federated_login.ex`

- [x] Add `start(provider_slug, resume_params \\ %{}, opts \\ [])`.
- [x] Use `Accounts.get_auth_provider_by_slug/1`.
- [x] Reject `nil` provider with `{:error, :provider_not_found}`.
- [x] Reject disabled provider with `{:error, :provider_disabled}`.
- [x] Require `authorization_url`; return `{:error, :missing_authorization_url}` when absent.
- [x] Generate verifier as 32 random bytes base64url and challenge as S256 base64url.
- [x] Generate a nonce and store it with PKCE verifier in `OAuthStateStore`.
- [x] Build default redirect URI with `Backplane.WebOrigins.api_url("/auth/#{provider.slug}/callback")`.
- [x] Return `{:ok, %{authorization_url: url, state: state}}`.
- [x] Run Task 3 tests.

## Task 5: Add Signed OIDC Completion Tests

**Files:**

- Modify: `apps/backplane_system/test/backplane/accounts/federated_login_test.exs`
- Modify: `apps/backplane_system/mix.exs`

- [x] Add explicit `:joken` and `:jose` deps if production code calls them directly.
- [x] Use `Req.Test` with `Application.put_env(:backplane, :federated_login_req_options, plug: {Req.Test, __MODULE__})`.
- [x] Build a signed `RS256` or `HS256` ID token in the test with a JWK served by the mocked JWKS endpoint.
- [x] Test that `complete/3` posts `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `client_secret`, and `code_verifier`.
- [x] Test that successful completion provisions a user and returns `resume_params`.
- [x] Test rejection for invalid signature, bad `iss`, bad `aud`, expired `exp`, bad `nonce`, missing `sub`, and disallowed email domain.
- [x] Run the federated-login test file and verify red failures against missing completion behavior.

## Task 6: Implement FederatedLogin.complete/3 For OIDC

**Files:**

- Modify: `apps/backplane_system/lib/backplane/accounts/federated_login.ex`

- [x] Add `complete(provider_slug, params, opts \\ [])`.
- [x] Pop state once via `OAuthStateStore.pop/1`; reject missing/expired state.
- [x] Verify stored provider slug/id matches the callback provider.
- [x] Exchange code via `Req.post/2`, merging `Application.get_env(:backplane, :federated_login_req_options, [])`.
- [x] Fetch provider JWKS and select the key by ID-token `kid`.
- [x] Verify the ID-token signature with Joken/JOSE before reading claims.
- [x] Validate `iss`, `aud`, `exp`, `nonce`, and required `sub`.
- [x] Enforce `allowed_email_domains` when configured.
- [x] Call `Accounts.provision_federated_user/2`.
- [x] Return `{:ok, %{user: user, identity: identity, resume_params: resume_params}}`.

## Task 7: Add And Implement OAuth2 Userinfo Fallback

**Files:**

- Modify: `apps/backplane_system/test/backplane/accounts/federated_login_test.exs`
- Modify: `apps/backplane_system/lib/backplane/accounts/federated_login.ex`

- [x] Add a test for an `oauth2` provider whose token response lacks `id_token`.
- [x] Stub `userinfo_url` and assert `Authorization: Bearer <access_token>`.
- [x] Map `sub` or `id`, `email`, and `name` from userinfo claims.
- [x] Reject missing `sub`/`id`, token transport failures, userinfo transport failures, and disallowed domains.
- [x] Implement the fallback and run the federated-login test file.

## Task 8: Verify Phase 2B

- [x] Run formatting:

```bash
devenv shell -- mix format --check-formatted apps/backplane_system/lib/backplane/accounts.ex apps/backplane_system/lib/backplane/accounts/*.ex apps/backplane_system/lib/backplane/settings/oauth_state_store.ex apps/backplane_system/test/backplane/accounts/*.exs apps/backplane_system/test/backplane/settings/oauth_state_store_test.exs apps/backplane_system/mix.exs config/config.exs config/runtime.exs docs/superpowers/plans/2026-06-26-oauth-rbac-phase-2b-federated-login.md docs/superpowers/plans/2026-06-26-oauth-rbac-full-roadmap.md
```

- [x] Run scoped tests:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/settings/oauth_state_store_test.exs apps/backplane_system/test/backplane/accounts
```

- [x] Run affected existing tests:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/accounts apps/backplane_system/test/backplane/settings/credentials_oauth_test.exs
```

- [x] Run full suite:

```bash
devenv shell -- mix test
```

- [ ] Full suite passes.

Current caveat: the full suite is expected to continue exiting `139` in `backplane_monitor` until `gsmlg-dev/denox#3` is resolved. Record the result and keep the larger goal active if that remains the only failing gate.

Verification result on 2026-06-26:

- Formatting passed with the Task 8 `mix format --check-formatted` command.
- Scoped tests passed: `48 tests, 0 failures`.
- Affected existing tests passed: `54 tests, 0 failures`.
- `git diff --check` passed.
- Full `devenv shell -- mix test` still exits `139` in `backplane_monitor` after earlier apps pass.
