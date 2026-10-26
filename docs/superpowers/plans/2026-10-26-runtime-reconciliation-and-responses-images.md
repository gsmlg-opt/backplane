# Runtime reconciliation and Responses images implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement approved internal requests #109–#113 and publish verified 1.10.40 packages and runtime artifacts.

**Architecture:** Extend the existing Kernel/Store, Conversation/MultiAgent, Code Mode and Responses codec boundaries. Preserve native settlement, durable evidence and catalog pinning. Parent owns shared Conversation changes, integration, Git and release; delegated edits have disjoint ownership.

**Tech Stack:** Elixir 1.18+, OTP 28, ExUnit, Deno 2.8.3, existing HTTP client, GitHub Actions and Hex.

Approved specification: `docs/superpowers/specs/2026-10-26-runtime-reconciliation-and-responses-images-design.md`, user approval received 2026-10-26. Use current main; no branch/worktree creation. Preserve unrelated `devenv.lock`.

All BEAM/devenv commands use `flock /tmp/backplane-ir40-beam.lock`. Prefix scoped checks with `devenv shell --no-tui -- env ERL_FLAGS='+S 4:4' MIX_ENV=test`. Code Mode checks set `PATH=/tmp/backplane-deno-2.8.3-shvogz4s:$PATH` inside the shell. Save command output under `/tmp/backplane-1.10.40-internal-_evdjo6a`. Do not reset existing databases.

## Task 1: terminal outbox ACK (#109)

Files owned by ACK implementer:

- Modify `apps/backplane_agent_runtime/lib/backplane/agent_runtime/kernel.ex`.
- Add `apps/backplane_agent_runtime/test/backplane/agent_runtime/terminal_goal_ack_test.exs`.
- Modify `apps/backplane_agent_runtime/PERSISTENCE.md` and ACK-specific package README documentation.
- Extend Store conformance coverage only if the new focused test cannot exercise the existing public Store paths.

- [x] Write a pure Kernel regression using a terminal run with two full receipts. ACK one exact receipt and assert the retained order and no other state mutation:

  ```elixir
  assert {:ok, acknowledged, transition, []} = Kernel.execute(run,
    {:goal_outbox_acknowledged, 20,
      %{run_id: run.run_id, incarnation: run.incarnation, receipts: [first]}})
  assert acknowledged.context.conversation.goal_outbox == [second]
  assert Map.delete(acknowledged, :expected_revision) ==
    put_in(Map.delete(run, :expected_revision), [:context, :conversation, :goal_outbox], [second])
  assert transition.expected_revision == run.expected_revision + 1
  ```

- [x] Run the focused file and confirm the new command fails before implementation.
- [ ] Register the command, validate terminal state/current identity/nonempty unique exact receipt subset, delete only matching receipts and call existing `commit/5` with unchanged state and no effects.
- [x] Cover all terminal states, malformed/changed/unknown/duplicate receipts, current fencing with older receipt incarnation, existing Store CAS, durable write rejection and lost-reply reload, Goal duplicate delivery and file-backed cold reopen with no provider/tool execution.
- [x] Run the focused test plus `kernel_test.exs`, `kernel_lifecycle_test.exs`, `store_test.exs`, `staged_store_test.exs`, `store_conformance_test.exs` and `goal_bridge_test.exs`. Document public command and recovery order.
- [x] Parent reviews spec compliance then code quality; commit only verified ACK-owned paths with `fix(runtime): acknowledge terminal Goal outboxes (fixes #109)`.

## Task 2: Code Mode settled Error projection (#111)

Files owned by Code Mode implementer:

- Modify `apps/backplane_agent_runtime/lib/backplane/agent_runtime/codex/code_mode.ex`.
- Extend `codex_ct08_test.exs`, `codex_framing_test.exs`, `codex_running_cell_test.exs`, `codex_command_lifecycle_test.exs` in `apps/backplane_agent_runtime/test/backplane/agent_runtime/`, or add a focused `codex_settled_error_test.exs` there.
- Modify `apps/backplane_agent_runtime/CODEX.md`.

- [x] Add real-Deno regression where a dispatcher returns `{:ok, %{is_error: true, error: Error.new(:not_found, "command session is unknown")}}`; JavaScript checks `result.error.class === "not_found"` and performs a second nested call. Confirm the current worker fails before implementation.
- [x] Project only known Error structs recursively within ordinary maps/lists to public class/message/details, omit cause, then safely encode the existing `tool_result` envelope. Preserve other encoders; never generically flatten structs.
- [x] Clear known-settled active state and install returned context before handling an invalid wire value. Return explicit malformed_result/budget_exceeded after confirmed cleanup; preserve actual unknown_outcome.
- [x] Add both success tuple forms, nested details/private cause, unsupported values/error details, Unicode/large/oversized records and explicit uncertainty. Assert the three-element tuple's new context reaches the next callback.
- [x] Extend the real public Session/Conversation/command flow: original command exits 0 with output, completed handle returns structured not_found, next command executes once, native Store settlement/identity remains and Conversation completes.
- [x] Run the five focused Code Mode files and the new focused file if created; document the JSON boundary. Parent performs spec then quality review and commits verified paths with `fix(runtime): encode settled Code Mode errors (fixes #111)`.

## Task 3: notification lifetime and pinned contexts (#110/#113)

Files owned by parent, serial edits:

- Modify `apps/backplane_agent_runtime/lib/backplane/agent_runtime/conversation.ex`.
- Modify `apps/backplane_agent_runtime/lib/backplane/agent_runtime/codex/multi_agent.ex`.
- Modify `apps/backplane_agent_runtime/lib/backplane/agent_runtime/conversation_adapter.ex`.
- Extend `conversation_catalog_test.exs`, `conversation_preparation_test.exs`, `codex_collaboration_boundary_regression_test.exs`, mailbox-related tests under `apps/backplane_agent_runtime/test/backplane/agent_runtime/`; add focused notification/catalog tests there if needed.
- Modify `apps/backplane_agent_runtime/COLLABORATION.md` if present, otherwise notification-related package documentation after coordination with ACK README owner.

- [x] First add a regression to the public collaboration fixture: hold child Provider, accept notification, return terminal immediately, perform genuine followup and assert zero marker occurrences. Add ordinary queued message in the same scenario. Observe the missed notification failure before production changes.
- [x] Expire pending notification-kind mailbox entries in acknowledged turn finish/cancellation/suspension and when initializing/rebinding/carrying into later turns or replacement runs. Keep already-consumed history and ordinary messages.
- [x] Rebase only mailbox changes with base-aware removals and deduplicated additions. Exercise acceptance/checkpoint races so notification deletion survives while concurrent ordinary additions remain.
- [x] Add positive same-turn consumption, root/new-turn/child/legacy-recovery, cancellation and duplicate/stale/checkpoint uncertainty coverage. Run notification, mailbox and collaboration suites.
- [x] Add a context regression to the catalog fixture: capture provider/preparation snapshots before/after publication and a registry-only descriptor. Observe missing snapshot failure first.
- [x] Implement provider snapshot with the role's captured catalog and preparation snapshot with the existing pinned argument:

  ```elixir
  {:provider, _identity, catalog} -> Map.put(context, :catalog_snapshot, catalog)
  ```

  ```elixir
  context = Map.put(context, :catalog_snapshot, catalog)
  ```

- [x] Check complete metadata, old immutable contexts, direct/nested invocation revisions, supplied field override and absence from persisted/model/public records. Keep provider/preparation callback availability unchanged.
- [ ] Run catalog/preparation/feedback suites and combined notification suites. Obtain spec and code-quality review; make scoped commits for #110 and #113 if the shared Conversation diff can be staged independently, otherwise one coherent commit closing both.

## Task 4: Responses image tool outputs (#112)

Files owned by Responses implementer after a worker slot becomes free:

- Modify `apps/backplane_ai_protocol/lib/backplane/ai_protocol/codec/openai_responses.ex` and image-related module documentation. Reuse `media.ex` helpers only where needed without broadening other provider routes.
- Add `apps/backplane_ai_protocol/test/backplane/responses_image_test.exs` and independently authored fixture/provenance files under `apps/backplane_ai_protocol/test/fixtures/openai_responses/`.
- Modify `apps/backplane_ai_protocol/README.md`, `SOURCE_NOTES.md` and scoped existing media/provider tests as needed for compatibility.

- [x] Add fixture regression with function and custom call IDs, ordered text/image/text outputs and the approved data map. Verify encoding fails on baseline.
- [x] Validate exact supported string-keyed map, MIME/base64/data URI consistency and four detail values. Encode explicit default `auto`; prefix bare data once and preserve complete URI bytes.
- [x] Build native ordered output arrays for image-bearing tool results, retain text-only string behavior and preceding typed-call identity. Reject semantic error status, unsupported fields/roles/media/metadata with explicit not_submitted incompatibility; never manufacture provider status flags.
- [x] Independently author native fixtures and compare equality after canonical serialization/reconstruction. Capture actual HTTP JSON on loopback using the public codec and an OTP HTTP host client for both output kinds, data forms and details. The protocol package has no HTTP transport client; no new client API is introduced.
- [x] Run `mix test apps/backplane_ai_protocol/test/backplane/responses_image_test.exs`, then the entire owning AI protocol suite; verify legacy codecs and document precise provider/model limits. Parent reviews spec then quality and commits `feat(ai): encode Responses image tool results (fixes #112)`.

## Task 5: integrated verification and authorized release

Files owned by parent: approved spec/plan, release notes only if required by current workflow, version files only through `scripts/set-version.sh`/release workflow. No unrelated source changes.

- [x] Review integrated diff against each spec requirement and confirm unrelated lock hash remains unchanged. Complete focused regressions and owning-app suites before broad required checks.
- [ ] Run required compile/format/Credo/Dialyzer and the current CI contract commands under the shared lock. Run `mix run --no-start test/release_config_test.exs` and `mix run --no-start test/ci_workflow_test.exs` against final main. Record out-of-scope failures and continue independent work without patching them.
- [x] Complete independent spec-compliance and code-quality reviews, repair only in-scope defects and rerun affected checks.
- [ ] Stage exact intended paths, inspect each commit with `git diff-tree`, push main and verify local/remote SHA convergence. Wait for required exact-source CI.
- [ ] Re-read `.github/workflows/release.yml` and `scripts/set-version.sh`, confirm version 1.10.40/tag free and release source still contains only authorized unpublished work, then dispatch:

  ```sh
  gh workflow run release.yml --ref main -f version=1.10.40 -f release_apps=all
  ```

- [ ] Follow every job to completion. Verify tag/source, GitHub assets/digests and packaged BuildInfo without overrides, configured Hex/HexDocs cohort, GHCR manifests/provenance and final post-publication checks.
- [ ] Create a fresh temporary consumer with official published 1.10.40 packages and repeat public terminal-ACK/reopen, actual later-provider notification inputs, real-Deno completed-handle, dynamic catalog and Responses loopback probes. This consumer is task-owned temporary verification, not a Git worktree or downstream application edit.
- [ ] Close/label only the five fixed issues with concrete release and validation evidence through the invoked internal-request workflow; verify final status. Report released vs. locally verified vs. real-provider/deployment limits accurately, preserve unrelated work and stop.
