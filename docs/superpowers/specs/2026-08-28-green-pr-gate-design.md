# Honest Green PR Gate Design

**Date:** 2026-08-28
**Status:** Approved
**Branch:** `codex/green-pr-gate`
**Worktree:** `.trees/green-pr-gate`

## Goal

Restore a trustworthy pull-request gate for the Backplane umbrella: every application must compile and test independently, static analysis must report real source failures without formatter crashes, and the CI toolchain must be reproducible.

## Context

At commit `55835fbd799c81238e455446f8fa43701a5adda6`, Compile and Format pass while Test, Credo, and Dialyzer fail.

The clean-worktree baseline reproduces the first Test failure:

- `apps/backplane_memory/test/backplane/memory/query_log_privacy_test.exs` cannot load `Backplane.DataCase` when `backplane_memory` is tested independently.
- Multiple `Backplane.Fixtures` and `Example.*` modules are compiled from more than one application's `test/support` tree.
- The current Test workflow runs only three complete application suites plus one MCP test file despite the umbrella containing 17 applications.
- Credo reports tautological numeric checks, discarded sandbox authorization results, localized refactoring findings, and one typespec problem.
- Dialyxir 1.4.7's GitHub formatter crashes on OTP's `:opaque_compare` warning before exposing the underlying source location.

## Scope

This milestone contains three bounded changes:

1. Normalize test-support ownership and remove compiled-module collisions.
2. Repair the current Credo and Dialyzer failures without weakening either analyzer.
3. Replace the partial Test workflow with an independent 17-application matrix and run static checks on pull requests.

The Admin security boundary, supervised application bootstrap, Memory protocol governance, repository version source, Docker metadata, broad README refresh, and release publication are separate milestones.

## Test-Support Ownership

`BackplaneDataCase` remains the low-level, repository-agnostic Ecto sandbox primitive. It owns only `setup_sandbox/2` and does not depend on `Backplane.Repo`.

Each database-using application owns its test case wrapper and domain helpers. Existing wrappers remain canonical rather than being renamed for cosmetic consistency:

- `Backplane.DataCase`
- `Backplane.Auth.DataCase`
- `BackplaneLlama.DataCase`
- `BackplaneMcp.DataCase`
- `Backplane.Memory.DataCase`
- `BackplaneSkills.DataCase`
- `BackplaneSystem.DataCase`

Admin and API tests use their existing LiveCase/ConnCase boundaries or receive an application-local DataCase only when a DB-only test has no suitable case. Applications that call `BackplaneDataCase.setup_sandbox/2` directly and do not need shared imports do not gain an unused wrapper.

All stale cross-application `Backplane.DataCase` references move to their owning application's case or connection/live case. `Backplane.DataCase` remains valid only inside the `backplane` application.

Parser input samples move out of compiled `test/support` paths into `test/fixtures`, preserving their source text while preventing `Example.*` modules from entering BEAM code paths. Fixture helper modules that execute as test code receive application-owned namespaces rather than sharing `Backplane.Fixtures`.

The Testing Conventions section in `AGENTS.md` is updated to describe the shared primitive plus per-application wrappers.

## Numeric Validation

Memory numeric validation uses a small, process-free `Backplane.Memory.Numeric` module. It expresses domain contracts rather than pretending that `value == value` detects a representable BEAM NaN.

The module provides only predicates used by multiple callers, such as:

- a numeric value in the inclusive unit interval;
- a non-negative numeric value with the existing upper bound;
- integer-to-float normalization where callers require a float.

Callers retain their existing public behavior: invalid external scores are rejected, converted into the existing validation error, or sent through the existing fallback path. This milestone does not change ranking weights, score ranges, ordering, or packing behavior.

## Crystal Worker Sandbox Semantics

`CrystalWorker` distinguishes production pools from SQL Sandbox pools.

- A production pool needs no sandbox allowance and returns `:ok`.
- A Sandbox pool searches the current process and `$callers` for an owner.
- `:ok` and `{:already, _}` are successful authorization outcomes.
- Failure to find an owner returns an explicit worker error instead of discarding the result.
- Unexpected authorization failures remain visible rather than being folded into `:ok`.

Tests cover normal production-pool behavior, successful allowance, already-authorized allowance, and missing ownership. The task is not sent its run message when required sandbox authorization fails.

## Remaining Credo Findings

The localized `Lease.acquire/4`, Recall partition handling, and Context partition findings are simplified only enough to satisfy the enabled Credo checks while preserving return values and error tuples. `Backplane.Proxy.Upstreams.runtime_config/1` receives the narrow typespec correction required by its actual accepted input.

No Credo check is disabled and no affected file is excluded.

## Dialyzer Strategy

Dialyzer remediation follows an evidence-first sequence:

1. Run Dialyzer with raw output to reveal the `:opaque_compare` source location.
2. Fix genuine source defects.
3. If a warning is a verified OTP/Ecto false positive, retain only an exact `{file, warning_description}` ignore.
4. Upgrade or configure Dialyxir so `--format github` completes successfully on the pinned OTP version.

Broad file ignores, warning-category suppression, and CI `continue-on-error` are prohibited.

## CI Topology

The static CI workflow runs for both `push` and `pull_request` and retains separate Compile, Format, Credo, and Dialyzer jobs.

The Test workflow uses `strategy.fail-fast: false` and one matrix entry for each umbrella application:

1. `backplane`
2. `backplane_admin`
3. `backplane_api`
4. `backplane_auth`
5. `backplane_data_case`
6. `backplane_host_agent`
7. `backplane_llama`
8. `backplane_mcp`
9. `backplane_mcp_protocol`
10. `backplane_memory`
11. `backplane_monitor`
12. `backplane_skills`
13. `backplane_system`
14. `backplane_telemetry`
15. `day_ex`
16. `math_ex`
17. `relayixir`

Each matrix job checks out the same revision, restores lock-keyed caches, starts PostgreSQL 17 with pgvector, creates and migrates the test database, and runs the selected application's normal test suite. Existing explicit integration-tag exclusions remain unchanged; release qualification continues to own those external-service checks.

All matrix entries run even after an earlier failure. Any failed entry makes the workflow red. Tests are not retried and no application is marked `continue-on-error`.

Toolchains used by these workflows are pinned to resolved versions rather than moving labels:

- Elixir 1.18.4
- OTP 28.5.0.5 for GitHub Actions
- Bun 1.3.13 where Bun is invoked
- Rust 1.95.0 where Rust is invoked

No unused setup step is added solely to mention a toolchain.

## Verification

Verification occurs from the isolated worktree with its own PostgreSQL process and migrated test database.

Required checks are:

- every one of the 17 application suites passes independently;
- `mix compile --warnings-as-errors` passes;
- `mix format --check-formatted` passes;
- `mix credo --strict` passes;
- Dialyzer succeeds with both raw and GitHub formatters;
- workflow syntax validation passes;
- `git diff --check` passes;
- GitNexus change detection reports only the intended test-support, Memory-quality, MCP typespec, and CI surfaces.

The implementation uses focused red/green tests before broader application-suite verification. Pre-existing failures outside this approved milestone are reported and left untouched.

## Delivery

Changes are organized as reviewable Conventional Commits for test-support ownership, code-quality remediation, and CI coverage. The branch is not pushed, merged, or released without explicit follow-through authorization.

After the implemented fixes are verified, an Agent Note is saved with label `project: backplane`, summarizing the changes, validation evidence, commit identifiers, and any remaining external failures.
