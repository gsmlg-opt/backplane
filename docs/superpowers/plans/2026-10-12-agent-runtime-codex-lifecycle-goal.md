# Agent Runtime Codex Lifecycle and Goal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking. Repository instructions override skill defaults: no automatic commits, branches, pushes, publication, or deployment.

**Goal:** Implement the source-backed long-running execution and thread-scoped Goal capabilities described in the approved analysis, with independently verifiable delivery stages.

**Architecture:** Preserve Conversation's store-first execution and exact run authority. Add an explicit disabled root deadline and opt-in provider idle timeout, then a Goal-specific shared runtime extension using existing Session and Usage primitives plus host-owned persistence and normal idle-turn admission.

**Tech Stack:** Elixir 1.18+, OTP 28+, ExUnit, existing runtime Store/Conversation/Session/Usage APIs, devenv, pinned Deno for native Code Mode checks.

---

## Read first

- Design: `docs/superpowers/specs/2026-10-12-agent-runtime-codex-lifecycle-goal-design.md`.
- Execution tasks: `docs/superpowers/plans/2026-10-12-agent-runtime-execution-lifecycle.md`.
- Goal tasks: `docs/superpowers/plans/2026-10-12-agent-runtime-goal-extension.md`.
- Existing compatibility boundaries: `apps/backplane_agent_runtime/CODEX.md`, `EMBEDDING.md`, `PERSISTENCE.md`, and `docs/agent-runtime/codex-tools/session-resources.md`.

## Task 0: Verify inputs and prepare the scoped environment

**Files:** Read `AGENTS.md`, `.github/workflows/agent-runtime.yml`, the design, and both implementation plans. No production edits.

- [x] Read all task ownership and allowed scope before starting. Preserve unrelated changes. Obtain explicit branch authority before creating a branch; any worktree must be under `.trees/`.
- [x] Establish the implementation baseline with `git status --short`, `git rev-parse HEAD`, and the owning app's `mix.exs`. The preparation baseline is `1f4012542ac95c98d3b6c8c7711fa4743df7ca0c`; if it changed, inspect the scoped diff rather than overwrite it.
- [x] Verify both official Codex source revisions. Use exact-commit checkouts or archives; local absolute reference locations are conveniences, not saved dependencies. Preserve the existing source inventory pin.
- [x] Install standalone dependencies without invoking the umbrella startup:

```sh
devenv shell --no-tui -- sh -c 'cd apps/backplane_agent_runtime && MIX_ENV=test mix deps.get'
```

Expected: dependencies resolve using `apps/backplane_agent_runtime/mix.lock`; no gateway services start. Do not blindly update dependencies or repair unrelated lock differences.

- [x] Check native prerequisites before scheduling native tests:

```sh
devenv shell --no-tui -- sh -c 'elixir --version; command -v coreutils; command -v deno; command -v setsid; command -v kill'
```

Use Deno `2.8.3`, as pinned by the current Agent Runtime workflow, for native conformance. Preparation found no Deno and no standalone `deps` directory; address those execution prerequisites, then verify actual version/path. Do not label the source tests as failing when the executable is unavailable.

- [x] Run and record an initial focused baseline for existing execution, conversation, approval, usage, and Goal extension tests. Use the commands in the stage plans. Serialize Mix invocations; agents may edit independent files concurrently.

## Delivery order and ownership

| Stage | Plan tasks | Dependency | Production ownership |
| --- | --- | --- | --- |
| A: disabled root deadlines | Execution plan Phase A | Task 0 | Execution/Controller/Conversation deadline paths, Kernel deadline representation, Approval, MultiAgent limit carry |
| B: provider idle waits | Execution plan Phase B | A | Conversation provider worker/timer handling and ConversationAdapter contract |
| C1: Goal state/store/accounting | Goal plan foundation tasks | Task 0; can proceed alongside A using disjoint new modules/tests | New Goal-specific modules and test fixtures; no concurrent Conversation edits |
| C2: Goal tools and lifecycle | Goal plan integration tasks | A+B+C1 | ExtensionRuntime routing, committed Conversation lifecycle bridge, Session-aware idle admission |
| C3: recovery/descendants/host proof | Goal plan verification tasks | C2 | Goal integration tests, documentation, package-local host/store fixtures |

Parallelize only disjoint ownership. One worker owns `conversation.ex` at a time. Another worker may prepare Goal state/store/accounting while execution work proceeds. Review interfaces before starting integration; do not run competing schedulers or reset budgets by opening a new run.

## Acceptance and stopping boundaries

- [x] Finish A with the issue #65 acceptance matrix green; keep its finite compatibility, cancellation, cleanup, and persisted disabled-mode proof independently reviewable.
- [x] Finish B with active-progress and silent-stream timer regressions green; do not treat total-effect and idle timeouts as interchangeable.
- [x] Finish C with the real multi-run Goal host integration green, including durable accounting, budget wrap-up, pause/clear races, descendant usage, and conservative recovery.
- [x] Update the detailed task checkboxes only after the stated tests pass. Record commands and exit codes, not inferred pass status.
- [x] Run the owning app's final scoped suite once the implementation changes settle, followed by warnings-as-errors compilation, scoped formatting, and `git diff --check`.
- [x] If a check outside the approved scope fails, list it and stop that validation path; do not repair unrelated apps.
- [x] Write an agent note after verified feature work, labeled `project: backplane`. Do not update filesystem memories without a separate explicit request.
- [x] Report actual completion and remaining host integration separately. No consumer rollout, release, commit, push, or deployment is included.

## Current status

Implementation was committed as `ca19921b` and merged into main by `5098c6e8`; `.trees/runtime65` was subsequently removed. The original standalone verification passed 684 tests, strict compilation, scoped formatting and source inventory checks. See [the validation record](2026-10-13-agent-runtime-validation.md) for that historical evidence and host launch boundaries.

Status refreshed on 2026-10-14 at local HEAD `c67e57c1`: [Agent Runtime CI](https://github.com/gsmlg-opt/backplane/actions/runs/38368420298) passed 689 tests on Elixir 1.18 / OTP 28 and strict production compilation on Elixir 1.20 / OTP 29. The latest lane does not run tests. [v1.10.20](https://github.com/gsmlg-opt/backplane/releases/tag/v1.10.20) is published; its [release workflow](https://github.com/gsmlg-opt/backplane/actions/runs/38371373191), including Agent Runtime Hex publication, succeeded. These later results do not establish production consumer Goal integration. The C3 host proof above uses package-local Conversation/Session/store fixtures.

Next-stage draft: [Goal package and host readiness](2026-10-14-agent-runtime-goal-readiness.md). The target production host remains a scope decision.

## Execution evidence

See [the final validation record](2026-10-13-agent-runtime-validation.md). Checkboxes record verified behavior; illustrative helper snippets above are design sketches, and production helper names may differ. Native/cleanup fixtures use reversible prior-boundary regression probes where concurrent implementation preceded the first fixture run. The final full suite used four concurrent cases and the first complete run seed.
