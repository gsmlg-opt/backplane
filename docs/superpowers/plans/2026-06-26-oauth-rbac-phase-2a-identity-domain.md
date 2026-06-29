# OAuth RBAC Phase 2A Identity Domain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the Backplane-owned identity foundation for inbound OAuth without
adding public OAuth routes, MCP OAuth behavior, RBAC management, or admin UI.

**Architecture:** `backplane_system` owns the data model and context APIs:
users, upstream login identities, encrypted auth providers, and the Boruta
resource-owner adapter. Federated-login HTTP routes, token issuance, RBAC role
tables, and `/mcp` introspection remain later hard-stop phases.

**Tech Stack:** Elixir, Ecto/PostgreSQL, Boruta `2.3.6`,
`Backplane.Settings.Encryption`, ExUnit, `devenv shell -- mix ...`.

---

## Scope Boundary

Implement:

- `users`
- `auth_providers`
- `user_identities`
- `Backplane.Accounts`
- `Backplane.Accounts.ResourceOwners`
- Boruta config for `contexts.resource_owners`

Do not implement:

- `/authorize`, `/token`, `/register`, callbacks, logout
- `/mcp` challenge or OAuth-token introspection
- Role/RBAC tables or admin role assignment
- Admin UI
- Upstream OIDC token exchange

`Backplane.Accounts.ResourceOwners.authorized_scopes/1` returns an empty list in
this phase. Phase 3 replaces that with RBAC-backed Boruta scope structs.

## Files

- Create:
  `apps/backplane_system/priv/repo/migrations/20260626000002_create_accounts_identity_tables.exs`
- Create: `apps/backplane_system/lib/backplane/accounts.ex`
- Create: `apps/backplane_system/lib/backplane/accounts/user.ex`
- Create: `apps/backplane_system/lib/backplane/accounts/user_identity.ex`
- Create: `apps/backplane_system/lib/backplane/accounts/auth_provider.ex`
- Create: `apps/backplane_system/lib/backplane/accounts/resource_owners.ex`
- Create: `apps/backplane_system/test/backplane/accounts/accounts_test.exs`
- Create: `apps/backplane_system/test/backplane/accounts/auth_provider_test.exs`
- Create:
  `apps/backplane_system/test/backplane/accounts/resource_owners_test.exs`
- Modify:
  `apps/backplane_system/test/backplane/accounts/boruta_foundation_test.exs`
- Modify: `config/config.exs`

## Acceptance Criteria

- [x] Identity tables migrate cleanly.
- [x] `users.email` is not unique.
- [x] `user_identities` enforces unique `(provider_id, subject)`.
- [x] Auth provider secrets are encrypted in `encrypted_client_secret`.
- [x] Provider list/get APIs do not expose plaintext secrets.
- [x] Secret rotation updates only the encrypted provider secret.
- [x] `provision_federated_user/2` creates a user and identity from stable
      provider subject claims.
- [x] Repeated login with the same `(provider_id, subject)` updates the existing
      identity and returns the same user.
- [x] Same email from a different provider subject creates a separate user.
- [x] `Backplane.Accounts.ResourceOwners` implements Boruta's resource-owner
      callbacks.
- [x] Boruta config resolves
      `Backplane.Accounts.ResourceOwners` via `Boruta.Config.resource_owners/0`.
- [x] No public HTTP route, admin route, or `AuthPlug` behavior changes.

## Task 1: Write Phase 2A Regression Tests

**Files:**

- Create `apps/backplane_system/test/backplane/accounts/auth_provider_test.exs`
- Create `apps/backplane_system/test/backplane/accounts/accounts_test.exs`
- Create `apps/backplane_system/test/backplane/accounts/resource_owners_test.exs`
- Modify `apps/backplane_system/test/backplane/accounts/boruta_foundation_test.exs`

- [x] Add tests for encrypted auth-provider secret creation, listing, fetching,
      and rotation.
- [x] Add tests for JIT provisioning by `(provider_id, subject)`.
- [x] Add tests proving same email on a different provider subject does not
      merge users.
- [x] Add tests for ResourceOwners `get_by(sub:)`, `get_by(username:)`,
      `check_password/2`, `authorized_scopes/1`, and `claims/2`.
- [x] Add a Boruta config assertion for `Boruta.Config.resource_owners/0`.
- [x] Run:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/accounts
```

Expected before implementation: failures for missing modules/tables/config.

## Task 2: Add Identity Tables And Schemas

**Files:**

- Create migration and schema files listed above.

- [x] Add `users` with binary id, `email`, `name`, `active`,
      `last_login_at`, `metadata`, and microsecond timestamps.
- [x] Add `auth_providers` with binary id, provider URLs, client id,
      `encrypted_client_secret`, `scopes`, `allowed_email_domains`, `enabled`,
      `discovery`, `metadata`, and microsecond timestamps.
- [x] Add `user_identities` with binary id, `user_id`, `provider_id`,
      `subject`, `email`, `name`, `raw_claims`, `last_login_at`, and
      microsecond timestamps.
- [x] Add unique indexes on provider slug and `(provider_id, subject)`.
- [x] Add schemas and operation-specific changesets.

## Task 3: Add Accounts Context

**Files:**

- Create `apps/backplane_system/lib/backplane/accounts.ex`

- [x] Add provider APIs:
      `create_auth_provider/1`, `update_auth_provider/2`,
      `rotate_auth_provider_secret/2`, `fetch_auth_provider_secret/1`,
      `list_auth_providers/0`, and `get_auth_provider_by_slug/1`.
- [x] Add user APIs:
      `get_user/1`, `list_users/0`, `get_user_by_identity/2`,
      `provision_federated_user/2`, and `to_resource_owner/1`.
- [x] Use `Ecto.Multi` or `Repo.transact/1` so user+identity provisioning is
      atomic.
- [x] Link identities only by `(provider_id, subject)`, never by email.

## Task 4: Add Boruta ResourceOwners Adapter

**Files:**

- Create `apps/backplane_system/lib/backplane/accounts/resource_owners.ex`
- Modify `config/config.exs`

- [x] Implement `@behaviour Boruta.Oauth.ResourceOwners`.
- [x] Resolve `%Boruta.Oauth.ResourceOwner{sub: user.id, username: user.email}`.
- [x] Deny password grant with `{:error, "password grant is not supported"}`.
- [x] Return `[]` from `authorized_scopes/1` until Phase 3 RBAC lands.
- [x] Return non-secret user claims from `claims/2`.
- [x] Configure:

```elixir
config :boruta, Boruta.Oauth,
  contexts: [
    resource_owners: Backplane.Accounts.ResourceOwners
  ]
```

## Task 5: Verify Phase 2A

- [x] Run formatting:

```bash
devenv shell -- mix format --check-formatted apps/backplane_system/lib/backplane/accounts.ex apps/backplane_system/lib/backplane/accounts/*.ex apps/backplane_system/priv/repo/migrations/20260626000002_create_accounts_identity_tables.exs apps/backplane_system/test/backplane/accounts/*.exs config/config.exs
```

- [x] Run scoped tests:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/accounts
```

- [x] Run affected existing tests:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/transport/auth_plug_test.exs apps/backplane_system/test/backplane/clients_test.exs apps/backplane_system/test/backplane/clients/client_test.exs
```

- [x] Run full suite:

```bash
devenv shell -- mix test
```

- [ ] Full suite passes.

Current result: the full suite still exits `139` in `backplane_monitor` after
`backplane_system` reports `315 tests, 0 failures` and `backplane_memory`
reports `196 tests, 0 failures`. This matches the existing
`gsmlg-dev/denox#3` blocker. Do not claim full goal completion until the full
suite passes.

## Review Notes

- [x] Parallel reviewers checked Phase 2A scope, data/security behavior, and
      Boruta callback wiring.
- [x] Reviewer findings were addressed: username lookup no longer relies on
      non-unique email, identity provisioning retries the existing identity after
      unique-conflict races, ordinary validation failures return changesets, and
      Boruta claims use string keys.
