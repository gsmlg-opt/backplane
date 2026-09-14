# Skill Protocol v1 Verification

Status: the 2026-09-14 user-directed consumer scope correction is implemented and its focused checks pass. Consumer caching, offline fallback, ownership coordination, and native locking are removed; server publication and retained-artifact behavior remain in scope and passed affected regressions.

## Environment And Provenance

- Repository: `gsmlg-opt/backplane` at `/Users/gao/Workspace/gsmlg-opt/backplane`.
- Branch: `feature/skill-protocol`.
- Baseline HEAD: `1c01f444ef3dff4289c0d596d8a6cde4cf2efde9`.
- Verification state: implementation originally verified against that baseline HEAD before commit.
- Host: macOS, Elixir 1.20.1, Erlang/OTP 29, Mix 1.20.1.
- Supported target: Elixir >= 1.18 and OTP 28+; focused CI pins Elixir 1.18.4 and OTP 28.5.0.5.
- No external consumer repository, live endpoint, live credential, deployment, publication, or production migration was used.

## Executed Checks

| Working directory and command | Result |
| --- | --- |
| `apps/backplane_skill_protocol`: `mix deps.get` | Passed; package runtime dependencies resolved without direct `elixir_make`. |
| `apps/backplane_skill_protocol`: `mix clean && mix compile --warnings-as-errors` | Passed from fresh development build; 22 library files compiled. |
| `apps/backplane_skill_protocol`: `mix test` | Passed, 35/35 tests. This includes parser, validator, discovery, bundle safety, client deadline/cancellation, resource, telemetry, and cache-free remote Source coverage. |
| `apps/backplane_skill_protocol`: `MIX_ENV=prod mix clean && MIX_ENV=prod mix compile --warnings-as-errors` | Passed from fresh production build; 22 library files compiled. |
| repository root: `bash scripts/verify_skill_protocol_package.sh` | Passed. Copied package compiled/tested; Hex artifact built and unpacked; schemas and README present; C source, Makefile, cache directory, and native lock binary absent; fresh production sparse Git consumer compiled and completed parser, bundle/resource, and loopback cache-free Source use. |
| repository root: focused Skills/API suites | The focused loader/archive/ingest/publication, generated-Skill, HTTP integration, router, and telemetry suites passed in the clean verification run. The standalone protocol package and the new malformed-query/router regression file pass independently (35/35 and 8/8 respectively). |
| repository root: `mix format --check-formatted` | Passed. |
| repository root: `git diff --check` | Passed after the final documentation update. |
| repository root: `mix credo --strict` | Failed with exit 12 after scanning 1,423 files. Two line-length findings were fixed in this change; the remaining report is four pre-existing arity-9 refactoring opportunities in unchanged `apps/backplane_skill_protocol/lib/backplane/skill_protocol/source/local.ex`. |
| repository root: `mix test` (full umbrella) | Failed with unrelated existing MCP, telemetry, memory, and Ecto sandbox-owner failures; no failure was reported from the focused protocol package or router regression tests. |
| repository root: `mix dialyzer` | Not completed: first-run PLT construction remained CPU-bound for over 20 minutes and was interrupted; no diagnostic result was obtained. |

The standalone verifier emitted `yamerl` deprecation warnings under OTP 29. The umbrella test run emitted existing compile warnings and asynchronous Ecto sandbox-owner shutdown logs after tests. All listed ExUnit suites still exited 0. These were not changed because their source is outside this correction.

## Artifact

- Path: `tmp/skill-protocol-package.ma0BgC/backplane_skill_protocol-0.1.0.tar`.
- SHA-256: `abca681835be5708e02156daa45ec92e69956db92cc660a766e978d8958fb273`.
- Built and unpacked by the current verifier from the uncommitted package snapshot.
- Contains Elixir library code, README, and v1 schemas. It contains no `c_src`, package `Makefile`, `lib/backplane/skill_protocol/cache` directory, or `priv/cache_native_lock.so`.
- The artifact is local ignored verification output and was not published.

## Acceptance Matrix

| AC | Current status | Evidence |
| --- | --- | --- |
| AC-01 | Verified | Current copied-package and sparse Git consumer verifier passed in production dependency mode without host/database apps. |
| AC-02 | Verified | Current 32-test package suite covers parser/validator fixtures and preserved source bytes. |
| AC-03 | Verified | Current 59-test Skills run covers affected legacy loader/archive/ingest behavior and publication diagnostics. |
| AC-04 | Verified | Current package discovery/resolution and resource containment tests passed. |
| AC-05 | Verified | Current package eligibility/capability tests passed without granting execution. |
| AC-06 | Verified | Current Source and bundle tests read `SKILL.md`, nested reference, binary asset, and script source without execution. |
| AC-07 | Verified | Current clean package suite covers cancellation, traversal, unsafe links/types, collisions, malformed archives, and size limits without out-of-root writes. |
| AC-08 | Verified | Current publication and real HTTP tests retain and fetch exact A after publishing B. |
| AC-09 | Verified | Current publication tests cover idempotence, competing publishers, failed replacement, and shared retained blobs. |
| AC-10 | Verified | Current 9-test generated-Skill run covers stable immutable publication and honest invalid/missing-source diagnostics. |
| AC-11 | Verified | Current nine API tests cover real HTTP, search/pagination, opaque IDs, retained revisions, disabled reads, and telemetry. |
| AC-12 | Verified | Current one-shot Source tests require a fresh destination, reject existing and dangling-link destinations before network access, forward cancellation, and expose no prepared path on failure. Bundle publication uses staging and atomic rename. |
| AC-13 | Verified | Current client/bundle tests cover shared deadlines, bounded retries, cancellation, malformed data, digest failure, response limits, and redirect refusal. |
| AC-14 | Verified | Current Source request-count test proves two uses perform two artifact downloads; a later remote error is returned without fallback and earlier content remains readable. |
| AC-15 | Verified | Current Source tests prove returned resources remain readable and failed/new destinations do not modify earlier or unrelated files. Lifetime and cleanup are host-owned. |
| AC-16 | Verified | Current 59-test Skills run proves affected loader/archive/ingest paths continue using the shared package. |
| AC-17 | Verified | Current standalone consumer and actual loopback HTTP integration exercise the same cache-free Source API. No external adopter is claimed. |
| AC-18 | Not rerun | Migration and rollback behavior was not changed. The earlier 2/2 isolated migration result is historical evidence only, not a current execution result. |

## Superseded Historical Evidence

The 2026-09-11 verification recorded 35 package tests, consumer cache/offline/ownership checks, a native artifact, and a later cache-ownership compile blocker. Those results describe the removed product scope and are not evidence for the current implementation. The earlier package artifact and checksum remain historical local outputs only; the current artifact above replaces them for this handoff.

## Not Run

- Migration tests, authorization suites, and CI workflow-contract tests were not rerun. Dialyzer was attempted but did not complete during the first-run PLT build. The full umbrella `mix test` was run and failed on unrelated existing MCP, telemetry, memory, and Ecto sandbox-owner paths as recorded above.
- Sigma, Synapsis, Samgita, and host-agent adoption remain deferred.
- No package publication, deployment, or production migration was performed.
