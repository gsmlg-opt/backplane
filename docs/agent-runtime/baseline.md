# Shared Agent Runtime Baseline

## Historical local inventory (2026-09-10)

| Item | Evidence |
| --- | --- |
| Backplane branch / SHA | `main` / `bd5bc83005fded6f67beefe3fa8abac31eae506a` |
| Backplane worktree | Untracked `docs/agent-runtime/`; no tracked-file modifications at T00 entry |
| Elixir / OTP | 1.18.4 / 28 (ERTS 16.4.0.1) |
| CI toolchain pins | Elixir 1.18.4; OTP 28.5.0.5; Rust 1.95.0 |
| Umbrella packages | 17 existing `apps/*/mix.exs` projects |
| Proposed runtime packages at that date | `apps/backplane_agent_runtime`, `apps/backplane_agent_tools` (new) |

These toolchain values, package count, and consumer searches are dated evidence from 2026-09-10. They were not refreshed on 2026-09-14 and must not be read as a current environment inventory.

## Current checkout and bounded consolidation (2026-09-14)

| Item | Evidence |
| --- | --- |
| Backplane branch / base SHA | `feature/agent-runtime` / `c36ccf619e0083c3de1f112e2c54ae6ef50289dd` |
| Worktree boundary | The three single-package documents had pre-existing user revisions. The bounded consolidation and this evidence update remain uncommitted. |
| Sole target application | `apps/backplane_agent_runtime` / `:backplane_agent_runtime` |
| Canonical tool facade | Existing `Backplane.AgentRuntime.Tools` remains the facade for optional port-backed tool families. |
| Bundled local adapters | `Backplane.AgentRuntime.Tools.LocalResource` and `Backplane.AgentRuntime.Tools.LocalCommand` |
| Removed tracked split surface | The `:backplane_agent_tools` Mix project, `Backplane.AgentTools` forwarding facade, duplicate facade tests, and both committed generated package archives were removed from the working tree. No compatibility namespace is retained. |
| Package harness | `scripts/verify_agent_runtime_package.sh` builds one temporary artifact and exercises fresh `empty_tool`, `bundled_basic`, and `fake_backend` consumers against its unchanged SHA-256 hash. |
| Publication state | The consolidation remains staged/unstaged and uncommitted at this evidence point. No push or pull request has occurred; publication is a separate authorized step after review. |

This is a bounded consolidation of an existing draft implementation. It does not implement T18 or later consumer adoption, complete all V1 tool families, or establish a milestone gate.

## Consumer repositories

Sigma and Synapsis checkouts were not present under the searched local roots
(`/home/gao/Workspace`, `/data/development`) at the 2026-09-10 baseline time.
Their SHAs remain unknown. Historical design references from
`gsmlg-opt/sigma@a7cbf4acf63f8ad1357c492e1eee49817f302cba` and
`gsmlg-opt/Synapsis@fe4ebf7d70d58ec46c1055f22e7c13cb455d8700` remain integration
seams, not current-state evidence.

This is a baseline gap for T00 consumer-path inventory and M4 adoption gates. It
does not block T01 scaffold work. Consumer inventories must be completed in their
repositories before claiming Sigma, Synapsis QueryLoop, or Synapsis graph
migration.

## Sibling contract availability

`backplane_ai_protocol` and `backplane_skill_protocol` are not present as
Backplane umbrella applications and no published version has been verified. The
runtime therefore declares no sibling production dependency and uses scripted
provider test ports for independent core work. Adding a provider/Skill boundary
requires first resolving their standalone release and API.

## Current package target contract

- Runtime namespace: `Backplane.AgentRuntime`.
- Bundled tools namespace: `Backplane.AgentRuntime.Tools.*`.
- Production package has no compulsory optional backend dependency.
- Runtime application starts no agents, tools, services, databases, Phoenix
  processes, or Backplane applications.
- Public identifiers are opaque serializable strings.
- The kernel accepts injected time and normalized external inputs.

## Clean-consumer fixture target and current limit

The fixture generator and verification script are intended to document package-only
consumers under `test/agent_runtime_packages/`. The required profiles remain
empty-tool, bundled-basic, and fake-backend, all consuming the identical
single-package artifact/version. They must remove umbrella-relative
build/config/dependency assumptions and must not resolve a second tools package.

The verifier's dependency scan is limited to the extracted Mix manifest, avoiding false matches against ordinary resource maps. The complete verifier passed on 2026-09-14. It confirmed the bundled adapters and launcher, one Mix application, no old tools namespace, no umbrella source dependency, an empty production dependency list, the selected generic-layer boundary, and identical artifact hash across all three fresh consumers. The fixtures cover inert empty-tool startup, an actual local resource read and local command invocation plus plan revisions, and fake Memory/Skill ports with a cross-scope denial. They do not represent the full V1 acceptance matrix.

## Focused test evidence

Direct application tests used C1 from the named application directory. Verifier commands used the repository root. No explicit environment assignment was supplied; `COREUTILS` was unset during the pre-refactor tools baseline.

```sh
# C1
if command -v unbuffer >/dev/null 2>&1; then unbuffer mix test; else mix test; fi

# C2, consolidation verifier attempt
if command -v unbuffer >/dev/null 2>&1; then unbuffer bash scripts/verify_agent_runtime_package.sh; else bash scripts/verify_agent_runtime_package.sh; fi

# C3, syntax-only verifier check
bash -n scripts/verify_agent_runtime_package.sh

# C4, historical split verifier attempt
if command -v unbuffer >/dev/null 2>&1; then unbuffer bash scripts/verify_agent_runtime_packages.sh; else bash scripts/verify_agent_runtime_packages.sh; fi

# C5, reopened focused adapter test
if command -v unbuffer >/dev/null 2>&1; then unbuffer mix test test/backplane/agent_runtime/tools/local_resource_test.exs test/backplane/agent_runtime/tools/local_command_test.exs; else mix test test/backplane/agent_runtime/tools/local_resource_test.exs test/backplane/agent_runtime/tools/local_command_test.exs; fi

# C6, package formatting and compilation
if command -v unbuffer >/dev/null 2>&1; then unbuffer mix format --check-formatted && unbuffer mix compile --warnings-as-errors; else mix format --check-formatted && mix compile --warnings-as-errors; fi

# C7, complete single-artifact verifier
scripts/verify_agent_runtime_package.sh
```

| State | Command / working directory | Observed result |
| --- | --- | --- |
| Pre-refactor runtime baseline | C1 / `apps/backplane_agent_runtime` | Exit 0; 109 tests, 0 failures. |
| Pre-refactor tools baseline | C1 / `apps/backplane_agent_tools` | Exit 2; 9 tests, 3 failures. `LocalCommand` required an unset `COREUTILS`; `LocalResource` used the shared system temporary directory and registered `File.rm_rf(System.tmp_dir!())` in `on_exit`; its symlink assertion never created the symlink. The unsafe cleanup callback was removed during test migration. |
| Consolidation red test | C2 / repository root | Exit 2 during package tests; 116 tests, 7 failures because the newly named `Tools.LocalResource` and `Tools.LocalCommand` modules had not yet moved. No artifact was built. |
| Pre-reopen consolidation test | C1 / `apps/backplane_agent_runtime` | Exit 2; 116 tests, 1 failure. `LocalResource.file_edit/4` shadowed the edit request map with the existing string content, then raised `BadMapError` from `Map.get("alpha one", :replace_all, false)`. |
| Verifier syntax | C3 / repository root | Exit 0. This checks shell syntax only. |
| Reopened focused adapter test | C5 / `apps/backplane_agent_runtime` | Exit 0; 8 tests, 0 failures. This covers the repaired file edit and one observed Linux command/descendant topology; it is not the full package suite or artifact matrix. |
| Final focused adapter test | C5 / `apps/backplane_agent_runtime` | Exit 0; 14 tests, 0 failures. This covers safe temporary fixtures, file-edit regression cases, verified launch identity, missing/malformed/timeout handshakes, cancellation during startup, literal argv, environment isolation, limits, descendant cleanup, and owner-scoped cancellation. |
| Package format and compile | C6 / `apps/backplane_agent_runtime` | Exit 0 for both checks; compilation used `--warnings-as-errors`. Fixture sources were formatted explicitly from the package formatter because the umbrella formatter imports unrelated dependencies. |
| Full package test | C1 / `apps/backplane_agent_runtime` | Exit 0; 123 tests, 0 failures. Log: `/tmp/backplane-agent-runtime-final-test.log`. |
| Complete artifact verification | C7 / repository root | Exit 0; repeated 123 tests, 0 failures, built `backplane_agent_runtime` 0.1.0, compiled and ran all three fresh consumers, and preserved SHA-256 `49ab63d8ff12ebd18389cafa388e04c81179f35e42e673eb1395bd4005d62213`. Log: `/tmp/backplane-agent-runtime-final-artifact.log`. The temporary artifact was removed by the verifier trap. |

The final focused test confirms that the earlier `file_edit/4` map shadow and invalid boolean option passed to `:binary.replace/4` are repaired. On supported Linux hosts, `LocalCommand` now starts `setsid --fork --wait` with a fixed POSIX launcher. The launcher reports a nonce and PID, blocks for acknowledgement, and executes the argv-only payload only after the runtime verifies positive PID, launcher parent, and equal PID/process-group/session IDs through `/proc`. Startup timeout, malformed identity, EOF, and owner cancellation fail the pending call without executing the payload. Cancellation targets only the verified owner group and preserves errors when group absence cannot be established. Commands that intentionally create a new session remain outside this cooperative cleanup contract; this adapter is not an OS sandbox.

The historical split verifier C4 stopped at the old tools formatting check after the runtime reported 109 tests with 0 failures and built an artifact. The earlier renamed-verifier attempt C2 did not reach artifact creation. After the user-approved launcher-handshake revision, the consolidation used two additional repair-and-validation rounds beyond the historical cumulative 4 rounds; its final scoped and artifact checks pass as recorded above.

Do not claim a published Hex artifact, independent external consumption,
completed T01/T23, or completed product milestones from this bounded evidence.
The verifier proves the consolidation artifact and three local fixture profiles;
the remaining PRD acceptance matrix and consumer migrations are still pending.
