# Skill Protocol v1 Verification

This record separates GitHub CI evidence for PR #34 from the current local
review. The reviewed PR head was `c0d7bf12c73638399716b8017f74ba66b7acb929`
on `feature/skill-protocol`; the comparison base was
`bd5bc83005fded6f67beefe3fa8abac31eae506a`. Commit `014dc444` contains the
validated discovery and completion-cleanup changes described below.

Full acceptance remains incomplete. The production ownership arrangement is
implemented, but dedicated deterministic coverage for owner death during
guardian startup and concurrent request isolation is still missing.

## Environment and scope

- Repository: `/Users/gao/Workspace/gsmlg-opt/backplane`.
- Local host: macOS, Elixir 1.20.1, Erlang/OTP 29.0.2.
- Target CI: Elixir 1.18.4, Erlang/OTP 28.5.0.5. The current local changes have
  not run on that pinned target.
- HTTP tests used local loopback servers. They did not depend on an external
  HTTP test service. Dependency installation fetched the configured GitHub
  dependencies.
- No package publication, deployment, production migration, or external
  consumer adoption was performed.
- No consumer cache, offline fallback, persistent ownership coordinator,
  native lock NIF, `elixir_make`, or process-wide umask change was introduced.

## Finding status

| Finding | Status | Evidence and remaining work |
| --- | --- | --- |
| P1 request ownership | Implementation fixed; acceptance coverage incomplete | The operation guardian monitors the owner and links and monitors the transport worker. On owner death or an operation stop it terminates the worker and awaits worker `DOWN`; on completion it awaits worker `DOWN` before sending the result. The caller acknowledges the result and awaits guardian `DOWN`. Transport crashes remain isolated from the caller. There is no production startup-acknowledgement protocol. Dedicated owner-death-during-guardian-startup and concurrent-request isolation regressions remain missing. |
| P2 retry backoff cancellation | Fixed | Backoff uses the combined client/per-call cancellation predicates and the existing absolute deadline. Cancellation or deadline expiry prevents another attempt. |
| P2 private temporary storage | Fixed | Operation-owned temporary directories and staged files are restricted before writes. Cleanup is ownership-aware and preserves collision sentinels and published caller-owned destinations. |
| Package CI dependency resolution | Fixed | The normal package matrix installs package-local dependencies before launching package-local Mix tests. The independently copied package installs, compiles, tests, builds, and supports a sparse Git consumer. |
| Lifecycle and real Req coverage | Partial | Existing real Req tests cover a stalled response, slowly delivered chunks, active cancellation, and owner termination, including request teardown observation. Completion cleanup is deterministic. The remaining gaps are the startup owner-death and concurrent-request isolation cases above. |
| PR CI compatibility | Implemented locally; validation pending | The local changes preserve legacy missing-archive `:enoent`, modernize the deprecated `File.stream!/3` argument order used by blob reads, add `Revision.t/0`, and prevent the Skill Protocol integration cache from restoring application metadata across package `mix.exs` changes. Dialyzer and the pinned CI target remain pending. |

## Current local validation

A clean candidate at `.trees/pr34-verified-slice` contained the package content
from commit `014dc444`. The failed untracked startup/concurrency test draft was
excluded. The later CI-compatibility changes were not part of this candidate.

From `.trees/pr34-verified-slice/apps/backplane_skill_protocol`:

| Command | Result |
| --- | --- |
| `mix deps.get` | Exit 0. |
| `mix compile --warnings-as-errors` | Exit 0. |
| `mix test` | Exit 0, 54 tests passed. |
| `mix test test/backplane/skill_protocol/client_test.exs test/backplane/skill_protocol/req_lifecycle_test.exs --seed 17` | Exit 0, 23 tests passed. |
| Same focused command with `--seed 101` | Exit 0, 23 tests passed. |
| Same focused command with `--seed 303` | Exit 0, 23 tests passed. |
| `MIX_ENV=prod mix compile --warnings-as-errors` | Exit 0. |

From `.trees/pr34-verified-slice`:

| Command | Result |
| --- | --- |
| `MIX_ENV=test mix do --app backplane_skill_protocol cmd mix deps.get` | Exit 0. |
| `MIX_ENV=test mix do --app backplane_skill_protocol cmd mix test` | Exit 0, 54 tests passed. The repaired normal-matrix invocation reached ExUnit. |
| `bash scripts/verify_skill_protocol_package.sh` | Exit 0. Its copied-package `mix deps.get`, development and production warnings-as-errors compilation, 54 tests, Hex archive/unpack, and sparse Git-consumer production and loopback API checks passed. Log: `/tmp/pr34-slice-verifier.log`. |

The verifier produced
`tmp/skill-protocol-package.aceqkr/backplane_skill_protocol-0.1.0.tar`, with
SHA-256
`9dba16c574e19a482c71020c5649f28a510f7aa9b556833def66838c4a052a01`.

## Earlier local verification

Before the `c0d7bf12` CI review, the temporary-storage regression group was
repeated from `apps/backplane_skill_protocol`:

```sh
mix test test/backplane/skill_protocol/bundle_test.exs \
  test/backplane/skill_protocol/source_backplane_test.exs \
  test/backplane/skill_protocol/temporary_storage_test.exs --seed SEED
```

Seeds `101`, `202`, `303`, `404`, and `505` each exited 0 with 17 tests
passed.

The excluded lifecycle draft was attempted from
`apps/backplane_skill_protocol` with:

```sh
mix test test/backplane/skill_protocol/client_test.exs \
  test/backplane/skill_protocol/client_lifecycle_race_test.exs \
  test/backplane/skill_protocol/req_lifecycle_test.exs --seed 73
```

It failed during compilation before ExUnit because
`InstrumentedClientCompiler` generated an AST containing the undefined
variable `worker`. This is not passing lifecycle evidence and does not
demonstrate a production failure.

Current-root compatibility checks:

| Command | Result |
| --- | --- |
| `mix test apps/backplane_skills/test/backplane/skills/archive_test.exs` before the legacy adapter fix | Expected regression red: exit 2, 19/20 passed; missing archive returned `{:invalid_bundle, "archive cannot be read"}` instead of `:enoent`. |
| Same archive command after the fix | Exit 0, 20 tests passed. |
| `mix test --no-compile apps/backplane_skills/test/backplane/skills/blob/local_fs_test.exs` | Exit 0, 18 tests passed. |
| `MIX_TEST_PARTITION=_pr34_review mix test apps/backplane_api/test/backplane/api/skill_protocol_http_integration_test.exs apps/backplane_api/test/backplane/api/skill_protocol_router_test.exs apps/backplane_api/test/backplane/api/skill_protocol_telemetry_test.exs` | Exit 0, 10 tests passed. |
| `mix credo --strict --files-included apps/backplane_skill_protocol/lib/backplane/skill_protocol/source/local.ex` | Exit 0; the four arity-9 findings are resolved. |
| `mix dialyzer` | Exit 2: `Total errors: 137, Skipped: 120, Unnecessary Skips: 48`. None of the nine PR-specific Skills publication/router/revision diagnostics remained. The emitted residuals involved Memory, web-search services, and the Skill Protocol `PathSafety`/`MapSet` opaque diagnostic under local Elixir 1.20 / OTP 29. Log: `/tmp/pr34-ci-compat-dialyzer.log`. |
| `mix run --no-start test/ci_workflow_test.exs` | Exit 0, 4 tests passed. |
| `mix format --check-formatted` | Exit 0 in the original root. Separately, each worker's scoped changed-file format check passed. The clean candidate root could not run the umbrella formatter because root dependencies were intentionally absent. |
| `git diff --check` | Exit 0. |

The earlier focused Skills run against the shared default `backplane_test`
database must not be hidden: the four Skills test files exited 2 with 52/60
tests passed and 8 failures. Direct `psql` inspection found 4 `skills` rows and
4 `skill_revisions` rows. The three API files had separately passed 10 tests
before that failed Skills run. These are historical results, not checks rerun
for the current CI-compatibility changes.

`MIX_ENV=test MIX_TEST_PARTITION=_pr34_review mix ecto.setup` then exited 0 and
created a fresh dedicated database. Pre-test counts were 0 `skills` and 0
`skill_revisions`. Running the four Skills files and three API files together
against that database passed all 60 Skills tests and all 10 API tests.

## GitHub CI evidence and comparison

At PR head `c0d7bf12`:

- Package matrix run `34874687473`, job `104078846160`: 53 tests passed.
- Standalone verifier run `34874687291`, job `104078844319`: package tests,
  production compilation, sparse Git-consumer compilation, and loopback smoke
  passed.
- HTTP integration run `34874687291`, job `104078844051`: 10 tests passed.
- Push run `34874681114`, job `104078826733`, restored stale application
  metadata and failed while starting the deleted
  `Backplane.SkillProtocol.Application`. The same head passed the pull-request
  integration job. The local workflow repair includes the package `mix.exs` in
  the cache key and removes the broad restore fallback that could reload the
  stale entry.

Exact-base CI run `34214605966` and Test run `34214605975` establish these
failures as inherited: backplane 2, admin 10, MCP 4, telemetry 2, Skills 20,
Memory 40, System 22, and the current four Llama failures, which are a subset of
the base's eleven. The base also emitted the same twelve Memory Dialyzer
diagnostics.

The PR head added one Skills failure: the legacy archive adapter returned the
new structured missing-file error instead of `:enoent`. The current local
adapter fix and regression test address it.

The PR head also added nine Dialyzer diagnostics. Seven were downstream
impossible-pattern reports caused by using the deprecated
`File.stream!(path, modes, line_or_bytes)` order while the current typespec
describes `File.stream!(path, line_or_bytes, modes)`. Two were unknown
`Revision.t/0` reports. The local changes address both causes without weakening
contracts or adding ignore entries. The local Dialyzer rerun emitted none of
these nine diagnostics. Twelve remaining Memory diagnostics match the exact
base. Three web-search guard diagnostics and two `PathSafety` opaque-type
diagnostics remain unclassified under the newer local runtime.

Relayixir had one current-only failure in
`http_plug_body_override_test.exs`. The exact base and reviewed commit both
passed 246 tests, and the PR changes no Relayixir source, root dependency,
lockfile, or config file. A focused rerun using
`mix test --no-compile --no-deps-check apps/relayixir/test/relayixir/proxy/http_plug_body_override_test.exs:102`
exited 2 with
0/1 passed and 8 excluded because
`Relayixir.ClosedChunkAdapter.read_req_body/2` was reported undefined or
private. Log: `/tmp/pr34-relayixir-rerun.log`. The result remains unclassified;
no Relayixir change was made.

## Remaining acceptance gaps

- Add a deterministic regression for owner death during guardian startup.
- Add deterministic concurrent-request reply and cancellation isolation
  coverage.
- Run the current local changes under the pinned Elixir 1.18.4 / OTP 28.5.0.5
  GitHub target.
- Resolve or separately classify the remaining local Dialyzer diagnostics.
  Known exact-base Memory diagnostics remain classified separately.

The CI-compatibility and verification-record changes accompany this follow-up;
Git history records their publication state.
