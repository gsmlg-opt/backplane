# Invocation tool deadlines and lossless message archives

Date: 2026-10-27

Status: proposed; not approved or implemented. The source audit and OTP
documentation check described here are complete. No implementation, runtime
verification, consumer acceptance, or release is claimed by this document.

Baseline: `main` at `fd31834b178e40a0ee335fc9c2872fa6dd8182ce`, released as
1.10.43. This document covers
[#121](https://github.com/gsmlg-opt/backplane/issues/121) and
[#126](https://github.com/gsmlg-opt/backplane/issues/126) within the proposed
1.10.44 internal-request batch. Other requests have separate designs.

## Outcome and ownership

Give trusted Conversation hosts a finite tool timeout selector operating on the
final invocation, and give tool backends a live view of the accepted remaining
effect budget. Preserve ordinary committed assistant metadata through child
archive export and restore.

Keep both changes in `backplane_agent_runtime`. Conversation remains the tool
execution and cancellation owner; Store remains authoritative for history and
recovery. Do not add a host scheduler, provider transport, Browser budget planner,
database migration, dependency fork, or downstream application change. Low-level
`Execution.run/5` does not gain the selector or deadline callback in this release.
The new contract is explicitly the direct and supported nested tool paths owned
by Conversation. Existing low-level execution defaults remain unchanged.

Work takes place on the current `main`. Preserve unrelated changes; do not create
a branch or worktree. The coordinating agent owns integration, verification and
authorized release delivery. Written design approval precedes implementation.

## Current behavior and causes

`Execution.validate_limits/1` caps all ordinary finite timeout options at
3,600,000 ms. Conversation uses `limits.effect` for direct and nested tools as
well as unrelated effects. `prepare_tool/2` can replace input before final
validation and approval, but no trusted callback selects a timeout for the final
invocation. Direct and nested dispatch create their worker before configuring
the timer. Backend contexts expose lifecycle callbacks and a pinned catalog,
but no accepted deadline. Supported human interaction already suspends and
resumes the remaining root, effect, preparation and nested budgets.

Conversation accepts and commits authoritative assistant message maps retaining
additional fields. Archive history first normalizes these maps with
`Reconciliation.Evidence.public/1`, then applies a separate message-field
whitelist. That list omits `timestamp`, `usage`, `provider`, `model`, `api`,
`stop_reason`, and the documented `phase`. Consequently, a successfully settled
and reconciled child can fail export solely because its committed history
contains ordinary metadata.

## Approach and alternatives

Use an optional trusted hook for one-time tool budget selection and the existing
Conversation worker, timer, token and pause machinery for enforcement. Relax only
the historical message metadata boundary after existing bounded JSON
normalization; retain all outer recovery schemas and authoritative comparisons.

Raising the shared effect timeout would alter unrelated providers and hooks,
still would not select from final input, and would give backends no shared
remaining budget. Model-supplied timeouts and descriptor mutation would move host
policy into untrusted input. A second scheduler would duplicate lifecycle
ownership. None meets #121's boundary.

Adding seven archive whitelist entries would fix the reported examples but leave
the archive contract narrower than Conversation's accepted metadata contract.
Stripping fields or moving them into a private envelope would alter committed
history and its digest. Accepting arbitrary runtime values would abandon the
existing portable JSON recovery boundary. The proposed change instead preserves
all already-supported bounded JSON metadata exactly in its public normalized
representation.

## #121: public selection contract

Add an optional callback to `ConversationAdapter`, implemented by the trusted
module configured through Conversation's existing `:hooks` option:

```elixir
@callback tool_effect_timeout(invocation :: map(), context :: map()) ::
            :default
            | {:ok, pos_integer()}
            | {:error, Backplane.AgentRuntime.Error.t()}
```

Omitting the callback or returning `:default` selects the existing
`effect_timeout`. `{:ok, milliseconds}` selects a complete finite tool effect
budget in the inclusive range `1..2_147_483_647`. `:infinity`, zero, negative,
noninteger and out-of-range budgets are invalid. A well-shaped error propagates
through the existing admission rejection path. An invalid return shape is
`:malformed_result`; an invalid numeric budget is `:validation`; a raised or
exited selector becomes `:execution_failure`; exhausted admission is `:timeout`
or the existing enclosing run deadline outcome, as applicable. Do not dispatch
a tool or record an execution intent for any unsuccessful selection.

Invoke the selector exactly once for each admitted invocation after preparation,
final schema/authority validation and any approval input replacement, before
`tool_invoked` intent commit and effect dispatch. Revalidate approved input using
the pinned descriptor before selection. Direct and supported nested invocations
use this same path. A rejected attempt does not dispatch or automatically retry
the selector. A later explicitly admitted invocation is a new selection.

The invocation retains its assigned identity, exact final arguments or raw
custom input, descriptor, backend, authority and catalog revision. The callback
cannot replace any of these. Its context includes the matching complete
`catalog_snapshot`, identity and `input_kind`. This is an ephemeral inspection
context: it exposes no dispatch, nested-dispatch, interaction, publication or
argument-replacement callback. Callback code is trusted host code; the runtime
does not claim to sandbox arbitrary Elixir side effects.

Run selection in a supervised bounded worker using only the **remaining**
existing tool-admission budget. Preparation, approval and selection share that
admission allowance; selection does not obtain a fresh `limits.effect` window.
Apply the enclosing run deadline and, for nested admission, the remaining outer
effect budget too. Preserve existing supported human-wait suspension during
earlier preparation/approval. Selection itself cannot open a human interaction.
Ignore late results by worker reference, invocation identity and generation;
cancellation and owner death terminate the selector worker.

The selection result is runtime-owned, ephemeral state carried across the
acknowledged intent commit to dispatch. Do not add it to model arguments,
provider requests, tool descriptors, committed messages, archive metadata or
catalog publication. An uncertain intent commit retains existing reconciliation
semantics and does not start the backend from an unacknowledged result.

### Finite range and OTP evidence

Keep the ordinary 3,600,000 ms maximum for `effect_timeout`, provider/hook,
commit, cleanup and finite run options. Only the new selected tool budget uses
the separate 2,147,483,647 ms product maximum.

This covers the reference aggregate 2,147,000,000 ms plus explicit example host
allowances of 120,000 ms initialization, 120,000 ms in-effect cleanup/settlement
and 120,000 ms reply delivery: 2,147,360,000 ms total. The host computes and
returns the complete total; the runtime adds no allowance and renews none.
These example component allowances are separately finite, not separate runtime
timers or a required Browser policy. Runtime-owned cancellation cleanup retains
its existing independent `cleanup_timeout` and ownership obligations.

OTP 28's `erlang:send_after/4` delegates its timing semantics to
`erlang:start_timer/4`. Its documented constraint is that the absolute expiry
lies within the VM's monotonic `start_time..end_time` interval; a relative delay
must be nonnegative. It does not impose an old unsigned or signed 32-bit
millisecond maximum. The chosen maximum is a deliberately finite application
cap below 2^31, not a claim about OTP's maximum.

Evidence checked without starting BEAM: installed OTP 28.5.0.8 source
`erts-16.4.0.7/src/erlang.erl`, lines 5915–5933 and 6110–6153, and the
[OTP 28 timer contract](https://www.erlang.org/docs/28/apps/erts/erlang.html#start_timer/4).
Implementation verification must positively schedule and immediately cancel
timers for the example and maximum budgets on the project's OTP 28 runtime;
this document does not claim that runtime check has occurred. A timer setup
failure must prevent backend dispatch and retain the acknowledged intent's
existing failure/settlement obligations rather than launch unbounded work.

### Dispatch budget and backend API

After acknowledged intent commit, calculate one effective active-time budget:

```text
direct = min(selected tool budget, remaining finite run budget)
nested = min(selected tool budget, remaining finite run budget,
             remaining enclosing effect budget)
```

An absent finite run deadline contributes no additional limit. An exhausted
enclosing budget prevents dispatch; do not turn zero remaining time into a
fresh positive allowance. Establish the deadline, timer generation, invocation
token and owned worker state before allowing adapter execution. Direct and
nested backends must observe the accepted state from their first instruction.
The selected effect clock begins at this dispatch boundary; intent persistence
keeps its existing bounded commit policy. Store acknowledgement cannot extend
an enclosing run or outer effect.

Add this runtime-owned callback to direct and nested `backend_context`, overriding
any configured host field with the same name:

```elixir
effect_deadline.() ::
  {:ok, %{
    selected_timeout_ms: pos_integer(),
    deadline_ms: integer() | nil,
    remaining_ms: non_neg_integer(),
    paused: boolean()
  }}
  | {:error, Backplane.AgentRuntime.Error.t()}
```

`selected_timeout_ms` is the accepted host selection (or unchanged default).
`remaining_ms` is the current effective shared budget after clipping and elapsed
active time. `deadline_ms` is the effective absolute
`System.monotonic_time(:millisecond)` expiry, which may be negative and is valid
only in that live VM. While paused it is `nil`, `paused` is true, and remaining
active time is frozen. After resume it reflects the shifted expiry and retained
remaining time. Do not persist the getter or compare its absolute values across
VMs. A one-time scalar captured before a human wait is not an adequate contract.

The getter reads Conversation-owned state and validates the direct/nested effect
token, invocation and live worker identity. Completion, cancellation, timeout,
replacement or owner loss makes retained callbacks fail with
`:resource_conflict`; they never return a renewed budget or affect state. A
snapshot racing subsequent cancellation is informational, not dispatch
authority. Backends remain subject to native cancellation and runtime ownership.

The host uses repeated reads to budget initialization, transport, serial phases
and settlement from the same diminishing allowance. The getter supplies no
extension or reset API. A nested invocation cannot extend its outer Code Mode
effect: the host must explicitly select enough budget for that outer invocation
as well. Provider total versus idle semantics, preparation defaults and unrelated
tool defaults remain unchanged.

### Interaction, failure and recovery

Supported blocking interaction suspends the selected direct and nested timers
together with the existing root and admission timers. Store each remaining
budget once, cancel its timer and invalidate its generation. Resume uses exactly
that remaining active time, preserving root and enclosing-effect clipping; it
does not re-run the selector or restore the original selected allowance.

Cancellation, worker DOWN, timeout, owner death and uncertain external outcomes
retain existing Conversation settlement, resource cleanup, Store and fencing
behavior. Kill only owned workers and resources. Distinguish a pre-intent
selection failure from a tool that may already have produced an external effect.
Late timer, getter and worker messages cannot revive either invocation.

Recovery does not serialize live monotonic deadlines, callback closures, worker
references or selector results. Reconcile any prior uncertain effect using the
existing Store/lifecycle contract. Do not replay it or call the selector during
archive import. An explicit fresh continuation creates a fresh run/binding and
selects budgets only for its newly admitted invocations.

## #126: historical message metadata

Replace the closed top-level message-field whitelist in `Archive.message/1`
with an open metadata check **only for maps already normalized by
`Evidence.public/1`**. Continue to require a map, supported role
`system | developer | user | assistant | tool`, and the existing presence of
`content` or `result`. Preserve existing content/result and typed tool-message
envelopes; do not reinterpret, flatten, migrate or invent field values. This
does not extend Conversation's supported executable message types.

Preserve all additional supported JSON metadata, including `timestamp`, `usage`,
`provider`, `model`, `api`, `stop_reason`, `phase` and future host/provider metadata.
Such data is historical and grants no authority, backend selection, executable
callback or recovery capability.

Keep `Evidence.public/1` unchanged: valid UTF-8, at most 16,777,216 encoded bytes,
depth 32 and 262,144 nodes; normalized keys must be unambiguous. Atom keys and
enum values become strings using the existing normalization. Structs, including
`DateTime`, and runtime handles, functions and tuples remain unsupported. A
timestamp must already be supported JSON, such as an ISO-8601 string or integer.
Lossless means exact public normalized JSON values and unchanged original Store
messages; it does not mean preserving arbitrary Elixir term identity.

Archive, admission, inventory, receipt and manifest schemas remain closed.
Retain archive/history digest verification, terminal eligibility, settled-input
requirements, lifecycle reconciliation and complete normalized history equality
against the reloaded authoritative Store record. Restored Conversation snapshots
continue using the original Store messages, not reconstructed arbitrary atoms
from imported JSON. Preserve existing schema version: this broadens accepted
historical metadata without changing archive shape. Older readers may still
reject archives containing new metadata; do not promise backward reader support.

Export and restore execute no Provider, tool, selector or followup. An explicit
followup after fresh manager restore retains logical child/transcript identity
while receiving a fresh run/incarnation/binding under existing authority rules.

## Allowed implementation files

- `apps/backplane_agent_runtime/lib/backplane/agent_runtime/conversation.ex`
- `apps/backplane_agent_runtime/lib/backplane/agent_runtime/conversation_adapter.ex`
- `apps/backplane_agent_runtime/lib/backplane/agent_runtime/codex/multi_agent/archive.ex`
- `apps/backplane_agent_runtime/README.md` and `PERSISTENCE.md`
- Focused tests under `apps/backplane_agent_runtime/test/backplane/agent_runtime/`:
  existing preparation, backend-context, interaction, uncertain-effects and
  `codex/multi_agent_recovery_test.exs` suites, plus a focused
  `conversation_tool_deadline_test.exs` if needed.
- Existing recovery fixtures under
  `apps/backplane_agent_runtime/test/fixtures/`, limited to the metadata lifecycle
  and independent cold-BEAM evidence.
- This design document and a scoped implementation plan under
  `docs/superpowers/plans/` after approval.

No generic `Execution.validate_limits/1` cap change is required. Do not add
selector behavior to `Execution.run/5` or edit shared Kernel/Store/reconciliation
schemas to implement these requests. Release version/changelog/workflow files
belong to the coordinator's separately authorized integrated release scope.

## Verification and acceptance

Run focused tests first, serializing shared BEAM/build resources with the other
1.10.44 work. Do not claim runtime or published-package acceptance from this
source audit. Record exact commands, exit statuses and fixture counts.

For #121, establish these positive behaviors and lifecycle boundaries:

1. A selector sees exact final prepared and approved input, unchanged invocation
   identity, and the pinned catalog even after a later catalog publication. It
   runs once before intent; direct and supported nested paths agree.
2. No callback and `:default` retain current defaults. A larger selected tool
   budget leaves other tools, hooks and provider total/idle budgets unchanged.
   `Execution.run/5` retains its documented prior scope.
3. Admit the reference budget and 2,147,360,000 ms example, and schedule/cancel
   the maximum timer promptly. Use pure arithmetic plus real positive timer
   admission evidence; never wait for a multi-hour effect to expire.
4. Initialization, serial backend work and settlement read a decreasing shared
   budget. Root and outer deadlines clip it. A short real deadline prevents
   excess work; nested selection cannot extend the enclosing effect.
5. A real human interaction freezes remaining time beyond the original wall
   expiry, resumes once with the retained allowance, and invalidates old timer
   generations. Both direct and nested getters expose live pause/resume state.
6. Selector failure/exhaustion, in-flight cancellation, effect timeout, worker
   DOWN and owner loss leave no owned worker/timer/resource leak, stale getter
   authority, replay, renewed allowance or false successful settlement. Preserve
   existing uncertain-outcome evidence for effects that actually began.

For #126, require an end-to-end supported lifecycle fixture:

1. Use an actual Provider and real child Conversation to commit assistant text
   with Unicode/CRLF and metadata including every reported field plus `phase`,
   bounded extension metadata and typed tool/text contents.
2. Close actual owned executor/Session/Registry resources, observe actual DOWN
   and closure receipts, acknowledge final Store state and reconcile through the
   public MultiAgent API. Do not substitute fabricated completion evidence.
3. Export through `MultiAgent.export_child/3`, encode/decode JSON, compare complete
   normalized messages and history digest, and restore into a fresh manager
   against the authoritative Store. Confirm original Store values remain intact.
4. Count Provider, tool and selector calls: export/import perform zero calls.
   Explicit followup uses a fresh run/binding and retains the full transcript.
5. Repeat export and restore across **independent cold BEAM processes** using
   file-backed authoritative state and real lifecycle evidence. The second BEAM
   must not inherit producer processes, ETS, references or atom reconstruction.
   Capture process exit status, normalized history/digest equality and no-replay
   counters. Existing same-BEAM manager restart tests alone are insufficient.
6. Retain tests proving closed outer schemas, role/envelope requirements,
   Evidence limits and full Store/digest matching; the metadata change must not
   bypass them or silently discard unsupported values.

The coordinator then runs the authorized integrated release gates, publishes
the official packages, and verifies their availability and exact version/source.
Downstream Synapsis Browser phase/Port/DOM acceptance and Sigma's unchanged
rename/archive and cold-BEAM/Deno no-replay acceptance remain separately reported
consumer work. A passing Backplane fixture or published tag alone does not prove
either consumer acceptance or a production deployment.
