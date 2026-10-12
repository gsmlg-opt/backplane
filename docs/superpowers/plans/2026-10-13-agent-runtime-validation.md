# Agent Runtime lifecycle and Goal validation

Implementation workspace: `/home/gao/Workspace/gsmlg-opt/backplane/.trees/runtime65`.
Detached baseline: `1f4012542ac95c98d3b6c8c7711fa4743df7ca0c`.
Verified on 2026-10-13 with Elixir 1.18.5 / OTP 28 and Deno 2.8.3.
Changes are uncommitted; the root checkout's separate CI commit and original planning documents are preserved.

## Delivered contracts

| Contract | Verification |
| --- | --- |
| Explicit persisted `run_timeout: :infinity`, unchanged finite defaults, independently bounded effects/store/cleanup | Execution, Controller, Conversation, approval and store conformance tests |
| Infinite human approvals retain operation/resolver/revision/digest fences without invented expiry | Approval and Conversation tests |
| Child replacements conserve finite absolute deadlines and remaining work; infinity carries only by explicit authority | MultiAgent profile and CT-06 tests |
| Optional normalized provider idle observation, progress validation, generation fences, human waits | Provider idle tests |
| Local accounting waits suspend opted-in provider idle observation, retaining root/store deadlines | Stream accounting latch test |
| Durable optional Goal, host provenance, CAS revisions, tombstones, invocation/receipt replay | Goal state, host, file-store conformance and Usage tests |
| Multi-run Conversation and existing Session admission, budget steering and wrap-up | Goal Conversation integration tests |
| Mid-provider and nested Code Mode Goal creation establish new accounting baselines | Stream, Conversation and native nested accounting tests |
| Nested mutation cannot advance before committed accounting acknowledgement | Native nested accounting latch test |
| Descendants contribute usage once with immutable root attribution; delegated capabilities cannot mutate root Goals | Descendant and MultiAgent tests |
| Trusted Plan mode excludes root charge/status/deferral/failure audits and cannot be overridden by children | Goal host/state tests |
| Source failure guards distinguish reasoning, commentary, final emptiness and actual interruption | State and stream tests |
| Goal revocation is bounded and leaves a responsive owner on timeout or Goal death | Goal cleanup latch tests |
| Recovery redelivers committed accounting without replaying providers/tools; fork copies the Goal snapshot | Goal Conversation/host/file-store tests |

Production storage, provider classification and normal turn admission remain host-owned. Consumer rollout, CI, release, commit and publication are outside this delivery.

## Final checks

All Mix invocations were serialized with `flock /tmp/backplane-runtime65-mix.lock`, from the root devenv shell, changing into `.trees/runtime65/apps/backplane_agent_runtime`. The Deno directory `/tmp/backplane-runtime65-tools` was explicitly prepended to `PATH`.

- Formatting: `MIX_ENV=test mix format --check-formatted` with all 35 changed/new `.ex` and `.exs` paths; exit 0.
- Strict standalone compilation: `MIX_ENV=test mix compile --force --warnings-as-errors`; 76 files, exit 0.
- Complete owning-app suite: `MIX_ENV=test mix test --max-cases 4 --seed 348260`; **684 tests, 0 failures**, exit 0.
- Source inventory: `CODEX_SOURCE_ROOT=/tmp/backplane-codex-reference-requests nix shell nixpkgs#ruby --command ruby scripts/codex_tools_inventory.rb --check`; **16 families, 66 exact-source entries**, exit 0.
- `git diff --check`; exit 0.

Final command/output log: `/tmp/runtime65-final-scoped-checks.log`. Full tests include the existing native Code Mode/source conformance cases and the new native nested Goal cases. Fixture-injected crashes produce diagnostic logs but are asserted recovery paths.

The first complete run had 673 tests and two failures: a real nested-completion context overwrite and one short commit timeout under concurrent test load. The context overwrite was repaired, preserving queued input and restamping newly committed Goal receipts. The two affected files passed together in focused verification. The final complete run used the original seed with four concurrent cases to reduce scheduler contention. No claim of CI or the Elixir 1.20 / OTP 29 lane is made.

## Regression evidence

Focused foundation validation finished at 57/0; execution stage validation at 137/0. Later integration repairs finished at 56/0 and final owner-boundary validation at 37/0, before the final complete suite.

Meaningful failing cases covered changed usage identities, streaming Goal creation, local accounting versus idle observation, commentary emptiness, admission identities, immutable descendant attribution, Plan authority and lifecycle, and elapsed clock boundaries. Native nested and revocation fixtures initially landed after concurrent fixes; reversible probes restored their prior unsafe boundaries, observed respectively 2/2 and 3/3 failures, and restored exact source bytes in `finally`. Their fixed behavior passed again and in the final suite. Two final acceptance regressions verified unknown-response disclosure and rejection of decreasing cumulative usage (16/1 and 9/1 red; combined accounting checks 32/0 green). Uncertain responses expose a conditional `accounting_uncertain: true`, unavailable remaining tokens and no final budget claim. These probes establish regression sensitivity without claiming every fixture's first run was red.

Evidence logs: `/tmp/runtime65-goal-stream-create-red.log`, `/tmp/runtime65-goal-stream-idle-red.log`, `/tmp/runtime65-goal-stream-commentary-red.log`, `/tmp/runtime65-unbind-regression-red.log`, `/tmp/runtime65-final-boundaries-green.log`. Detailed worker records: `/tmp/runtime65-execution-validation.md` and `/tmp/runtime65-goal-validation.md`.

## Source and compatibility

The tool inventory remains pinned to `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`; additional lifecycle behavior is audited at `a9b0815167c27ab13719dd12d13b63e02b70d221`. The latter was inspected from the exact-commit archive, not a Git checkout. Source links are recorded in the design and runtime `CODEX.md`. Only the generated local source/hash manifest was refreshed; the source lock and upstream inventory are unchanged.

Explicit Backplane adaptations are host-owned CAS storage, committed receipt outboxes, capability attribution, snake_case response fields, and conservative unknown-usage admission. Runtime metadata is not a replacement for the provider's raw SSE observation timeout. `Goal.restore/1` reloads metadata and revokes old bindings; the host must fence ordinary runs, redeliver retained outboxes and prove Session readiness before signaling idle. Durable fixtures establish package behavior, not a deployed consumer adapter.

## Agent Note

Saved and read back note `b0a31b64-8d6d-4aa7-bd2a-1afeb73017cf`, revision 1, with label `project: backplane`. It records the verified uncommitted workspace, source contract, final checks and consumer launch boundary.
