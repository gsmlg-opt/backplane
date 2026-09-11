# Skill Protocol v1 Verification

Status: partial as of 2026-09-11. AC-07 has new malicious-archive coverage, but the current checkout does not compile because the AC-12 cross-process cache ownership repair is incomplete. Static review also found that concurrent stale-claim recovery can move a newly acquired live claim because reclamation does not verify that the path still names the stale claim that was read. The earlier BP-06 evidence and artifact predate that repair.

## Environment And Provenance

- Repository: `gsmlg-opt/backplane` at `/Users/gao/Workspace/gsmlg-opt/backplane`.
- Branch: `feature/skill-protocol`.
- Baseline HEAD: `bd5bc83005fded6f67beefe3fa8abac31eae506a`.
- Host: macOS, Elixir 1.20.1, Erlang/OTP 29, Mix 1.20.1.
- Supported target: Elixir >= 1.18 and OTP 28+; focused CI pins Elixir 1.18.4 and OTP 28.5.0.5.
- Checkout state: BP-00 through BP-06 were uncommitted in a shared dirty worktree. The verifier copied reviewed package files and created an isolated temporary Git repository and commit solely to exercise pinned sparse Git-subdirectory dependency mechanics. It did not commit, stash, reset, or modify checkout history.
- External systems: no live deployment, external consumer repository, or live credential was needed. PostgreSQL-backed tests used the repository test database and isolated fixtures.

Unless stated otherwise, commands ran from the repository root and exited 0. Passing package commands below were recorded before the current cross-process ownership repair.

## Executed Checks

| Command | Result |
| --- | --- |
| `cd apps/backplane_skill_protocol && mix compile --warnings-as-errors` | **Failed on the current checkout.** `cache.ex:510` invokes `System.pid/0` in a guard, which Elixir rejects. No current package test suite can run until this is repaired. |
| `cd apps/backplane_skill_protocol && MIX_ENV=test mix run --no-compile -r test/support/archive_helpers.ex -r test/test_helper.exs -r test/backplane/skill_protocol/bundle_test.exs` | 6/6 bundle tests passed against the previously compiled package, including new USTAR hardlink and character-device rejection cases. This is focused evidence only and does not replace a clean compile and normal test run. |
| `nix shell nixpkgs#expect -c unbuffer bash scripts/verify_skill_protocol_package.sh` | Copied package compiled with warnings as errors; 35/35 tests passed; Hex artifact build/unpack/content checks passed; fresh production sparse Git consumer compiled; dependency isolation, parser, local resources, and loopback TCP client/source/cache flow passed. |
| `cd apps/backplane_skill_protocol && mix test` | 35/35 package tests passed. |
| `cd apps/backplane_skill_protocol && MIX_ENV=prod mix compile --warnings-as-errors` | Passed. |
| `mix test apps/backplane_skills/test/backplane/skills/loader_test.exs apps/backplane_skills/test/backplane/skills/archive_test.exs apps/backplane_skills/test/backplane/skills/ingest_test.exs apps/backplane_skills/test/backplane/skills/export_test.exs apps/backplane_skills/test/backplane/skills/api_router_test.exs` | 73/73 legacy compatibility tests passed. |
| `mix test apps/backplane_skills/test/backplane/skills/publication_test.exs` | 8/8 publication and retention tests passed. |
| `mix test apps/backplane_memory/test/backplane/memory/generated_skills_test.exs` | 9/9 generated-skill tests passed. |
| `mix test apps/backplane_system/test/backplane/repo/migrations/create_skill_revisions_test.exs` | 2/2 isolated-schema migration tests passed. |
| `mix test apps/backplane_auth/test/backplane/auth/resources_test.exs apps/backplane_auth/test/backplane/auth/token_resources_test.exs apps/backplane_auth/test/backplane/auth/resource_auth_plug_test.exs` | 52/52 scoped authorization tests passed. |
| `mix test apps/backplane_api/test/backplane/api/auth/discovery_controller_test.exs apps/backplane_api/test/backplane/api/auth/resource_auth_compatibility_test.exs apps/backplane_api/test/backplane/api/auth/resource_oauth_e2e_test.exs` | 20/20 API authorization/discovery compatibility tests passed. |
| `nix shell nixpkgs#expect -c unbuffer mix test apps/backplane_api/test/backplane/api/skill_protocol_http_integration_test.exs apps/backplane_api/test/backplane/api/skill_protocol_router_test.exs apps/backplane_api/test/backplane/api/skill_protocol_telemetry_test.exs` | 9/9 protocol API tests passed, including actual loopback HTTP. |
| `MIX_ENV=test nix shell nixpkgs#expect -c unbuffer mix run test/ci_workflow_test.exs` | 4/4 workflow contract tests passed after adding `backplane_skill_protocol` to the main test matrix. |
| Focused `YamlElixir` assertion via `MIX_ENV=test ... mix run -e` | Parsed `.github/workflows/skill-protocol.yml`; verified standalone/integration job split, package verifier, PostgreSQL apt source, and umbrella-root API test command. |

The API/auth runs emitted an asynchronous `Backplane.Clients.touch_last_seen/1` Ecto sandbox-owner shutdown log after the requesting test owner ended. ExUnit exited 0 and all affected tests passed. This is retained as test noise and a residual harness risk, not reported as a failed assertion.

## Artifact

- Path: `tmp/skill-protocol-package.TQ56eP/backplane_skill_protocol-0.1.0.tar`
- SHA-256: `0a68c4e5fa1b140a9eb31e917b82fcfb64d4cb36e933e57494ea98521d465bd1`
- Contents were built by `mix hex.build`, unpacked by `mix hex.build --unpack`, and checked for package metadata, README, and protocol schemas.
- The artifact is local, ignored verification output. It was not published.
- The artifact predates the current hardlink/device tests and cross-process cache ownership changes. It is retained as historical evidence, not a build of the current checkout.

Older ignored `tmp/skill-protocol-package.*` directories are not provenance for this result.

## Acceptance Matrix

| AC | Status | Evidence |
| --- | --- | --- |
| AC-01 | Verified | Full verifier copied the package outside the umbrella and compiled a fresh pinned sparse Git consumer in `MIX_ENV=prod`; dependency tree excluded host apps, Ecto, Postgrex, and Phoenix. |
| AC-02 | Verified | Package parser/validator fixtures cover YAML variants, exact bytes, duplicate keys, line endings, extensions, comments, and limits within the 35-test suite. |
| AC-03 | Verified | 73 legacy tests plus publication diagnostics prove covered fields/reads remain compatible without fabricated v1 metadata. |
| AC-04 | Verified | Package discovery/resolution and canonical resource-root tests cover deterministic conflicts, qualified references, escaping links, and loops. |
| AC-05 | Verified | Package eligibility tests cover automatic/explicit triggers, manual-only, host disablement, and capability policy without granting tools. |
| AC-06 | Verified | Bundle tests and consumer verifier read entrypoint, nested reference, binary asset, and script bytes without execution. |
| AC-07 | Partial | New hardlink and character-device cases pass in the focused no-compile run, alongside existing traversal, symlink, collision, expansion, cancellation, and containment coverage. A normal clean-compile test run remains blocked by AC-12's compile error. |
| AC-08 | Verified | Publication and real HTTP tests publish A then B and continue resolving/fetching exact A metadata and bytes. |
| AC-09 | Verified | Eight publication tests cover dry-run/apply idempotence, competing publishers, failed replacement, and shared retained blobs. |
| AC-10 | Verified | Nine generated-skill tests cover stable immutable publication and honest invalid/missing-source diagnostics. |
| AC-11 | Verified | Nine real server/client tests cover pagination, opaque IDs, retained/missing revisions, legacy routes, and disabled/deleted/denied reads. |
| AC-12 | Blocked | Cross-process exclusive-root ownership and a real subprocess test were added, but the current implementation does not compile because `System.pid/0` is called in a guard at `cache.ex:510`. In addition, two contenders can both read a stale PID; after one installs a new live claim, the other's unconditional `File.rename/2` at `cache.ex:531` can move that new claim and take ownership. Existing tests cover one crashed owner and one reclaimer, not concurrent reclaimers, so the required process boundary remains unproved. |
| AC-13 | Verified | Package client tests cover shared deadlines, bounded retries, cancellation, malformed data, terminal integrity failure, response bounds, and redirect refusal. |
| AC-14 | Verified | Cache/source tests cover disabled-by-default offline mode, exact age-bounded reuse, source/context/revision isolation, expiry, and persisted denial blocks. |
| AC-15 | Verified | Cache tests retain active prepared resources across refresh/cleanup and return explicit capacity errors without eviction. |
| AC-16 | Verified | Backplane loader/archive/ingest paths use the shared package while the 73 legacy tests pass. |
| AC-17 | Verified | Package consumer fixture and Backplane HTTP integration use the same parser, manifest, digest, resource, client, cache, and source APIs for equivalent exact content. External adopter integration is not claimed. |
| AC-18 | Verified | Two migration tests prove guarded retained-revision rollback and clean empty rollback/reapply; `migration.md` documents staged upgrade, retention, withdrawal, and rollback. |

## Invalid Validation Attempts

These commands are recorded separately and are not passing evidence:

- `mix do --app backplane_skills cmd mix test ...` ran 55/73 assertions and failed 18 API router tests because the command excluded `Backplane.Api.Endpoint`. The correct umbrella-root 73-test command passed.
- `mix test test/ci_workflow_test.exs` in the umbrella printed a no-match message for each child application and exited 0. The valid `MIX_ENV=test mix run test/ci_workflow_test.exs` invocation first exposed the missing package matrix entry, then passed 4/4 after the scoped repair.
- `unbuffer -- ...` is unsupported by Expect 5.45.4. Successful checks use `unbuffer mix ...` or `unbuffer bash ...`.

## Deferred And Skipped Work

No Sigma, Synapsis, Samgita, or host-agent repository was changed or tested as a Skill Protocol consumer. Their adoption is a later assignment described in `consumer-handoff.md`. No Hex publish, commit, push, deploy, production migration, destructive rollback, live external endpoint, or live credential test was performed or required for BP-06.
