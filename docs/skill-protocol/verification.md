# Skill Protocol v1 Verification

Verification snapshot for PR #34 on `feature/skill-protocol`, reviewed against
`1bb52c6ac900dd7ef70a055e62c9202875c239b1` with the current uncommitted fixes
present. The implementation is not fully acceptance-complete: lifecycle
coverage for findings 1 and 5 still needs the dedicated concurrent-request and
owner-death-during-guardian-startup regressions described below.

## Environment and scope

- Repository: `/Users/gao/Workspace/gsmlg-opt/backplane`.
- Host: macOS, Elixir 1.20.1, Erlang/OTP 29.0.2.
- Target: Elixir >= 1.18 and OTP 28+; GitHub CI pins Elixir 1.18.4 and OTP 28.5.0.5.
- HTTP regression tests used local loopback servers and no external HTTP test service. Dependency installation fetched configured GitHub dependencies.
- The current fixes are local, uncommitted, and unpushed. They were not run under the pinned Elixir 1.18.4 / OTP 28.5.0.5 CI target.
- No package publication, deployment, or production migration was performed.
- No persistent consumer cache, offline fallback, ownership coordinator, native lock NIF, or `elixir_make` was added.

## Finding status

| Finding | Status | Evidence and remaining work |
| --- | --- | --- |
| P1 request ownership | Implemented; acceptance coverage incomplete | The operation guardian monitors the owner, links and monitors the worker, kills the worker and awaits worker `DOWN` when the owner dies or the operation stops, and awaits worker `DOWN` before sending a result. The caller acknowledges the result and awaits guardian `DOWN`. There is no production startup-acknowledgement protocol. It does not alter caller process flags or shared HTTP pools. Dedicated owner-death-during-guardian-startup and concurrent-request isolation tests remain required. |
| P2 retry backoff cancellation | Fixed | Backoff waits use the combined client/per-call cancellation predicates and the existing absolute deadline. Cancellation and deadline expiry prevent another attempt. |
| P2 private temporary storage | Fixed | Operation-owned directories and staged files are permission-private before writes, with ownership-aware cleanup and collision protection. No process-wide umask or caller-owned parent is changed. |
| CI dependency resolution | Fixed | The normal matrix conditionally runs package-local `mix deps.get`; the standalone verifier also runs production compilation after package tests. |
| Lifecycle/real HTTP regression coverage | Implemented; acceptance coverage incomplete | Real Req stall, chunked-response, cancellation, and owner-termination tests exist. A repeated completion monitor assertion can race normal exit and currently expects only `:noproc`; deterministic late-monitor coverage remains required. |

## Executed checks

For the clean package and normal-matrix verification, package-local `deps`,
`_build`, and `mix.lock` were moved aside first.

| Command | Result |
| --- | --- |
| Repository root: `MIX_ENV=test mix do --app backplane_skill_protocol cmd mix deps.get` | Passed. This is the added package-matrix dependency setup. |
| Repository root: `MIX_ENV=test mix do --app backplane_skill_protocol cmd mix test` | Passed, 53 tests; the repaired normal matrix invocation reached and passed ExUnit. |
| `apps/backplane_skill_protocol`: `mix test test/backplane/skill_protocol/client_test.exs test/backplane/skill_protocol/req_lifecycle_test.exs` | Passed, 22 tests with the default seed. |
| `apps/backplane_skill_protocol`: `mix test test/backplane/skill_protocol/client_test.exs test/backplane/skill_protocol/req_lifecycle_test.exs --seed 17` | Passed, 22 tests. |
| `apps/backplane_skill_protocol`: `mix test test/backplane/skill_protocol/client_test.exs test/backplane/skill_protocol/req_lifecycle_test.exs --seed 101` | Passed, 22 tests. |
| `apps/backplane_skill_protocol`: `mix test test/backplane/skill_protocol/client_test.exs test/backplane/skill_protocol/req_lifecycle_test.exs --seed 202` | Passed, 22 tests. |
| `apps/backplane_skill_protocol`: `mix test test/backplane/skill_protocol/client_test.exs test/backplane/skill_protocol/req_lifecycle_test.exs --seed 303` | Passed, 22 tests. |
| `apps/backplane_skill_protocol`: `mix test test/backplane/skill_protocol/bundle_test.exs test/backplane/skill_protocol/source_backplane_test.exs test/backplane/skill_protocol/temporary_storage_test.exs --seed 101` | Passed, 17 tests. |
| `apps/backplane_skill_protocol`: `mix test test/backplane/skill_protocol/bundle_test.exs test/backplane/skill_protocol/source_backplane_test.exs test/backplane/skill_protocol/temporary_storage_test.exs --seed 202` | Passed, 17 tests. |
| `apps/backplane_skill_protocol`: `mix test test/backplane/skill_protocol/bundle_test.exs test/backplane/skill_protocol/source_backplane_test.exs test/backplane/skill_protocol/temporary_storage_test.exs --seed 303` | Passed, 17 tests. |
| `apps/backplane_skill_protocol`: `mix test test/backplane/skill_protocol/bundle_test.exs test/backplane/skill_protocol/source_backplane_test.exs test/backplane/skill_protocol/temporary_storage_test.exs --seed 404` | Passed, 17 tests. |
| `apps/backplane_skill_protocol`: `mix test test/backplane/skill_protocol/bundle_test.exs test/backplane/skill_protocol/source_backplane_test.exs test/backplane/skill_protocol/temporary_storage_test.exs --seed 505` | Passed, 17 tests. |
| `apps/backplane_skill_protocol`: `mix compile --warnings-as-errors --force` | Passed; 23 library files compiled. |
| Repository root: `bash scripts/verify_skill_protocol_package.sh` | Passed. Inside the clean copied package, `mix deps.get`, `mix compile --warnings-as-errors`, `mix test` (53 tests), and `MIX_ENV=prod mix compile --warnings-as-errors` all passed. Hex build/unpack passed, and the sparse Git consumer passed production compilation and its loopback API smoke. |
| `mix run --no-start test/ci_workflow_test.exs` | Passed, 4 tests. |
| `bash -n scripts/verify_skill_protocol_package.sh` | Passed. |
| `mix format --check-formatted` | Passed. |
| `git diff --check` | Passed after this documentation update. |
| Repository root: `mix test apps/backplane_api/test/backplane/api/skill_protocol_http_integration_test.exs apps/backplane_api/test/backplane/api/skill_protocol_router_test.exs apps/backplane_api/test/backplane/api/skill_protocol_telemetry_test.exs` | Passed, 10 API tests, before the failed default-database Skills run. |
| Repository root: `mix test apps/backplane_skills/test/backplane/skills/loader_test.exs apps/backplane_skills/test/backplane/skills/archive_test.exs apps/backplane_skills/test/backplane/skills/ingest_test.exs apps/backplane_skills/test/backplane/skills/publication_test.exs` | Failed with exit 2 against the default `backplane_test` database: 52/60 Skills tests passed and 8 failed. Direct `psql` inspection found 4 `skills` rows and 4 `skill_revisions` rows. This failed run is not clean acceptance evidence. |
| Repository root: `MIX_ENV=test MIX_TEST_PARTITION=_pr34_review mix ecto.setup` | Passed with exit 0 and created a fresh dedicated database; pre-test counts were 0 `skills` and 0 `skill_revisions`. |
| Repository root: `MIX_TEST_PARTITION=_pr34_review mix test apps/backplane_skills/test/backplane/skills/loader_test.exs apps/backplane_skills/test/backplane/skills/archive_test.exs apps/backplane_skills/test/backplane/skills/ingest_test.exs apps/backplane_skills/test/backplane/skills/publication_test.exs apps/backplane_api/test/backplane/api/skill_protocol_http_integration_test.exs apps/backplane_api/test/backplane/api/skill_protocol_router_test.exs apps/backplane_api/test/backplane/api/skill_protocol_telemetry_test.exs` | Passed against the fresh database: Skills 60/60 and API 10 tests. Log: `/tmp/backplane-pr34-clean-integration.log`. |

The verifier artifact was
`tmp/skill-protocol-package.Q9TR1o/backplane_skill_protocol-0.1.0.tar` with
SHA-256
`3091b0da92f1cd2831fd54013e7a7176ac5e4db8959532014d55e1a72f57564b`.

## CI dependency failure and repair

GitHub run `34825411869`, job `103916293545`, failed before ExUnit because the
separately launched package Mix process could not find `req`, `yaml_elixir`, or
`telemetry`. A clean archive reproduced the failure after root `mix deps.get`:

```text
MIX_ENV=test mix do --app backplane_skill_protocol cmd mix test
```

The child process resolves package-local `deps_path`, `_build/test`, and
`mix.lock`; running the child dependency installation first fixes it. The
workflow now does that only for the package matrix entry. No package
`mix.exs` or dedicated Skill Protocol workflow change was needed.

## Other CI observations

At reviewed commit `1bb52c6ac900dd7ef70a055e62c9202875c239b1`, CI separately
reported these failures:

- Credo exited 8 with four arity-9 findings in
  `apps/backplane_skill_protocol/lib/backplane/skill_protocol/source/local.ex`.
- Dialyzer exited 2 with 21 unskipped diagnostics involving Memory and
  Skills publication/router paths.
- Matrix jobs reported failures for `backplane` (2), `backplane_admin` (10),
  `backplane_mcp` (4), `backplane_telemetry` (2), `backplane_skills` (21),
  `memory` (40), and `system` (22); the Llama child run also exited 2.

No base-branch comparison was performed, so these are observed reviewed-commit
failures and are not classified as pre-existing. They were not fixed or rerun
in this review. Full acceptance remains incomplete because the dedicated
startup owner-death and concurrent isolation regressions are absent and the
late-monitor test still has the race risk described above.

No package publication, deployment, production migration, or external consumer
adoption was performed.
