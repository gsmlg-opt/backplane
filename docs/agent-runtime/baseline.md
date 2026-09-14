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

## Current checkout and PR #33 review (2026-09-14)

| Item | Evidence |
| --- | --- |
| Backplane branch / reviewed HEAD | `feature/agent-runtime` / `f9a8ef339fb267127aa41eac7fab45dc8254a66b` |
| Pull request base | PR #33 targets `main` at `bd5bc83005fded6f67beefe3fa8abac31eae506a` for this review. |
| Toolchain | Elixir 1.18.4 / OTP 28 / ERTS 16.4.0.1. |
| Worktree boundary | The checkout was clean at review entry. At verification time, the focused repairs and this evidence update were uncommitted. |
| Sole target application | `apps/backplane_agent_runtime` / `:backplane_agent_runtime` |
| Canonical tool facade | Existing `Backplane.AgentRuntime.Tools` remains the facade for optional port-backed tool families. |
| Bundled local adapters | `Backplane.AgentRuntime.Tools.LocalResource` and `Backplane.AgentRuntime.Tools.LocalCommand` |
| Removed tracked split surface | The `:backplane_agent_tools` Mix project, `Backplane.AgentTools` forwarding facade, duplicate facade tests, and both committed generated package archives were removed from the working tree. No compatibility namespace is retained. |
| Package harness | `scripts/verify_agent_runtime_package.sh` builds one temporary artifact and exercises fresh `empty_tool`, `bundled_basic`, and `fake_backend` consumers against its unchanged SHA-256 hash. |
| Publication state | PR #33 already existed at the reviewed HEAD. At verification time, the current correctness repairs had not yet been committed or pushed; the subsequent Git commit and remote branch state are authoritative for publication status. |

This is a bounded consolidation of an existing draft implementation. It does not implement T18 or later consumer adoption, complete all V1 tool families, or establish a milestone gate.

### Review finding disposition

All eight original findings were reproduced through source inspection or a
focused regression before repair. The table below records their post-repair
disposition. Already-correct fixes were retained rather than rewritten and are
listed after the table.

| Finding | Disposition at current working tree | Focused evidence / remaining issue |
| --- | --- | --- |
| 1. Store transitions and staged acknowledgements | **Fixed** | Atomic ETS insert/replace, exact-next revision validation, and stale-stage fencing; 19 tests, 0 failures. |
| 2. Kernel lifecycle and external-result fencing | **Fixed for the supported kernel contract** | Queued admission/start, continuation resume, exact provider/tool/wait identities, owned-child settlement, and explicit cleanup terminals; 41 tests, 0 failures. |
| 3. Runtime execution path | **Partial — blocked implementation review** | Registry/schema/policy/approval/budget gates, store-first dispatch, supervised controller barriers, and a real LocalResource multi-step fixture were added; 69 adjacent tests pass. Review still found lost task metadata on backend crash, non-persisted budget accounting, raw rather than authoritative normalized committed operations, missing active-provider rejection at tool preparation, and no finite worker timeout. These defects prevent claiming the execution boundary correct. |
| 4. Ownership and dependency handling | **Fixed** | Opaque roots/depth, ownership-only cancellation, and transitive cycle detection; 12 tests, 0 failures. |
| 5. Collaboration responses | **Fixed or explicitly deferred** | Hosted admission and recorded status/settlement are observable. Spawn, delegation, send, wait, cancel, and ask-user wrappers return typed unsupported/unavailable results and are not advertised as working; 13 tests, 0 failures. |
| 6. Local resource tools | **Fixed** | Grep confinement and complete coordinated write/edit/create-only mutations, with optional instance handle; 15 tests, 0 failures. |
| 7. Local command tool | **Partial — blocked implementation review** | Focused command tests pass 16/0, but an unmonitored cleanup task can leave a job pending indefinitely. A job moved to completed with an uncertain cleanup result can still own a live process group, while termination signals only jobs in the active map. Cleanup correctness is therefore not complete. |
| 8. Event retention and instance naming | **Fixed** | Events are physically evicted per aggregate, replay floors and gaps agree, zero retention preserves sequence, and optional adapter handles isolate instances; 10 tests, 0 failures. |

Already-correct code retained in this review includes the single
`backplane_agent_runtime` package and existing Tools facade, the fixed command
launcher handshake with literal argv/environment filtering and verified
PID/process-group/session identity, and the LocalResource file-edit shadowing
and replacement-option fixes.

### Review task routing and repair counters

| Task | Initial / current worker | Sol escalated | Repair rounds | Status |
| --- | --- | --- | ---: | --- |
| `store-1` | Sol / Sol | false | 2 | Fixed |
| `kernel-2` | Sol / Sol | false | 2 | Fixed |
| `execution-3` | Sol / Sol | false | 2 | Blocked after review |
| `ownership-4` | Terra planned; Sol executed / Sol | false | 0 | Fixed; Terra was not started because the thread limit forced a direct reroute |
| `collaboration-5` | Sol / Sol | false | 1 | Fixed/deferred honestly |
| `resource-1` | Sol / Sol | false | 0 | Fixed |
| `command-7` | Sol / Sol | false | 2 | Blocked after review |
| `events-8` | Sol / Sol | false | 0 | Fixed |

The fresh pre-repair baseline was 123 tests with 0 failures
(`/tmp/backplane-pr33-baseline-tests.log`). Focused counts above establish
only their named scopes.

### Current post-repair verification

All required mechanical checks completed successfully on the working tree
before publication. These results show that the package builds, its current tests
pass, and the single artifact works in the three fixture profiles. They do not
resolve the execution and command correctness blockers above.

| Command / working directory | Observed result |
| --- | --- |
| `mix format --check-formatted` / `apps/backplane_agent_runtime` | Exit 0. |
| `mix compile --warnings-as-errors` / `apps/backplane_agent_runtime` | Exit 0. |
| `mix test` / `apps/backplane_agent_runtime` | Exit 0; 170 tests, 0 failures; seed 648652; 4.0 seconds. |
| `bash -n scripts/verify_agent_runtime_package.sh` / repository root | Exit 0. |
| `bash scripts/verify_agent_runtime_package.sh` / repository root | Exit 0; repeated 170 tests with 0 failures (seed 780691), built version 0.1.0 with 39 modules, and ran all three fresh same-artifact consumers. SHA-256: `9dffb4c7e37762896f73247e7f264ef0370564d1032d7ffcf6de3d268259634f`. Log: `/tmp/backplane-pr33-final-artifact.log`. |
| `git diff --check` / repository root | Exit 0. |

The reviewed Git HEAD remains
`f9a8ef339fb267127aa41eac7fab45dc8254a66b`. The repairs were uncommitted
and unpushed at verification time despite these passing checks;
the subsequent Git commit and remote branch state are authoritative.

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

## Historical bounded-consolidation test evidence

The following results predate the current PR #33 correctness repairs. They
remain useful consolidation history but are not fresh verification of the
working tree. Direct application tests used C1 from the named application
directory. Verifier commands used the repository root. No explicit environment
assignment was supplied; `COREUTILS` was unset during the pre-refactor tools
baseline.

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
