# Archived children and explicit closure reconciliation

Date: 2026-10-27

Status: approved by the user on 2026-10-27; implementation and verification are in progress.

Scope: [#117](https://github.com/gsmlg-opt/backplane/issues/117) and
[#119](https://github.com/gsmlg-opt/backplane/issues/119), targeting the next
Backplane release after 1.10.42. The source baseline is runtime commit
`2b7a3318a5fbb31b5a49824b01a3343dac043d0b`; the current local `main` also contains
an unrelated Memory commit, which is outside this design and publication scope.

## Problem and outcome

A host can recover a run through Store/Kernel while its old MultiAgent controller
still reads a failed Conversation snapshot. A Session retains its first failed
close result. Neither exposes an operation to consume independently established
closure facts. A fresh manager also cannot retain a retired child's logical
identity and history for a later explicit followup.

Add opt-in host evidence validation, persisted closure/retirement receipts and
archive import. Keep historical run outcomes, component shutdown, controller
retirement and new execution admission distinct. Reconciliation and import start
no Provider, tool, cleanup callback, Goal notification or queued work.

## Alternatives

| Approach | Consequence |
| --- | --- |
| Host evidence and separate receipts, recommended | Reuses host ledgers and the existing run Store; supports live projection and cold recovery without reconstructing capabilities. Requires complete evidence and a narrow Registry integration. |
| Refresh live Conversation/manager snapshots | Smaller, but cannot prove resource closure or handle dead controllers and cold recovery. Insufficient for #119. |
| Persist manager and Session execution aggregates in Store | Broadens Store beyond run transitions and requires capability/persistence redesign. Outside these requests. |

The package supplies validation and lifecycle integration. The host owns durable
storage, actual backend observations, recovery exclusivity, policy and subsequent
admission. A same-BEAM fixture does not establish production durability.

## Existing boundaries

Relevant paths are under `apps/backplane_agent_runtime`:

- `codex/multi_agent.ex` initializes an empty roster; replacement already carries
  messages, feedback, remaining work/deadline and the old authority ceiling through
  fresh admission. `settled_snapshot/1` only consults cached/live Conversation state.
- Child run IDs currently use name plus a process-local sequence. Admission
  attempt IDs include the manager identity; run IDs can collide across managers.
- `codex/session.ex` permanently closes admission and caches the first close result.
  Its bindings are process-local capabilities, which journals cannot reconstruct.
- `codex/resource_registry.ex` retains failed cleanup but has no public operation
  for applying independently established closure evidence.
- `Store.load/3` and durable `Store.fence/6` are authoritative. Original execution
  incarnation and the current recovery fence are different identities.
- `Kernel.cleanup_settled` requires a cancelling run. It cannot be used to rewrite
  an already terminal `unknown_outcome` merely to certify lifetime closure.

No general Conversation reload/reopen operation or Kernel/Goal transition is added.

## Trusted host adapter

Add `Codex.Reconciliation.Adapter` with these callbacks:

```elixir
mode() # :ephemeral | :durable
load_evidence(context, evidence_ref)
runtime_store(context, store_ref)
load_receipt(context, receipt_id)
compare_and_swap_receipt(context, receipt_id, expected_revision, next_record)
```

Loads return `{:ok, value}` or `{:error, %Error{}}`. `runtime_store` resolves an
opaque host reference to `{StoreModule, store_context}`. Receipt CAS atomically
compares its revision and subject/payload identity, increments the revision once
and acknowledges only at the adapter's documented persistence boundary.
An absent receipt loads as `{:error, %Error{class: :not_found}}`. Creation requires
expected revision 0 and atomically writes revision 1 only if the ID is absent;
an existing different record is `resource_conflict`. Updates require the exact
current positive revision. Persist the accepted request fingerprint with each
receipt revision so an acknowledged-but-lost latest request can be recognized
without another write. Other adapter errors are never treated as absence.

Recovery-enabled managers and Sessions receive trusted start options
`recovery: {Adapter, context}` and `recovery_scope_id: nonempty_binary`.
Managers also require `root_agent_id: nonempty_binary`, stable across root runs.
The Session passes the same recovery configuration to its owned Registry.
Existing instances without recovery configuration retain their current behavior.
Adapters, contexts, capabilities and credentials never appear in serialized data.

`load_evidence` only reads immutable versioned records; it does not observe or
perform shutdown as a side effect. The host must hold exclusive recovery/writer
authority and a fenced admission boundary throughout validation and receipt CAS.
This is an explicit adapter guarantee, not an inferred cross-Store transaction.
Missing authority or evidence refuses confirmation.

## Public host operations

These APIs are absent from model tool catalogs:

```elixir
MultiAgent.recovery_manifest(manager, :manager | child_identity)
Session.recovery_manifest(session)
ResourceRegistry.recovery_manifest(registry, owner_id)
# {:ok, manifest} | {:error, error}

Codex.Reconciliation.reconcile({adapter, context}, request)
# {:ok, receipt} | {:error, error_with_progress}

MultiAgent.reconcile_child(manager, receipt_ref)
MultiAgent.reconcile_close(manager, receipt_ref)
Session.reconcile_close(session, receipt_ref)
ResourceRegistry.reconcile_owner(registry, owner_id, receipt_ref)
# {:ok, acknowledgement} | {:error, error}

MultiAgent.export_child(manager, child_identity, retirement_receipt_ref)
MultiAgent.restore_child(manager, archive)
# {:ok, archive_or_restore_receipt} | {:error, error}
```

Manifests can be sealed only after the corresponding admission is fenced. Callback
work runs in bounded supervised workers outside controller mailboxes. Controllers
pin the subject before starting validation and recheck it before projection.
Timeout/death leaves uncertainty and its reservation intact. Adapter callbacks
must not synchronously call the controller waiting for their result.

## Evidence and receipt contract

Use versioned string-keyed JSON projections, fixed known enum decoding and
unambiguous identities. Reject unknown fields, ambiguous atom/string keys,
non-JSON runtime values and unsupported versions. Known runtime message fields
round-trip through an explicit schema; do not atomize arbitrary input. Hash a
canonical encoding with sorted object keys and preserved list order. Digests
correlate immutable data; trust comes from the configured adapter.

The exact records are:

- **Child identity:** recovery scope, stable root ID, source manager ID, child
  agent ID, canonical name, parent ID/name, admission attempt ID, original run ID
  and original positive run incarnation.
- **Subject:** exact child identity, or manager ID/root/scope, Session owner ID
  plus Session incarnation/scope, or Registry owner plus Session incarnation/scope.
- **Manifest:** schema version 1, unique ID/revision, subject, admission-fence
  reference, Store/run/original-incarnation references, complete ordered
  obligations and a digest. Each obligation has an ID, kind, exact identity and
  provenance reference. An explicit sealed empty inventory is valid; omission is
  not proof that no work existed.
- **Observation:** immutable ID/revision, exact obligation/identity, result
  `stopped`, `closed` or `not_started`, producer reference and wall-clock time.
  A stopped effect is not a successfully reconciled external mutation.
- **Request:** schema version 1, receipt ID, expected receipt revision, subject
  and immutable evidence reference.
- **Receipt:** ID/revision, subject, manifest/evidence digests, original/current
  Store fence identities and revisions, historical outcomes, satisfied/pending
  obligations, unresolved effects, closure/retirement status, accepted request
  fingerprint and first failure.

Obligations cover original Provider attempts, tool invocations, child admissions,
dependencies/waits, Conversation executors, managed Sessions, Registry entries,
owned managers and host-owned components. Provider identity includes run,
incarnation, step and attempt; tool identity also includes invocation; resources
include owner, kind, resource/session ID and incarnation. Names or OS PIDs alone
are insufficient.

Compile obligations from authoritative owner inventories, the host admission/effect
ledger and `Kernel.cleanup_requirements/1`. Do not omit work hidden by a partial
checkpoint or cleared cache. Unsupported/missing inventory provenance refuses.
Unknown external mutation effects remain unresolved in this first version; this
feature adds no generic effect-success override.

Validate the ownership DAG: components and Registry entries precede child Session
closure; child Session/executor closure precedes child retirement; all required
children precede manager closure; root run/resources/owned managers precede root
Session closure. Managed child Sessions borrow their manager and do not own its
whole lifetime. Reject conflicting ownership and cycles.

## Reconciliation sequence and retries

1. Load evidence and any existing receipt. Match exact subject, original admission
   and sealed inventory. Reusing a receipt ID with changed subject/manifest fails.
2. Resolve Stores through trusted configuration and load their current records.
   Match record revision, expected revision, run ID and incarnation. Nonterminal
   runs must first be settled by their owning host through existing Store/Kernel
   operations; this API performs no run recovery effects.
3. For failed/recovered execution, verify the fence chain from original admission
   to the current Store incarnation and independently observed executor stoppage.
   A larger number alone is not a verified chain. Normal positive retirement of a
   same-incarnation terminal run needs no artificial fence.
4. Validate every obligation against exact observations or subordinate confirmed
   receipts. Preserve missing facts, contradictory observations and unresolved
   effects as unconfirmed. Whole-BEAM exit proves only its local executors stopped;
   external processes/actions require separate evidence.
5. Recheck Store authority under the host's exclusive recovery boundary, then CAS
   persist progress/receipt before releasing reservations or projecting state.
6. Apply confirmed receipts to live controllers after their identity checks.
   Failure after persistence is recovered by loading that same receipt. Confirmed
   child progress survives a sibling or aggregate failure.

An exact retry of the latest committed request returns the existing receipt and
causes no duplicate events or effects, including a retry with expected revision 0
after successful creation. An older request after a later progress revision is
stale and returns a conflict with the current revision. Changed evidence advances
progress only against its current revision and the same manifest. Lost write
acknowledgement returns uncertainty with the receipt ID; reload before retry.
Definite refusal preserves previous progress.
Use existing `validation`, `resource_conflict`, `unsupported_capability` and
`unknown_outcome` classes, with explicit pending obligations.

## Live manager, Registry and Session behavior (#119)

`reconcile_child` consumes authoritative recovered settlement and retirement
without replacing its immutable original admission identity. It preserves the
historical unknown/error, records the current Store fence and receipt, invalidates
old pending interaction/delivery correlations and releases execution capacity
only after all owned obligations and effects are resolved. It never attaches the
old binding or starts/replays work. An old executor still alive is insufficient
retirement evidence.

`reconcile_close` verifies every child in the sealed manager inventory and leaves
the manager closed. Its acknowledgement certifies owned obligations; manager PID
termination remains a separate host lifecycle action.

Registry reconciliation is included, restricted to a fenced owner and exact
receipt-backed entries. It records independently confirmed closure without
repeating cleanup or acknowledgement callbacks. A failed receipt-consumption
obligation needs its own confirmed fact; physical shutdown alone cannot erase it.
Retain original errors while moving confirmed entries into settled accounting.

Session adds `initial_cleanup`, `cleanup_revision` and `reconciliation` to host
status. `cleanup` becomes the latest explicitly reconciled result. Explicit
`reconcile_close` requires the exact Session identity, fenced admission, run
retirement, Registry closure and every owned manager receipt. It keeps
`phase: :closed`; old Session binding stays permanently unavailable. Ordinary
`close` returns the latest result, and remains cached unless explicit
reconciliation changes it. Exact receipt reapplication is a no-op.

For a containing root already terminal `unknown_outcome`, preserve its run state,
outcome, journal, active/uncertain identities, budget, tool results and Goal
attribution/outbox byte-for-byte. A separate receipt may confirm all exact
Provider attempts stopped and lifetime obligations closed. It does not call
`cleanup_settled`, rewrite the root to cancelled/successful, or signal Goal idle.
Fresh independent admission remains a host decision after its own accounting and
readiness checks. Unknown mutating effects still prevent confirmed retirement.

## Archive and fresh followup (#117)

The immutable archive contains schema version 1, archive ID/digest, child identity,
source tool profile, admission and retirement receipt references, authoritative
terminal Store/run/incarnation/revision, canonical messages/host feedback and
history digest, remaining work/deadline, immutable child-request/configuration
and authority-ceiling references, and safe host metadata.

Export obtains committed history and limits from the terminal record. Restore
loads that record or its authoritative read-only archival Store through the
adapter and compares the exact history, limits, original admission and receipt.
The destination's empty execution Store is not a replacement for the original
evidence. Artifact references must still resolve. No arbitrary Conversation state,
PIDs, ports, callbacks, capabilities or grants are serialized.

The host rebuilds child options and fresh authority only on a later execution
admission. Resolve immutable historical configuration/authority references then
and enforce both the prior ceiling and the current ancestry. Missing configuration
or an unprovable ceiling refuses continuation. Import itself calls no child
preparation callback.

Eligibility is completed, failed, cancelled or timed-out history with confirmed
retirement/resource closure and no unresolved effects. Version 1 refuses
unknown-outcome archive continuation even if lifetime retirement is confirmed;
#119 can retire that history separately. Stable root/scope/name/parent must match;
parents are restored before descendants. Import is allowed only into a fresh,
non-executing manager roster: multiple imports and exact duplicate retries are
allowed, but any fresh execution admission in that destination closes the import
phase. No reparenting is introduced.

Archive import creates a nonresident closed entry, preserving child ID/name and
parent, without an execution slot. Host snapshots expose additive `archived`,
`historical_outcome`, `retirement_receipt_ref` and `source_manager_id` fields.
Model `list_agents` keeps its current closed-entry filtering. Emit one `restored`
observer event; exact duplicate import returns the same restore receipt without
an event. New-manager admissions contain only its own fresh attempts; old
admissions remain archive provenance. Changed duplicate, name/ID collision,
conflicting ancestry or obsolete archive after replacement is a conflict.

Do not import pending mailbox/input, interactions, delivery actions, Provider/tool
outbox or Goal bindings. Refuse unsettled accepted-work obligations; do not
silently drop them. Old final results are not delivered again. Historical run-ID
lookup may resolve the archive only when unambiguous and cannot override a current
run mapping.

Recovery-enabled managers allocate opaque run IDs as
`canonical_name <> ":" <> manager_id <> ":" <> sequence`. Other managers keep
their existing format. Later explicit V2 followup or V1 resume uses fresh ordinary
admission, attempt/run identity, an incarnation above the historical recovery
fence, preparation, birth acknowledgement and managed Session binding. Carry
accepted history, remaining budget/deadline and current policy checks. Capacity
refusal leaves the archive unchanged and does not prepare a child. Failed
admission retains history and consumes its attempt identity normally. Old manager,
run, Session, interaction and delivery events cannot settle the replacement.

An archived descendant cannot follow up while its immediate parent is still
archived. Return a conflict before reading parent execution options or calling
preparation. The host must first request and obtain a successful fresh admission
for that parent in this manager; no ancestor starts implicitly. A parent may have
completed that new run, provided its current destination-manager authority is
available and passes normal current-ancestry checks. The root uses this manager's
fresh parent authority. Historical authority is only a ceiling, never executable
parent options or a substitute for fresh authority.

## Write scope and acceptance

Approved implementation would be limited to runtime MultiAgent, Session and
ResourceRegistry; new `codex/reconciliation` and `codex/multi_agent/archive`
modules; their tests; `PERSISTENCE.md`, `EMBEDDING.md`, `CODEX.md` and
`docs/agent-runtime/codex-tools/session-resources.md`. Native command/PDF changes
have separate designs. Store/Kernel/Goal semantics, database migrations, new
dependencies, Memory, downstream repositories and deployment are excluded.

Required verification:

1. Public-only real child completion/closure, export, old manager retirement,
   fresh manager import with zero execution/preparation/cleanup/Goal calls, then
   actual followup preserving ID/history and producing fresh admission/binding.
   Explicitly exercise source/destination sequence 1 and changed old events.
2. Inject child usage and terminal commit failures, including committed-but-lost
   ACK. Recover Store with public fences/Kernel operations; reconcile child,
   manager, Registry and previously uncertain Session, preserving original failure.
3. Retire an exact provider-only terminal unknown root without journal mutation.
   Missing tool/child/dependency/component evidence must remain unconfirmed.
4. Verify exact retries, stale revisions, changed duplicates, partial siblings,
   lost receipt ACK and crash after persist/before projection with fixture barriers.
5. Validate identity/scope/ancestry/fence/history conflicts, missing manifests,
   unresolved artifacts, unsupported versions and nonserializable input.
6. Retain existing admission, observer, interaction, managed Session, manager close
   and Session lifetime coverage. Serialized Mix builds use the task build lock.
7. Run a fixture across two independent BEAMs with a genuinely persisted host
   adapter, CAS/fences and failed ACKs. The second process loads only durable data;
   execution markers prove no replay. Report same-BEAM and cold-BEAM results
   separately. Consumer production-store acceptance remains downstream work.

## Approval choices

Approval accepts the opt-in host adapter/manifest/receipt contract, narrow Registry
reconciliation, stable root/scope identity and manager-qualified recovery run IDs,
closed archived roster behavior, and refusal of unknown-outcome continuation in
this first version. These are proposed policies, not existing runtime guarantees.
