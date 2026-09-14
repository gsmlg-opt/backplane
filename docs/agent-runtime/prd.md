# Shared Agent Runtime — Product Requirements

**Package:** `backplane_agent_runtime`  
**Repository:** `gsmlg-opt/backplane`  
**Date:** 2026-09-10  
**Updated:** 2026-09-14  
**Document revision:** 1.4 — verified bounded consolidation  
**Status:** Proposed; bounded package consolidation verified, full product acceptance pending  
**Companion documents:** [Design](design.md), [Implementation plan](implement_plan.md)

## 1. Product definition

Provide one embedded Elixir/OTP runtime that can power a session-owned coding agent with nested subagents, a set of independently hosted role agents with separate contexts and peer delegation, and service-owned configuration/content agents without a coding environment.

Supply runtime collaboration, file/resource, command, plan, and backend-dependent memory/Skill tools in one `backplane_agent_runtime` Mix package under `Backplane.AgentRuntime.Tools.*`. Runtime and bundled tools share one version and release; implementation inclusion, profile registration, and invocation authorization remain independent. No second tools package or application is required.

**Success means the same released runtime version supports Sigma, both Synapsis execution paths, and a sessionless Backplane consumer without copying the execution engine or imposing a shared product lifecycle.**

### 1.1 Requirements basis

The current user requirements supersede the older singleton-agent target in the attached `Repo Analysis Request.txt`. The latest single-package decision supersedes the earlier runtime/tools packaging split without changing the multi-agent feature scope. That attachment remains historical context for restricted autonomous profiles and host-level heartbeat/reflection/schedule triggers. It does not require a singleton runtime, Oban, or a particular database.

Consumer and sibling-package observations remain the earlier static excerpts described in the source register in [design.md](design.md); they were not refreshed by the current bounded Backplane review. Shared AI/Skill package names describe adjacent proposed boundaries, and their availability and versions remain unverified.

The current Backplane working tree has consolidated the draft package surface around the existing `Backplane.AgentRuntime.Tools` facade and the `Tools.LocalResource` and `Tools.LocalCommand` adapters, removing the old `Backplane.AgentTools` forwarding facade and second Mix application. The Linux command adapter admits a payload only after a nonce handshake and verified launcher parent/process-group/session identity. Focused tests pass 14/0 and the full package passes 123/0. The complete verifier builds one artifact and exercises fresh empty-tool, bundled-basic, and fake-backend consumers against the same recorded hash, including an actual bundled resource and command operation. The implementation remains uncommitted and unpublished at this evidence point. See [baseline.md](baseline.md) for commands and exact limits. This verifies the bounded consolidation, not a full milestone or the complete PRD acceptance matrix.

## 2. Problem and intended value

The products need many of the same correctness mechanisms—model/tool execution, cancellation, permission checks, context management, bounded retries, results, and observability—but organize agents differently. Extracting only a loop leaves duplicate agent collaboration and lifetime logic. Extracting an entire product runtime would impose session, storage, graph, workspace, and scheduling assumptions on other consumers.

The intended value is a shared enforcement boundary and reusable runtime primitives, not a superficial common API over three independent executors. A fix to stale-result fencing, nested cancellation, tool-loop termination, or root accounting should be reusable across all migrated paths. A single package also keeps tool-contract and bundled-tool changes in one tested upgrade, rather than requiring a runtime/tools release-compatibility matrix. Internal layering and optional backends preserve dependency isolation.

## 3. Users and essential journeys

### Sigma user

A user starts a coding session. Its main agent accepts successive tasks. A task spawns a research subagent; that subagent spawns an analysis subagent. Contexts and tool grants are explicitly scoped. Results return to the owning task. Cancelling the task cleans up its descendants without deleting the session or unrelated work.

### Synapsis operator

The application hosts Planner, Coder, and Reviewer roles. Each retains its own identity and context namespace. Planner submits a task to Coder; Coder requests review from Reviewer. Tasks can be queued or use isolated contexts for concurrency. Cancelling one delegation does not stop the target role agent or its other tasks.

### Backplane operator

A service-owned agent receives a content-classification or configuration-review task. It uses only authorized domain tools. A configuration change is previewed/validated and applied through existing domain-service revision, authorization, and audit checks. The agent does not require a repository, terminal, chat session, or unrestricted storage access.

### Package maintainer

A clean Mix application installs the single released package and runs scripted model/tool tasks without Backplane service applications. The same artifact supports an empty-tool agent, an agent using selected bundled basic tools, and an agent using fake configured MemoryPort/SkillPort bridges. A consumer chooses its own adapters, profiles, and runtime namespace. Test-only libraries, example servers, and service configuration do not enter production dependencies; no optional backend starts merely because its wrapper is bundled.

## 4. Scope and milestones

| Milestone | Required result |
| --- | --- |
| M0 — Baseline and contracts | Record current consumer SHAs/toolchains, map actual execution paths, resolve sibling package/type boundaries, freeze initial contracts and ownership decisions. |
| M1 — Shared execution core | One independently buildable package, internally layered contracts, deterministic kernel, context ownership, policy/tool gateway, provider effects, budgets, cancellation, and ephemeral execution. |
| M2 — Agent collaboration and tools | Managed/embedded hosts, nested subagents, peer delegation, bounded messaging/waits, and all in-scope bundled tool implementations with opt-in registration. No separate tools release. |
| M3 — Recovery and observability | Durable conformance, effect uncertainty/recovery, inbox/outbox replay, fenced results, canonical events, bounded subscribers, accurate usage semantics. |
| M4 — Three consumer integrations | Sigma migration, Synapsis QueryLoop and graph migration, and opt-in sessionless Backplane configuration/content agents. |
| M5 — Release readiness | One standalone artifact tested across tool/backend profiles, cross-consumer acceptance, compatibility/rollback documentation, and removal of migrated duplicate enforcement paths. |

M1/M2 are internal adoption milestones, not proof that the entire multi-agent product requirement is complete. V1 acceptance includes M4/M5.

### 4.1 Included tool surface

Bundled collaboration tools under `Backplane.AgentRuntime.Tools.Collaboration.*`, with opt-in registration: `agent_discover`, `agent_spawn`, `agent_delegate`, `agent_send`, `run_status`, `run_wait`, `run_cancel`, and `ask_user`.

Bundled basic tools under `Backplane.AgentRuntime.Tools.Resource.*`, `Tools.Command.*`, and `Tools.Plan.*`, with opt-in registration: `file_read`, `list_dir`, `glob`, `grep`, `file_write`, `file_edit`, `exec`, `job_read`, `job_cancel`, `plan_read`, and `plan_update`.

Bundled backend-conditional bridges under `Tools.Memory.*` and `Tools.Skill.*`: `memory_search`, `memory_store`, `skill_list`, and `skill_load`. Their wrapper implementations and tests are required in V1; building a new memory backend or Skill distribution service is not. Without a suitable configured port, they are omitted from optional selections. Explicitly requiring one without a suitable backend fails profile configuration with a typed `missing_backend` or `unsupported_capability` error instead of silently dropping the requirement.

Tool implementations being required does not make activation mandatory. Empty tool sets remain valid, and host business tools remain in their consumer repositories. Packaging/activation does not expand grants.

HTTP fetching/search implementations, automatic detached jobs, remote agent routing, distributed failover, team planning, and universal workflow graphs are outside V1.

## 5. Functional requirements

All FR requirements below are mandatory for V1 unless their wording explicitly makes activation conditional. Acceptance scenarios in section 7 define observable completion evidence.

### 5.1 Packaging, identity, and execution

| ID | Requirement | Acceptance |
| --- | --- | --- |
| FR-01 | Ship one independently consumable `backplane_agent_runtime` package/application/version containing the runtime and all in-scope tool implementations. It compiles/boots without session, Git, shell, Phoenix, Backplane server, database, or optional backends. Kernel/gateway depend on generic contracts, not concrete `Tools.*` implementations. | AC-01 |
| FR-02 | Multiple runtime instances coexist in one VM with independent registries, policies, stores, queues, and events. No unqualified global singleton assumption. | AC-02 |
| FR-03 | Agent definition, instance, context, task, run, and attempt have distinct identities. Hosted and owner-bound lifecycles are supported; identity does not equal PID. | AC-03 |
| FR-04 | Each agent has a private context namespace. Child inheritance and peer result admission select explicit data/resources rather than sharing mutable history or credentials. | AC-04 |
| FR-05 | One writer owns a context revision. Same-context tasks serialize; isolated contexts can run concurrently under quotas. Fork/merge requires explicit versioned operations. | AC-05 |
| FR-06 | Shared execution is deterministic at its core and asynchronous at effect boundaries. All work is finite, cancellable, and budgeted; products may use managed or embedded hosting. | AC-06 |
| FR-07 | Model streams are correlated by step/attempt and normalized by a provider adapter. Incomplete, malformed, or unterminated tool calls never execute. | AC-07 |
| FR-08 | Retry attempts, repeated tool failures, no-progress loops, and recursive delegation have hard limits. Prompt nudges do not substitute for enforced termination. | AC-08 |

### 5.2 Multi-agent collaboration and lifetime

| ID | Requirement | Acceptance |
| --- | --- | --- |
| FR-09 | A run can create temporary subagents, including nested children, within authorized depth/count/concurrency limits. Children settle or are cancelled before owner completion. | AC-09 |
| FR-10 | An agent can submit work to an authorized existing role agent. Acceptance, execution, result, and cancellation are explicit; recipient agent lifetime remains independent. | AC-10 |
| FR-11 | Typed notifications, progress, task requests, results, and controls have different admission/wake semantics. Ordinary messages do not automatically trigger inference or reply loops. | AC-11 |
| FR-12 | Awaiting another run uses a continuation, not a blocking tool task. Detect run cycles and held-context dependencies; waits are bounded and cancellable. | AC-12 |
| FR-13 | Cancel owned child trees and contract-cancellable delegated runs precisely. Keep host control responsive; fence late provider/tool/approval/store results after cancellation or recovery. | AC-13 |
| FR-14 | Commit one terminal per run. Cancellation acceptance is not cleanup completion. Unknown external mutation outcomes remain explicit and cannot be reported as success. | AC-14 |
| FR-15 | Descendants, delegations, retries, and compaction share authorized root accounting. Concurrent reservations cannot overspend logical admission limits or silently mint new budget accounts. | AC-15 |

### 5.3 Authorization and tools

| ID | Requirement | Acceptance |
| --- | --- | --- |
| FR-16 | Enforce caller, role, resource, and task authority. Spawned children cannot inflate grants; service-role delegation requires a specific allowed operation contract at the receiver. | AC-16 |
| FR-17 | Approvals bind exact operation, arguments, identity, revisions, and expiry. `ask_user` is not a self-approval mechanism. Headless tasks never auto-approve because no resolver exists. | AC-17 |
| FR-18 | Direct calls, bundled collaboration/basic tools, product tools, and MCP adapters use one registered-tool gateway and effect lifecycle. No arbitrary module/function dispatch from model input or privileged bypass for same-package tools. | AC-18 |
| FR-19 | Tool schemas, results, error classes, progress, timeouts, cancellation, and output bounds are normalized. Read-only, retry-safe, and concurrency-safe metadata are separate and host-attested. | AC-19 |
| FR-20 | Bundled, opt-in resource tools use authorized namespaces and expected-revision/create-only writes. Traversal, symlink/race, output, and backend-confinement guarantees are explicit and tested. | AC-20 |
| FR-21 | Bundled, opt-in commands are run-owned, explicitly authorized, deadline/output bounded, environment restricted, and cancellable through tested backend/platform cleanup. No implicit detached jobs or sandbox claim. | AC-21 |
| FR-22 | Bundled, opt-in plans are task-scoped revisioned resources. Plan edits do not silently schedule tasks or overwrite newer versions. | AC-22 |
| FR-23 | Bundled Memory/Skill wrappers compile without backend libraries and register only with configured capable ports. Missing optional entries are omitted; explicitly required unavailable bridges fail configuration. Scope/provenance are enforced; Skill declarations grant no tools or private-memory access. | AC-23 |

### 5.4 Persistence, events, and integration

| ID | Requirement | Acceptance |
| --- | --- | --- |
| FR-24 | Ephemeral and durable modes disclose different guarantees. Durable transition/event/outbox commits and compare-and-set semantics are adapter-tested; no silent fallback on failure. | AC-24 |
| FR-25 | Durable messaging distinguishes submission, acceptance, and completion. Retained idempotency keys/digests prevent duplicate task admission; timeout ambiguity reuses the same submission handle. | AC-25 |
| FR-26 | Recovery restores ownership/context/accounting, fences old executors, and reconciles effects before execution. Mutating effects with uncertain outcomes are not replayed automatically. | AC-26 |
| FR-27 | Versioned events have stable IDs, per-aggregate sequences, causation, snapshots, and bounded replay. Slow observers may lose provisional deltas with a gap marker, not silently redefine execution outcome. | AC-27 |
| FR-28 | Attribute provider/tool/compaction/descendant usage without double counting. Distinguish missing/estimated/cumulative usage, context occupancy, generation throughput, and total wall time. | AC-28 |
| FR-29 | Sigma retains session/repository ownership, public headless/UI contracts, context/history/fork behaviour, hooks, and storage compatibility while adopting shared enforcement and nested children. | AC-29 |
| FR-30 | Synapsis QueryLoop uses the shared execution and collaboration boundaries while preserving daemon/routine triggers, role identity, existing host tools, and private context semantics. | AC-30 |
| FR-31 | Synapsis graph execution uses the same provider/tool/policy/budget/cancellation boundaries. Product-specific graph nodes remain outside the package; QueryLoop-only migration is insufficient. | AC-31 |
| FR-32 | Backplane can opt in to service-owned configuration/content agents using restricted domain tools, no repository/session/shell, and existing revision/authorization/audit boundaries. | AC-32 |
| FR-33 | Reuse verified sibling provider/Skill contracts. Bundling tools adds no copied provider parser, compulsory memory/Skill/MCP service, test-only production dependency, or unverified version assumption. Optional adapters support absent/present dependency builds, and package startup activates no unconfigured backend. | AC-33 |
| FR-34 | Bundling, agent registration, and per-task invocation permission are independent. The same artifact supports empty and restrictive role/task profiles. Backend availability does not grant authority; optional omissions are reported, explicit missing requirements fail configuration, and unusable tools are not advertised. | AC-34 |
| FR-35 | Work/inbox/output/stream queues, retries, active jobs, and subscribers are bounded. Saturation is observable and recoverable; waiters release execution slots. | AC-35 |
| FR-36 | Resource, peer, tool, and Skill content retains provenance and classification. Data cannot silently override instructions, impersonate a control message, or expand access. | AC-36 |

## 6. Non-functional requirements

| ID | Requirement and evidence |
| --- | --- |
| NFR-01 — Standalone installation | Build one artifact containing runtime and all V1 tools. Use the identical artifact/version in fresh empty-tool, bundled-basic, and fake-backend consumers without Backplane service apps. Test absent/present optional libraries, missing-backend errors, internal dependency direction, and no startup leakage. Confirm contents and production dependency tree; disabled tools do not excuse mandatory backend dependencies. |
| NFR-02 — Responsive control | In deterministic tests with a stalled provider/tool/store adapter, status and cancellation acknowledgement remain serviceable within the test's one-second control-call timeout. This is not a one-second external-process cleanup guarantee. |
| NFR-03 — Bounded resources | Production profiles require finite budgets. A scripted stress fixture submits at least 200 tasks across 20 agents with intentionally small quotas; measured accepted/active/pending work never exceeds those quotas and overload is explicit. This is a correctness fixture, not a performance claim. |
| NFR-04 — Security and isolation | Test cross-runtime/cross-agent access denial, forged identity/approval, model-controlled module names, traversal/races, secret environment leakage, and untrusted remote tool metadata. Record unsupported sandbox/confinement capabilities honestly. |
| NFR-05 — Deterministic verification | Required CI uses scripted providers, fake clocks/IDs, controlled faults, and isolated resource backends. No real model credentials, network billing, sleeps as the sole synchronization mechanism, or uncontrolled tool side effects. |
| NFR-06 — Compatibility | Baseline records pin exact tested consumer SHAs, the single package version, sibling dependency versions, Elixir/OTP versions, platform capabilities, and public behaviour fixtures. Unsupported configurations return explicit errors; one changelog/release pipeline covers runtime and bundled tools. |
| NFR-07 — Observability and privacy | Structured errors/events enable root-to-child tracing without credential leakage. Content-bearing events enforce visibility. Logs do not dump sensitive context/tool arguments by default. |
| NFR-08 — Safe adoption | Choose engine at new-session/context creation; no dual execution of real mutating tools. Provide new-work rollback and retain readable completed artifacts. Do not claim in-flight backward compatibility without tests. |

## 7. Acceptance scenarios

These scenarios are executable acceptance contracts. Each must have a stable test identifier and recorded result in the implementation evidence. The plan specifies ownership.

| ID | Given / when / then |
| --- | --- |
| AC-01 | Build one artifact containing runtime and all in-scope `Tools.*` implementations. In a fresh consumer with no optional backends/helpers, compile and run a scripted zero-tool interaction without repository/session/service configuration. Using the identical artifact/version, a second consumer explicitly enables and exercises bundled basic tools. Neither install/boot auto-registers tools; dependency checks show no kernel/gateway reference to concrete tool implementations. |
| AC-02 | Start two runtime instances with identical agent-local labels. Work, discovery, events, contexts, policies, and cancellation remain isolated; stopping one instance leaves the other usable. |
| AC-03 | Reactivate a hosted role agent and create/cancel a session-owned main agent plus a run-owned child. Stable identity, owner type, and affected lifetime are correct in each case. |
| AC-04 | Give a parent private history, secrets, and selected public context. Its child and a peer recipient see only selected material/resources; result admission cannot rewrite either recipient's instructions. |
| AC-05 | Submit two writes to one context and two tasks to separate contexts. The first pair serializes or conflicts by revision; the second can overlap under quotas without history interleaving. |
| AC-06 | Replay the same kernel inputs with fixed time/IDs and get identical transitions/effects. Stall I/O tasks; the owning host still handles control requests and cannot dispatch uncommitted durable intents. |
| AC-07 | Inject malformed arguments, duplicate chunks, late chunks, and end-of-stream without a canonical terminal. No incomplete invocation executes and errors retain the correct attempt identity. |
| AC-08 | Script a model that repeatedly calls a failing tool, changes superficial arguments, or repeatedly delegates. The root hard limits terminate known work; nested adapter retries cannot multiply the allowed budget. |
| AC-09 | Main run creates a child that creates a grandchild. Their contexts/grants differ appropriately, the root aggregates work once, and parent completion waits for or cancels required descendants. |
| AC-10 | Planner delegates to hosted Coder while Coder has unrelated work. Cancelling the delegated task leaves Coder and unrelated work alive. Repeated submission returns the same accepted task/run. |
| AC-11 | Deliver notification, progress, acceptance acknowledgement, result, and explicit task request. Only the authorized task/wake operation starts a model run; status querying causes zero provider calls. |
| AC-12 | Run A waits for B; attempt B→A waiting and a held-context self-dependency. Invalid waits are rejected, valid waits release tool slots, and cancellation resolves the suspended invocation once. |
| AC-13 | Cancel/restart during streaming, tool execution, approval, persistence, and a peer wait. Late results from the previous attempt/incarnation do not change context or commit an additional outcome. |
| AC-14 | Race provider completion with cancellation/deadline. One canonical terminal wins under policy; cancellation acknowledgement is distinct from final outcome and uncertain mutations produce `unknown_outcome`. |
| AC-15 | Admit sibling children and delegated tasks concurrently against a small root limit. Reservations never authorize work beyond the limit; releasing/replaying reservations cannot double-spend. |
| AC-16 | Request a stronger child profile and delegate an unauthorized mutation to a privileged service-role agent. Both are denied despite the target's own authority; an explicitly permitted service task succeeds. |
| AC-17 | Reuse an expired approval or alter arguments/tool revision after approval. Execution is denied/reapproved. In headless mode with no resolver, the task does not silently authorize the operation. |
| AC-18 | Exercise the same denied operation through a direct API, bundled collaboration wrapper, bundled basic tool, host adapter, and MCP adapter fixture. All stop at the same policy gateway before side effects. |
| AC-19 | Send invalid input, malformed backend results, duplicate progress, and oversized output. Receive typed bounded errors/results. Retry eligibility and parallelism do not derive from read-only annotations alone. |
| AC-20 | Read/search/write through a scoped resource adapter; attempt traversal, symlink replacement, stale revision, and concurrent writes. Access stays within declared guarantees and conflicts never silently overwrite. |
| AC-21 | Start an authorized command with a child process, excess output, and a forbidden environment secret. Output is capped, the secret is absent, cancellation cleans up supported descendants, and unsupported capabilities are rejected. |
| AC-22 | Two plan updates use the same expected revision. Only one commits; the plan remains task-scoped and creates no task or delegation by itself. |
| AC-23 | Compile the same package without Memory/Skill libraries or ports: wrappers remain in the artifact but are absent from optional tool selections. Explicitly requiring either bridge fails configuration with a typed missing/unsupported-backend error. With fake ports configured, authorized operations work, cross-agent memory is denied, and Skill content activates no unauthorized tools. |
| AC-24 | Compare restart in ephemeral mode with durable host adapters. Loss is explicitly allowed only in ephemeral mode; failed durable commits cannot acknowledge acceptance or launch dependent effects. |
| AC-25 | Crash around sender outbox/receiver inbox/acceptance acknowledgement and retry the original submission. One task/run is accepted; the same key with changed payload conflicts and expired replay horizons are explicit. |
| AC-26 | Inject crashes before dispatch, after external mutation, before result commit, and after terminal commit. Only proven-safe operations resume; uncertain mutations are not replayed and committed terminals retain identity. |
| AC-27 | Attach a slow subscriber, drop it, and reconnect using a cursor. Bounded provisional loss emits a gap; retained canonical outcomes replay by original ID or cursor expiry requests a snapshot. |
| AC-28 | Feed cumulative and delta usage, retry reports, child usage, and compaction usage. Totals do not double-count. Missing metrics remain unknown; context occupancy differs from lifetime totals. |
| AC-29 | Replay Sigma prompt/steer/follow-up/cancel/fork/headless event fixtures against the shared path. Preserve host contracts and test nested run-owned agents without rewriting historical sessions. |
| AC-30 | Trigger manual and routine work through Synapsis's existing host boundary using QueryLoop integration. Role agents retain isolated contexts and delegate while shared gateway/budget events prove enforcement. |
| AC-31 | Run a Synapsis coding graph through model/tool/approval/compaction paths. Shared instrumentation proves the same enforcement as QueryLoop; stale graph events and eager partial-stream tools cannot bypass it. |
| AC-32 | Start a Backplane service agent with only scoped domain tools. Run read/preview/validate, reject an unapproved apply, and apply an authorized revision-bound change through a fake then real domain boundary. |
| AC-33 | Verify pinned sibling contracts and no duplicate provider codecs. Inspect the one artifact, production dependency graph, and application startup: no test-support or compulsory optional-backend dependencies; no unconfigured Skill/memory/MCP/service clients start. Compile/test declared optional-library adapters with their dependency absent and present, and fail on compile-time leakage or an undeclared dependency. |
| AC-34 | Use the same artifact/version for Planner/Coder/Reviewer/service profiles and a zero-tool agent. Descriptors/grants differ; optional backend omissions are reported, explicit missing requirements fail configuration, and adding a backend neither auto-registers tools nor expands grants. Backend loss after registration produces an explicit error without permissive fallback. |
| AC-35 | Fill work queues/inboxes/subscriber buffers and withhold producer acknowledgements. Admission limits hold, explicit overload is observable, waiters use no execution slots, and cancellation remains available. |
| AC-36 | Insert instructions disguised as peer results, resource text, Skill metadata, or model-controlled control fields. They remain untrusted content; the runtime denies forged identity, policy, and context changes. |

## 8. Release gates and completion evidence

A release candidate must provide the following evidence in a single completion report:

- A requirement-to-test matrix covering FR-01 through FR-36 and NFR-01 through NFR-08, with exact commands, tested SHAs/versions, platform capabilities, and pass/fail/skipped status.
- One artifact/hash used by fresh empty-tool, bundled-basic, and fake-backend consumers; optional-library absence/presence and explicit missing-backend tests; inspection of bundled contents, production/internal dependency graphs, and no automatic tool/backend/service startup.
- The three product journeys, both Synapsis paths, real-store durable adapter fault tests where durable mode is claimed, and declared command/resource backend conformance.
- Migration compatibility and rollback evidence; a list of remaining legacy paths and an explanation of any still outside the release boundary.

No required acceptance case may be silently marked not applicable. Backend-conditional tools can be tested with fake ports, but real backend support must not be claimed without its own tests. Command/resource capabilities may be platform-limited only when the limitation is explicit and unsupported invocation fails closed.

Live model quality is not a correctness gate. These tests establish runtime behaviour; they do not promise that an LLM produces a correct code change, review, or configuration proposal.

## 9. Risks and mitigations

| Risk | Required mitigation |
| --- | --- |
| Shared package becomes renamed Sigma | Prove isolated role-agent delegation and sessionless Backplane use before calling the architecture complete. |
| Shared package becomes a full Synapsis platform | Exclude scheduling, graphs, product stores, and role-selection logic; enforce dependency checks. |
| Two authoritative runtime owners during migration | Use managed or embedded hosting per context, never both. Add explicit registration/context ownership assertions. |
| Durable delivery mistaken for exactly-once tools | Track dispatch certainty separately from message/task deduplication; preserve uncertain outcomes and require reconciliation. |
| Nested budgets or permissions escape scope | Root reservations, explicit delegation contracts, non-expanding child grants, and concurrent race tests. |
| Basic tools expand attack surface | Bundling is not registration or authorization. Use opt-in profiles, revision-aware resource access, explicit command/sandbox capabilities, and host-owned policy. |
| Single package pulls in every backend or erodes layering | Keep generic contracts separate from `Tools.*` implementations; inject host ports, test absent optional dependencies, inspect production/startup graphs, and reject mandatory backend leakage. |
| Adjacent protocol proposals are unavailable | Gate the dependency contract early; report upstream blockers rather than cloning codecs or assuming a version. |
| Migration breaks public sessions/history | Preserve host facades and storage formats; use fixtures and per-new-context feature flags. |

## 10. Change control

Implementers may refine private module decomposition without changing these requirements. Changes to lifecycle ownership, authorization, context concurrency, durability promises, tool surface, public event semantics, the single-package distribution or sibling package boundaries, or V1 consumer coverage require a recorded design decision and updates to all three documents and acceptance mappings.

Do not use this task to rewrite unrelated UI, add product workflows, replace consumer databases, configure live autonomous mutations, publish the package, or deploy services without explicit authorization. The implementation plan provides bounded change sets and stop conditions.
