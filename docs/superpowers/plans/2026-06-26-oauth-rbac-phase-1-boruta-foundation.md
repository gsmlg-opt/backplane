# OAuth RBAC Phase 1 Boruta Foundation Implementation Plan

> For agentic workers: use superpowers:subagent-driven-development or
> superpowers:executing-plans to implement this plan task-by-task.

## Goal

Add the Boruta OAuth storage foundation required by `docs/oauth-design.md` without
exposing user-facing OAuth routes or changing MCP authorization behavior.

## Scope Boundary

This plan implements only Phase 1 from the design. Later phases remain separate
hard stops:

1. Identity plus federated login.
2. RBAC roles, assignments, and effective scope resolution.
3. MCP protected-resource metadata, OAuth challenges, and token introspection.
4. Authorization server routes: `/authorize`, `/token`, `/register`,
   callbacks, and logout.
5. Admin UI for providers, roles, users, and OAuth clients.
6. Hardening: telemetry, pruning jobs, and host-agent design updates.

## Architecture

Boruta belongs in `backplane_system` because it is an Ecto-backed system/data
concern shared by future API and admin surfaces. Phase 1 configures Boruta to
use `Backplane.Repo`, adds its dependency, creates Boruta-owned tables, and
proves the Ecto admin contexts can persist scopes and clients.

The Boruta `2.3.6` generator/migration history starts from unprefixed tables
(`clients`, `tokens`, `scopes`, `clients_scopes`) and later renames them to
`oauth_*`. Backplane already owns a `clients` table, so this implementation uses
a hand-authored squashed migration that creates the final `oauth_*` tables
directly.

Do not run `mix boruta.gen.migration` for the initial install in this repo; the
generator checks for its own historical filenames and would not recognize this
squashed migration as already applied.

Configuration uses Boruta's current namespace:

```elixir
config :boruta, Boruta.Oauth,
  repo: Backplane.Repo,
  issuer: "http://localhost:4220"
```

Production sets the issuer from `BACKPLANE_API_URL` or the resolved API host and
port. Test config sets the issuer to the test API URL.

## Changed Files

- `apps/backplane_system/mix.exs` adds `{:boruta, "~> 2.3"}`.
- `mix.lock` records Boruta `2.3.6` and transitive dependencies.
- `config/config.exs` configures Boruta with `Backplane.Repo`.
- `config/test.exs` sets the Boruta test issuer.
- `config/runtime.exs` sets the production Boruta issuer from the public API URL.
- `apps/backplane_system/priv/repo/migrations/20260626000001_create_boruta_oauth_tables.exs`
  creates `oauth_clients`, `oauth_scopes`, `oauth_clients_scopes`, and
  `oauth_tokens`.
- `apps/backplane_system/test/backplane/accounts/boruta_foundation_test.exs`
  verifies config, table isolation, and Boruta Ecto persistence.
- `apps/backplane_monitor/lib/backplane/monitor/providers/claude_code.ex` adds
  `# TODO(upstream): gsmlg-dev/denox#3` at the Denox callsite because full-suite
  verification is blocked by a pre-existing Denox crash.

`AGENTS.md` and `CLAUDE.md` are dirty in the worktree but were pre-existing and
are intentionally outside this plan's scope.

## Acceptance Criteria

- [x] `Boruta.Ecto.Client`, `Boruta.Ecto.Scope`, and `Boruta.Ecto.Token` compile.
- [x] Boruta is configured to use `Backplane.Repo`.
- [x] Boruta issuer follows Backplane's API URL in test and production config.
- [x] Boruta tables use `oauth_*` names and do not collide with Backplane's
      existing `clients` table.
- [x] A test creates a scope and PKCE client through Boruta's Ecto admin context.
- [x] No `/mcp`, `/authorize`, `/token`, `/register`, identity, RBAC, or admin UI
      behavior is added in this phase.
- [ ] Full umbrella `mix test` passes. Blocked by pre-existing
      `gsmlg-dev/denox#3`, reproduced on `main` and isolated to
      `apps/backplane_monitor/test/backplane/monitor/providers/claude_code_test.exs`.

## Execution Checklist

- [x] Read `docs/oauth-design.md` and identify Phase 1 as the correct stopping
      point.
- [x] Dispatch parallel subagents to inspect data ownership, API/MCP boundaries,
      admin UI boundaries, and Boruta dependency/migration shape.
- [x] Create isolated worktree
      `.trees/codex-oauth-rbac` on branch `codex/oauth-rbac`.
- [x] Run GitNexus impact checks before edits. GitNexus did not find the edited
      Elixir symbols and reported unknown risk.
- [x] Write the Boruta foundation regression test and confirm it failed before
      dependency/config/migration implementation.
- [x] Add Boruta dependency and fetch dependencies with
      `devenv shell -- mix deps.get`.
- [x] Configure Boruta under `config :boruta, Boruta.Oauth`.
- [x] Inspect Boruta `2.3.6` schemas and migration history.
- [x] Add squashed `oauth_*` migration instead of running the historical
      unprefixed generator output.
- [x] Run test migration with `MIX_ENV=test mix ecto.migrate`.
- [x] Run focused Boruta foundation tests.
- [x] Run affected existing PAT/client/auth tests.
- [x] Run full umbrella test suite.
- [x] Reproduce the full-suite crash in the smallest affected test file.
- [x] Reproduce the crash on `main` to confirm it predates this branch.
- [x] Create upstream Denox issue `gsmlg-dev/denox#3` and mark the callsite.
- [x] Run GitNexus detect changes before close-out. It returned no detected
      changes despite the git diff, so direct diff inspection and tests are the
      source of truth.

## Verification

Passed:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/accounts/boruta_foundation_test.exs
```

Result: `3 tests, 0 failures`.

Passed:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/transport/auth_plug_test.exs apps/backplane_system/test/backplane/clients_test.exs apps/backplane_system/test/backplane/clients/client_test.exs
```

Result: `37 tests, 0 failures`.

Blocked:

```bash
devenv shell -- mix test
```

The umbrella suite compiled and completed multiple apps, including
`backplane_system` with `303 tests, 0 failures`, then exited `139` while running
`backplane_monitor`. The same
`apps/backplane_monitor/test/backplane/monitor/providers/claude_code_test.exs`
file exits `139` on `main`, while each individual line-targeted test in that
file passes. Upstream issue:
https://github.com/gsmlg-dev/denox/issues/3.

## Next Phase Entry Criteria

Do not start identity/RBAC/API route work until Phase 1 is accepted and the
Denox full-suite blocker is resolved or the user explicitly chooses to proceed
with scoped verification only.
