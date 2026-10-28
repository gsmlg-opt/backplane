# Resource retirement, native adapters, and provider-free host context

Date: 2026-10-28. Baseline: main `2a006a9fa762529a33b648f0e8bf805264d9b2f5` (1.10.49).
Target: 1.10.50. Status: approved by the user; implemented and undergoing release verification.
Scope: Backplane internal requests #141, #142, #143.

## Problem and selected approach

| Request | Source-confirmed gap | Required behavior |
| --- | --- | --- |
| #141 | Conversation retains resource_scope_cancellation, but materializes only plugin and Code Mode retirement; Reconciliation accepts only those two types | Persist exact resource-scope retirement that satisfies the original started-tool obligation, including nested execution |
| #142 | cooperative_outer matches the descriptor backend module, so transparent native execution/presentation adapters lose cooperative cancellation | Bind cancellation to actual native execution and its owned worker rather than the outer adapter module |
| #143 | Headless rejects provider_context; preparation and timeout selection use provider_context as their only host input | Expose trusted ephemeral host_context independently of provider transport |

Extend Conversation, ToolEffects, CodeMode and Reconciliation within their current
Store/Session/Registry ownership. Keep the existing public resource scope and
plugin wait APIs and existing business results. No alternate executor, scheduler,
mutable context sidecar, automatic installation or downstream policy is added.

Alternatives considered:

1. Recommended: execution-bound native registration, typed resource retirement,
   and an additive host context option. This retains one source of lifecycle truth
   and supports transparent adapters without weakening cleanup requirements.
2. Recognize any descriptor with family code_mode or any stopped process as
   retired. Rejected: metadata and process death cannot establish actual native
   execution, complete resource inventory, or transport cleanup.
3. Require hosts to bypass their original hooks, wrap context in a fake provider,
   or implement a separate execution/recovery layer. Rejected: this changes the
   intended public composition and duplicates ACK and resource ownership.

## Durable resource scope retirement (#141)

Add schema version 1 record_type `resource_scope_retirement`. Conversation creates
it only from the already validated AggregateCancellation for the exact registered
invocation, after observing its actual effect Task DOWN and confirmed Session or
run-owned Registry resource cleanup within the original finite cleanup deadline.
The public record contains:

- Exact ToolEffects cancellation identity, including enclosing invocation and
  Session binding identity when present.
- Original registration ID, scope generation and stop generation.
- The sealed ordered slot inventory, its count and digest, and the original
  resource_scope_cancellation report. Every admitted slot must have its actual
  handle/client incarnation and validated local retirement receipt. Already
  completed slots remain represented and are never dispatched or cancelled again.
- Provenance tying the record to the Session binding, executor_down true,
  resources confirmed, local_cleanup confirmed, outcome unknown and a canonical
  retirement_digest over the complete public record excluding that digest.

Use exact allowed fields and bounded JSON validation in ToolEffects. Live creation
must validate the original admission capability and inventory digest before they
are converted into portable evidence; cold validation uses the immutable record,
original authoritative intent and trusted evidence adapter, not a reconstructed
ephemeral capability. A checksum detects corruption; the adapter supplies storage
provenance. Preserve the existing 128-slot bound and original deadlines.

Retain proofs in status retirement_evidence and durable cleanup evidence. Include
the same bound record at terminal persistence; do not emit a durable confirmed
claim before the terminal Store ACK. ACK failure retains existing unknown-outcome
semantics. No clearing of started-tool obligations on generic errors is added.

Reconciliation recognizes the new type, validates exact authoritative invocation
and Session identity and retained source generation, and permits it as a nested
reference in code_mode_retirement. Outer proofs enumerate every original nested
intent: either its exact typed retirement digest or its acknowledged settlement
digest. All nested retirement references must have the same stop generation as
the outer proof. Omitted, duplicate, foreign, reordered or changed slot records,
wrong identity and mismatched nested digests remain unconfirmed. Historical
results and cancelled/unknown business outcomes are unchanged by local retirement.

The direct resource-scope and real-Deno nested paths must both support subsequent
whole-child reconciliation through existing public APIs. Independent callers and
the shared MCP client remain alive; client reinitialization is not cleanup proof.
Legacy single-request cancellation behavior remains unchanged by this extension.

## Actual native Code Mode identity through adapters (#142)

Add an invocation-scoped Runtime callback for registering actual native Code Mode
execution. Native CodeMode invokes it after obtaining its real Registry-owned
worker/handle and before beginning or resuming guest execution. The registration
binds the exact outer invocation, current effect token, owner/Session incarnation,
Registry handle and worker identity. Conversation verifies its live outer effect
caller, current pinned invocation, and Registry ownership before retaining it.
For wait, validate and bind the existing continuation to the new wait invocation
before resuming; an old exec registration cannot authorize a later wait.

Carry this Runtime-owned callback through the same trusted backend context as
nested_dispatch and register_cancellation. A transparent adapter preserves it and
delegates once to native execution, then may use ToolEffects.present for its normal
result. Adapters need no new metadata assertion, replacement hook or alternate
cancel handler. No closures, PIDs or Registry handles enter durable history.
Standalone CodeMode.execute/resume users keep their existing API; registration is
required when using this Conversation-owned composition, not for standalone calls.

cooperative_outer uses the live native registration and exact enclosing nested
identity. A family tag alone, adapter module name, stale token, foreign worker or
mere invocation of nested_dispatch cannot authorize cooperative outer coverage.
Registration grants no cleanup proof: the exact nested cancellation report, Task
DOWN, Deno/Registry/Session cleanup and finite deadline remain independently
required before either outer or nested retirement is confirmed. Registration is
cleared on settlement, cancellation or replacement of the outer effect.

## Trusted provider-independent host context (#143)

Add optional map `host_context` to Conversation.start_link and Headless.start_link.
Reject non-map values before starting a run. It is trusted ephemeral host data,
including resolver functions and ordinary metadata; it is never guest input,
provider request content, catalog metadata or serialized execution history.
Headless continues rejecting both provider and provider_context options.

For tool preparation, finite timeout selection and trusted tool execution, start
with the existing provider_context compatibility data and overlay host_context
(host_context wins ordinary duplicate host keys). If host_context is absent,
provider-backed consumers retain existing behavior. Provider effect execution
continues receiving its original provider_context, without the new host map.

After merging host data, Runtime overwrites authoritative invocation/catalog,
Session ownership, callbacks and deadlines. Timeout selection remains inspection
only and strips all execution/publication callbacks, including the new native
registration callback. Preserve the established descriptor backend context
boundary: host_context does not overwrite native family-specific dependencies.
Original hooks can resolve and return those dependencies using the supported
preparation hook as before. Nested tools use the same current trusted host context
and their exact pinned invocation/catalog, without copying context into Store.

## Scope and verification

Implementation ownership: apps/backplane_agent_runtime code, public documentation,
tests and package consumer qualification relevant to these three contracts; release
metadata and the existing unified five-package publication workflow. No unrelated
Memory changes, downstream edits/upgrades, deployments, dependency workarounds,
new branches/worktrees or new permission/sandbox features are included. Do not
append newly opened issues to this release automatically.

First reproduce the supported public occurrences with real owned effects, Deno
and MCP fixtures where relevant. Do not fabricate cleanup records or seed private
Runtime state to make acceptance pass. Cover:

1. Direct and Deno sequential MCP scope: completed first page, pending second page,
   exact interruption, independent caller survival, same-client reuse with one
   initialization, parent continuation, durable readback and complete child/host
   retirement. Confirm receipt inventory and original outcomes remain intact.
2. Plugin wait direct/Deno with and without a transparent post-hook adapter,
   preserving exact plugin and outer retirement evidence. Late explicit host
   installation cannot mutate the original run; a fresh admitted run succeeds.
   Exercise resumed wait as well as initial exec and reject unbound registration.
3. Provider-free Headless with original resolver-based preparation/timeout hooks,
   caller-owned Store and pinned catalog: one ordinary nested local effect,
   committed intent before effect and result before reply, raw terminal result and
   ordered output, zero provider calls/events and confirmed normal worker close.
   Check existing provider_context consumers and provider/host context separation.
4. Cold public reconciliation validates retained resource and nested retirement
   after original processes are gone. Missing or changed proof cannot close an
   unresolved started obligation; no replay occurs.

Run focused regressions, complete owning Runtime suite, strict compilation,
formatting, strict Credo, configured Dialyzer and workflow contract checks, then
applicable exact-SHA CI. Run required protocol tests if implementation changes
protocol code; do not broaden scope to unrelated failures. Serialize shared BEAM
build/test state. Publish 1.10.50 only after required gates pass. Verify terminal
release jobs, five official Hex packages and fresh exact-version consumers,
archive/qualification checksums and container source/version provenance. Local,
CI, artifact and downstream evidence are reported separately; no downstream
deployment or real host-client acceptance is claimed from local fixtures alone.
