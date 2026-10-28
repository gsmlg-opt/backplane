# Staged child export, native effect retirement, and headless execution

Date: 2026-10-28. Baseline: main `7f7ddfd9e3cc02ee66ca3f06872b242b91dbc19b`.
Target: 1.10.47. Status: proposed, awaiting user approval; implementation has not started.
Scope: internal requests #134–#138 in gsmlg-opt/backplane.

## Problem and approach

The five requests are still applicable after 1.10.46:

| Request | Current boundary | Required result |
| --- | --- | --- |
| #134 | Export needs a live manager pin; outstanding Goal deliveries correctly prevent archives | Preserve an export stage before manager loss, then complete after exact Goal ACK using authoritative Store |
| #135 | Generic stopped/closed observations cannot retire started tools | Independently prove retirement of an acknowledged native plugin request's observation wait and its enclosing Code Mode invocation |
| #136 | Image generation inherits read-only, retry-safe Web metadata | Describe paid generation/edit as a mutating, non-retry-safe service |
| #137 | Service backend discards invocation-local execution context | Supply exact runtime identity, deadline and resource ownership to the existing image adapter |
| #138 | Only a provider step establishes Kernel current_step | Execute a durable host-authored script with zero provider events and normal native nested tool settlement |

Recommended: extend the existing Runtime/Store/Conversation/Session/Registry
boundaries. Reconciliation continues to validate independent evidence; it does not
execute cleanup or installation. A staged export is evidence, not another manager.
Headless execution uses the existing Conversation owner, not a second scheduler.

Alternatives considered:

1. A separate headless coordinator and generic recovery broker would duplicate
   intent/result ACK, lifecycle fencing and catalog ownership. Reject the extra
   authority and implementation drift.
2. Expose low-level pins, require consumers to seed current_step, relabel image
   contracts, or treat Session close as proof of every effect. Reject these because
   they push private composition downstream or erase genuine uncertainty.
3. The recommended additive native APIs reuse current public machinery and retain
   strict archive validation. They require explicit opt-in only where a host must
   attest the narrow meaning of its plugin observation callback.

No deployment, downstream code/dependency edits, new branches/worktrees, general
scheduler, automatic plugin installation, arbitrary tool replay, authentication,
permission or sandbox feature work is included. New issues opened during execution
require a separate scope decision. The five-package unified release remains the
existing delivery contract.

## 1. Durable staged export (#134)

Add public APIs on `Codex.MultiAgent`:

```elixir
stage_child_export(manager, child, opts \\ [])
complete_child_export(recovery_config, stage_ref, retirement_receipt_ref)
```

The first runs through the existing live-manager recovery fence and pin checks.
It returns a bounded, sealed JSON record, without requiring an empty Goal outbox.
It does not return a PID, capability, closure or private pin. The host durably saves
the record using its existing immutable evidence store; `stage_ref` must resolve
through `Reconciliation.Adapter.load_evidence/2`. No additional adapter write
callback is needed. The stage must be saved before losing the original manager.

The stage contains schema_version 1, record_type `child_export_stage`, deterministic
stage_id/stage_digest, exact child identity, admission_ref, original manifest and
admission fence reference, bounded host metadata, and a source checkpoint. The
checkpoint records the original run reference, revision/incarnation, terminal
state/outcome digest, committed messages and feedback digests, remaining budget,
deadline, exact outstanding Goal receipt identities, and the bounded source
journal prefix plus its digest. Native retirement can be pending when staging, but the source
Runtime must already be fenced and in the existing archive-eligible terminal state;
the stage itself cannot satisfy retirement or bypass accepted-input obligations.

Store.load currently promises a snapshot, not a readable journal. Add an optional
read-only recovery-adapter capability `load_recovery_journal(context, run_ref)`
for staged export only. It returns a bounded portable contiguous revision chain:
each entry identifies its revision, prior/current incarnation, transition kind and
canonical command input; fence entries explicitly identify their prior revision
and incarnation. The chain starts at run admission and ends at the authoritative
Store revision. Stage verifies that boundary and includes the exact bounded prefix
and digest inline. The host persists this entire stage under stage_ref; that same
immutable evidence reference supplies the prefix, with no separate save-order or
self-reference requirement. Completion loads the stage and a fresh authoritative
chain, requires the original prefix unchanged,
and validates the suffix. Existing adapters remain compatible; missing journal
capability, incomplete prefix or exceeded JSON bounds fails staged export explicitly. Do not
infer a journal from a final snapshot, invent host persistence, or expand Store's
existing write contract. Host journal evidence has the same trusted storage and
exclusive-writer boundary as existing recovery evidence.

Completion is an offline bounded operation. It loads the stage through the trusted
adapter, validates its shape/digest/admission/inventory/manifest, reloads the
authoritative Store, and loads the current confirmed retirement receipt. It permits
only exact Goal-outbox ACK progress and normal recovery incarnation fencing after
the source checkpoint. Validate journal progression rather than accepting any
larger revision: no provider/tool execution, new accepted input, altered history,
changed outcome, budget increase, or deadline change is allowed. All staged Goal
entries must match the source and may only disappear through their exact ACK.

After Goal ACK, an old receipt can be stale. Refresh it with the existing public
Reconciliation receipt CAS against current Store fences; do not silently refresh or
forge it inside archive completion. Completion reuses the existing Archive export
and history checks, including refusal of any remaining mailbox, steering, follow-up,
Goal outbox, interaction or notification obligation. The public API internally
derives validated export material; hosts never reconstruct pins.

The same stage, receipt and Store state yield the same archive bytes/digest.
Persistence-only retries never replay providers, tools or Goal business writes.
The host remains responsible for idempotent Goal redelivery before Store ACK.
The trusted evidence adapter supplies provenance/exclusive writer authority; a
digest detects corruption and is not an independent authorization mechanism.
Existing archive schema/version and restore checks remain compatible.

## 2. Narrow started-tool retirement (#135)

This release adds retirement proof for the native `request_plugin_install`
observation wait, plus an enclosing native Code Mode invocation. It does not make
every arbitrary backend cancellable, equate process DOWN with remote rollback,
or reinterpret a started request as not_started.

### Plugin observation wait

Add the opt-in adapter helper:

```elixir
DynamicRuntime.plugin_install_wait(operation, host_request_ref, wait_fn)
DynamicRuntime.plugin_install_retirement(runtime, exact_identity)
```

The adapter first durably writes/acknowledges its host request and then invokes the
helper. `wait_fn` may only observe completion of that request: it must not install,
start MCP, dispatch another effect, or create untracked work. `host_request_ref` is
an immutable reference, separate from native `plugin_request_id`. Old adapters
remain compatible but cannot obtain this proof without adopting the helper.

Split plugin execution into serialized begin/admission, adapter execution on the
actual effect caller, and serialized finish/publication. Begin allocates and pins
the native request and exact operation. Finish validates that same admission and
the still-open completion gate before applying existing dynamic state/catalog
publication. Preserve concurrent request isolation and existing completion
validation. A stale finish cannot update the cancelled invocation or publish its
completion into a new run. Candidate listing/search publication stay serialized.

The helper validates the native request identity and registers before invoking the
observation callback. Registration binds the full original operation (including
presence of fields), Session identity, actual caller/coordinator, immutable host
request reference, registration ID and stop generation. Stop closes the gate and
seals further completion; actual registered waiter/caller termination must be
observed. The request already written by the host remains independently durable.

All registration, gate closure, waiter retirement, Deno exit and Session/Registry
cleanup share the original absolute cleanup deadline. A stop racing unacknowledged
registration cannot obtain confirmed proof. No callback, proof lookup or retry
renews the deadline; unavailable or late evidence remains uncertain.

Retirement lookup returns bounded canonical proof only after those exact facts are
observed. Its record_type is `native_plugin_wait_retirement`; it includes the full
invocation and native request binding/provenance, host_request_ref, registration_id,
stop_generation, completion_gate `closed`, waiter_down true, local_cleanup
`confirmed`, business outcome `unknown`, and a digest. The runtime issues this
record from its registered state, not from a host-supplied success map. Retain
settled proofs in a bounded cache; hosts must fetch and persist them before losing
the source runtime. Missing/evicted proof remains unavailable, not inferred.

### Independent reconciliation and outer Code Mode

A tool observation may add `effect_retirement_ref` to its existing `closed` result.
The reference is loaded through the existing trusted evidence adapter. Only the
tool branch validates the new typed proof against the exact original Store tool
invocation, immutable native request binding, source provenance and recovery
manifest/fence. Ordinary closed/stopped observations, missing or mismatched
proofs, unrelated tools, stale generations and legacy unregistered waits continue
to leave unresolved effects. A closed observation for another component cannot
borrow the exception.

Conversation.status/1 adds `retirement_evidence`, a bounded list indexed by each
record's exact invocation identity, retained for inspection after stop. An outer
`code_mode_retirement` proof is issued only after
the exact Deno executor exits, relevant Registry/Session cleanup is confirmed,
and every original nested invocation has its own valid retirement or acknowledged
settlement evidence. It binds the exact outer operation and nested evidence
identities/digests. It is separately persisted and validated; one inner waiter or
Session close alone cannot retire the outer exec. Reuse shared validators with
the existing MCP cancellation proof where possible, without weakening that proof.

The new receipt certifies local invocation retirement, permitting a new binding;
it does not certify successful installation or a known external outcome. Original
cancelled/unknown Run outcomes, journal entries and host requests stay unchanged.
A later explicit Settings installation is separate and cannot settle the old call.
No tool_completed or not_started event is synthesized. Receipt CAS loss, missing
cleanup proof or a genuinely unobserved started effect remains uncertain.

## 3. Image metadata and invocation context (#136/#137)

Assign native service metadata per service. Imagegen declares read_only false,
retry_safe false, parallel_safe false: host adapters have no general concurrency
guarantee, so concurrent generation must not be implied by the common Web helper.
Keep Web metadata unchanged. Preserve imagegen's native name, schema, backend and
source; advance only its tool revision to represent the changed effect contract.
Neither an ambiguous paid POST nor an existing artifact causes automatic retry.

Pass a reserved `:runtime_context` keyword to the existing `generate(request, opts)`
callback. Backend constructs it from the actual invocation, not model arguments or
static image_options. It contains a bounded identity projection (run/incarnation,
turn, step/attempt/invocation, provider tool_call_id, tool/catalog revision,
enclosing invocation and Session identity), resource_owner, resource_owner_pid,
effect_owner_pid and the existing live effect_deadline accessor. These process-
local values are never serialized as artifact metadata; the identity projection
alone is portable. The accessor preserves current selected/remaining deadline and
stale-owner errors; it never allocates a fresh budget.

Image execution clamps adapter timeout to the live runtime deadline and configured
image timeout. Construct runtime_context before spawning the adapter task so the
original effect caller is retained, rather than replaced with the adapter PID.
Static options cannot override this reserved context. Keep requests byte-for-byte
equivalent and preserve adapter result/error contracts. Standalone Image.generate
and old simple adapters remain supported; standalone calls carry no invented
runtime identity. Legacy adapters may ignore the additive keyword. Context-aware
adapters use exact identity to publish immutable delivery facts and the owner/
deadline for their local lifecycle. Do not claim confirmed cancellation or remote
rollback merely because an image Task was stopped; unproved effects stay uncertain.

## 4. Native headless Code Mode (#138)

Add `Codex.Headless` as a facade over one Conversation owner. Public composition:
`start_link(opts)`, `execute(pid, source, input: json)`, `await(pid, opts)`,
`status(pid)` and `cancel(pid)`. execute admits one occurrence and returns its
ordinary run/turn identity; await returns the terminal outcome, never a continuation
handle. A scheduled host may keep those calls entirely inside its job. Exactly one
occurrence is admitted per headless instance; repeated admission is rejected.

Persist explicit execution_mode `headless` and use caller-supplied Store, native
catalog, resources and original absolute deadline. Provider is absent. Headless
prompt/steer/follow_up and provider-only transitions are rejected rather than
silently invoking a model. Existing Conversation mode remains unchanged.

Add a journaled `host_step_started` Kernel command with fresh step/attempt identity
and a portable catalog identity projection (catalog revision, exact tool/revision
identities and descriptor digest). The actual immutable executable registry remains
owned ephemerally by Conversation; PIDs, callbacks and Session capabilities never
enter the journal. It is accepted only for the admitted headless mode
and establishes current_step without provider_started/provider_completed. Prepare
and invoke the actual native outer exec contract through normal Execution and
Store ACKs. Its nested dispatcher is the existing owner-bound Conversation path.
For every nested tool, committed intent precedes dispatch and committed result
precedes its reply to JavaScript. A side-effect-free script is valid with zero
nested calls; the native outer exec still has its own work reservation.

The outer effect privately loops execute/resume until terminal. Time-slice yields
and generator yields stay internal; resume with nil under the same owner,
dispatcher, catalog and absolute deadline. Do not renew the budget when the worker
timer is rearmed. Aggregate each output slice in order under one total output bound,
with monotonically retained truncation. Persist the exact terminal supported JSON
value, ordered output, truncation state and nested-call accounting after result ACK.
Count accepted nested invocations by distinct committed invocation IDs; report the
outer reservation separately. Do not stringify the raw value or mistake an interim
generator yield for completion. No provider usage is fabricated.

Add explicit bounded JSON `input` to the worker protocol/global, separate from
host-side execution_context callbacks and from retained interactive stored state.
Validate source/input before admission; never interpolate JSON into JavaScript.
At execute admission, capture and monitor the actual execute caller as the fixed
lifetime owner. The start_link supervisor and later await/status observers do not
replace it. Await timeout neither cancels nor restarts work; explicit cancel or
the execution owner's DOWN starts cancellation. Persist only portable execution
identity, never that PID; nonterminal restore cannot reattach or invent an owner.
Cancellation/caller-down seals new dispatch and late replies using the same owner
and deadline machinery. Actual Deno/Registry closure is required; #135 can retire
an adopted plugin observation wait. Other unknown started effects remain uncertain.

Headless completion takes a dedicated finish path after the outer result ACK,
never the ordinary tool-completion path that starts another provider step.
Terminal Store reload is history/outcome inspection only. A nonterminal restored
headless occurrence is recovery_required and dispatches nothing automatically;
there is no exactly-once promise or implicit script/effect replay after ACK loss.

## Persistence, compatibility and implementation boundaries

New evidence record types have explicit schema_version 1 and strict bounded JSON
validation. Existing archive/receipt data remains readable; the optional tool
observation reference is absent for old callers. No database migration or new
package dependency is planned. The optional journal read callback is required only
for staged export; it must never execute cleanup or business effects. New host-step event/mode handling must be covered
by Store reload/replay tests, and unsupported old readers must fail explicitly
rather than execute a different mode.

Suggested order: staged export; narrow plugin/outer retirement; image services;
headless admission and execution; integrated public consumer and release checks.
Runtime lifecycle changes are serialized during integration. Parallel work, if
used after approval, has disjoint files and one coordinator for shared code/builds,
Git and delivery. Preserve unrelated edits and do not repair out-of-scope failures.

## Acceptance and delivery

1. #134: failure before Goal commit and after commit/before Store ACK; stage before
   ACK; exact redelivery/ACK; stale receipt refresh; persistence-only retry;
   complete producer BEAM exit before archive completion; fresh-BEAM completion,
   import and real follow-up without replaying original effects. Unsettled archive
   refusals and changed checkpoint rejection remain covered.
2. #135: real root Conversation and real Deno cases, each creating an acknowledged
   host plugin request before cancel. Fetch/persist native proofs; late explicit
   installation does not alter original request/journal/outcome; fresh prompt uses
   a new binding and installed catalog, with real fixture MCP/cleanup. Missing or
   incomplete proof, generic stopped/closed and unrelated backend remain uncertain.
3. #136/#137: inspect the actual issued native descriptor; run direct and nested
   fixture image calls through Conversation and Store. Reuse provider call ID in
   distinct invocations and prove distinct exact provenance, unchanged arguments,
   actual deadline/owner propagation, one provider effect per invocation and no
   replay on history read. Retain old adapter and standalone Image tests.
4. #138: real Deno with zero provider calls/events, zero and one actual nested tool,
   controlled internal yields, exact bounded JSON input/raw output, total output
   truncation/call limits, intent/result ACK ordering, actual worker/OS exit,
   deadline/caller cancellation, lost result ACK and terminal reload without replay.
5. Run focused regressions first, then Runtime/package qualification and required
   compile warnings-as-errors, format, strict Credo, Dialyzer and workflow contract
   gates. Serialize local BEAM/devenv builds; use existing native helper requirements.
6. Commit only approved scope on main, verify remote convergence, require exact-SHA
   CI success, recheck version availability, and dispatch release.yml once with
   version=1.10.47/release_apps=all. Reconcile ambiguous dispatch before retry.
7. Consume all five official ==1.10.47 Hex packages without source overrides; run
   scoped contracts and independent BEAM recovery/headless fixtures. Verify Hex
   checksums/source/HexDocs, six archive checksums/qualification manifest, packaged
   helper probes, compiled production version/SHA and GHCR version/latest provenance.
   Close only verified #134–#138, then evaluate one coherent Agent Note review.

Source audit is complete; no new regression, live provider, implementation or
publication result is claimed by this document. Fixture/official-package proof
does not equal downstream Sigma/Synapsis adoption or production deployment.

## Source references

- `codex/multi_agent.ex`: export_child and recovery_operation/recovery_pin.
- `codex/multi_agent/archive.ex`: child_manifest, material, export, history.
- `codex/reconciliation.ex`: observations, satisfy, receipt_authority and receipt CAS.
- `codex/dynamic_runtime.ex`: serialized plugin request callback and publication.
- `codex/services.ex`, `codex/backend.ex`, `codex/image.ex`: common safety metadata,
  service context loss and adapter Task execution.
- `kernel.ex`, `execution.ex`, `conversation.ex`: current_step, Store-first effects,
  nested dispatch, deadline/fencing and ordinary start_provider continuation.
- `codex/code_mode.ex`, `priv/codex/code_mode_worker.js`: owned continuations,
  timer rearming, input protocol and worker/resource cleanup.

Historical guidance: Agent Note `30677b9a-8b63-45c1-bf39-a7104a8fc592` describes
1.10.46's MCP-specific cancellation and archive fidelity. This proposal adds
distinct contracts and does not rewrite that release's verified scope.
