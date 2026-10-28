# Internal requests #134–#138 implementation plan

> **For agentic workers:** Use subagent-driven-development for independent tasks,
> executing inline for shared owner code. Parent owns Git, builds and integration.
> Work on current main; do not create branches/worktrees or revert another worker.

**Goal:** Implement approved design `2452cd41` and publish verified 1.10.47.

**Architecture:** Existing Conversation owns interactive and headless execution;
Store remains authoritative. Staged export and typed native wait retirement extend
the existing recovery adapter; image callbacks receive live invocation context.

**Tech stack:** Elixir 1.18+/OTP 28, existing Runtime/Store, ExUnit, real Deno and
existing native helpers; no new dependencies or deployment.

## Execution contract

Approved spec: `docs/superpowers/specs/2026-10-28-staged-export-native-effects-headless-design.md`.
Write scope: Runtime implementation/tests/fixtures/docs, this plan/spec status,
and version metadata only if required by established release flow. Other apps,
lockfiles, dependencies and consumer repositories are excluded unless an actual
in-scope requirement is established and authorized. Preserve concurrent edits.

Evidence: `/tmp/backplane-1.10.47-internal`. All local BEAM/devenv commands use
`flock /tmp/backplane-ir47-beam.lock`; no concurrent shared builds. Example:

```sh
flock /tmp/backplane-ir47-beam.lock devenv shell --no-tui -- \
  python3 /tmp/backplane-1.10.47-internal/run-check.py image-red ci119 \
  env MIX_ENV=test mix test \
  apps/backplane_agent_runtime/test/backplane/agent_runtime/service_invocation_context_test.exs --seed 0
```

Use test-first functional regressions, retain red/green logs. One worker owns each
shared file at a time. Source implementation failures are repaired within scope;
stop after two failed repair rounds for coordinator audit/escalation. Do not hide
failures, change deadlines merely to pass tests, or fix unrelated checks.

## Task 1: image service semantics and invocation context (#136/#137)

Owner: image worker; `codex/services.ex`, `codex/backend.ex`, `codex/image.ex`, new
`service_invocation_context_test.exs` and scoped `codex_ct09_test.exs` assertions.
Parent does not edit Backend until worker handoff.

- [x] Add regressions for the actual Services.contracts descriptor: image safety
  equals `%{read_only: false, retry_safe: false, parallel_safe: false}`; Web metadata
  stays unchanged and image native schema/backend/source remain equal.
- [x] Exercise provider fixture -> direct and nested Conversation -> image adapter:
  collect `opts[:runtime_context]`, assert exact current invocation/Session identity,
  actual effect owner/deadline, unchanged request and one execution. Reuse a provider
  call ID in distinct native invocations and assert their invocation IDs differ.
- [x] Run red, then construct reserved runtime context in service Backend before
  spawning Image task. Carry resource_owner/resource_owner_pid/effect_owner_pid and
  live effect_deadline. Clamp timeout; static image_options cannot override context.
- [x] Keep `generate(request, opts)` compatible, standalone calls without invented
  identity and old adapters ignoring additive options. Advance image tool revision.
- [x] Run focused green, scoped format/diff; report changed files/actual evidence.

## Task 2: staged offline child export (#134)

Owner: staged-export worker; `codex/multi_agent.ex`, `codex/multi_agent/archive.ex`,
new `codex/multi_agent/staged_export.ex`, `codex/reconciliation/adapter.ex`,
`codex/reconciliation.ex` until explicit handoff, new staged-export tests/fixtures.
Parent does not write these files until handoff.

- [x] Add red public stage/completion tests: ordinary export still refuses Goal
  outbox, stage succeeds with exact source journal, offline completion refuses
  outstanding delivery and stale receipt, then succeeds after actual Goal ACK/CAS.
- [x] Add optional read-only `load_recovery_journal(context, run_ref)` contract and
  strict bounded contiguous revision/incarnation-chain validation. Stage includes
  inline source prefix/digest plus identity/admission/manifest/checkpoint; host
  persists the whole bounded record under one immutable evidence reference.
- [x] Add public `stage_child_export/3` and `complete_child_export/3`, reuse existing
  archive/history/Store validation. Only exact Goal ACK/fence suffix is admissible;
  missing capabilities, altered history/outcome/budget/deadline remain explicit errors.
- [x] Prove deterministic retry and before-Goal-write/after-write-before-ACK cases;
  no provider/tool replay, private pin mutation or synthetic receipts.
- [x] Add separate producer/consumer BEAM fixture: producer actually exits before
  archive exists, consumer completes ACK/receipt/archive/import and explicit fresh
  follow-up with original effects counted exactly once.
- [x] Run focused red/green and fixture; hand off shared Reconciliation source.

## Task 3: exact plugin wait and outer effect retirement (#135)

Owner: parent; `codex/dynamic_runtime.ex`, new `codex/plugin_install_wait.ex`,
`conversation.ex`, `tool_effects.ex`, cancellation Backend clause after Task 1,
Reconciliation/Evidence after Task 2 handoff, new plugin-retirement tests.

- [x] Reproduce direct and real-Deno started plugin cancellation with durable host
  request, late explicit installation and failed fresh-run admission.
- [x] Split serialized native plugin admission and finish from adapter execution
  on actual effect caller. Pin exact request and gate; stale finish cannot publish.
- [x] Implement `plugin_install_wait(operation, host_request_ref, wait_fn)` only for
  observation of an ACKed durable request. Register before waiter execution, bind
  full identity/Session/generation and observe actual waiter retirement within the
  original cleanup deadline. Legacy/unregistered adapters remain uncertain.
- [x] Expose bounded `plugin_install_retirement(runtime, exact_identity)` plus
  `Conversation.status/1.retirement_evidence`; typed outer proof additionally needs
  exact Deno/Registry/Session closure and every nested proof/settled result.
- [x] Accept optional `effect_retirement_ref` only through typed exact validation
  in Reconciliation tool branch. Never infer retirement from generic closed/DOWN,
  mint not_started/tool_completed, rewrite history, or rerun installation.
- [x] Run direct and real-Deno green including fresh next-prompt/catalog/MCP and
  cleanup. Retain unknown outcomes for missing, stale or incomplete evidence.

## Task 4: one native headless owner (#138)

Owner: headless worker after shared Conversation handoff from Task 3; new
`codex/headless.ex`, `conversation.ex`, `kernel.ex`, `execution.ex`, `codex/code_mode.ex`,
`priv/codex/code_mode_worker.js` and new headless tests. Parent serializes shared files.

- [x] Add red real-Deno test with zero Provider calls/events, one actual native
  nested tool, exact raw value/output and Store ACK ordering; add zero-nested case.
- [x] Implement facade start_link/execute/await/status/cancel over Conversation;
  one occurrence, fixed execute-caller lifetime, caller-supplied Store/catalog and
  original deadline. Reject provider operations in headless mode.
- [x] Add truthful `host_step_started` Kernel/Execution transition and portable
  catalog identity; actual executable snapshot stays ephemeral. Invoke native exec
  with fresh step/attempt/invocation, ordinary outbox and nested dispatcher.
- [x] Add bounded JSON worker input without source interpolation. Keep yielded
  handles internal, resume with nil under one absolute deadline, accumulate output
  within a total limit and report accepted nested invocations separately from exec.
- [x] Finish only after result ACK with exact raw terminal JSON; never call provider
  continuation. Verify actual worker/OS exit, cancellation/ACK-loss uncertainty and
  terminal reload without replay; nonterminal restore remains recovery_required.
- [x] Run focused red/green and shared Conversation/Kernel/CodeMode regressions.

## Task 5: review, integration and official delivery

- [x] Independent spec-compliance review then quality review of each bounded task;
  coordinator fixes/integrates and reviews the combined diff against all five issues.
- [x] Update Runtime public docs/approved spec status for actual APIs and limits.
  Run focused combined tests, Runtime suite and extracted package qualification
  (Elixir 1.18), docs/native helpers/independent BEAM fixtures.
- [x] Run required strict compile, whole-repo format, Credo, Dialyzer and
  `mix run --no-start test/ci_workflow_test.exs`. Record out-of-scope failures.
- Commit only scoped files, inspect commit diff, push main and verify exact
  remote SHA convergence. Require all four exact-SHA CI workflows to succeed.
- Recheck version/tag/Hex availability, dispatch unified release once:
  `gh workflow run release.yml --ref main -f version=1.10.47 -f release_apps=all`.
- Require every release job success; consume all five official ==1.10.47 Hex
  packages without source overrides; run public contracts and independent BEAM
  staged export/headless tests. Verify source/checksums/docs, six archives,
  qualification manifest, prod version/SHA/helpers and GHCR version/latest provenance.
- Close only verified #134–#138; save one coherent Agent Note review if quality
  gate passes, read it back, verify clean main/tag/remote and report delivery limits.
  No production deployment or downstream upgrade.
