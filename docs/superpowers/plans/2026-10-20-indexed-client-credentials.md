# Indexed Client Credentials Implementation Plan

> **For agentic workers:** Use subagent-driven-development and test-driven-development. Tasks have disjoint file ownership; parallel execution is required by AGENTS.md. All Mix/Devenv invocations use `flock /tmp/backplane-indexed-auth-mix.lock` to serialize builds. Production deployment is outside this implementation plan.

**Goal:** Replace client bcrypt scans with server-issued 256-bit tokens and digest-indexed authentication; revoke all old database and configured shared client tokens at cutover.

**Architecture:** Keep the client-ID ETS table and existing lease/publication barriers. Add a digest-to-client-ID table and remove verification workers/evidence/negative caches. Management uses trusted issuance APIs and excludes secret-bearing MCP responses from replay/task storage.

**Tech Stack:** Elixir/OTP, Ecto/PostgreSQL, protected ETS, Phoenix LiveView, Plug, ExUnit.

**Delivery state (2026-10-21):** Implementation and independent spec/quality review complete in
the workspace. Combined scoped verification: 560 tests, zero failures; compilation and scoped
format checks pass. Extra audio socket verification retains three failures (one missing SDK
environment, two media-observation assertions; original baseline unverified). See the
[operations report](../../operations/token-auth-indexed.md) for measurements and limits.
No release, deployment or production credential changes were performed.

## Shared contracts

```elixir
# No caller-supplied credential fields are accepted by these entry points.
Clients.create_client(attrs)             # {:ok, client}, initially unissued
Clients.issue_client(attrs)              # {:ok, client, plaintext_token}
Clients.rotate_client_token(client, attrs \\ %{}) # {:ok, client, plaintext_token}
Clients.revoke_client_token(client)      # {:ok, client}
Clients.update_client(client, attrs)     # {:ok, client}; credential unchanged
Clients.upsert_from_config(attrs)        # metadata-only, never reissues
```

Tokens are `bp2_` plus unpadded base64url of 32 random bytes (47 ASCII bytes). The schema stores only nullable `token_digest` (`bytea`, unique, 32-byte constraint, redacted on inspection); NULL clients remain configured protection. All error paths sanitize externally supplied secret fields.

## Task 1: Credential persistence and cache (core worker)

Files: `apps/backplane_system/lib/backplane/clients.ex`, `clients/client.ex`, `clients/auth_cache.ex`, `clients/auth_supervisor.ex`, necessary `clients/activity.ex` references; new migration under `apps/backplane_system/priv/repo/migrations`; system client/schema/cache/activity tests and `test/support/fixtures.ex`; `scripts/benchmark_client_auth.exs`.

- [x] Write failing issuance/rotation tests and an explicit production-cache test asserting a valid token and many different invalid tokens execute no bcrypt and no client enumeration.
- [x] Run the focused tests against the old implementation and record the expected failure.
- [x] Add nullable digest with unique/length constraints and remove old `token_hash` in an explicitly irreversible migration. Preserve existing client IDs and authorization fields.
- [x] Implement the shared context contracts. Reject caller `token`, `token_hash`, `token_digest` and scheme attrs; use trusted `put_change` for generated digests only. Keep pre-write invalidation and PubSub propagation.
- [x] Replace request verification with fixed-format validation, SHA-256 and protected ETS digest lookup. Preserve snapshot incarnation/epoch and lease checks, revision fencing, slow-load lease start, mutation barriers and bounded Activity writes.
- [x] Remove verifier flight/waiter/evidence/negative machinery and keep only supervised refresh and Activity work. Test sandbox verification uses one indexed digest SQL query and matches production semantics.
- [x] Adapt fixture issuance and rewrite obsolete bcrypt-specific tests into digest/lease/restart/race invariants.
- [x] Run scoped system tests. Update the benchmark to use a dedicated empty test database and report 1/32/1000/10000 client results, request SQL/bcrypt/tasks/index work and separate snapshot-build cost.

Test examples:

```elixir
assert {:ok, client, token} = Clients.issue_client(%{name: "indexed", scopes: ["*"]})
assert byte_size(token) == 47
assert client.token_digest == :crypto.hash(:sha256, token)
assert {:ok, ^client} = AuthCache.verify(token)
assert {:ok, rotated, replacement} = Clients.rotate_client_token(client)
assert :error = AuthCache.verify(token)
assert {:ok, ^rotated} = AuthCache.verify(replacement)
assert {:ok, _} = Clients.revoke_client_token(rotated)
assert :error = AuthCache.verify(replacement)
```

Run: `flock /tmp/backplane-indexed-auth-mix.lock devenv shell --no-tui -- mix test apps/backplane_system/test/backplane/clients_test.exs apps/backplane_system/test/backplane/clients/`.

## Task 2: Resource authentication and boot/config (auth worker)

Files: `apps/backplane_auth/lib/backplane/auth/resource_auth_plug.ex`; config loader/validator and their tests; `config/runtime.exs`; gateway and system application startup validation if needed; `apps/backplane_auth/test/backplane/auth/resource_auth_*`; `apps/backplane_api/test/backplane/api/auth/resource_auth_compatibility_test.exs`; config examples/docs limited to removed credentials.

- [x] Add failing cases proving configured shared tokens cannot authorize and that malformed/new-token misses cannot fall through; add secret-free configuration rejection tests.
- [x] Remove `:legacy` bearer authorization and preserve verified-OAuth rejection, scopes, both headers, conflict rejection, 503 and existing open-mode conditions.
- [x] Reject nonempty `auth_token`/`auth_tokens` and token-bearing client seeds before any public listener can start; errors name keys only. Metadata-only seeds must be idempotent and cannot rotate credentials.
- [x] Update scoped fixtures to trusted issuance. Retain production-cache integration cases for inactive/NULL clients, resource failures, mutation and restart/lease behavior.
- [x] Run auth and API auth/config suites under the shared Mix lock.

```elixir
Application.put_env(:backplane, :auth_token, "retired-token")
conn = authenticated_request("retired-token")
assert conn.status == 401
# Boot preflight raises on this key without echoing its value.
```

## Task 3: Management and secret delivery (coordinator)

Files: `apps/backplane_admin/lib/backplane/admin/live/clients_live.ex` and tests; `apps/backplane_mcp/lib/backplane/tools/admin.ex`; new small sensitive-result policy module; `transport/idempotency.ex`, `task_manager.ex`, necessary `mcp_handler.ex`/transport response header integration; their focused tests; remaining client fixture/direct call adapters in gateway/API/Llama/admin/MCP tests.

- [x] Write failing native-tool tests for generated creation/explicit rotation and rejection of arbitrary token input; write sensitive-result replay/task rejection tests before production edits.
- [x] Use shared issuance APIs in UI and native tool. Creation returns the generated token after commit; ordinary updates keep the credential; `rotate_token: true` rotates. Keep token display transient and show unissued clients.
- [x] Define one sensitive-tool predicate for `admin::upsert-client`. Detect it before idempotency lookup, including batches; reject supplied idempotency keys before execution; never cache its response and add `Cache-Control: no-store`.
- [x] Reject that tool inside TaskManager before storing arguments or starting work. Keep metadata/hash-only observability and sanitize secret-bearing errors.
- [x] Adapt remaining client fixtures to use actual issued tokens and remove references to the retired client hash. Do not change password/session/host-agent token hashing.
- [x] Run focused management, MCP transport and affected API/Llama suites.

## Task 4: Integration, review and evidence (coordinator)

- [x] Review implementation against every design invariant, then perform code-quality/security review with a separate agent. Resolve concrete findings and rerun affected checks.
- [x] Run combined scoped tests, format checks, and warnings-as-errors compilation. Record unrelated baseline failures separately; do not repair unrelated domains.
- [x] Run the production-path benchmark in a dedicated empty test database, confirm zero bcrypt/SQL/verification tasks for valid and invalid request paths and compare scaling; report background refresh separately.
- [x] Write one operations report explaining final behavior, actual test/measurement evidence, destructive cutover and rollback limits. Update the approved design status and this checklist to actual results.
- [x] Inspect `git diff --check` and final status; deliver code and measured limits without a release or deployment.
