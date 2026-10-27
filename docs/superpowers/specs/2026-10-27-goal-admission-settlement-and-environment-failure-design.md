# Released Goal admission settlement and environment startup failures

Date: 2026-10-27

Status: approved by the user at design commit `248fc3c1` and implemented on main
for release 1.10.45. Focused integrated and static checks pass; extracted-package
qualification, exact-source CI and publication remain separate delivery gates.

## Batch, baseline and authority

The user requests `cmd-fix-internal-requests` on the existing `main`, followed by
the next release. The frozen batch has two open `internal request` issues,
neither marked `unable to resolve`, and no open issue-fix pull requests:

| Issue | Required result |
| --- | --- |
| [#127](https://github.com/gsmlg-opt/backplane/issues/127) | Settle a definitively ended, released host executor before any Runtime admission, without inventing Runtime receipts or clearing newer work |
| [#128](https://github.com/gsmlg-opt/backplane/issues/128) | Return definite environment startup failure promptly through public Readiness, native Control and nested Code Mode, preserving a bounded cause and exact identity |

The clean source baseline is `71f108ec58f562da7b0ba308f091871458a14010`, equal to
remote main and `v1.10.44`. Latest GitHub and all five Hex publications are
1.10.44; remote tag and Hex version 1.10.45 are absent at investigation time.
Recheck publication and scope immediately before release dispatch.

The issue reports used published 1.10.43. Current 1.10.44 source retains both
reported gaps. A diagnostic using the official 1.10.44 Runtime BEAM confirmed
that the real `Execution.validate_limits(cleanup_timeout: 0)` validation message
becomes a readiness timeout in both `Readiness.await/3` and `Control.call/1`.
This is public-component evidence, not a Sigma production acceptance test.
Evidence: `/tmp/backplane-1.10.45-internal-fdhdbxrk/baseline-128-qualified.log`.
The first diagnostic command had an incorrectly expanded BEAM path; its separate
log is retained and is not product-failure evidence.

Work stays in this checkout and on main. No branch/worktree creation, Sigma or
other downstream changes, deployment, managed-process restart, unrelated Memory
work or unrelated dependency refresh is included. New issues are a later batch
unless the user expands this one. Preserve concurrent changes and commits.

## Ownership and alternatives

Keep Goal policy/accounting in `Goal.State`, serial ownership and capabilities
in `Goal`, persistence in the host's existing `Goal.Store`, and actual executor
admission and fencing in the ordinary host owner. Environment facts remain
host-owned; Readiness classifies observations and Control projects tool results.
Conversation, Execution, Code Mode and ResourceRegistry retain their existing
admission, persistence and dispatch authority.

For #127 the recommendation is a separate, owner-only no-start settlement API.
It can durably retire one exact reservation while retaining the existing Runtime
receipt path. Extending `withdraw_admission/3` would conflate never-released and
released lifecycles. Requiring a cancellable Runtime before every host release
would change host preparation ordering and is a wider alternative.

For #128 the recommendation is to recognize terminal states in public Readiness
and project only the resulting observed-state errors into ordinary Control tool
results. A new tagged callback would require unnecessary host migration.
Changing Control alone would leave the public await bug; changing all native
error or JavaScript worker behavior would widen the change unnecessarily.

The pinned Codex reference is
[`wait_for_environment.rs` at 46fdd5ef](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/core/src/tools/handlers/wait_for_environment.rs).
It distinguishes failed startup, unavailable IDs and readiness, responds to the
model on failure, and bounds the UTF-8 startup reason to 256 bytes. The Goal
settlement API, host attestation, structured error fields and environment-ID
validation below are explicit Backplane host adaptations, not Codex APIs.

## #127: an exact, owner-attested no-start settlement

### Public contract and evidence

Add:

```elixir
Goal.settle_unstarted_admission(goal, admission, reason, attestation)
```

`reason` is exactly `:preparation_failed`, `:cancelled` or `:superseded`.
`admission` is the map returned by `Goal.idle/2`. Its identity consists of all
five fields, compared without coercion:

```elixir
%{
  run_id: nonempty_binary,
  incarnation: positive_integer,
  turn_id: nonempty_binary,
  host_generation: serializable_term,
  reservation_token: nonempty_binary
}
```

The host's logical `turn_id` is not a Runtime-minted turn ID. Additional fields
on the original admission are not identity or authority. For this new durable
API, every identity value must be serializable under Goal Store's existing
no-live-capabilities rule; this does not tighten existing `idle`, `bind` or
withdrawal inputs. A host using a PID/reference generation must choose a durable
generation before using this new contract.

`attestation` is a closed atom-keyed map with exactly these fields and values;
its nested admission contains exactly the five canonical identity fields:

```elixir
%{
  admission: exact_five_field_identity,
  executor: :confirmed_down,
  runtime_admission: :never_started,
  future_start: :fenced,
  effects: :none_dispatched
}
```

Only the configured Goal owner may call the API. It attests that:

1. The actual monitored, exclusively owned released executor has ended, with
   authoritative terminal acknowledgement correlated to this exact admission.
2. Its atomic admission boundary has permanently sealed this token/generation
   against binding, Runtime admission and later Provider/tool/effect dispatch.
   Seal and admission compete at the same boundary. Queued continuations and
   startup workers are included; a surviving child that can admit work prevents
   this attestation.
3. Runtime admission never occurred, no effects were dispatched, and any
   possibly committed startup/outbox state has been reconciled. Store
   `:not_found`, a UI/end event or absence of a Goal receipt alone proves none
   of these facts.

This is a trusted-owner attestation, not a new Runtime process verifier. The
host retains the seal through storage errors and retries. Missing executor
acknowledgement, uncertain Runtime/store admission, or pre-Runtime dispatched
effects remain unresolved and cannot use this path. Started Runtime work uses
existing cancellation, receipt delivery and recovery instead.

Returns:

| Result | Meaning |
| --- | --- |
| `{:ok, {:settled, reason}}` | Exact settlement is durably acknowledged, including an identical historical retry |
| `{:ok, {:not_settled, :stale}}` | No matching current reservation/original Goal and no stored exact settlement |
| `{:ok, {:not_settled, :bound}}` | A live binding exists for the reserved thread/run/incarnation |
| `{:ok, {:not_settled, :started}}` | A fresh matching Runtime start was observed, even if its accounting ACK failed |
| `{:ok, {:not_settled, :execution_observed}}` | Other fresh matching Runtime/accounting evidence contradicts no-start settlement |
| `{:error, %Error{}}` | Invalid/unauthorized input, conflicting retry or actual persistence failure; no settlement confirmation |

Use `:validation` for malformed identity/evidence/reason, `:forbidden` for a
non-owner, and `:resource_conflict` for changed payload under an existing token.
Invalid, stale and refused requests change no reservation, binding or policy.

### Race with binding and Runtime evidence

On successful idle reservation, retain its original Goal ID and a per-pair
receipt-observation baseline internally, alongside its existing complete
identity. Do not expose another admission or dispatch callback.

`Goal.bind/2` currently can run before Conversation creation and drops the token,
generation and logical turn fields. Therefore any live binding with the same
thread/run/incarnation prevents settlement, including Plan bindings. Do not
automatically unbind it. Different Runtime/logical turn IDs cannot evade this
check. A binding with another thread or run/incarnation remains unrelated.

Retain the existing pre-CAS `reserved_start` guard. Additionally record a local
fresh, valid matching Runtime receipt observation before attempting its Goal
accounting CAS. A failed or lost accounting ACK must not permit a subsequent
no-start assertion. Invalid receipts and identical old receipt replays do not
create observations.

Add `runtime_receipt_counts: %{}` to the durable State defaults, keyed by
`{run_id, incarnation}`. Successful accounting of each new receipt ID advances
that pair's count atomically with its existing receipt fence. Duplicate delivery
does not advance it. Capture the pair's count when idle reserves and recheck it
on settlement CAS reload; an advance prevents settlement. Keep the existing
event-revision check as supplementary evidence. Revision equality alone is
insufficient: GoalBridge deliberately emits multiple new receipts at one
revision. Old records start with an empty counter map; no historical policy or
usage is recomputed. Preserve the map through Goal mutation and replacement.

After initial validation, exact-current-identity checks and no-start guards pass,
install a local settlement-attempt fence before CAS. Retain its original Goal
ID, canonical identity, reason and attestation; do not remove it on storage
failure, generic Goal mutation or same-process restore.

Enforce pending and durable fences in the shared binding-minting path. This
covers both `bind` and `delegate`: delegation currently may target the root
thread and otherwise bypass a bind-only guard. A delayed legacy bind for a
fenced thread/run/incarnation returns `:resource_conflict` and cannot mint a
capability. Binding processed first makes settlement return `:bound`;
settlement processed first installs the fence before any later bind.

To deliberately reuse a fenced run/incarnation under a new reservation, allow
optional `attrs.admission` on bind/delegate. It must be the complete current
reservation identity, match the binding thread/run/incarnation, and have a
different token from the settled/pending attempt with no fence of its own.
Validate an explicitly supplied admission even when no fence exists. Retain it
on the binding; never infer it from an unrelated parent or a newer reservation.
Descendant bindings cannot borrow a root-thread admission. Existing unrelated
bindings and callers that never encounter such a fence remain compatible.

These checks prevent contradictory local capabilities. Across Goal restart,
only durable tombstones survive; external no-start safety still depends on the
host's retained atomic seal and ordinary authoritative recovery.

### Durable result, retries and policy

Add optional `admission_settlements: %{}` to State defaults. Key it by unique
reservation token and persist this closed canonical record:

```elixir
%{
  thread_id: thread_id,
  expected_goal_id: original_goal_id,
  admission: exact_five_field_identity,
  reason: reason,
  attestation: canonical_attestation,
  response: {:settled, reason}
}
```

The record is separate from Runtime receipts, deliveries, usage and audits.
Check an existing token before requiring a current reservation. An identical
identity/reason/attestation returns its saved response without another policy
mutation. A changed payload conflicts, including a changed pending attempt.
Persist a new result with the current Goal Store CAS, fenced to the reservation's
original Goal ID, and recheck guards on conflict reload. Validate the exact
acknowledged record through the existing Store wrapper.

- `:preparation_failed` retires only the reservation; an active Goal remains
  active, with no fabricated error turn, failure audit or cancellation deferral.
- `:cancelled` also persists the existing explicit-cancellation continuation
  deferral atomically with the settlement. It does not pause/complete the Goal.
- `:superseded` retires only the old reservation and does not alter newer work
  or continuation policy.

Only acknowledged persistence may clear the matching reservation and its
observation state. Compare all five fields again before clearing. A historical
exact retry after a newer reservation or Goal replacement returns its saved
result without clearing that reservation or reapplying cancellation deferral.
No call here launches another turn; a later ordinary host idle decision may.

CAS rejection, malformed ACK and persisted-but-lost ACK return their actual
error, retaining the reservation and local fence. On retry, existing CAS
conflict reload can find the saved result and acknowledge it once. If the
original Goal/reservation has disappeared and no saved settlement exists, return
stale/conflict without imposing historical policy on a replacement Goal.
An absent reservation after restart is not a successful acknowledgement.

Retain both new maps through create/update/clear and restore, with missing-field
defaults for old stored records. Validate present new fields; do not replace
malformed data with empty maps. A fork starts with fresh maps and must not copy
source-thread settlement tombstones or receipt counts. As with existing receipt
fences, automatic history pruning is outside this change; the host must retain
the full record. Do not copy settlement capabilities into public Goal responses.

Preserve unrelated bindings, pending accounting, usage, event revisions, audit
counters and whole/fractional active elapsed time. Continue using the existing
elapsed-time/CAS machinery; reservation retirement is not a clock reset. Restore
remains host-fenced recovery, not evidence that an executor never started.
Update the withdrawal/Host docs to describe the new exception after release;
the never-released withdrawal API and its behavior remain intact.

## #128: terminal readiness observations and ordinary tool errors

### Callback and await behavior

Keep `Readiness.await(provider, timeout_ms, cancelled)` returning
`{:ok, state} | {:error, %Error{}}`, and retain the existing zero-timeout single
observation, ten-millisecond polling ceiling, 300,000 ms Control default and
cancellation behavior. No permission or authorization policy changes are
included. `ready?/1` and `execute_if_ready/2` retain their existing contracts.

Add `Readiness.await(provider, timeout_ms, cancelled, options)`, sharing the same
observation loop. Existing `/2` and `/3` delegate with `[]`. Options accept only
`[]` or `[expected_environment_id: valid_id]`; unknown/duplicate options,
non-keyword input and an explicit nil/invalid ID return `:validation` before
calling either callback. Control supplies its validated request ID through this
option. This avoids changing the callback shape, throwing identity errors or
introducing sentinel states. Identity binding is logical: successful await
returns the original callback map, without inserting a missing ID.

The callback returns the existing atom-keyed map. `:ready` and `:authorized`
remain booleans, defaulting to false when absent. Optional `:status` accepts an
atom, string or nil. Optional `:error` supplies an Error struct or a map with
`class`/`message` using either atom keys or string keys. Conflicting aliases are
malformed; missing or non-map error information uses the safe fallback below.
Class aliases compare after normalization, so `:validation` and `"validation"`
agree; message aliases must be identical before fallback. An invalid alias may
not be silently ignored in favor of another valid alias. Do not inspect or copy
arbitrary callback terms.

Interpret each observation in this order: cancellation; callback shape/identity;
explicit terminal status; existing readiness/authorization gate; deadline; poll.
Terminal state wins over contradictory ready booleans.

| Status | Result |
| --- | --- |
| `:failed` / `"failed"` | Immediate `:execution_failure` with bounded startup reason |
| `:unavailable` / `"unavailable"` | Immediate `:not_found`, retaining unavailable status |
| `:closed` / `"closed"` | Immediate `:not_found`, retaining closed status |
| `:starting` / `"starting"`, `:ready` / `"ready"` | Existing `ready && authorized` gate; otherwise poll/timeout |
| Missing, nil or another atom/string | Legacy readiness gate and polling behavior |
| Non-map state, unsupported status type, or nonboolean supplied gate flags | `:malformed_result`, with an allowlisted reason tag |

For public await without a requested ID, legacy ready/polling maps may omit an
ID. Explicit failed/unavailable/closed states require a valid `environment_id`.
An explicitly supplied invalid ID is malformed on any state.

Control validates its requested ID as a nonempty valid UTF-8 binary of at most
1,024 bytes. Compare exact bytes; do not trim, normalize or truncate identity.
For every callback observation, an explicit `:environment_id` must be valid and
equal the request before readiness or terminal interpretation. Explicit nil,
empty, invalid or oversized IDs are malformed. A missing key is bound to the
requested ID for interpretation and error details, preserving the original map
for existing legacy callback compatibility. Do not mistake missing for
explicitly nil or let an older environment generation satisfy a new wait.

### Error projection and bounds

Failed startup's top-level Error class is `:execution_failure`, independent of
the startup error's original class. Its message is:

```text
Environment `<exact environment id>` failed to start: <bounded reason>
```

Use up to 256 bytes of the original reason at a valid UTF-8 boundary, matching
the pinned Codex limit. Do not append an ellipsis; expose truncation explicitly.
Missing, blank or non-text reasons become `startup reason unavailable`.
Invalid UTF-8 becomes `[invalid UTF-8 startup reason]`. Preserve meaningful
message bytes rather than formatting an arbitrary error term. Output messages
are at most 4,096 bytes, including identity and prefix.
`reason_truncated` is true only for a valid, nonblank original reason longer
than 256 bytes; every fallback/invalid-UTF-8 placeholder uses false.

Allow only the existing Error class names as startup-class atom/string input;
emit their string names, otherwise `"unknown"`. Do not dynamically create atoms.
The failed-state details are exactly environment ID, normalized status,
normalized startup class and `reason_truncated`. Never project callback `cause`,
arbitrary `details`, `kind` or inspected values.

Unavailable uses the model-facing message
`environment \`<id>\` is neither ready nor starting`; closed uses
`Environment \`<id>\` is closed`. Their details contain environment ID and distinct
status only. Malformed-state errors use a fixed message and bounded allowlisted
reason tag, such as `environment_identity_mismatch`, with the safe requested ID
when available. Never echo an invalid/oversized callback ID or malformed value.

Public Readiness returns these as `%Error{}`. Control projects observed terminal
and malformed-callback errors into this ordinary settled tool result, using
only JSON-safe maps and string inner keys/class values:

```elixir
{:ok,
 %{
   is_error: true,
   error: %{
     "class" => "execution_failure",
     "message" =>
       "Environment `actual-failed-command-startup` failed to start: cleanup_timeout must be a finite positive timeout",
     "details" => %{
       "environment_id" => "actual-failed-command-startup",
       "status" => "failed",
       "startup_class" => "validation",
       "reason_truncated" => false
     }
   }
 }}
```

Keep successful Control output as environment ID, `status: "ready"` and the
observed environment map. Argument-validation, missing-host-callback, genuine
wait-timeout and cancellation errors retain their current error-tuple behavior.
Do not catch arbitrary provider exceptions and misclassify them as known
startup failure.

The existing direct Conversation normalization preserves `is_error: true` maps;
nested Code Mode returns them as values. A JavaScript caller can read
`result.is_error`, `result.error.class/message/details`, then call another tool.
Do not route these definite observed failures through a rejected worker Promise
that retains only its message, or change global native error handling.

## Authorized implementation and verification scope

After approval, write a scoped implementation plan. Production edits belong to:

- `apps/backplane_agent_runtime/lib/backplane/agent_runtime/goal.ex` and
  `goal/{state,store,host}.ex`; a small Goal-local helper may hold closed identity
  and settlement-record validation if that keeps these changes cohesive.
- `apps/backplane_agent_runtime/lib/backplane/agent_runtime/codex/{readiness,control}.ex`;
  shared Error classes and unrelated backends are unchanged.
- Corresponding owning-package tests/fixtures, `EMBEDDING.md`, `PERSISTENCE.md`,
  `CODEX.md`, changelog and these design/implementation documents.
- Necessary qualification entries in `scripts/verify_agent_runtime_package.sh`
  and its existing workflow-contract checks. Release metadata changes only as
  required by the current unified release workflow; no dependency update is
  presently required.

Use disjoint ownership for independent implementation slices. The coordinator
serializes Git mutations, integration and shared Mix/devenv build state, with
task lock `/tmp/backplane-ir45-beam.lock`. No isolation branch or worktree is
authorized. Focused checks precede suites. Required coverage includes:

1. A real supervised host executor released through the ordinary two-phase
   host contract, failing genuine preparation before binding/Conversation.
   Prove executor DOWN, atomic sealing, no Runtime/Provider/tool dispatch or
   invented receipts; settle and then complete later ordinary work and automatic
   continuation through the public APIs.
2. Never-released withdrawal, cancelled versus preparation-failed versus
   superseded policy, unauthorized/partial/stale identities, changed retries,
   delayed bind/delegate, deliberate fresh-token reuse and delayed executor
   admission rejected by the actual host seal.
3. Competing real Conversation start with different logical/Runtime turn IDs,
   start accounting ACK failure, unbind/outbox races, equal-revision fresh
   accounting versus replay, unrelated bindings/pending receipts, cancellation
   deferral, audit/usage preservation and whole/fractional active time.
4. Rejected/malformed CAS, persisted-but-lost ACK, exact retry, replacement Goal,
   newer reservation and restore. A cold independent BEAM reopens persisted
   settlement state and returns historical acknowledgement without new work,
   policy mutation or replay; do not claim production multi-writer durability.
5. Initially failed and starting-to-failed environments, legacy ready/timeout,
   cancellation before callback, zero-timeout terminal observation, distinct
   unavailable/closed, exact/missing/mismatched/invalid environment IDs and
   malformed callback shapes. Exercise multibyte truncation, invalid UTF-8,
   blank reason, unknown class, conflicting aliases and huge nested cause.
6. Actual direct Conversation and real-Deno nested calls receive the structured
   error, continue to another tool exactly once and complete. Assert subsequent
   Provider input and retained Store journal fidelity, including ID/class/reason
   and no duplicate dispatch. Use the existing journal restoration boundary;
   this is package fixture proof, not downstream production reopening.

Keep existing #91 withdrawal, #109 terminal ACK and #119 lifecycle/reconciliation
coverage intact. Run owning Runtime suites and package qualification, strict
compilation, formatting, Credo, Dialyzer and workflow-contract checks required
by the repository. Do not repair or weaken unrelated failing gates; record
their exact evidence and stop only affected work. Route any confirmed covered
upstream blocker through `upstream-issue-routing`, with no local workaround.

## Implementation review and local evidence

The implementation keeps the specified owning modules and adds the small
`Goal.Settlement` validator. Both new-field maps are validated by the existing
Store wrapper. Independent review identified coercing numeric equality at new
admission/attestation/retry/binding boundaries and the exact Store ACK boundary;
strict term equality now distinguishes scalar and nested generations such as
`1` versus `1.0`. Nine regressions failed before correction and pass afterward.
Readiness message-alias comparison likewise uses strict equality, with its
own red/green numeric-alias counterexample. No withdrawal policy was changed.

Final focused Goal contracts pass 76 tests, including 30 new settlement cases.
Readiness units plus direct and real-Deno continuation pass 16 tests; the earlier
existing-control/settled-error group passed 32 before the additional alias case.
The integrated owning suite passed 1,181 tests before these review corrections;
the extracted-package suite and exact-source CI independently verify the final
source. Strict compilation, repository format, strict Credo, configured Dialyzer
and all nine workflow-contract tests pass under the CI Elixir 1.19.5 toolchain.
The existing Dialyzer ignore configuration is unchanged.

Independent producer/consumer BEAMs confirm a durable cancellation settlement
can be replayed after Goal replacement without applying old deferral or clearing
a new reservation. Both actual OS process exits are checked. The executable
fixture lives at `test/fixtures/run_goal_settlement_cold.py` in the Runtime app
and is included in the existing package qualifier. This is sequential fixture
custody, not production host/persistence acceptance. Local logs are under
`/tmp/backplane-1.10.45-internal-fdhdbxrk`.

## Release and completion gates

Audit each scoped commit and the full publication range. Recheck local/remote
main and unrelated concurrent commits before push or release. Existing source
manifests intentionally use an older build-template version; the unified
workflow stamps artifacts with `scripts/set-version.sh`. Derive the next
version from actual publication, not these source values.

After scoped review, all required exact-source CI and package gates pass, and
version availability is reconfirmed, publish 1.10.45 from the authorized main
commit using the existing `release.yml` version/release_apps inputs. Verify all
selected jobs, five official Hex packages and versioned HexDocs, release
archives/checksums/provenance, packaged helper qualification, GHCR identities,
and a fresh official-package consumer exercising the new public contracts.
An existing tag or running workflow alone is not a consumable release.

Commit/push/release are already requested; after approval of this design,
routine in-scope delivery requires no repeated permission. Close #127/#128 only
after the public fix is verified and published. Report local fixtures, exact
CI, publication and independent consumption separately. Downstream dependency
updates, actual Sigma failed-startup/managed-child acceptance, client reopening
and production deployment remain downstream work and are not claimed here.
