# Shared Agent Runtime — Design

**Package:** `backplane_agent_runtime`  
**Repository:** `gsmlg-opt/backplane`  
**Date:** 2026-09-10  
**Updated:** 2026-09-11  
**Document revision:** 1.1 — single-package distribution  
**Status:** Proposed implementation specification; not an implementation-complete claim  
**Language:** English  
**Companion documents:** [Product requirements](prd.md), [Implementation plan](implement_plan.md)

## 1. Decision and scope

Build an independently consumable, embedded Elixir/OTP runtime for **agents with independent contexts, bounded executions, temporary nested subagents, and communication between independently hosted agents**. Ship collaboration tools and reusable file/resource, command, plan, and backend-dependent memory/Skill tools in the same `backplane_agent_runtime` package. Maintain one Mix application, namespace root, package version, changelog, and release artifact. Tool families are opt-in registrations, not separate installations.

The three required consumers are:

| Consumer | Required composition |
| --- | --- |
| Sigma | A session owns a main agent. A run can spawn temporary subagents, which can spawn nested subagents. Each child has an isolated context. |
| Synapsis | Multiple independently hosted agents have different roles and contexts. They exchange messages, accept delegated work, and may also spawn temporary subagents. |
| Backplane | The service can host configuration/content agents without requiring a Git repository, coding workspace, chat session, shell, or connection to a separate Backplane server. |

**Agent is not Session. Agent is not Run. Creating a subagent is not delegating to an existing agent.** These distinctions are the architectural foundation.

The runtime shares execution and collaboration mechanisms. Products retain role definitions, business workflows, user interfaces, persistent storage implementations, scheduling, domain tools, and authorization policy. A common package does not imply a centralized remote agent service.

### 1.1 Source precedence and evidence limits

This design is based on the explicit requirements in the current discussion, the earlier static repository excerpts, and the attached `Repo Analysis Request.txt`.

1. The user's current multi-agent requirements and latest single-package decision define the target. This revision supersedes the earlier runtime/tools packaging split; it does not change the multi-agent execution, ownership, or security contracts.
2. Earlier repository excerpts identify migration seams, not the current state of every branch.
3. The attachment describes an earlier **single local daemon** reduction. Its separation of cheap liveness from model-driven heartbeat/reflection and its conservative tool profiles remain useful host-level concepts. Its singleton product target, database/table suggestions, Oban assumptions, and historical bug claims are **not adopted as requirements for this package**.
4. The shared AI and Skill protocol packages are adjacent proposals. Their availability, exact public types, and versions must be verified before adding dependencies.

No repository was modified and no repository tests were executed to produce these documents. All new module names, APIs, invariants, and release gates below are proposed contracts. Implementation starts with a fresh baseline inventory, not an assumption that the historical snapshots are current.

## 2. Architectural decisions

| ID | Decision |
| --- | --- |
| D01 | Use agent identity, context, task, and run as separate concepts. A product session is optional correlation metadata. |
| D02 | Represent lifecycle ownership, task dependencies, and communication separately. Do not force all relationships into an agent tree. |
| D03 | Keep a deterministic execution kernel and an asynchronous effect boundary. Reuse them in managed and embedded hosting modes. |
| D04 | Enforce one authoritative writer per context; default to serial execution within a context. |
| D05 | Run-owned subagents use structured lifetime management. Delegation to a hosted peer creates work, not ownership of the peer. |
| D06 | All direct and model-visible tool calls enter the same validation, policy, budget, execution, and result pipeline. |
| D07 | Built-in collaboration tools are supplied but not automatically registered or authorized. |
| D08 | Publish one `backplane_agent_runtime` package. Concrete tools live under `Backplane.AgentRuntime.Tools.*`; the kernel depends on generic tool contracts/ports, not concrete tool implementations. Optional backends and Backplane service applications are not mandatory dependencies. |
| D09 | V1 routes collaboration within one BEAM node/runtime instance. Remote routing, failover, and cross-node placement are not V1 features. |
| D10 | Provide explicit ephemeral and durable storage modes; do not advertise a process mailbox as a durable queue. |
| D11 | Preserve unknown external outcomes. No exactly-once external side-effect claim and no blind replay of mutations. |
| D12 | Keep product protocols, historical storage formats, schedulers, and workflow graphs outside the shared package. |

## 3. Non-goals

V1 does not implement a distributed scheduler, agent team planner, generic workflow DSL, vendor gateway, replacement memory service, new provider codecs, OS sandbox, repository manager, MCP hub, UI, or universal persistent database.

The package does not replicate OpenClaw or Pi feature-for-feature. It does not implement heartbeat, dream, cron scheduling, GitHub issue/PR workflows, or configuration mutation semantics. Those are host triggers and host tools.

Agent CLI dispatch and ACP/MCP/application-server transports are separate integrations. An external agent that owns its own execution loop may later be addressed through an adapter; this design does not claim to control its internal tool loop or cancellation guarantees.

## 4. Package, dependencies, and ownership

### 4.1 Single package and internal layers

The sole distribution unit is **`backplane_agent_runtime`**, with the OTP application `:backplane_agent_runtime` and namespace root `Backplane.AgentRuntime`. Maintain it at **`apps/backplane_agent_runtime`** in Backplane. Do not create a second tools Mix application, release artifact, version stream, or compatibility matrix.

| Internal layer / proposed namespace | Contents and dependency boundary |
| --- | --- |
| `Backplane.AgentRuntime` execution/hosting modules | Domain contracts, deterministic kernel, effect lifecycle, managed/embedded hosting, context/run coordination, admission and budgets, messaging/delegation, recovery and events. |
| `Backplane.AgentRuntime.Tool.*` | Generic tool descriptors, registry, schema/policy gateway, scheduling, cancellation, progress and result contracts. No dependency on a particular concrete tool family. |
| `Backplane.AgentRuntime.Tools.Collaboration.*` | Opt-in wrappers for agent discovery/spawn/delegation/messaging, run status/wait/cancel, and user information requests. |
| `Backplane.AgentRuntime.Tools.Resource.*` / `Tools.Command.*` / `Tools.Plan.*` | Bundled file/resource, command/job, and task-local plan implementations using the shared gateway and ports. |
| `Backplane.AgentRuntime.Tools.Memory.*` / `Tools.Skill.*` | Bundled, backend-conditional wrappers. They do not own memory storage, Skill parsing, distribution, or activation policy. |
| `Backplane.AgentRuntime.Ports.*` / `Adapters.*` | Behaviour boundaries and reference adapters with explicit capabilities. Generic contracts do not require every optional backend library to be installed. |
| Consumer applications | Storage/provider/context/policy/backend adapters, role profiles, presentation, schedules, domain tools, and historical format adapters. These remain outside the package. |

Concrete tools implement the generic tool contract and use approved runtime operations or ports. The kernel and generic gateway must not call or branch on `Tools.Resource.*`, `Tools.Command.*`, or any other concrete implementation. Registration is a host composition step; merely loading the package does not populate a tool registry, start backend clients, open a workspace, launch a subprocess, or activate service agents. Domain tools use the same contract without being moved into the shared package.

**One package, one version, one release.** Runtime contract and bundled-tool changes are reviewed, tested, and released together; a tool-only fix also updates the package version. Versioned tool descriptors, event schemas, context revisions, and authorization grants retain their separate meanings—they are not replaced by the package version.

The package directory must build as a standalone Mix project from its actual release artifact. Declare all dependencies explicitly; do not assume umbrella-relative build/config/dependency/lockfile locations outside umbrella development. The release must not require another application's `Application.get_env` values, global registered names, database, Phoenix endpoint, or startup callback. Use one package changelog and one release pipeline; independent protocol siblings retain their own existing release boundaries.

### 4.2 Provider and Skill boundaries

Use the proposed `backplane_ai_protocol` canonical request/message/event contracts once their standalone release and API have been verified. Provider authentication, model capability metadata, provider-specific continuation state, HTTP/SSE parsing, and Backplane WebSocket model transport remain there or in a host adapter—not in the runtime.

`ProviderPort` is the runtime's execution-facing behaviour. It wraps the canonical provider contracts with runtime execution identity and lifecycle control. It must not introduce a competing full message schema or another OpenAI/Anthropic parser. Pin the exact sibling dependency/API in the baseline decision record before implementing this boundary. If the sibling is unavailable, continue independent kernel/tool work using a scripted test port; do not ship a production parser copy as a workaround.

The package does not require `backplane_skill_protocol`. The bundled `Tools.Skill.*` wrappers depend on SkillPort; a host adapter resolves a versioned bundle and submits selected content/resources through the normal context and capability boundaries. A verified in-package sibling adapter may use an explicitly optional dependency only if the absent-dependency build passes. Skill declarations are content and requests for capabilities, not authorization grants.

### 4.3 Ports

| Port | Responsibility | Required for |
| --- | --- | --- |
| ProviderPort | Start a model attempt, deliver normalized events, cancel, report usage/continuation capabilities. | Model execution |
| ContextPort | Load selected context material, build instructions, estimate/compact under a versioned context contract. | Model execution |
| PolicyPort | Resolve capabilities and decide allow/deny/approval for exact operations. | Any work admission/tool effect |
| StorePort | Commit versioned runtime transitions and optional durable inbox/outbox/checkpoints. | All modes; ephemeral reference implementation included |
| ToolBackend | Execute one already admitted tool operation and report normalized progress/outcome. | Enabled tool |
| ResourcePort | Access an authorized resource namespace with confinement and revision checks. | File/resource tools |
| CommandPort | Own a subprocess/job, stream output, enforce configured isolation/timeouts, terminate descendants where supported. | Command tools |
| MemoryPort / SkillPort | Scoped memory operations / versioned Skill resolution. | Optional bridges only |
| EventSink | Consume canonical events or a bounded subscription. Never owns runtime state. | Optional observation |

A production port must declare unsupported capabilities explicitly. The runtime must not silently downgrade durable delivery, resource confinement, cancellation, or schema validation.

### 4.4 Dependencies and activation are separate

Bundling tool source does not require bundling every service implementation. Prefer host-injected ports for memory, Skills, MCP, storage, and product services. A backend-specific dependency is allowed only when explicitly declared and reviewed; optional-library adapters must compile without that library installed and report availability before registration. Generic contracts and bundled wrappers must not reference optional-library structs or compile-time facilities in a way that makes that library compulsory.

Disabling a tool is not a dependency-isolation mechanism. Inspect the actual production dependency graph and application startup behaviour: an unused mandatory dependency is still mandatory. Do not add Phoenix, a database driver/service, a memory service, an MCP client/hub, a Skill service, or a command helper to the unconditional dependency set merely because a wrapper exists. Command helper executables, where required by a backend, are capability-checked when that backend is selected; they are not required to compile or boot a zero-tool agent.

Registration distinguishes optional availability from an explicit requirement:

- An empty tool profile is valid. A host may select optional families from an eligible catalog; unavailable backend-dependent entries are omitted and the selection result explains why.
- If a host explicitly requires a tool or family whose backend is missing or incapable, profile validation fails with a typed `missing_backend` or `unsupported_capability` configuration error. Do not silently accept a degraded profile or advertise a nonfunctional descriptor.
- A configured backend supplies capability, not authority. Every registered invocation still passes the common policy gateway. Backend loss after registration yields an explicit execution error, not automatic backend substitution or expanded permissions.

CI must install the same release artifact into fresh consumers with (a) no tools and no optional backends, (b) selected bundled basic tools, and (c) configured fake MemoryPort/SkillPort bridges. Also test explicit missing-backend configuration errors and any declared optional-library adapter with that dependency absent and present. This proves a single distribution can support different tool profiles without multiple package releases.

## 5. Domain model

All externally addressable identifiers are opaque serializable values. PIDs, references, closures, ETS identifiers, credentials, and executable module names are internal implementation details and must not appear in public envelopes or durable records.

| Entity | Important fields and semantics |
| --- | --- |
| RuntimeInstance | `runtime_id`, routing namespace, policy/store references, limits, adapter capabilities. Multiple instances must coexist without name collisions. |
| AgentDefinition | Versioned role/instruction reference, provider selection policy, allowed tool profiles, context strategy, lifecycle policy. Definition edits do not silently mutate active runs. |
| AgentInstance | `agent_id`, definition revision, owner reference, hosted/owner-bound lifecycle, agent-local scope, incarnation, admission status. Stable identity is independent of PID. |
| Context | `context_id`, owning agent, revision, instructions reference, immutable history/summary segments, resource grants/references, provenance. |
| Task | A submitted unit of work, requester, target agent, input, idempotency key, acceptance/result contract, budget account, cancellation contract. |
| Run | One accepted execution of a task: agent/context IDs, context base revision, root correlation/budget IDs, state, limits, outcome, active attempts and dependencies. |
| ModelStep / Attempt | A logical model step and its individual transport attempts. Retries do not create fresh unaccounted work. |
| ToolInvocation | Stable invocation ID, provider call ID, bound tool revision, normalized arguments/hash, grants, attempt state, result/effect certainty. |
| Delegation | Requesting run, target agent, accepted target run, task status, authorized operation contract, result/cancellation relationship. |
| Message | Sender/recipient references, message kind, correlation IDs, payload/artifact reference, deduplication key, expiry, provenance. |
| Approval | Request ID, principal, exact operation digest, tool/arguments/grant revisions, run/incarnation, expiry, decision and resolver identity. |
| ExecutionEvent | Versioned event ID, aggregate sequence, runtime/agent/context/run/root IDs where relevant, timestamp, causation, payload. |

A model-facing conversation message and an inter-agent message are different records. An inter-agent message does not enter the model conversation until an authorized context admission step selects it.

### 5.1 Lifecycle ownership

An agent is either:

- **Hosted:** owned by a product/runtime host and independent of incoming delegated tasks. May be activated on demand without changing identity.
- **Owner-bound:** owned by an explicit host resource or run. Sigma's main agent may be session-owned; a spawned subagent is owned by the spawning run.

Owner references are not free-form model input. Stopping a host/session-owned agent is a host lifecycle action. A model-visible `run_cancel` operation is not an agent-stop API.

Temporary children must not outlive their owner run by accident. V1 has no model-visible detach/adopt tool. A future trusted-host ownership transfer requires an explicit durable transaction and new budget/cancellation contract; it must not happen implicitly during completion.

### 5.2 Relationship graphs

Maintain three distinct relationships:

1. **Ownership:** session/run/host owns an agent or temporary run. Run-owned children form an acyclic bounded tree.
2. **Dependency:** run A awaits delegated or child run B. Detect cycles and context-resource self-dependencies before committing a wait.
3. **Communication:** authorized messages between agents. This may be many-to-many and does not imply ownership or automatic execution.

Use `root_run_id` for causal grouping and a distinct `budget_account_id` for accounting authority. A string correlation ID never grants budget or cancellation rights.

## 6. Hosting and process architecture

### 6.1 Managed hosting

Recommended components per runtime instance:

- Instance supervisor and registry, with injected names/references.
- Agent host processes for bounded work admission, mailbox/inbox projection, context assignment, and lifecycle.
- Per-context execution ownership and per-run controllers.
- Supervised provider/tool/store/transport tasks.
- Root budget/dependency coordination and bounded event relays.

Agent host callbacks do not stream models, execute tools, block for peer replies, or wait indefinitely on storage. A run waiting on approval or another run releases execution slots and resource locks, but retains its logical context ownership until the safe boundary permits release.

Supervision recovers infrastructure; it is not permission to rerun business effects. A restarted controller reconciles committed state before doing work. A root controller must not automatically respawn a successful or uncertain tool invocation just because its worker died.

### 6.2 Embedded hosting for migration

Sigma's existing control process and Synapsis's Session Worker may own the kernel state directly while adopting shared effect, tool, budget, and event contracts. An embedded agent endpoint participates in the same registry/admission contracts as a managed agent.

**There is one kernel state owner and one context writer.** Do not start a second managed controller for a context already owned by a product worker. A compatibility wrapper is not an independent executor.

For Synapsis graph execution, use the shared model-step/tool-step/effect lifecycle underneath product-owned graph transitions. Specialized graph nodes may choose the next product operation but cannot call providers or tools around shared policy, accounting, and cancellation. Graph and QueryLoop migration are separate required paths.

### 6.3 State-machine model

Run states:

| State | Meaning |
| --- | --- |
| `queued` | Accepted but no execution slot/context ownership yet. |
| `running` | Advancing work; phase identifies preparing context, streaming model, running tools, compacting, or coordinating children. |
| `waiting_approval` | An exact operation is suspended awaiting a valid decision. |
| `waiting_result` | A typed continuation awaits a child/delegated run, user answer, or explicit external result. |
| `cancelling` | Cancellation accepted; providers, tools, and required descendants are being reconciled/terminated. |
| `completed` | Result committed and required children/dependencies settled. |
| `failed` | Known failure, including budget exhaustion, invalid dependency, or unrecoverable protocol failure. |
| `cancelled` | Execution stopped with required cleanup settled and no unresolved mutation outcome hidden. |
| `timed_out` | Deadline caused termination with the same cleanup/certainty requirements. |
| `unknown_outcome` | An external mutation or required operation may have happened; automatic replay is unsafe. |

Recovery is a control procedure, not a successful run outcome. A durable nonterminal record is fenced, reconciled, and either resumed at a proven safe boundary or finalized with an explicit outcome.

A cancellation acknowledgement means **request accepted**, not **all work stopped**. If external mutation certainty cannot be established within the cleanup budget, finalize as `unknown_outcome` with `stop_reason: cancelled` or `deadline_exceeded` and retained invocation evidence.

A run has exactly one committed terminal transition. Event deliveries may be duplicated and clients deduplicate by event ID. Retries/regeneration create new run/attempt identities as specified; they never erase the prior terminal record or imply filesystem rollback.

## 7. Deterministic kernel and effects

The kernel transforms **state + command/event** into **new state + transition records + effect intents**. It does not read clocks, generate randomness, call providers, touch storage, or start processes directly. Inject time, generated identifiers, and normalized external results as inputs.

A transition includes its expected revision and required identity/epoch fencing. The effect runner only executes intents whose prerequisite transition is acknowledged under the selected storage mode.

Durable effect ordering:

1. Validate command, authority, budget reservation, and expected state.
2. Commit the state transition and its effect intent/outbox atomically for that aggregate.
3. Dispatch the committed intent asynchronously.
4. Receive a result stamped with run, invocation/attempt, incarnation, and operation IDs.
5. Validate fencing, commit completion/context change, settle accounting, and publish the canonical outcome.

Slow commits run outside control callbacks. A controller can stage a transition but cannot launch its effects before acknowledgement. Control requests remain bounded; cancellation arriving during a commit is recorded/applied in sequence before further effects are admitted. Do not let an asynchronous completion overwrite a newer cancellation.

Streaming text deltas are provisional, bounded observation events. They need not create a durable transaction per token. Canonical messages, tool-call completion records, and run terminals use explicit committed boundaries. A persistence failure prevents claiming a durable terminal and prevents starting dependent mutations.

Pure replay reconstructs state only; it does not execute historical effects. Effects require separate reconciliation and admission.

## 8. Context ownership and composition

Each agent has its own context namespace. A role can have multiple task contexts; it need not accumulate every task into one unlimited conversation.

Default rules:

- At most one active writer per `context_id`.
- Tasks targeting the same context queue; distinct task contexts may run concurrently within agent/root quotas.
- A child receives an explicitly selected immutable snapshot, summary, and resource references. No implicit full-history, private-memory, or credential inheritance.
- Peer messages and tool output are provenance-tagged data, not higher-priority instructions.
- A delegated result is admitted at a safe boundary; it cannot arbitrarily replace the receiver's system instructions.
- Context updates and compaction use expected revisions. Stale writes fail with `context_conflict`.
- Terminal context updates preserve complete tool-call/result pairs and artifact references. Interrupted tool calls receive explicit unresolved/error records rather than fabricated success.

Do not merge concurrent contexts by last-write-wins. A host-controlled merge creates a new versioned summary/update from selected results. Context forks and history branching do not undo tool side effects in a workspace.

### 8.1 Compaction

Context capacity is derived from verified model metadata and a conservative estimate including instructions, tool schemas, selected history/resources, reserved output, and safety headroom. Missing estimates/metadata are represented as unknown and require a host fallback limit; zero is not a valid substitute for unknown.

Compaction is an explicit effect and context transition. Its model usage counts toward the same budget. Preserve mandatory instructions, active approvals, unresolved dependencies, and tool-result pairing. Context revisions and compaction events let products display accurate lineage and counters.

Do not use lifetime total tokens as current context occupancy. Do not promise a precise time-until-compaction from a token threshold.

## 9. Model-step execution

A ProviderPort invocation binds agent/run/root IDs, model configuration revision, canonical request, deadline/cancellation handle, tool exposure snapshot, and trace references. Provider-specific credentials and continuation artifacts remain with the provider/host boundary and are not leaked into ordinary event payloads.

V1 waits for a validated completed model response before executing its tool calls. Partial JSON, incomplete streams, invalid tool-call IDs, and a missing terminal provider event cannot produce tool side effects. Speculative/eager tool execution during a partial provider response is deferred; migration must disable it or leave the affected session on the legacy engine until the common safe path is integrated.

Retry policy distinguishes:

- Transport retries before a usable response.
- Provider-supported continuation of an interrupted response.
- A model choosing to repeat a failed tool call in a subsequent step.
- Tool backend retries with a proven retry contract.

All are accounted for, bounded, and identified independently. Streaming retries do not silently concatenate a new response onto a failed attempt. Prefer a typed failure unless the adapter proves continuation/deduplication semantics.

## 10. Tool contract and gateway

### 10.1 Tool descriptor

A versioned registered descriptor contains:

- Stable tool ID/name/revision, description, input schema, and output schema or documented result union.
- Host-attested capability requirements, resource/network scopes, data classification, and approval category.
- Side-effect class, idempotency/reconciliation contract, concurrency safety, conflict/resource keys, deadlines, and output limits.
- Backend reference, cancellation support, and normalized progress/result contract.

`read_only`, `retry_safe`, and `parallel_safe` are separate properties. Untrusted remote annotations are advisory input to a host-owned descriptor, not enforceable authorization facts. Unknown metadata uses restrictive defaults.

### 10.2 Mandatory execution path

**Registered descriptor lookup → schema validation → bound-argument resolution → policy/approval → budget/concurrency/resource admission → invocation intent → execution → result validation/normalization → committed outcome.**

Lookup only accepts admitted registry entries. Model input cannot select arbitrary Elixir modules, functions, supervisor names, credentials, trusted context IDs, or dynamic atoms.

Runtime-injected invocation context includes agent/run/root identity, principal, effective grants, resource namespace, cancellation/deadline, and provenance. Target IDs may be supplied as tool arguments where needed, but authorization validates them against the injected caller.

Approvals bind the final argument digest, descriptor revision, resource/grant revision, caller/run identity, and expiry. Parameter modification after approval requires revalidation and, where relevant, a new approval. A stale approval, old incarnation response, or self-approved model instruction is rejected.

Tools can emit progress and a final normalized result. Failure classes include validation, forbidden, approval-required, not-found, timeout, cancellation, transient transport, resource conflict, execution failure, malformed result, budget exceeded, unsupported capability, and unknown outcome. A textual error message is not the sole error representation.

### 10.3 API and model tools

Trusted callers and model-visible wrappers both use the same gateway. Trusted identity comes from a host-authenticated execution context, not a boolean argument such as `trusted: true` supplied by a model.

Bundling a tool implementation, registering it for an agent, and permitting a particular invocation are three independent decisions. Every consumer installs the same package; its role/task profile chooses exposure and PolicyPort authorizes each invocation. The empty tool set is valid. Explicitly required tools with missing backends fail configuration under section 4.4.

### 10.4 Built-in collaboration tools

These implementations live under `Backplane.AgentRuntime.Tools.Collaboration.*` in the single package but are opt-in registrations:

| Tool | Contract |
| --- | --- |
| `agent_discover` | Return only authorized, bounded role/capability summaries. Do not reveal hidden identities, contexts, or secrets. |
| `agent_spawn` | Atomically admit a temporary agent and its initial task/run under the caller's run ownership and budget. Select an approved profile and explicitly supplied child context material. Return child agent/run handles. |
| `agent_delegate` | Submit a task to an existing authorized agent. Return a durable submission handle, then accepted target run or rejection. Does not create lifecycle ownership of the recipient. |
| `agent_send` | Enqueue a typed notification/message under messaging policy. A delivery acknowledgement is not a work-completion acknowledgement. |
| `run_status` | Return an authorized bounded status/result view without causing model inference. |
| `run_wait` | Suspend via a typed continuation until an authorized run settles or the wait expires. Do not occupy a tool worker slot, block an agent host callback, or poll the model. |
| `run_cancel` | Request cancellation of an owned or contract-cancellable run. Never stops the recipient agent or unrelated work. |
| `ask_user` | Request information with a bounded interaction. Human approvals remain a separate policy operation. No available resolver yields explicit unavailability/denial or a configured finite wait, never auto-approval. |

`run_wait` is not implemented as a tool task waiting synchronously while holding a concurrency slot. The gateway records a suspended invocation and the kernel completes that invocation exactly once when the continuation resolves.

### 10.5 Spawn and delegation authority

Spawned agents receive a non-expanding subset of the caller's effective capabilities and remaining resource budget. A child profile is an allowlisted configuration, not a model-defined permission grant.

Delegation to a service-role agent requires a separate **delegation policy**: permitted recipient, task class, resources, allowed service actions, result visibility, and cancellation contract. The recipient's authority alone is not sufficient. For example, a content classifier cannot obtain unrestricted configuration mutation merely by sending a prompt to a configuration agent. The target validates the allowed operation contract before accepting the task.

All task-derived work uses an authorized root budget account. A recipient may have additional host capacity limits, but cannot silently reset the caller's task budget. A trusted host can fund a genuinely separate task with a new account and explicit causation; a model cannot mint one.

## 11. Bundled general tools with opt-in activation

### 11.1 V1 tool families

| Family | Proposed tools | V1 treatment |
| --- | --- | --- |
| Resource/file | `file_read`, `list_dir`, `glob`, `grep`, `file_write`, `file_edit` | Required bundled implementation; opt-in registration. Local workspace adapter plus a fake resource adapter in tests. |
| Command | `exec`, `job_read`, `job_cancel` | Required bundled implementation; opt-in registration. Jobs belong to their initiating run, with bounded output and cleanup. Unsupported platform/isolation capabilities fail closed. |
| Plan | `plan_read`, `plan_update` | Required bundled implementation; opt-in registration. Scope to the current task/run with expected revision. Not a project scheduler. |
| Memory | `memory_search`, `memory_store` | Required bundled wrappers, registered only with a configured capable port; tested against a fake port. Real storage and scope policy belong to hosts. |
| Skill | `skill_list`, `skill_load` | Required bundled wrappers, registered only with a configured capable port; versioned discovery/loading does not authorize arbitrary execution. |
| Network/search | `http_fetch`, search services | Deferred implementation. Reserve an extension boundary, not placeholder tools advertised as working. |

All in-scope implementations and wrappers ship in `backplane_agent_runtime`; optional activation is not permission to defer their V1 implementation. No tool is enabled merely because the package is installed. Backend-dependent entries are omitted from optional selections when unavailable; an explicit requirement for an unavailable tool fails profile validation as specified in section 4.4. Host business tools remain outside the package.

### 11.2 Resource operations

A resource namespace is an authorized host-provided handle, not an unrestricted OS path. Model-supplied paths are resolved inside that namespace. Enforce input/output limits, resource classification, traversal protection, symlink policy, and revision-aware writes.

`file_write` and `file_edit` require either an expected content revision or a create-only condition. Missing-file creation is distinct from replacing an existing file. Conflicting concurrent writes return `resource_conflict`; do not silently reread and overwrite newer content. Atomic replacement and the expected-revision check must be enforced by the resource adapter, not separated by an unprotected read/write race. The adapter must state its concurrency domain: coordinated writes can provide revision checks under a shared resource coordinator; arbitrary uncooperative external writers require a stronger transactional resource backend or an isolated workspace. Atomic rename alone is not compare-and-set against every external OS process.

A local path-prefix check is not a complete confinement boundary. The local adapter must state and test its handling of symlink races, mount boundaries, and concurrent replacement. If the required guarantee cannot be implemented on a platform, require a stronger sandbox/resource backend or reject that profile. Do not advertise a secure filesystem sandbox based on `Path.expand` alone.

Reading resources grants neither execution permission nor instruction authority. File contents, retrieved documents, Skill resources, and peer results remain provenance-tagged inputs.

### 11.3 Command execution

Prefer an explicit executable/argument-vector mode. Shell interpretation is a separate capability and must be explicitly requested and authorized. Do not treat command-string heuristics as an OS security boundary.

The CommandPort owns the process/job and its descendant cleanup. Bind working directory, environment allowlist, resource/network policy, deadline, output caps, and cancellation to the run. Do not inherit arbitrary host credentials/environment variables. Network isolation is only claimed when the selected backend actually enforces it. Commands default to an exclusive workspace conflict key while active, so shared file tools and other agent commands cannot concurrently mutate that workspace through the runtime. Narrower concurrency requires a host-attested backend contract, not inference from a command string; writers outside the runtime remain subject to the resource adapter's stated isolation limits.

V1 supports only platform/backend combinations with tested subprocess and descendant cleanup. The portability matrix is recorded during implementation; do not pretend unsupported Windows/Linux/macOS behaviour is equivalent. An OTP process supervisor alone is not an OS sandbox.

Long-running jobs may return a scoped job handle while output is streamed. They remain owned by the run, count against its quotas, and must settle or be cancelled before a successful owner terminal. `job_read` is bounded/cursor-based. A model cannot detach a job, enumerate another run's jobs, or use `job_cancel` to terminate arbitrary host processes.

### 11.4 Plans, memory, and Skills

Plans are versioned task-local resources. They do not implicitly submit work to other agents; use `agent_delegate` for that operation.

Memory operations distinguish agent-private, task, and explicitly shared project scopes. The runtime injects allowed scopes, and the backend checks them. A free-form `scope` argument cannot expand visibility. Context compaction and long-term memory publication are separate operations.

Skill loading records the bundle reference, revision/digest, selected content, resource handles, and provenance. The host decides activation policy. `allowed-tools` or similar Skill metadata does not grant capabilities, and a Skill cannot override system policy or automatically acquire another agent's resources.

## 12. Communication, delegation, and dependency handling

### 12.1 Message kinds and admission

Separate `notification`, `task_request`, `task_result`, `progress`, and `control` messages. Only an explicit accepted task, or a host-approved wake policy, can start a model run. Acknowledgements and status updates do not trigger reply loops by default.

Routing is local to the runtime namespace in V1. Validate sender authority, recipient discoverability, task/delegation contract, payload size, expiry, inbox capacity, root causation, and deduplication identity before accepting work.

Expose distinct states for a delegation submission: `submitted`, `accepted`, `rejected`, and target run progress/outcome. A timeout waiting for acceptance is not proof that the task was rejected. Return/query the existing submission handle instead of issuing another task with a fresh idempotency key.

### 12.2 Delivery and idempotency

In ephemeral mode, accepted messages are bounded in-memory records and may be lost on VM restart. In durable mode, acceptance acknowledges the adapter's declared committed boundary for an inbox item; delivery can be at least once, and processing is deduplicated using retained keys.

Idempotency scope includes runtime namespace, authenticated requester, operation type, and caller key. Store a payload digest. Reusing a key with different arguments returns an explicit conflict. Retention must cover the documented retry/recovery horizon and active work; do not evict keys for live tasks to satisfy a size limit.

Sender intent/outbox and receiver inbox/run admission may cross aggregates. Do not assume one distributed transaction. Use an idempotent submission record, committed outbox, recipient acceptance/deduplication, and acknowledgement projection. Failures converge by replaying the same submission identity.

Deduplication of a task submission does not make its external tools exactly once. Those tools have their own invocation and effect-certainty records.

### 12.3 Waiting and cycles

`run_wait` creates a dependency and continuation, not a blocking RPC. Check both run dependency edges and context ownership dependencies. In particular, A waiting for B is invalid if B can only start by acquiring A's currently held context and no defined safe release is possible.

Reject detectable cycles with `dependency_cycle` or `context_dependency_conflict`. Bound wait deadlines and count them against overall task time. Releasing worker/resource slots while waiting prevents capacity deadlocks, but does not by itself solve logical cycles.

Do not automatically launch a second writer in a context to resolve a cycle. A host can instead delegate into an explicitly isolated context, or reject the work.

### 12.4 Cancellation relationships

- Owner-run cancellation propagates to its temporary children and their descendants.
- A delegated run is cancelled only under the acceptance contract for that task; cancellation never stops the target hosted agent or unrelated target runs.
- Read-only status subscriptions and UI sockets own no run lifetime.
- Completion waits for required children/dependencies. Intentionally independent work requires a trusted host to create a separate ownership/budget contract; V1 model tools cannot detach it.

When a target was admitted outside the local runtime through a future adapter, its cancellation/delivery guarantees must be negotiated separately. That extension is not part of V1 acceptance.

## 13. Persistence, durability, and recovery

### 13.1 Storage modes

| Mode | Guarantees |
| --- | --- |
| `ephemeral` | Live-process ordering, in-memory idempotency and state, explicit loss on VM/store restart. Suitable for tests and intentionally transient embedded runs. |
| `durable` | Adapter-declared acknowledged commits, versioned transition records, inbox/outbox, checkpoints, invocation evidence, and recovery. Must pass the durable conformance suite. |

The runtime supplies storage behaviours and an ephemeral reference implementation. Consumer adapters use existing persistence where appropriate. No shared database service, compulsory Ecto schema, or universal JSONL/Concord format is introduced.

A durable adapter must implement compare-and-set/version checks, atomic transition-plus-associated-events/outbox for an aggregate, immutable IDs, bounded reads, and explicit commit failures. It must document the crash/power-loss boundary actually provided. A test fake proves contract handling, not production durability.

Do not allow an adapter configured as durable to acknowledge before its promised durable boundary. Storage unavailability blocks new durable effects and surfaces a typed degraded state rather than silently falling back to memory.

### 13.2 Context, events, and invocation checkpoints

Persist enough to distinguish accepted work, admitted effect intent, dispatch start, external acknowledgement, recorded result, committed context revision, and terminal outcome. Store large bodies as referenced artifacts with scope/access controls rather than repeating them in every event.

Product history can remain a projection of canonical runtime events. Historical session files and Concord layouts do not have to be rewritten. Any new runtime metadata/sidecar storage requires a documented adapter-owned schema and migration, not an implicit change to historical replay semantics.

### 13.3 Fencing

Assign a fresh incarnation/epoch to recovered owners. Stamp every provider chunk, tool result, approval response, continuation, and store completion with the relevant owner/operation identity. Reject results from old incarnations, cancelled attempts, retired tools, or superseded context revisions.

Epochs prevent stale state writes; they do not undo an external command or prevent an already running external system from mutating. Resource/tool backends need their own cancellation, idempotency, reconciliation, or isolation contract.

### 13.4 Recovery algorithm

1. Load committed nonterminal work and mark its old executor incarnation invalid.
2. Rebuild context/version, reservations, unresolved invocations, inbox/outbox, and ownership/dependency relationships.
3. Classify unresolved effects using recorded dispatch evidence and backend reconciliation capabilities.
4. Resume only safe work: unstarted effects, explicitly idempotent/reconciled effects, or read-only effects with an attested retry contract.
5. For uncertain mutations, preserve `unknown_outcome`, known artifacts/receipts, and a bounded operator-facing reason. Do not issue the mutation again automatically.
6. Reconcile required children and release reservations only after confirming they cannot continue spending/executing.
7. Republish committed events with their original event IDs and sequence; do not fabricate a second terminal transition.

A process crash between intent and result may leave uncertainty even when the operation appears not to have started. Be conservative unless dispatch evidence or the backend can prove otherwise.

## 14. Budgets, scheduling, and loop protection

### 14.1 Root task accounting

Enforce required finite limits for model steps/attempts, tool invocations/attempts, overall deadline, total created agents/runs, descendant depth, outstanding delegations, active model/tool jobs, inbox/queue bytes and counts, and artifact/output sizes. Hosts choose profile values; zero tools/children can be a valid restriction. Production omission must not turn a limit into infinity. Use monotonic time for live-process deadlines and persist an absolute expiry plus conservative remaining-budget evidence for recovery; persisted monotonic timestamps are not portable across VM restarts. Clock regression or uncertain elapsed time must not silently extend task lifetime: expire or reconcile conservatively under the host clock policy.

Use an authoritative root account with idempotent reservations for concurrent work. Child-local limits can only tighten the root policy. Recipient agent limits additionally constrain delegated work.

Admission across root and recipient aggregates uses a versioned reservation token and idempotent acknowledgement. A target cannot execute against an expired/revoked token. Do not release a live reservation merely because a local timer expired; first fence/reconcile admitted work so the same budget cannot be spent twice.

Model input/output usage, including retries, compaction, and subagents, is attributed to invocation/attempt IDs. The total aggregates each reported unit once. Root totals are not the sum of already-aggregated parent and child totals.

Exact provider billing is not guaranteed. Token/cost reservations use conservative estimates and provider output limits where supported. Provider reports can arrive late; report unknown/estimated values distinctly. Monetary estimates are not a hard billing cap. Logical admission limits and local cancellation deadlines are enforceable within the runtime/backend contract, not guarantees about a disconnected remote provider's final invoice.

### 14.2 Fairness and backpressure

Use bounded admission queues, per-agent quotas, root concurrency limits, and a fair scheduling policy. Saturation yields an explicit overload/retry response or a bounded queue position; it never silently creates an unlimited task list.

A raw BEAM mailbox is not inherently a bounded application queue. Enforce admission before sending large work payloads, use credits/acknowledgements for cooperating stream adapters, cap relay buffers, and disconnect/reconcile misbehaving producers. Report limits actually enforced by the implementation.

Waiting for peers/approval consumes task lifetime but not a scarce model/tool execution slot. Context serialization is separate from execution-slot allocation.

### 14.3 Hard loop breakers

Track repeated normalized tool-call fingerprints, failure class, no-progress iterations, repeated delegation signatures, and total model/tool activity. Hash fingerprints include stable tool identity and normalized arguments; retain bounded state and avoid logging secrets.

A prompt nudge may be emitted before stopping, but does not replace a hard limit. When limits are reached, reject new effects and transition to a known failure after cleanup. A model changing trivial arguments or delegating to another agent cannot reset the root limit.

Avoid nested retry amplification: the runtime and adapters expose attempt accounting and a single remaining-attempt/time envelope. Backoff is scheduled asynchronously, bounded by the root deadline, and cancellation-aware.

## 15. Events, metrics, and public contracts

Canonical lifecycle families include `agent.*`, `task.*`, `run.*`, `model.*`, `tool.*`, `message.*`, `approval.*`, `context.*`, and `budget.*`. Products map them into existing UI/API event names rather than changing public protocols as a prerequisite.

Each canonical event has a schema version, immutable event ID, aggregate ID/sequence, causation/correlation references, and structured payload. Ordering is per aggregate, not a fictional total global order. A client reconnects with a cursor and can recover from an authoritative snapshot plus retained events.

Bounded subscribers may coalesce/drop provisional text/progress deltas and emit a gap marker. Canonical durable outcomes remain replayable within documented retention. A subscriber cannot force unbounded buffering or stall the executor indefinitely. After retention expires, return an explicit cursor-expired response and a snapshot path.

Usage distinguishes model-reported input/output/cache/reasoning fields where available, estimates, missing values, and cumulative versus delta reports. A provider adapter declares usage semantics and the runtime deduplicates by attempt/report identity. Measure first-token latency, generation duration, end-to-end run time, tool duration, and wait duration separately. Throughput labels specify the denominator; absent counts remain unknown rather than zero.

Structured logs omit credentials, unrestricted prompts, and sensitive tool arguments by default. Events carrying content inherit resource classification and recipient visibility. Telemetry tags should avoid unbounded high-cardinality identifiers where the chosen metrics backend cannot safely handle them; tracing/event records retain correlation IDs.

### 15.1 API surface categories

| Surface | Representative operations | Caller |
| --- | --- | --- |
| Hosting | Register definition, start/activate agent, stop agent, register embedded endpoint, inspect health. | Trusted host |
| Work | Submit task, inspect submission/run, cancel under contract, attach continuation. | Authorized host or built-in tool wrapper |
| Context | Create/fork isolated context, append selected result, compact/merge with expected revision. | Host/context coordinator |
| Tool registry | Register/revoke versioned descriptor, select profile, execute admitted invocation. | Host; execution through gateway |
| Interaction | Send notification, discover visible agents, resolve user interaction, resolve approval. | Authorized caller; approval resolver is never the model itself |
| Observation | Subscribe, snapshot, replay retained events, read bounded metrics. | Authorized observer |

This is a category contract, not a promise that exact exported function arities have already been implemented. Freeze concrete types/functions in the first implementation contract task and keep them consistent across consumers.

## 16. Consumer migration

### 16.1 Sigma

Earlier excerpts identify `Sigma.Agent`, `Runtime`, `PublicRuntime`, the repository/session supervisors, and `Sigma.Coding.Dispatcher` as integration seams [SRC-SIG]. Preserve repository-owned session lifetime, JSONL/session operations, UI/headless protocol, context files, coding hooks, and storage compatibility.

First adapt the existing provider/dispatcher and make a session's agent an embedded runtime endpoint. Then replace duplicate execution lifecycle, cancellation, budget, and nested-child handling with common components. Register compatible bundled tools under `Backplane.AgentRuntime.Tools.*` through Sigma-selected profiles; keep product-specific tools in Sigma. No separate tools package is installed. Sigma's public prompt/steer/follow-up/cancel/fork interfaces remain compatible.

Existing hooks are not bypasses. Hook changes to tool arguments require revalidation/reauthorization. Stop-hook continuation and steering consume the same execution budget and enter only at defined safe boundaries. Subagent creation is a new run-owned relation, not an assumption that every current Sigma agent already supports nested subagents.

### 16.2 Synapsis

Keep daemon/routine triggers, role definitions, product graph nodes, workspace/memory services, and Concord-backed storage adapters in Synapsis. The earlier excerpts show `Daemon` and `RunCoordinator` orchestrating sessions rather than doing model/tool work [SRC-SYN-CONTROL]. Preserve that separation.

Migrate QueryLoop and graph paths explicitly. `Session.Worker` can remain the authoritative embedded state owner during migration. Graph nodes reuse shared model/tool effects and events; the product graph remains product-owned. Do not ship a migration that covers QueryLoop but leaves graph tools outside shared authorization/cancellation/accounting.

Independent role agents receive stable identities and separate context namespaces. Delegated tasks create target runs and do not become lifecycle children of the sender. Scheduled/heartbeat/reflection work is an ordinary host-submitted task using an appropriate restricted profile. The runtime does not import a scheduler dependency. Roles select bundled `Tools.*` implementations or host tools through the same registry; sharing one package does not give every role the same tool profile.

### 16.3 Backplane

Add an opt-in service integration outside the runtime package to register limited configuration/content profiles. Default new service agents and mutation tools to disabled until explicitly configured.

A first configuration workflow should read current state, produce a validation/preview result and proposed revision-bound change, then apply only through an existing domain-service validation/authorization/audit boundary with an authorized decision. A content workflow uses scoped content query/update tools. The runtime does not write Backplane tables or configuration files directly.

These consumers prove that repository paths, sessions, shells, and memory services are optional even though their tool wrappers ship in the same artifact. Installing the package must not start these service agents, register coding tools, open filesystem resources, or start optional backend clients.

### 16.4 Rollout and rollback

Select the engine at new-session/context creation. Pin an active session to its selected engine until it reaches a documented safe boundary. Do not hot-switch a live context between controllers.

Use recorded/scripted model traces for parity tests. Never run legacy and shared engines against real mutating tools in parallel for comparison. Rollback sends new work to the previous engine; completed shared-runtime artifacts remain readable through adapters. Do not claim old engines can resume unknown new-format in-flight state.

Remove duplicate implementations only after their path's parity/conformance gate passes. Retaining a temporary compatibility mapper is acceptable; retaining a second ungoverned executor is not.

## 17. Required invariants

| ID | Invariant |
| --- | --- |
| I01 | No session, repository, shell, Phoenix, or Backplane service is required to run an agent. |
| I02 | One authoritative writer owns a context revision at a time. |
| I03 | A spawned agent/run is owned by its initiating run; a delegated hosted peer is not. |
| I04 | Old-incarnation/attempt/context results cannot alter current state. |
| I05 | Every tool route, including direct APIs and collaboration tools, uses the same gateway. |
| I06 | Partial or invalid model tool calls do not execute. |
| I07 | Child and delegated work cannot escape authorized root accounting or inflate grants. |
| I08 | A cancellation request is not reported as completed cleanup. |
| I09 | A run has one committed terminal transition; event delivery may repeat it. |
| I10 | An uncertain external mutation is never blindly replayed or labelled successful. |
| I11 | Durable acceptance is not acknowledged before the promised storage boundary. |
| I12 | Waiting consumes no model/tool worker slot and cannot introduce an unchecked dependency cycle. |
| I13 | Status/progress/acknowledgement messages do not automatically trigger model inference. |
| I14 | Queues, streams, output, retries, descendants, and total work have explicit finite bounds. |
| I15 | Slow/disconnected observers do not own execution lifetime or require unbounded buffering. |
| I16 | Empty tools and unselected optional backends are valid. Explicitly requiring an unavailable tool fails configuration; bundling never implies registration or authorization. |
| I17 | Context inheritance, data visibility, and action authorization are separate decisions. |
| I18 | Tool/argument/policy revisions and approval identities are validated before effects. |
| I19 | File writes are revision-checked and resource backends state their real confinement guarantees. |
| I20 | Hosted role agents survive cancellation of unrelated delegated work. |
| I21 | All provider, tool, compaction, retry, and descendant usage is attributed without double counting. |
| I22 | Recovery reconstructs state before admitting effects; pure replay does not execute them. |
| I23 | One package artifact includes the runtime and all in-scope bundled tool implementations, compiles/boots without optional backends, and supports distinct tool profiles without umbrella/service leakage or kernel-to-concrete-tool dependencies. |
| I24 | Both Synapsis execution paths and Sigma use the shared enforcement boundaries after migration. |

## 18. Validation and release strategy

The PRD defines acceptance scenarios and the implementation plan maps them to work items. The principal release gate is not unit-test count: it is successful execution of all three consumer modes with the same runtime version and unchanged host-specific ownership/storage boundaries.

Test the pure kernel with generated transition sequences and controllable clocks. Test providers/tools through scripted ports, cancellation acknowledgements, duplicate/late events, malformed payloads, and deterministic fault injection. Durable adapters need real-store restart tests at intent/dispatch/result/terminal boundaries, not only mock assertions.

Test two runtime instances in the same VM, resource traversal/symlink races, process descendant cleanup on declared platforms, blocked approval/headless behaviour, peer cycles, root budget races, inbox/outbox deduplication, observer overload, the single package artifact, and consumer compatibility. Run fresh-consumer fixtures with empty, bundled-basic, and fake-backend tool profiles against the same artifact/version. Inspect package contents, dependency/startup graphs, and internal kernel/gateway dependencies; test absent/present optional libraries and explicit missing-backend configuration errors. Merely disabling tools in a full umbrella build does not pass this gate.

Do not use live billable providers in required CI. Optional live smoke tests require explicit credentials and are outside deterministic release acceptance. The complete shared architecture is accepted only when both Synapsis paths, Sigma nesting, and a sessionless Backplane agent pass.

## 19. Deferred extensions

Remote addressing/transports, cross-node agent activation/failover, durable distributed ownership leases, autonomous detached jobs, richer team scheduling, speculative streaming tools, universal workflow graphs, network/search tool implementations, and shared long-term-memory storage are deferred.

Interfaces preserve room for these features, but V1 must not add empty production modules, claim remote delivery guarantees, or introduce policy switches without a tested consumer requirement. A future tool family may be extracted only after a concrete heavy-dependency, independent-consumer, or release-cadence need is demonstrated and approved. Do not pre-create a second tools app or publishing pipeline for that possibility.

## 20. Source register and baseline follow-up

| Source ID | Material and use |
| --- | --- |
| SRC-USER | Current discussion: Sigma session/main-agent with nested children; Synapsis independent communicating role agents; future Backplane config/content agents; latest accepted single-package distribution with bundled, opt-in tools. Authoritative target requirements. |
| SRC-LEGACY | Attached `Repo Analysis Request.txt`. Historical single-daemon proposal. Host-level trigger/profile concepts only; conflicting singleton/storage/scheduler assumptions are explicitly not adopted. |
| SRC-SIG | Earlier static excerpts at `gsmlg-opt/sigma@a7cbf4acf63f8ad1357c492e1eee49817f302cba`: `apps/sigma_agent/lib/sigma_agent.ex`, `runtime.ex`, `public_runtime.ex`, `apps/sigma_agent/mix.exs`, `apps/sigma_coding/lib/sigma_coding/dispatcher.ex`. Evidence for integration seams, not proof of target feature completeness. |
| SRC-SYN-CONTROL | Earlier static excerpts at `gsmlg-opt/Synapsis@fe4ebf7d70d58ec46c1055f22e7c13cb455d8700`: `apps/synapsis_agent/lib/synapsis/agent/daemon.ex`, `run_coordinator.ex`, `apps/synapsis_agent/mix.exs`. |
| SRC-SYN-EXEC | Same Synapsis snapshot: `apps/synapsis_agent/lib/synapsis/session/worker.ex`, `agent/query_loop.ex`, `agent/query_loop/executor.ex`, `agent/runtime/engine.ex`, `agent/graphs/coding_loop.ex`. Evidence for two migration paths and embedded state ownership. |
| SRC-BP | Earlier Backplane root `mix.exs` excerpt: umbrella/service and host-agent releases. It was read at `main`, not a pinned commit. Verify current SHA before implementation. |
| SRC-SIBLING | Earlier shared AI/Skill package discussions, including proposed `backplane_ai_protocol`, `Backplane.AiProtocol`, and `backplane_skill_protocol`. Proposed adjacent interfaces, not verified published dependencies. |

Implementation must record current SHAs, actual toolchain/dependency versions, current module paths, current tests, provider/Skill contract availability, storage capabilities, and platform support. If source observations differ, update the migration inventory and adapters; do not silently weaken the requirements or replace the product target.
