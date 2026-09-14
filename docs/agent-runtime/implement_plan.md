# Shared Agent Runtime — Implementation Plan

**Package:** `backplane_agent_runtime`  
**Primary repository:** `gsmlg-opt/backplane`  
**Consumer repositories:** `gsmlg-opt/sigma`, `gsmlg-opt/Synapsis`, `gsmlg-opt/backplane`  
**Date:** 2026-09-10  
**Updated:** 2026-09-14  
**Document revision:** 1.4 — verified bounded consolidation  
**Status:** Plan approved; bounded package consolidation verified; T18 and later work not started  
**Companion documents:** [Design](design.md), [PRD and acceptance scenarios](prd.md)

## 1. Execution contract

Implement the agreed multi-agent runtime and all in-scope bundled tools in one `backplane_agent_runtime` Mix application/package under `Backplane.AgentRuntime`, with concrete tools in `Backplane.AgentRuntime.Tools.*`. Keep one version, changelog, and release pipeline without merging the products or changing their business roles. Use the PRD's FR/AC identifiers as the completion contract and the design's I01–I24 as invariants.

Do not treat this plan as evidence that every proposed module or bundled tool exists, that sibling protocol versions are available, or that current tests pass. Use [baseline.md](baseline.md) for dated implementation evidence. The earlier attachment's singleton daemon, Oban, and table proposals are historical, not instructions to migrate a database or scheduler.

Work in small PRs. A task is complete only with code, focused tests, exact evidence, and a bounded handoff. Opening a facade around a legacy engine does not complete migration of its enforcement responsibilities.

The 2026-09-14 bounded consolidation keeps the existing `Backplane.AgentRuntime.Tools` facade, moves the local adapters to `Backplane.AgentRuntime.Tools.LocalResource` and `Backplane.AgentRuntime.Tools.LocalCommand`, and removes the `Backplane.AgentTools` forwarding facade and second Mix application. These actual names are the current private decomposition; broader `Tools.Resource.*`, `Tools.Command.*`, and other family names in this plan remain proposed task scopes.

The final focused adapter run passes 14 tests with 0 failures, including repaired file edits and the approved command-launch handshake. The full package passes formatting, warnings-as-errors compilation, and 123 tests with 0 failures. The complete verifier builds one 0.1.0 artifact and runs fresh empty-tool, bundled-basic, and fake-backend consumers against SHA-256 `49ab63d8ff12ebd18389cafa388e04c81179f35e42e673eb1395bd4005d62213`; the bundled-basic fixture performs an actual local resource read and local command invocation. This bounded result does not complete T01, T13, T14, T23, or any milestone. The implementation remains uncommitted at this evidence point; push and pull-request creation follow separate review and publication steps. Exact commands and limits are recorded in [baseline.md](baseline.md).

### 1.1 Global guardrails

- Preserve each product's public session/API/event and historical storage contracts unless a separately reviewed migration explicitly changes them.
- Never enable real autonomous mutations, execute billable model calls in CI, publish the package, or deploy services as a side effect of implementation.
- Do not create a second tools Mix app, namespace root, version, or release pipeline. Keep generic kernel/gateway code independent of concrete `Tools.*` implementations; tool registration and backend startup remain host-selected.
- Do not copy provider parsers, implement a second memory/Skill service, introduce a new universal database, or add a generic workflow engine to unblock a task.
- Do not create dual controllers for one context or compare engines by running both against real mutating tools.
- All source, toolchain, sibling dependency, and platform assumptions must be recorded with actual versions or explicitly marked blocked.
- A missing security/durability capability must return an explicit error; do not implement a permissive production fallback behind an adapter stub.

## 2. Coordination and parallel work

### 2.1 Work lanes

| Lane | Scope |
| --- | --- |
| R — Runtime | Contracts, kernel, ports, lifecycle, budgets, policy, messaging, recovery. |
| T — Tools | Bundled opt-in file/resource, command, plan, and Memory/Skill wrappers within the same runtime package, plus their reference adapters. |
| S — Sigma | Existing facade/storage compatibility and shared execution adoption. |
| Y — Synapsis | QueryLoop, graph, role-agent/daemon adapters and storage conformance. |
| B — Backplane service | Opt-in service-owned profiles and restricted domain-tool integration. |
| Q — Conformance/release | Fixtures, fault matrix, cross-consumer tests, artifact independence, release evidence. |

One coordinating maintainer owns public contract/schema changes and the single package's Mix manifest, dependency declarations, version, and release configuration. Runtime and Tools lanes are module ownership boundaries, not separate release units. Contributors propose changes through that owner instead of independently renaming types or modifying shared event semantics. Create worktrees per task/PR and avoid simultaneous edits to the same contract files.

Consumer teams may inventory and write fixture tests early. They may not work around unfinished shared requirements with a second executor. Use test-only scripted ports while an upstream contract is blocked; record the block and continue independent tasks.

### 2.2 Dependency table

| Task | Lane | Depends on | Milestone |
| --- | --- | --- | --- |
| T00 | R/Q + consumer maintainers | None | M0 |
| T01 | R/Q | T00 | M0 |
| T02 | R | T00, T01 | M1 |
| T03 | R/Q | T02 | M1 |
| T04 | R | T02 | M1 |
| T05 | R | T03, T04; verified sibling contract from T00 | M1 |
| T06 | R | T03, T04 | M1 |
| T07 | R | T03, T05 | M1 |
| T08 | R | T03, T04 | M1 |
| T09 | R | T06, T07, T08 | M2 |
| T10 | R | T03, T04, T08, T09 | M2 |
| T11 | R | T06, T08, T09, T10 | M2 |
| T12 | R/T | T04, T10, T11 | M2 |
| T13 | T | T01, T04, T06 | M2 |
| T14 | T | T01, T04, T06, T08 | M2 |
| T15 | T | T01, T03, T04, T07 | M2 |
| T16 | Q/R | T03, T05, T06, T08 | M3 |
| T17 | R/Q | T03, T06, T07, T08, T10, T11, T16 | M3 |
| T18 | S | T05, T06, T07, T09, T16 | M4 |
| T19 | S | T12, T13, T14, T15, T17, T18 | M4 |
| T20 | Y | T05, T06, T07, T09, T10, T12, T16 | M4 |
| T21 | Y | T17, T20 | M4 |
| T22 | B | T12, T16, T17 | M4 |
| T23 | Q + consumer maintainers | T13, T14, T15, T19, T21, T22 | M5 |
| T24 | R/Q + consumer maintainers | T23 | M5 |

Safe parallel groups after their dependencies pass: T03/T04; T05/T06/T08; T13/T14/T15 alongside hosting/collaboration work; T16 alongside tools; T18/T20 alongside generic recovery completion; T19/T21/T22 after the appropriate recovery gate.

The dependency table is authoritative for integration ordering. A contributor can prepare tests/adapters earlier but cannot mark the task complete against missing prerequisites.

## 3. Baseline and shared core tasks

### T00 — Rebaseline sources and freeze extraction boundaries

**Scope:** Read-only inventory across all three repositories, then a small design/baseline record in Backplane. No broad refactoring.

**Work:** Record current branch/commit SHAs, dirty-worktree boundaries, Elixir/OTP/dependency versions, current package conventions, CI commands, actual provider/Skill contract availability, and tool/resource/command capabilities. Inventory Sigma execution/facade/hooks/storage; Synapsis QueryLoop, graph, daemon/routines, role definitions, and stores; Backplane domain-service APIs and release boundaries.

Compare findings with historical sources in `design.md`. Resolve the exact shared AI types and version/consumption path, without inventing a published version. Identify the schema validator and its supported subset. Record which storage operations actually satisfy durable acknowledgements, CAS, and event/outbox atomicity.

Record the single package path/application/namespace and classify each proposed dependency as core, optional-adapter, host-owned, or test-only. Map tool source into `Tools.*` and generic execution into contracts/ports; verify that empty-tool consumers will not require command helpers or service backends. If a partial tools scaffold already exists, inventory its callers and plan a bounded consolidation rather than maintaining two release streams or deleting it blindly.

**Tests/evidence:** Run existing focused baselines when the environment permits; otherwise record the exact blocker, not a pass. Capture public session/event/permission fixtures and known pre-existing failures.

**Acceptance:** Approved dependency/ownership map and baseline evidence. Sources conflicting with the target are distinguished from requirement changes.

**Stop condition:** Missing upstream protocol/storage capability produces a precise upstream request. Do not recreate the missing service or parser inside the runtime.

### T01 — Scaffold one independently buildable package and profile fixtures

**Scope:** `apps/backplane_agent_runtime`, its package-local Mix configuration, internal layer layout, formatting/test support, single-artifact/clean-consumer CI harness, and one changelog/release definition. No service integration.

**Work:** Create one `:backplane_agent_runtime` application with the `Backplane.AgentRuntime` namespace and one version. Reserve generic `Tool.*`/`Ports.*` contracts, concrete `Tools.Collaboration.*`, `Tools.Resource.*`, `Tools.Command.*`, `Tools.Plan.*`, `Tools.Memory.*`, `Tools.Skill.*`, and explicitly configured `Adapters.*` modules. Do not create a tools sibling app or separate publication task.

Make runtime naming/configuration injectable and startup inert with respect to product agents, tool registration, workspaces, subprocesses, and optional backend clients. Add a module-dependency check that rejects kernel/gateway calls into concrete tools. Record core versus optional/host/test dependencies; optional adapter modules must compile when their optional libraries are absent.

Provide a standalone artifact harness outside the service release path and an initial scripted zero-tool consumer. Define empty-tool, bundled-basic, and fake-backend profiles that will all consume the identical artifact/version as the tool tasks land. Package tests may use ExUnit/support libraries, but production must not depend on test infrastructure or umbrella-relative configuration/build/dependency/lockfile paths. Artifact assembly must include the bundled implementation files, not only their descriptors.

**Tests:** Initial AC-01/AC-33, NFR-01. Build the standalone skeleton without service configuration or optional backends, verify a zero-tool boot, and exercise the dependency/startup checks. Extend this harness in T12–T15 and T23 for the completed tool profiles; scaffold checks do not count as final acceptance.

**Acceptance:** One artifact resolves its declared dependencies and compiles independently. Installing/booting it registers no tools or optional backends, the layer check is active, and no separate tools release exists. Full contents/activation acceptance remains pending until the tool tasks pass.

**Stop condition:** Do not pin an unavailable sibling package, use an `in_umbrella`-only production dependency, or hide a mandatory backend dependency behind a disabled-tool flag.

### T02 — Domain types and deterministic execution kernel

**Scope:** Runtime contracts, IDs, commands/events/effects, state transitions, errors, contract fixtures.

**Work:** Define AgentDefinition/AgentInstance, Context, Task, Run, attempts, ToolInvocation, ownership/dependency references, Approval, and event envelopes. Freeze concrete public types/API operations under the coordinating maintainer. Keep provider-owned canonical payload types at the agreed boundary.

Implement kernel transitions for admission, start, waits, effect completion, cancellation, deadlines, and terminal outcomes. Time/IDs/randomness arrive as inputs. Include expected revision, effect identity, incarnation fencing, and terminal precedence. Distinguish cancellation request acknowledgement from terminal completion.

**Tests:** AC-03, AC-06, AC-14; generated transition sequences for one terminal, invalid transition rejection, deterministic replay, and no effects during pure replay. Test serializable contracts without internal process terms.

**Acceptance:** A scripted sequence produces a complete run and explicit effects without I/O in the kernel; invalid/duplicate/late inputs cannot reopen a terminal run.

**Stop condition:** Do not add an execution process or store-specific records to compensate for unclear domain contracts.

### T03 — StorePort, ephemeral store, and asynchronous commit discipline

**Scope:** Runtime storage interface, ephemeral implementation, transition coordinator, contract/fault fixtures.

**Work:** Implement expected-revision commits, transition-associated events/outbox intents, scoped reads, idempotency records, mode/capability declarations, and commit errors. Build a controllable test store that can fail/delay acknowledgements; it is not a production durable backend.

Integrate staged asynchronous commits with kernel ownership: unacknowledged effects cannot execute, cancellation remains serviceable, and late acknowledgements cannot overwrite a newer state. Define versioned recovery/checkpoint records and large-artifact references without prescribing consumer schemas.

**Tests:** AC-06, AC-14, AC-24 and NFR-02. Restart an ephemeral instance to prove documented loss; inject failed/stalled commits to prove no false durable acceptance or dependent effect dispatch.

**Acceptance:** The store contract and failure semantics are reusable by all consumer adapters. Missing durable capabilities fail configuration/admission explicitly.

**Stop condition:** Do not mark the fake store as proof of real power-loss durability or introduce a compulsory database.

### T04 — Policy, tool registry, schemas, and approval contracts

**Scope:** Runtime PolicyPort, generic `Backplane.AgentRuntime.Tool.*` registry/gateway contracts, versioned descriptors, profile validation, and approval records/decisions. No concrete tool implementation belongs in the kernel/gateway.

**Work:** Bind caller/run/resource authority from trusted runtime context. Validate tool lookup, schemas, arguments, descriptor/grant revisions, profiles, delegation contracts, and output limits. Separate read-only, retry-safe, and parallel-safe metadata. Use restrictive defaults for untrusted remote metadata.

Make direct APIs and model wrappers share admission. Bind approvals to exact operations, expiry, identity, and revisions; reject model self-approval. Define revocation/revalidation at safe execution boundaries and behaviour when no interaction resolver exists.

Separate bundled availability, host-selected registration, and per-invocation authorization. Optional selections omit unavailable entries with reasons; an explicitly required missing/incapable backend fails profile validation with `missing_backend` or `unsupported_capability`. Adding a backend must not auto-register tools. Backend loss after registration produces a typed error rather than a permissive fallback.

**Tests:** AC-16 through AC-19, AC-34, AC-36, NFR-04. Include forged identity/module names, changed arguments after approval, stale approval, absent backend, and direct-call bypass attempts.

**Acceptance:** No side effect is permitted without a registered descriptor and a successful exact-operation policy decision. Empty tool sets work, missing explicit requirements fail configuration, and profile validation requires no knowledge of a concrete tool module in the kernel/gateway.

**Stop condition:** Do not interpret Skill metadata, role names, or remote MCP annotations as authorization grants.

### T05 — ProviderPort and fenced model attempts

**Scope:** Runtime provider effect adapter and canonical stream integration; no new provider codecs.

**Work:** Integrate the sibling canonical types verified in T00. Add asynchronous start/cancel, model-step/attempt identity, output/input limits, normalized completion/errors, continuation capability reporting, and usage metadata. Associate model tool calls with the run's exposed tool snapshot.

Buffer/validate tool calls through canonical response completion before admitting execution. Treat incomplete or malformed terminal responses as failures, not executable partial results. Define interrupted-stream retry/continuation rules without silently combining attempts.

**Tests:** AC-07, provider portion of AC-13, AC-28, AC-33. Script malformed JSON, missing completion, duplicate/late chunks, cancellation, cumulative usage, and unsupported continuation.

**Acceptance:** A real adapter boundary and a scripted test port produce the same runtime lifecycle events; no runtime-owned OpenAI/Anthropic parser is added.

**Stop condition:** Upstream contract unavailability blocks production integration, not justification to fork protocols. Continue independent tasks.

### T06 — Tool effects, scheduler, cancellation, and normalization

**Scope:** Shared invocation executor, scheduling/resource conflict boundaries, normalized results/progress, cancellation/cleanup lifecycle.

**Work:** Execute only admitted committed invocations. Separate worker limits from waiting continuations; enforce deadlines, cancellation, bounded output, backend capability checks, and ordered tool-result association. Preserve idempotency/effect-certainty data through errors and retries.

Use asynchronous retry scheduling with remaining-attempt/time envelopes; never nest hidden retries. Revalidate changed/revoked descriptors/grants before dispatch. Integrate model-independent ToolBackend ports so legacy Dispatcher/Gateway adapters can be used without bypassing shared policy.

**Tests:** AC-13, AC-14, AC-18, AC-19, scheduler portion of AC-35 and NFR-02. Race completion/cancellation, fail worker tasks, return malformed data, and saturate worker slots.

**Acceptance:** Every invocation has one normalized committed completion or explicit uncertainty, cancellation remains controllable, and result order is independent of execution completion order.

**Stop condition:** Do not equate killing an Elixir task with confirming the external operation was undone.

### T07 — Context coordination, isolation, fork/merge, and compaction

**Scope:** Runtime ContextPort/ownership, versioned context transitions, context composition and compaction effects.

**Work:** Serialize same-context writers, allow isolated task contexts, and reject stale commits. Implement explicitly selected child snapshots, provenance, context-safe result admission, instruction/resource references, and controlled summary/merge updates.

Integrate capacity estimation and compaction using verified model metadata/fallback limits. Count compaction model work; preserve unresolved tool pairs, approvals, and dependencies. Expose context revision and compaction events separately from lifetime token totals.

**Tests:** AC-04, AC-05, AC-28, AC-36. Exercise concurrent writes, forks, selected inheritance, compaction failure/cancellation, missing model metadata, and resource text trying to override policy.

**Acceptance:** One authoritative context owner survives concurrent work and retry races; no child/peer receives implicit private history or action grants.

**Stop condition:** No last-write-wins history merge and no assumption that a context fork reverses external edits.

### T08 — Root budgets, reservation protocol, fairness, and hard loop breakers

**Scope:** Root accounting coordinator, quotas/admission, reservation records, no-progress/retry/delegation guards.

**Work:** Implement finite model/tool/attempt/time/output/depth/child/delegation limits. Bind child and recipient work to authorized budget accounts; implement idempotent reservations and target acceptance/reconciliation so release cannot double-spend.

Add per-agent fairness, bounded queue admission, explicit overload, cancellation-aware deadlines/backoff, and repeated normalized tool/delegation fingerprints. Keep cost estimates and missing usage distinct from logical hard caps. Test live monotonic deadlines and conservative recovery after clock regression; no restart may reset the task deadline. Do not double-count descendant aggregates.

**Tests:** AC-08, AC-15, accounting portion of AC-28/AC-35 and NFR-03. Simultaneously submit sibling children/delegations at the quota boundary and replay reservation acknowledgements; verify hard stop despite model argument variations.

**Acceptance:** No execution route resets its budget through retry, compaction, child creation, or peer delegation. Capacity is reusable only after ownership/effect reconciliation permits it.

**Stop condition:** No claim of exact provider billing control from estimated token/cost reservations.

## 4. Hosting, collaboration, and basic tools

### T09 — Managed agent hosting and embedded endpoints

**Scope:** Runtime instance supervisor/registry, managed AgentHost, context/run ownership, embedded endpoint contract.

**Work:** Support hosted and owner-bound identities, independent instances, bounded work admission, optional activation/rehydration, and multiple task contexts per role. Add embedded adapters that permit an existing product worker to own the kernel state without a second managed controller.

Host control callbacks delegate I/O and remain available while a run waits. Host shutdown/agent stop are trusted operations, distinct from model-visible run cancellation. Runtime installation starts no product agent automatically.

**Tests:** AC-02, AC-03, AC-05, AC-06 and NFR-02. Start two runtime namespaces; reject duplicate ownership; exercise a fake product worker as an embedded endpoint.

**Acceptance:** The same shared execution contracts run through managed and embedded modes, with a single writer and no product session dependency.

**Stop condition:** Do not add a Session requirement or unqualified global registered process to simplify routing.

### T10 — Typed messaging, inbox/outbox, and peer task admission

**Scope:** Local router, messaging policy, delegation submission/acceptance records, inbox/outbox dispatch and bounded admission.

**Work:** Implement typed messages with trusted sender, target visibility, payload/TTL limits, deduplication, acceptance states, and provenance. A task request starts work only after receiver delegation-policy validation. Notifications/status/acknowledgements do not invoke a model by default.

Use a stable submission identity across outbox replay and ambiguous acknowledgement. Distinguish submission, receiver acceptance, target run progress, and completion. Implement payload-digest conflict handling and retention rules that never evict live idempotency state.

**Tests:** AC-10, AC-11, AC-25, messaging portion of AC-35/AC-36. Replay duplicate task requests, overflow inboxes, drop acknowledgement, and submit the same key with changed payload.

**Acceptance:** Peer task routing does not own the receiver's agent lifetime. Delivery/acceptance guarantees accurately reflect the configured store mode.

**Stop condition:** No network transport, remote placement, or distributed transaction work in this task.

### T11 — Nested children, dependency continuations, and cancellation trees

**Scope:** Run-owned child creation, dependency graph, continuation/wait resolution, child/delegation cleanup contracts.

**Work:** Admit child agent+initial run with explicit inherited context, non-expanding grants, root budget, depth, and ownership. Support another child level through the same mechanism. Require children/dependencies to settle before an owner can complete.

Implement asynchronous wait continuations, cycle and held-context dependency checks, deadline/cancellation propagation, and exactly one suspended-invocation resolution. Cancel accepted peer work only under its contract, never the target hosted agent. No model-visible detach/adopt operation.

**Tests:** AC-09, AC-10, AC-12, child portions of AC-13/AC-14/AC-15. Main→child→grandchild, A↔B waits, waits on one's held context, cancel during child startup, and unrelated recipient work survival.

**Acceptance:** Structured ownership and peer collaboration coexist without conflating their lifetime, permission, or budget relationships.

**Stop condition:** Do not solve deadlocks by adding concurrent writers or hiding live child jobs after parent completion.

### T12 — Runtime collaboration tools and user interaction wrapper

**Scope:** Bundled `Backplane.AgentRuntime.Tools.Collaboration.*` wrappers over the completed runtime/gateway APIs, within the single package.

**Work:** Implement `agent_discover`, `agent_spawn`, `agent_delegate`, `agent_send`, `run_status`, `run_wait`, `run_cancel`, and `ask_user`. Define bounded input/output schemas, target visibility, task/context data selection, and normalized errors.

Register tools only through a host-selected profile, never during package/application startup. Include their implementations and tests in the same artifact as the runtime. Ensure `run_wait` suspends the invocation without holding a tool slot. Keep information requests separate from permission resolution. Status/discovery/waits do not generate model polling calls.

**Tests:** AC-09 through AC-12, AC-16 through AC-19, AC-34. Exercise APIs and wrappers against identical denied/allowed operations, hidden agents, zero-tool profile, and no-resolver headless runs.

**Acceptance:** Wrappers add no alternate executor or elevated internal privilege. Each result contains only authorized identifiers/data and represents the correct acceptance/completion stage.

**Stop condition:** Do not expose agent-definition/permission mutation, model self-approval, arbitrary context replacement, or hosted-agent shutdown as default tools.

### T13 — Shared file/resource tools with revision-safe writes

**Scope:** `Backplane.AgentRuntime.Tools.Resource.*` and ResourcePort/reference adapters/tests inside `apps/backplane_agent_runtime`. No repository manager, second Mix app, or shell work.

**Work:** Implement `file_read`, `list_dir`, `glob`, `grep`, `file_write`, and `file_edit` through an authorized resource namespace. Support bounded/partial reads and searches, structured resource references, expected-revision replacement, and create-only writes. Preserve the common tool gateway and output/error contracts.

Implement a local-workspace adapter only with explicit supported confinement semantics. Test symlink handling and concurrent replacement; use a stronger backend or reject profiles where the required confinement cannot be guaranteed. Keep schema/input policy separate from OS enforcement. State which writers participate in the resource coordinator; do not claim compare-and-set against arbitrary external writers based on atomic rename.

**Tests:** AC-20, AC-19, relevant AC-16/AC-36, bundled-basic AC-01/AC-34 coverage. Use temporary directories and a fake non-filesystem resource backend. Race writes against the same revision; attempt traversal, symlink changes, and output overflow. Run the same artifact with the family disabled and with it explicitly configured; no workspace is touched merely by package startup.

**Acceptance:** Bundled implementations are present in the single release artifact; valid scoped operations work, stale writes fail without silent overwrite, and platform/backend capabilities are documented. Consumers with no selected resource tools still require no workspace/path or configured filesystem backend; generic core code has no concrete-resource-tool dependency.

**Stop condition:** Do not call a lexical path-prefix check a sandbox, or silently weaken resource confinement to make a test pass.

### T14 — Run-owned command jobs and tested cleanup

**Scope:** Bundled `Backplane.AgentRuntime.Tools.Command.*` implementations of `exec`, `job_read`, and `job_cancel`, plus CommandPort, a supported reference backend, and platform conformance fixtures. Registration stays opt-in.

**Work:** Implement explicit executable/argv execution, separately authorized shell mode, injected working directory, environment allowlist, deadline/output limits, run-owned jobs, cursor-based output, and descendant cleanup. Cancellation and parent completion must account for every live job.

Declare supported OS/backend capabilities based on tests. If isolation is not provided, say so; do not label the tool a sandbox. Refuse required capabilities that cannot be enforced. Do not detach jobs or allow arbitrary process IDs supplied by the model. Default active commands to an exclusive workspace conflict key, shared with resource tools; narrower concurrency requires explicit host-attested semantics.

**Tests:** AC-21, command portions of AC-13/AC-14/AC-35, profile portions of AC-01/AC-34, and NFR-04. Use harmless fixtures that create a child process, stream excess output, stall, and inspect a sentinel environment variable. Verify supported cleanup leaves no descendants. Compile/boot the same package with CommandPort/helper executables absent; requiring an unavailable command capability fails profile validation, and package startup launches no job.

**Acceptance:** Jobs stay attributable to the initiating run and can be cancelled/observed without leaking secrets or requiring unbounded buffers. Unsupported platform capabilities fail closed.

**Stop condition:** Do not substitute unbounded blocking command execution or ignore cleanup failures. Preserve uncertain outcomes when external mutation cannot be reconciled.

### T15 — Plans and backend-conditional memory/Skill bridges

**Scope:** Bundled `Backplane.AgentRuntime.Tools.Plan.*`, `Tools.Memory.*`, and `Tools.Skill.*`, scoped fake-port tests, and a sibling Skill adapter only where verified. No independent tools release or compulsory backend library.

**Work:** Implement task-scoped `plan_read`/`plan_update` with expected revision. Implement memory search/store and Skill list/load wrappers against host-provided ports. Bind allowed memory scopes, provenance, bundle revision/digest, resource handles, and output limits.

Keep all in-scope wrapper implementations in the artifact even when no backend is installed. Omit unavailable entries from optional profile selections with an explanation; explicitly requiring an unavailable port/capability fails configuration under T04. Keep Skill resolution/activation distinct from tool authorization. Real memory stores, remote Skill APIs, long-term consolidation, and Skill selection UX remain host/sibling work.

Generic wrappers depend only on runtime-owned ports. Any verified optional-library adapter must compile without that library, capability-check before registration, and start only through explicit host configuration; adding the wrapper must not add an unconditional memory/Skill/MCP service dependency.

**Tests:** AC-22, AC-23, AC-33, AC-34, AC-36 and NFR-01. Concurrent plan updates; attempted cross-agent memory access; a malicious Skill requesting elevated tools; optional versus explicitly required missing backends; configured fake memory and immutable Skill ports. Test the same artifact with backend libraries absent, fake ports configured, and each declared optional-library adapter dependency present. No unconfigured clients or tools may start/register.

**Acceptance:** Plans and bridge wrappers ship with the runtime and create no hidden tasks. Unconfigured consumers still compile/boot; configured bridge tools enforce grants through the gateway. Service implementations do not become mandatory runtime dependencies, and no separate tools version or artifact is introduced.

**Stop condition:** Do not create a new memory service, replicate Skill parsing, or advertise a nonfunctional placeholder tool when an upstream port is unavailable.

## 5. Events, recovery, and consumer adoption

### T16 — Canonical events, bounded subscriptions, and usage accounting

**Scope:** Event envelopes/projections, replay/snapshots, bounded subscriptions, telemetry/usage aggregation fixtures.

**Work:** Implement schema versions, stable event IDs, per-aggregate sequences, causation/root references, cursor retention, and authorized snapshots. Distinguish provisional text/progress from committed state. Coalesce/drop provisional deltas with explicit gap markers and disconnect/limit slow observers without blocking execution.

Aggregate usage by attempt/report identity; distinguish deltas, cumulative snapshots, unknown counts, estimates, cache/reasoning fields, compaction, and child totals. Measure first-token, generation, total run, wait, and tool time separately. Redact secrets and restrict content-bearing event visibility.

**Tests:** AC-27, AC-28, subscriber portion of AC-35, NFR-07. Duplicate usage reports, nested aggregation, cursor expiry, slow subscribers, disconnect/reconnect, and hidden-resource events.

**Acceptance:** Metrics do not double-count or invent missing values; replay preserves original terminal identity and ordering claims are per aggregate only.

**Stop condition:** Do not retain unlimited terminal/delta buffers or claim every client sees every provisional token under overload.

### T17 — Generic durable recovery and storage conformance harness

**Scope:** Runtime recovery coordinator, durable StorePort conformance/fault harness, invocation certainty and ownership/accounting reconstruction.

**Work:** Recover committed nonterminal records, renew/fence incarnations, restore context/relationships/reservations, replay outboxes idempotently, and reconcile each unresolved effect. Resume only proven-safe operations. Preserve `unknown_outcome` and evidence for uncertain mutations.

Test failure windows around commit, dispatch, external acknowledgement, result recording, terminal commit, and outbox/acceptance. Define adapter fixtures reusable by consumer integration tests. A generic harness is not a claim that any real consumer store already passes.

**Tests:** AC-13, AC-14, AC-24, AC-25, AC-26. Fail/restart fake components at deterministic boundaries, prove no stale-result commits, duplicate terminals, automatic mutation replay, or premature budget release.

**Acceptance:** Recovery behaviour is deterministic and the conformance suite can be run against a real host adapter. Exposed durability guarantees match StorePort capabilities.

**Stop condition:** Do not make recovery retry every unfinished operation or equate task deduplication with exactly-once side effects. Real-store evidence is required in T19/T21/T22 before claiming durable consumer support.

### T18 — Sigma compatibility adapters and embedded runtime facade

**Scope:** Sigma provider/tool/context/storage/event adapters plus existing public runtime/session seams verified in T00. No UI redesign or history rewrite.

**Work:** Adapt the provider and coding Dispatcher to shared contracts; preserve the existing permission/hook semantics while routing through common enforcement. Register the session-owned main agent as one embedded endpoint with one context writer. Map shared events into existing public/UI/headless contracts.

Capture parity for prompt, steer, follow-up, model selection, cancellation, subscriptions, fork, and historical replay. Define where runtime metadata belongs without changing legacy session interpretation. Active sessions remain on their selected engine until a safe new-context boundary.

**Tests:** Adapter portion of AC-29, AC-05, AC-18, AC-27. Existing focused Sigma tests plus scripted facade/event fixtures. Trace gateway entry to prove adapters do not bypass authorization.

**Acceptance:** Existing clients can use the facade with shared adapters, and no second session controller or provider parser exists. Report remaining legacy execution functions explicitly.

**Stop condition:** This adapter task alone is not full execution migration. Do not remove old code until T19 passes, or broaden into unrelated skill/UI work.

### T19 — Sigma execution migration, nested agents, and durable adapter proof

**Scope:** Sigma's actual loop/lifecycle replacement, run-owned child integration, bundled common tools selected where compatible, persistence conformance and rollout flag.

**Work:** Replace duplicated model/tool lifecycle, cancellation, hard-loop protection, root budget handling, and context transitions with shared components. Preserve host-owned hooks, repository/session lifetime, prompt queues, JSONL/history/fork semantics, and public protocols.

Integrate child/grandchild runs and selected `Backplane.AgentRuntime.Tools.*` families through the gateway using the single runtime dependency; retain Sigma-specific tools locally. Implement/validate durable runtime records or a reviewed sidecar using existing persistence boundaries; do not claim the historical store can already provide missing atomicity. Keep regenerated/forked runs from silently replaying previous mutations.

**Tests:** AC-09, AC-13, AC-14, AC-24, AC-26, full AC-29, I24 Sigma coverage. Run real-store restart tests and the same scripted model/tool scenarios as the standalone consumer.

**Acceptance:** Sigma's shared path contains one enforcement engine, retains public parity, and passes nested cancellation and durable conformance at the adapter's declared guarantee.

**Stop condition:** If the store lacks necessary acknowledged/CAS behaviour, record the precise upstream/adapter change; do not advertise durable mode or rewrite all history as a shortcut.

### T20 — Synapsis roles, daemon integration, and QueryLoop migration

**Scope:** Synapsis QueryLoop and role-agent integration; preserve daemon/routine/control-plane ownership and existing workspace/domain services.

**Work:** Register independently hosted role agents with private context namespaces and explicit tool/delegation profiles. Select bundled `Backplane.AgentRuntime.Tools.*` families or host tools through the same registry; do not install or version a second tools package. Adapt manual/routine work into tasks without moving scheduling into the runtime. Migrate QueryLoop provider/tool/context/cancellation/budget handling to shared mechanisms.

Disable eager tool execution from partial provider responses on the shared path. Add Planner→Coder→Reviewer task fixtures, isolated task contexts, acceptance/results, and task-scoped peer cancellation. Keep the graph path visibly legacy until T21 completes.

**Tests:** AC-10, AC-11, AC-12, AC-16, AC-30. Existing QueryLoop/daemon focused tests plus common conformance fixtures, unrelated recipient task survival, and no inference on notifications/status.

**Acceptance:** QueryLoop uses shared enforcement, role agents remain independent, and daemon/routine triggers keep their host contract. Report exact graph paths not yet migrated.

**Stop condition:** Do not collapse Synapsis into one singleton agent, make every role a child of Planner, or claim whole-product completion while graph execution remains separate.

### T21 — Synapsis graph integration and durable store conformance

**Scope:** Synapsis Session Worker/graph nodes that perform model/tool/approval/compaction work, embedded ownership, existing-store adapter and compatibility tests.

**Work:** Replace graph-side effect/lifecycle duplication with shared model/tool/policy/budget/cancellation components while retaining the product graph's transitions and specialized decisions. Keep exactly one context/kernel owner. Ensure fallback, escalation, stop/retry, and compaction nodes cannot bypass root limits.

Run the same durable StorePort/inbox/outbox/recovery tests against the actual adapter. Preserve Concord/workspace/public event contracts or record small reviewed adapter schema additions. Cover both graph and QueryLoop records during recovery; a graph-only store test is insufficient for shared role tasks.

**Tests:** AC-13, AC-14, AC-24, AC-25, AC-26, AC-30, AC-31. Trace every provider/tool effect through shared enforcement; inject stale epoch results and failures during graph transitions.

**Acceptance:** Both Synapsis execution paths meet I24 and have tested durability/recovery claims. Product scheduling, role configuration, workspace tools, and graph orchestration remain outside the package.

**Stop condition:** No generic graph DSL extraction, no hidden direct-provider/tool fallback, and no blanket consumer-store replacement.

### T22 — Opt-in Backplane configuration/content agents

**Scope:** Existing Backplane service integration namespace selected in T00, restricted domain-tool adapters, role profiles, and real-store conformance. Keep service code outside the shared package.

**Work:** Add an opt-in hosted agent using no repository, chat session, shell, or coding tools. Implement scoped content inspection/classification and configuration read/preview/validate contracts. Expose apply/update only through existing domain-service authorization, revision checks, and auditing with an explicit valid decision.

Provide disabled-by-default configuration and task submission wiring. Use the generic recovery harness with the actual service store adapter. Do not bypass service APIs to mutate internal tables/files from the runtime.

**Tests:** AC-16, AC-17, AC-24, AC-26, AC-32, AC-34. Fake-domain unit tests followed by sandboxed real domain-service tests; stale revision and unauthorized apply must fail, and core package installation must not start the agent.

**Acceptance:** A non-coding, sessionless consumer runs the same runtime artifact/version as coding consumers, selects only its domain tools despite the bundled coding implementations, and proves package independence and controlled mutation boundaries.

**Stop condition:** Do not enable the agent in production, add unrestricted administrator tools, or invent a new configuration/content subsystem to complete this integration.

## 6. Release and cleanup

### T23 — Cross-consumer conformance, artifacts, and release evidence

**Scope:** Shared acceptance harness, package verification script, consumer CI matrices, completed requirement/evidence report.

**Work:** Run AC-01 through AC-36 and NFR-01 through NFR-08 against the appropriate standalone and consumer fixtures. Build one actual runtime artifact containing all in-scope tools and consume that identical hash/version from fresh empty-tool, bundled-basic, and fake-backend Mix fixtures. Test absent/present optional libraries and explicit unavailable-backend requirements. Record the package version/hash, consumer SHAs, dependency/toolchain versions, store capabilities, and supported command/resource backends.

Run the bounded stress fixture, property/transition tests, durable fault matrix, permission cases, observer overload, Sigma parity, both Synapsis paths, and Backplane domain boundary. Inspect artifact contents and source/dependency/startup graphs for missing bundled implementations, mandatory backend leakage, kernel/gateway dependencies on concrete `Tools.*`, automatic registration/client startup, duplicate codecs, and migrated direct execution bypasses. Verify one Mix app/version/changelog/release path for the runtime and bundled tools.

**Tests:** All release acceptance and design invariants. Fail release readiness on a required skipped case, undeclared dependency, missing real-store proof, or unknown supported-platform claim.

**Acceptance:** Produce a reproducible report with passed/failed/blocked entries and the single package artifact hash plus dependency evidence. The same hash supports all required profile fixtures. No live providers are required for a pass and no package publication occurs automatically.

**Stop condition:** Partial consumer adoption is an internal milestone, not V1 completion. Do not replace missing evidence with unit-test counts or screenshots.

### T24 — Remove migrated duplication and finalize maintainer handoff

**Scope:** Only paths proven migrated by T23, adapter/API documentation, compatibility/release notes, profile/backend support matrix.

**Work:** Remove obsolete duplicated execution/authorization/accounting code in small consumer PRs, keeping required compatibility mappers. Document lifecycle/delegation semantics, supported tools/platforms/store modes, single-package installation, profile/backend configuration, new-work rollback, event replay/retention, and operational handling of unknown outcomes. Use `Backplane.AgentRuntime.Tools.*` consistently; consolidate any pre-existing draft tools scaffold/callers after verification, and remove only superseded tools-specific dependency/release instructions. Keep one changelog/version/publication path.

Ensure examples use no real credentials or automatic mutations. Capture unresolved upstream requests and deferred features separately from accepted V1 scope. Re-run focused tests and release artifact checks after cleanup; if cleanup changes semantics, rerun the affected acceptance suite before signing off.

**Tests:** Repeat affected AC scenarios plus AC-01, AC-29, AC-30, AC-31, AC-32, AC-33 and the final invariant scan.

**Acceptance:** One shared enforcement implementation remains for each migrated path; the maintainer has exact evidence, remaining limitations, and a safe rollback plan. Publication/merge/deployment follows separate authorization.

**Stop condition:** No opportunistic cleanup of unrelated UI, scheduler, tool integrations, or historical files. Do not delete the only working legacy path before its corresponding shared path is proven.

## 7. Requirements-to-task traceability

| Requirement | Acceptance | Primary tasks |
| --- | --- | --- |
| FR-01 | AC-01 | T01, T12, T13, T14, T15, T23 |
| FR-02 | AC-02 | T09, T23 |
| FR-03 | AC-03 | T02, T09, T11 |
| FR-04 | AC-04 | T07, T11 |
| FR-05 | AC-05 | T07, T09, T18, T21 |
| FR-06 | AC-06 | T02, T03, T05, T06, T09 |
| FR-07 | AC-07 | T05, T20, T21 |
| FR-08 | AC-08 | T06, T08 |
| FR-09 | AC-09 | T11, T12, T19 |
| FR-10 | AC-10 | T10, T11, T12, T20 |
| FR-11 | AC-11 | T10, T12, T20 |
| FR-12 | AC-12 | T11, T12, T20 |
| FR-13 | AC-13 | T05, T06, T11, T17, T19, T21 |
| FR-14 | AC-14 | T02, T03, T06, T17 |
| FR-15 | AC-15 | T08, T11, T17 |
| FR-16 | AC-16 | T04, T10, T11, T12, T22 |
| FR-17 | AC-17 | T04, T12, T22 |
| FR-18 | AC-18 | T04, T06, T12, T18, T20, T21 |
| FR-19 | AC-19 | T04, T06, T12, T13 |
| FR-20 | AC-20 | T13 |
| FR-21 | AC-21 | T14 |
| FR-22 | AC-22 | T15 |
| FR-23 | AC-23 | T15 |
| FR-24 | AC-24 | T03, T17, T19, T21, T22 |
| FR-25 | AC-25 | T10, T17, T21 |
| FR-26 | AC-26 | T17, T19, T21, T22 |
| FR-27 | AC-27 | T16, T18 |
| FR-28 | AC-28 | T05, T07, T08, T16 |
| FR-29 | AC-29 | T18, T19, T24 |
| FR-30 | AC-30 | T20, T21, T24 |
| FR-31 | AC-31 | T21, T24 |
| FR-32 | AC-32 | T22, T24 |
| FR-33 | AC-33 | T00, T01, T05, T15, T23 |
| FR-34 | AC-34 | T04, T09, T12, T13, T14, T15, T22, T23 |
| FR-35 | AC-35 | T06, T08, T10, T16, T23 |
| FR-36 | AC-36 | T04, T07, T10, T15 |
| NFR-01 | Artifact independence | T01, T23, T24 |
| NFR-02 | Responsive control | T03, T06, T09, T23 |
| NFR-03 | Bounded stress | T08, T23 |
| NFR-04 | Security/platform matrix | T04, T13, T14, T23 |
| NFR-05 | Deterministic CI | T02, T03, T17, T23 |
| NFR-06 | Compatibility matrix | T00, T18, T19, T20, T21, T22, T23 |
| NFR-07 | Privacy/observability | T16, T23 |
| NFR-08 | Safe adoption/rollback | T18, T19, T20, T21, T22, T24 |

## 8. Verification procedure and artifacts

### 8.1 Per-task evidence

Each PR/task handoff must contain: repository/branch/base SHA, task ID, changed files and public contracts, tests and exact commands, pass/fail/blocked status, relevant FR/AC/I IDs, compatibility implications, migration/rollback notes, and upstream blockers.

A test not run is reported as not run. Distinguish a dependency/environment failure from a product defect. Do not fix unrelated baseline failures inside a scoped PR; record them and continue only independent work.

### 8.2 Single-package and profile checks

Create one repository-owned verification script in T01/T23, for example `scripts/verify_agent_runtime_package.sh`. It must verify the release artifact, not merely compile the umbrella:

1. Run formatting, warnings-as-errors compilation, and focused tests for `apps/backplane_agent_runtime` using the recorded toolchain. Check one Mix application, namespace root, version/changelog, and release path. Check that kernel/gateway modules do not depend on concrete `Tools.*` modules.
2. Build one distributable artifact and inspect its file list: include the runtime and every in-scope collaboration/resource/command/plan/Memory/Skill implementation, required reference adapters, and documentation. Inspect the production dependency/startup graph for optional-backend leakage and test/service dependencies. Do not equate a disabled profile with dependency independence.
3. Create three fresh temporary Mix consumers—**empty-tool**, **bundled-basic**, and **fake-backend**—and install the identical artifact/hash/version plus its declared required dependencies. No path may resolve back to the umbrella and no second tools artifact is allowed.
4. In the empty-tool fixture, omit all optional backend libraries, command helpers, product configuration, workspace paths, and service apps. Compile/boot a scripted zero-tool execution and two runtime namespaces; assert an empty registry and no automatically started optional backend clients, jobs, or service agents.
5. In the bundled-basic fixture, explicitly configure authorized resource/plan tools and the supported command backend. Exercise harmless scoped operations, revision conflicts, bounded outputs, and cleanup. Do not start jobs or open a workspace before that configuration. Additional backend/platform limitations remain explicit.
6. In the fake-backend fixture, configure MemoryPort/SkillPort fakes without installing production memory/Skill services. Exercise scoped wrappers. Separately request missing/incapable backends and verify typed configuration failures; optional selections omit unavailable entries with reasons. Adding a backend alone must not register tools or grant permission.
7. For each declared optional-library adapter, run absent-dependency compile/boot and configured present-dependency contract tests in fresh fixtures. Fail on compile-time references that require the absent library, an undeclared/compulsory backend dependency, or unconfigured application startup.
8. Run the artifact-backed common suite and record the one package hash/version, exact dependency/toolchain versions, profile configurations, and observed startup/dependency checks. Rebuild and rerun affected checks after cleanup rather than carrying forward stale artifact evidence.

Expected developer checks after scaffolding include `mix format --check-formatted`, `mix compile --warnings-as-errors`, and focused `mix test` commands under the relevant package/consumer root. T00 records valid commands for each current repository. T01 establishes the harness; T12–T15 fill in bundled-tool coverage; T23 runs the full matrix. Scaffold-only tests or umbrella compilation do not satisfy final package acceptance.

### 8.3 Recovery fault matrix

| Failure window | Required observation |
| --- | --- |
| Before durable acceptance commit | No successful durable acceptance and no dispatched effect. |
| After sender intent, before receiver acceptance | Replay original submission; no new identity or assumed rejection. |
| After receiver acceptance, before acknowledgement | Retry/query finds the same target task/run. |
| After intent, before proven dispatch | Reconcile dispatch evidence; resume only if safe, otherwise preserve uncertainty. |
| After external mutation, before result commit | No automatic repeat; record/reconcile `unknown_outcome`. |
| After result commit, before context/terminal projection | Recover committed result and finish projection without rerunning the effect. |
| After terminal commit, before observer delivery | Replay same event ID; no second terminal. |
| After parent cancellation while children/tools live | Fence/reconcile owned work; do not release live budget or claim successful cleanup prematurely. |

Run this matrix against real durable adapters in their consumer repositories. Simulated commits cannot establish a production store's acknowledged durability boundary.

### 8.4 End-to-end fixtures

The mandatory fixture set includes same-artifact empty-tool/bundled-basic/fake-backend profiles, explicit missing-backend errors, absent/present optional-library builds, a no-tool agent, Sigma main→child→grandchild, Planner→Coder→Reviewer with unrelated peer work, same-context contention, dependency cycles, headless approval, hard tool loop, root reservation race, delayed store/provider/tool, subscriber overload, resource revision race, command descendants, and a sessionless configuration/content agent.

All models are scripted. File/command fixtures use temporary locations and harmless commands. Domain writes target test stores/sandbox fixtures only. Optional live smoke tests are separately labelled and cannot replace deterministic acceptance.

## 9. Milestone gates

| Gate | Required evidence |
| --- | --- |
| G0 / M0 | T00/T01 complete; current baseline, single-package layout, dependency/type contract, and layer checks recorded; one independent skeleton artifact works. |
| G1 / M1 | T02–T08 complete; deterministic kernel, policy, contexts, attempts, budgets, and ephemeral execution pass their AC cases. |
| G2 / M2 | T09–T15 complete; main/child/grandchild and hosted peer delegation work; all in-scope tool implementations are bundled, opt-in, bounded, and backend-conditional where specified. |
| G3 / M3 | T16/T17 complete; canonical events, accounting, generic recovery harness, and explicit storage modes pass. Production durable support still requires consumer adapter proof. |
| G4 / M4 | T19/T21/T22 complete with their prerequisites; Sigma, both Synapsis paths, and Backplane satisfy product journeys and real-store claims. |
| G5 / M5 | T23/T24 complete; every mandatory FR/AC/NFR has evidence, the same single artifact passes all profile/backend fixtures, migrated bypasses are removed, and unified release/limitations/rollback are documented. |

Tasks may progress in parallel; a milestone gate is not passed merely because dependent code exists. Each gate needs observed evidence.

## 10. Definition of done and final handoff

The implementation is done when the requirements matrix is complete, all three consumers use the same shared enforcement layer, one package artifact includes the runtime and all in-scope tools and is independently usable across the required profiles, and declared durability/security/platform behaviour is backed by tests.

The final handoff must include the single package version/artifact hash, verified sibling dependency versions, same-artifact profile/backend evidence, consumer SHAs, full test matrix, public contract changes, supported/unsupported backends, migration status of every execution path, safe rollout/rollback procedure, unresolved upstream requests, and deferred features.

Do not report a feature as complete because its module exists, a mock passes, a PR is open, or a progress note says it was implemented. Report exactly what was executed and verified. Package publication, merges, production configuration, and deployment remain separate authorized actions.
