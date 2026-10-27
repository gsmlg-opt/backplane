# Goal admission settlement and environment failure implementation plan

> **For agentic workers:** Use executing-plans to implement these tasks. The user
> approved design `248fc3c1` and release 1.10.45. Work in current main; no new
> branch/worktree. Serialize builds with `/tmp/backplane-ir45-beam.lock`.

**Goal:** Implement #127/#128 and publish a verified 1.10.45.

**Architecture:** Goal owns serial admission settlement and capability fences;
its existing host Store persists separate settlement receipts and receipt counts.
Readiness interprets host observations; Control returns JSON-safe ordinary errors.

**Tech Stack:** Elixir/OTP, ExUnit, existing Store fixtures, real Deno, unified
GitHub Actions/Hex release workflow. No new dependency.

## Task 1: Exact released-admission settlement (#127)

Files: `apps/backplane_agent_runtime/lib/backplane/agent_runtime/goal.ex`,
`goal/{state,store,host}.ex`, optional Goal-local validation helper, corresponding
`goal_admission_settlement_test.exs` and existing Goal test fixtures.

- [ ] Add a failing public regression for preparation failure after host release:
  `assert {:ok, {:settled, :preparation_failed}} =
  Goal.settle_unstarted_admission(goal, admission, :preparation_failed, attestation)`.
  Observe no Runtime/Provider effect, then later real work and continuation.
- [ ] Run owning test with `devenv shell --no-tui -- mix test
  apps/backplane_agent_runtime/test/backplane/agent_runtime/goal_admission_settlement_test.exs`;
  retain failure evidence before production edits.
- [ ] Implement the approved closed attestation, exact identity, owner check,
  pre-CAS observation, fresh receipt counts and separate durable result ledger.
  Use the existing CAS wrapper; retain fences on unknown acknowledgement.
- [ ] Fence shared binding minting (bind/delegate), with explicit fresh admission
  permitting deliberate reuse; preserve unrelated capabilities and accounting.
- [ ] Cover stale/conflicting retries, real start, lost/rejected/malformed ACK,
  replacement, restore, equal-revision receipts and elapsed time. Run new tests
  plus existing withdrawal/terminal/recovery tests. Report exact checks.

## Task 2: Terminal environment observations (#128)

Files: `apps/backplane_agent_runtime/lib/backplane/agent_runtime/codex/{readiness,control}.ex`,
new `codex_readiness_failure_test.exs` and `codex_environment_failure_test.exs`.

- [ ] Add failing tests for initially failed and starting-to-failed states:
  `assert {:error, %Error{class: :execution_failure}} = Readiness.await(provider, 20)`.
  Run tests and retain expected baseline timeout failures.
- [ ] Add shared-loop `await/4` expected-ID option, terminal/error normalization,
  256-byte UTF-8 reason bound and exact identity validation as specified.
- [ ] Project only observed terminal/malformed callback errors in Control:
  `{:ok, %{is_error: true, error: json_safe_error}}`.
- [ ] Test compatibility, cancellation, zero timeout, malformed state/options,
  aliases, UTF-8, unavailable/closed and ID mismatch. Exercise actual direct
  Conversation and real-Deno nested errors, next-tool continuation and journal.
- [ ] Run focused files and existing control/settled-error tests; report results.

## Task 3: Integration, docs and package verification

Files: Runtime `EMBEDDING.md`, `PERSISTENCE.md`, `CODEX.md`, `CHANGELOG.md`, approved
design/plan and package qualifier only where required to exercise these APIs.

- [ ] Review both integrated diffs against every approved contract. Add a cold
  independent-BEAM durable settlement acceptance probe using existing fixtures.
- [ ] Document host seal obligations, public result shapes, persistence defaults,
  retries/recovery limits and readiness callback/structured-error contract.
- [ ] Run focused regressions, Runtime suite, strict compile/format/Credo/Dialyzer,
  workflow contract and candidate package qualification. Serialize all Mix work.
  Record unrelated failures without fixing or weakening gates.
- [ ] Obtain bounded read-only implementation review; fix in-scope findings and
  rerun affected checks. Commit only coherent authorized paths.

## Task 4: Authorized delivery

- [ ] Audit commit range and remote main for unrelated work, push scoped commits,
  and wait for every required exact-SHA source workflow to pass.
- [ ] Recheck 1.10.45 absence; dispatch `gh workflow run release.yml --ref main
  -f version=1.10.45 -f release_apps=all` only after gates pass.
- [ ] Verify all release jobs, five Hex/HexDocs publications, archives/checksums,
  provenance/helpers, GHCR and a fresh exact-version official consumer of the new
  APIs. A tag or running workflow is insufficient.
- [ ] Close #127/#128 with published verification evidence; update coherent
  project knowledge only if the Agent Note quality gate passes. Report actual
  local/CI/publication proof and remaining downstream acceptance separately.
