# Sequential resource scope implementation plan

> **For agentic workers:** Use subagent-driven-development with disjoint MCP and
> Runtime ownership; parent owns integration, reviews, Git and release. Work on
> current main. Do not create branches/worktrees or revert others' edits.

**Goal:** Implement approved design `a9e22dbc` for #139 and publish verified 1.10.48.

**Architecture:** One Conversation cancellation registration owns an explicit
sequential scope. MCP enrolls real owner-bound retirement obligations before
dispatch; Runtime retains exact per-slot receipts until Store settlement.

**Tech Stack:** Elixir >=1.18 / OTP28, existing Client/RequestCleanup, Runtime,
Store, Session/Registry, ExUnit and real Deno; no new dependencies/migrations.

## Execution contract

Approved spec: `docs/superpowers/specs/2026-10-28-aggregate-resource-requests-design.md`.
Write scope is the two owning apps, their tests/docs/fixtures, this plan/spec status
and established release metadata. No unrelated failures, workflows, lockfiles,
consumer repositories or deployments. Parent coordinates shared builds under
`/tmp/backplane-ir48-beam.lock`; evidence is `/tmp/backplane-1.10.48-internal`.

```sh
flock /tmp/backplane-ir48-beam.lock devenv shell --no-tui -- \
  python3 /tmp/backplane-1.10.48-internal/run-check.py NAME ci119 \
  env MIX_ENV=test mix test TEST_PATH --seed 0
```

`ci119` uses the existing Elixir1.19.5/OTP28 cache; final extracted package also
uses supported Elixir1.18.5. Serialize all BEAM commands, preserve red/green logs.
After two failed functional repair rounds stop for coordinator audit/escalation;
do not weaken tests or change deadlines to obtain green.

## Task 1: pre-dispatch MCP tracked retirement

Owner: MCP worker. Files: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/`
`client.ex`, `client/{resource_request,owned_request,request,state,request_cleanup}.ex`,
new `client/resource_retirement.ex`, HTTP lifecycle and HTTP/SSE/stdio transport
files only as required for exact pins; owning tests/support and README. No Runtime
source edits. Read public start/await/cancel and RequestCleanup before changing them.

- [x] Add public regressions in existing `client/resource_request_test.exs`: tracked
  list/templates/read ordinary results remain equal; exact receipt contains original
  logical ID, Client incarnation, all wire obligations and actual cleanup proof.
  Use existing real mock HTTP/stdio servers, not synthetic successful receipts.

  ```elixir
  {:ok, handle} = Client.start_list_resources(client, track_retirement: true)
  assert {:ok, original} = Client.await_resource_request(handle)
  assert {:ok, receipt} = Client.retire_resource_request(handle)
  assert receipt.local_cleanup == :confirmed
  assert original == expected_page
  ```

- [x] Run targeted red first; require missing feature/behavior failure. Add bounded
  tracking before activation, capacity256, exact owner/handle/incarnation and fixed
  enrollment deadline; untracked paths retain their behavior.
- [x] Accumulate real MRTR dispatch/resolver/wire obligations and explicit transport
  pins across completion. Retire via existing worker-DOWN and transport barriers,
  without replay or extra cancellation notification for completed requests.
- [x] Implement `retire_resource_request/2`: timeout default5000, deadline clamped to
  enrollment and supplied absolute bound; terminal-only; public proof consumption
  never drops unresolved ledger/pins/capacity. Owner/Client lifecycle owns cleanup.
- [x] Cover cancelled tracked requests with full-ledger retirement, >128 unrelated
  HTTP completions, MRTR, capacity refusal before dispatch, stale/wrong owner,
  deadline expiry, uncertain barriers and owner/Client shutdown. Confirm unknown
  is retained when proof is absent. Run focused green and owning MCP suite.
- [x] Update public README options/results/build contracts; report exact files,
  API shape and red/green commands. Parent reviews spec then code quality.

## Task 2: one sequential Runtime scope

Owner: Runtime worker. Files: new
`apps/backplane_agent_runtime/lib/backplane/agent_runtime/codex/resource_scope.ex`,
`codex/{dynamic_runtime,resource_request,backend}.ex`, `conversation.ex`,
`tool_effects.ex`, `mix.exs`, CODEX.md/PERSISTENCE.md and scoped tests/fixtures.
No MCP source edits. Coordinate MCP interface with Task1 worker before integration.

- [x] Add a public failing two-source native regression in
  `test/backplane/agent_runtime/codex_resource_scope_test.exs`:

  ```elixir
  DynamicRuntime.resource_request_scope(operation, fn scope ->
    first = DynamicRuntime.resource_request(scope, fn opts ->
      Client.start_list_resources(client_a, opts)
    end)
    second = DynamicRuntime.resource_request(scope, fn opts ->
      Client.start_list_resources(client_b, opts)
    end)
    aggregate(first, second)
  end)
  ```

- [x] Record red. Register one scope with Conversation before callback. Bind full
  original identity/Session, actual effect caller and scope generation. Admit one
  slot at a time under serialized open gate, bounded128. Reject foreign caller,
  nested/reentrant/concurrent scope, stale capability and overflow before starter.
- [x] Pass reserved tracked-start options with live effect deadline to starter/1;
  preserve raw success/error and collect exact retirement before another slot.
  Seal on unresolved retirement, callback return/exit and interruption; retain
  inventory/proofs through result/cleanup Store ACK, not callback return.
- [x] Implement a distinct typed aggregate assertion/strict validator rather than
  fake representative logical IDs or relaxed single-request Cancellation. Include
  every slot, inventory digest, registration, generation, full operation and
  request evidence; empty scope has explicit zero inventory, no fake cancellation.
- [x] On cancel seal starts, resolve admitted starter/current request with its own
  control, require full-ledger retirement even after cancellation. After proof,
  Conversation stops actual effect Task and observes DOWN under original deadline;
  existing Session/Registry and nested Deno cleanup remain required.
- [x] Cover success/error, list/templates/read options and cursors, first completed
  plus second current, between-slot stop, starter/attach race, result-before-ACK
  cancellation, completion race, stale identities/generation, owner/coordinator
  death, deadline, missing proof, storage ACK loss, zero/overflow, direct and real
  Deno nested calls. No fabricated handles/private state mutation for acceptance.
- [x] Update MCP requirement to `~> 1.10.48`, scoped public docs and preserve old
  helper/legacy behavior. Run focused green and existing cancellation/interruption,
  plugin/headless/recovery regressions. Parent reviews spec then code quality.

## Task 3: integrated verification and official consumption

Owner: parent. No concurrent writes to worker-owned source before handoff.

- [x] Inspect combined diff against spec and allowed files. Independently review
  both implementations for spec compliance, then code quality; repair findings in
  bounded rounds and re-review. Integrate only after MCP API and Runtime agree.
- [x] Run complete owning MCP and Runtime suites, strict compile, format, Credo,
  Dialyzer and workflow-contract checks; retain actual evidence and skipped-warning
  configuration limitations. Diagnose failures before retry, record out-of-scope
  blockers and continue independent scoped work.
- [x] Run extracted Runtime package qualification on Elixir1.18.5 with native
  helpers, its full suite and existing cold fixtures; include new aggregate tests.
  Use candidate overrides only for prepublication qualification, never final proof.
- [ ] Prepare independent consumer pinning all five official packages to ==1.10.48,
  aggregate public tests/fixtures plus existing cancellation/recovery checks. After
  release resolve only Hex packages, compile strictly, build public helpers, verify
  versions/lock/checksums/source bytes, and execute functional consumer tests.

## Task 4: release and close exactly #139

Owner: parent, serialized Git/release mutations.

- [ ] Mark actual implementation/verification in scope docs. Stage only approved
  files, inspect exact commit paths, commit Conventional Commit, push main and
  verify local/remote SHA. Verify applicable CI workflows by changed path filters;
  require all exact-SHA jobs successful before dispatch.
- [ ] Preflight latest version and absence of target tag/Hex release/duplicate run;
  dispatch established release workflow once with version1.10.48/release_apps=all.
- [ ] Watch all jobs, diagnose failures rather than blindly rerunning. Verify five
  published Hex packages/docs, fresh consumer, six archive checksums/manifest,
  packaged prod version/source/helpers and GHCR version/latest provenance.
- [ ] Close/comment/label only #139 after publication verification. Evaluate and
  write one coherent scoped Agent Note implementation review with verified readback.
- [ ] Verify clean main, remote/tag convergence. Report implemented, tested and
  released separately from deployment; stop without unrelated issue expansion.

## Evidence

Evidence directory: `/tmp/backplane-1.10.48-internal`. MCP spec and independent quality reviews PASS; Runtime independent quality review PASS after two reproduced findings were repaired (ordered inventory binding and registration/coordination race). Focused final regressions: 51 tests, 0 failures. Final local checks passed: Runtime 1272 tests; MCP 33 doctests and 1502 tests (11 integration-tag exclusions); strict compile/format/Credo/Dialyzer/workflow contract; both extracted-package qualifications under Elixir1.18.5. Dialyzer retains the existing113 skipped diagnostics. Publication and official-Hex verification remain delivery gates, recorded in the external evidence directory.
