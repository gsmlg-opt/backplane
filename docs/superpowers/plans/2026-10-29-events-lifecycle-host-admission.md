# Events lifecycle and host admission Implementation Plan

> **For agentic workers:** Use subagent-driven-development for bounded components and executing-plans for integrated verification. Follow the approved spec task by task.

**Goal:** Implement #144/#145 and publish fully verified 1.10.51 from main.

**Architecture:** Keep typed Events handles and use shared private request lifetime machinery. Add a separate host-effect Goal settlement normalizer feeding the existing durable settlement pipeline. Runtime remains responsible for intent/result ACKs and exact native retirement.

**Tech Stack:** Elixir 1.18+/OTP28, existing MCP HTTP/stdio transports, ExUnit, real Python command and Deno fixtures, existing Store adapters and unified release workflow.

Approved spec: `docs/superpowers/specs/2026-10-29-events-lifecycle-host-admission-design.md` (`ace0943b`). User explicitly approved implementation/release and main checkout. No branch/worktree creation. Builds are serialized under `/tmp/backplane-ir51-beam.lock`; evidence lives in `/tmp/backplane-1.10.51-internal/`.

## Task 1: typed MCP Events lifetime

Owner: MCP implementer. Allowed: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client.ex`, `client/{owned_request,event_request,resource_cancellation,resource_retirement}.ex`, small private shared/Events modules alongside them, focused tests and protocol docs. No Runtime writes.

- [x] Add public regressions using the existing real modern HTTP fixture and controlled request fixtures; baseline must lack the new identity/retirement path.
- [x] Enrich EventRequest without changing its mailbox tag; support immutable identity, typed control, fixed tracking deadline, verified cancellation and terminal retirement.

```elixir
{:ok, request} = Client.start_list_events(client, track_retirement: true, cursor: opaque)
{:ok, identity} = Client.event_request_identity(request)
assert identity.method == "events/list"
{:ok, response} = Client.await_event_request(request, 5_000)
{:ok, receipt} = Client.retire_event_request(request, timeout: 5_000)
assert receipt.schema == :event_retirement
assert receipt.local_cleanup == :confirmed
```

- [x] Reuse private tracking/receive machinery with an explicit two-family whitelist. Preserve resource API/schema; validate control family and exact handle before signals/waits.
- [x] Cover normal/cancelled MRTR full inventory, retained pins/capacity, unknown/late collector, ownership/control mismatch and registration timeout.
- [x] Run focused Events plus existing resource request tests under the shared lock, inspect diff and return evidence. No commits; coordinator commits integrated changes.

## Task 2: post-host-effects Goal settlement

Owner: Goal implementer. Allowed: Runtime `goal.ex`, `goal/{settlement,state,store,host}.ex` where needed; new `goal_host_admission_settlement_test.exs`, related Goal cold fixtures and Goal documentation sections in `EMBEDDING.md`/`PERSISTENCE.md`. Coordinate docs with parent; no Conversation/ToolEffects/MCP writes.

- [x] Add a real supervised hook command occurrence and baseline assertion proving no supported host-effect settlement.
- [x] Add owner-only `settle_host_admission/4` and a strict tagged normalizer, retaining legacy no-effect normalization.

```elixir
attestation = %{admission: identity, executor: :confirmed_down,
  runtime_admission: :never_started, future_start: :fenced,
  effects: %{kind: :host_pre_runtime, records: records,
    result: actual_host_result, cleanup: :confirmed}}
assert {:ok, {:settled, :host_stopped}} =
  Goal.settle_host_admission(goal, admission, :host_stopped, attestation)
```

- [x] Validate exact outer/effects/record fields, unique nonempty IDs/kinds, 1–128 records, JSON-compatible nested results and 1MiB encoded bound, preserving original data.
- [x] Route both forms through existing token ledger/pending fence/CAS ACK/retry/bind guards; stored receipt validator accepts either strict form without migration/new Store callback.
- [x] Prove settlement dispatches nothing, old hook stays unchanged, later ordinary Conversation succeeds and explicit idle admits fresh automatic work for the same active Goal. No set/clear/restore bypass.
- [x] Cover lost/rejected/malformed ACK, changed evidence, newer admission, late binding, actual Runtime activity, unrelated accounting and cold saved ACK.
- [x] Run focused Goal suites and cold fixture under shared lock; return evidence and reviewable diff.

## Task 3: Runtime Events composition and retirement

Owner: coordinator. Allowed: `codex/event_request.ex` (new), `codex/dynamic_runtime.ex`, `codex/backend.ex`, `conversation.ex`, `tool_effects.ex`, `codex/reconciliation.ex`, related tests/fixtures, `CODEX.md`, Events-only sections of Runtime persistence/embedding docs and package verification scripts.

- [x] Add single-request helper and registration state. Register responsibility before starter, preserve reserved tracking options, attach exact handle identity, controlled await, full terminal retirement and retain proof to result ACK.

```elixir
DynamicRuntime.event_request(operation, fn reserved ->
  Client.start_list_events(client, Keyword.merge([cursor: cursor], reserved))
end)
```

- [x] Advertise `mcp_events` only for `list_events/2` adapter support. Require explicit server plus optional cursor; keep source policy in host.
- [x] Add typed EventsCancellation validation and explicit dispatch/release/fencing; no weakening of resource/plugin contracts.
- [x] After exact request retirement, observe real effect DOWN and Session cleanup before sealing event_request_retirement. Extend durable reconciliation and nested Code Mode references to the exact original Store proof.
- [x] Add real HTTP normal Conversation ACK test, direct/Deno cancellation and full-child recovery tests. Missing cleanup/ACK or substituted proof stays unknown. Verify shared client survival and no normal replay/cancel notification.
- [x] Update public docs and package-consumer fixtures with actual supported APIs and verification limits.

## Task 4: integrated verification and review

- [x] Inspect combined diff and run focused suites first. Review spec compliance, then quality, using independent readers. Repair only in-scope findings and rerun affected checks.
- [x] Run full affected MCP/Runtime suites, strict compile/format/Credo/configured Dialyzer and root workflow/release contracts. Record out-of-scope failures without fixing them.
- [x] Run `scripts/verify_agent_runtime_package.sh` against extracted candidate packages on Elixir1.18.5 with independent consumer/cold fixtures; no official package patching.
- [ ] Commit only scoped files with `fixes #144` and `fixes #145`; push main, verify exact remote SHA, require all exact-commit CI jobs successful.

## Task 5: release 1.10.51 and verify publication

- [ ] Re-read live release inputs, ensure target version absent and current main clean, then dispatch exactly once:

```sh
gh workflow run release.yml --ref main -f version=1.10.51 -f release_apps=all
```

- [ ] Wait every release job to terminal success, not only GitHub Release creation.
- [ ] Fresh exact official five-Hex consumer: strict compile, native helper builds, functional contracts, independent Goal/runtime cold recovery, staged export and Headless cold fixtures.
- [ ] Verify five package checksums/source bytes/versioned HexDocs, six archive checksums/qualification manifest, compiled prod version/SHA, packaged Linux x64 helper probes, GHCR revision/version and version/latest digest parity.
- [ ] Mark only #144/#145 fixed, retain unrelated work and main advancement, report exact release SHA and verification limits. No downstream upgrade/deployment.

## Review evidence

MCP and Goal implementation and independent specification/quality reviews passed.
Runtime Events specification/quality review also passed after explicit regressions
reproduced premature ACK-loss/unknown-terminal release and nested caller-DOWN
settlement. The final focused Events set passes 9/9, including adapter advertisement,
wrong-family handles and retention after actual coordinator exit. The final full
Runtime suite passed 1337 tests after those corrections. Strict compilation,
format, Credo, configured Dialyzer, and both root workflow/release contracts
passed. Dialyzer retains 113 existing configured skips. MCP final suite: 33 doctests and 1531 tests, no failures, 11
existing exclusions. Goal host-effects cold producer/consumer and original
no-effect cold recovery passed. Candidate package qualification passed on Elixir 1.18.5, including the full
1337-test suite, native helpers, independent package consumers and all three
Plugin/Goal cold producer-consumer pairs. The fixture explicitly uses its Python
HTTP server without relying on an umbrella-only Gaoxy test application.
Full publication verification remains pending below.
