# Backplane AI Protocol — Product Requirements

| Field | Value |
| --- | --- |
| Status | Proposed; no implementation acceptance claimed |
| Revision | 0.2 — English implementation handoff |
| Date | 2026-09-10 |
| Owning repository | `gsmlg-opt/backplane` |
| Intended path | `docs/ai-protocol/prd.md` |
| Architecture | [design.md](design.md) |
| Execution | [implement_plan.md](implement_plan.md) |

## 1. Product summary

Backplane AI Protocol is an independently usable Elixir library for inference clients and an API gateway. It provides one request, response, event, authentication, and model-capability contract across direct provider access and Backplane WebSocket access.

The shared implementation lives in Backplane, but Sigma and Synapsis must not require a running Backplane service to use direct mode. Backplane consumes the same protocol mechanisms for native observation and explicitly supported translation. Samgita is a future consumer, not part of this delivery.

This PRD is derived from the supplied design revision 0.1 and the confirmed discussion. Requirement decomposition and milestone names below are implementation-planning elaborations, not newly verified repository facts. `design.md` preserves the evidence boundary, reference register, and source fingerprint. The original `T01–T28` acceptance IDs are retained.

## 2. Problem and desired outcome

The supplied source review describes separate provider-message mapping, streaming, error, usage, authentication, and model-discovery mechanisms across the projects. W0 must verify the exact duplication and callers at pinned source revisions before code removal.

The product outcome is **one verified set of protocol and connection mechanisms**, with application-specific execution and policy remaining in each host. Success is not a namespace rename or an SDK that only emits OpenAI-shaped messages.

A correct result lets an agent submit the same canonical intent directly or through Backplane, understand the effective model limits, receive consistent typed events, and handle failure without hidden resubmission. A gateway can observe native traffic without corrupting it and translate only when semantics are representable or an explicit downgrade is authorized.

## 3. Users and scenarios

| User / consumer | Required outcome |
| --- | --- |
| Sigma | Use shared direct/WS clients without changing agent loops, persisted-history meaning, tool execution, or cancellation behavior. |
| Synapsis | Reuse protocol/auth/model mechanisms while preserving QueryLoop, provider availability, and background-agent execution. |
| Backplane gateway | Parse native traffic for observations, perform declared bidirectional translation, and serve a canonical WS endpoint under host authorization. |
| Library integrator | Install the production package in a clean Mix project without a database, Phoenix, or Backplane root configuration. |
| Test author / Codex implementer | Reuse deterministic fixtures, fake servers, fault injection, and contract tests with clear pass/fail evidence. |
| Operator | See accurate capability/usage completeness, keep secrets scoped, and roll out by path without replaying uncertain requests. |

### 3.1 Representative user journeys

**Direct generation:** The host binds a profile and credential, resolves model capabilities, and submits canonical input. The caller consumes one handle's typed events or a complete response. Tools are returned to the host; the library does not execute them.

**Gateway generation:** Sigma or Synapsis authenticates to Backplane over WS and chooses a public model selector. Backplane validates permissions, resolves its own upstream binding, and returns the same semantic event contract. The client never receives an upstream refresh token.

**Protocol translation:** Backplane receives a native request, builds a translation plan, and rejects unsupported requirements before generation submission. Supported upstream responses are translated back. A later unsupported event causes explicit failure/incompleteness, not a fake successful end.

**Authentication and model selection:** A host drives an explicit login or supplies an API key, owns persistence, and discovers an account-scoped catalog. The UI can show effective context and effort options without inferring capacity from a model name.

**Failure:** A user cancels, a consumer dies, or a connection drops. Local execution reaches one terminal where observable, resources are released, partial output and upstream uncertainty remain explicit, and reconnect does not replay generation.

## 4. Scope

### 4.1 Required for full V1

| Area | Required scope |
| --- | --- |
| Deliverables | `backplane_ai_protocol`, `backplane_ai_protocol_testkit`, independent `examples/protocol_lab`. |
| Native codecs | OpenAI Chat Completions, OpenAI Responses, Anthropic Messages; request, non-streaming response, and streaming response in both directions. |
| Common translation | Text, representable image input, client function calls/results, usage/errors/stop semantics; only verified structured-output constraints. |
| Access | Direct HTTP/SSE and the proposed Backplane WS V1 path using the same canonical API. |
| Auth | API-key/bearer mechanism, explicit OAuth lifecycle and storage contracts, safe refresh coordination, separately validated Codex profile. |
| Models | Discovery, pagination/completeness, scoped availability, field provenance, context/output limits, thinking/effort/budget, effective capabilities. |
| Reliability | Bounded buffering, deadlines, cancellation, one execution per handle, explicit retries/uncertainty, secret-safe telemetry. |
| Migration | Sigma first, then Synapsis and Backplane business paths; preserve non-target/native capabilities. |
| Evidence | T01–T28, independent installation, real gateway tests, bounded explicit live validation where required. |

### 4.2 Non-goals

This project does not build agent loops, subagent orchestration, tool executors, MCP/skill runtimes, context-compression policy, scheduling, account UI, session storage, cost ledgers, or a new global routing service. Synapsis's daemon/heartbeat/reflection/schedule model is not being redesigned.

It does not deliver Samgita migration, comprehensive embeddings/media/batch/file APIs, realtime audio, portable cross-provider remote sessions, durable WS resume, or distributed exactly-once generation. Existing native gateway routes are preserved independently of canonical support.

### 4.3 Preview versus full V1

An API-key-only preview may be useful before OAuth/Codex or all consumer migrations finish. Its support matrix must explicitly say what is implemented and tested. It cannot claim full V1, hide stubbed auth behind a supported profile, or mark live compatibility passed without evidence.

## 5. Functional requirements

All requirements below are mandatory for the scope declared as full V1. Priority labels in the design's risk register indicate implementation urgency, not permission to omit release obligations.

| ID | Requirement | Acceptance evidence |
| --- | --- | --- |
| FR-01 | Ship an independently installable production package with no Backplane service/database/Phoenix requirement and no TestKit production startup. | T22, T23 |
| FR-02 | Represent ordered roles/content, call/result identity, refusals, limits, and origin-bound state without flattening semantics. Separate portable intent from trusted execution context. | T03, T08, T27 |
| FR-03 | Expose a single-execution handle, typed event consumption, complete responses, and idempotent local cancellation. A second consumption cannot submit again. | T06, T07, T28 |
| FR-04 | Implement independently tested bidirectional request/non-streaming/streaming codecs for all three protocols, including byte-correct bounded SSE framing. | T01, T03, T04, T05 |
| FR-05 | Preflight every translated request with a versioned plan and field diagnostics. Reject unsupported semantics before submission; allow only named approved downgrades. | T02, T21 |
| FR-06 | Preserve native forwarding without mandatory canonical re-encoding. Observation errors/limits must not corrupt forwarded bytes or fabricate usage. | T20, T26 |
| FR-07 | Distinguish content completion from protocol terminal, retain trailing usage, represent partial results, and clean up on cancellation/failure/consumer exit. | T06, T07, T08 |
| FR-08 | Apply explicit transport configuration/deadlines, disable hidden generation retries, count real attempts, and prevent untrusted endpoint/credential injection. | T12, T19, T27 |
| FR-09 | Provide WS version negotiation, request correlation, model queries, bounded per-request credit, cancellation/control capacity, duplicate detection, and no generation replay on reconnect. | T09, T10, T11 |
| FR-10 | Provide API-key/bearer and supported OAuth flow mechanisms with explicit host storage/presentation, validation, secret redaction, and no ambient credential fallback. | T12, T13, T20 |
| FR-11 | Coordinate one refresh owner per grant, revision/generation-checked persistence, revocation, and unknown outcomes after possible remote token rotation. | T14, T15 |
| FR-12 | Preserve and concretely validate the dedicated Codex auth/profile/native routes. Do not substitute Platform-key semantics or hidden App Server agent execution. | T12, T15, T26 |
| FR-13 | Discover and merge models with account scope, complete-pagination semantics, field provenance, stale handling, operator-disable preservation, and revision checks. | T12, T16, T17 |
| FR-14 | Resolve effective capabilities across model/deployment/account/codec/policy; validate separate input/output/context and thinking/effort/budget constraints. Preserve unknown values. | T17, T21 |
| FR-15 | Report usage and timing with source, completeness, inclusion relationships, attempt identity, and observation boundary; never double-count snapshots or client/gateway observations. | T18, T20 |
| FR-16 | Supply reusable fixtures, scripted providers, raw HTTP/WS/OAuth servers, clock/store helpers, fault probes, and conformance suites without a dependency cycle. | T01–T21, T27, T28 |
| FR-17 | Supply an independent public-API-only CLI for discovery, capability/preflight inspection, fixture replay, direct/WS calls, cancellation, and diagnostics. | T11, T22, T23 |
| FR-18 | Migrate consumers through thin adapters and route-level rollout while preserving history, tool loops, non-target providers, and native Codex behavior. | T24, T25, T26 |
| FR-19 | Publish versioned API/wire/fixture/provider compatibility, artifact-based installation evidence, release boundaries, and explicit unverified items. | T22, T23, T26 |

### 5.1 Mandatory capability-validation outcomes

| Condition | User-visible result |
| --- | --- |
| Fully supported intent | Execute the resolved plan and report effective model/options. |
| Unsupported requested field or state affinity | Structured pre-submission failure with the relevant field and constraint. |
| Lossy mapping with no permission | Reject; no silent omission or option change. |
| Named downgrade explicitly permitted | Execute with specific warnings and requested/effective values. |
| Unknown context, basic known-supported call, host permits unverified budget | Execute with `budget_validation: unknown`; do not label it fully budget-validated. |
| Strict budget requested or requested semantics cannot be verified | Refuse before submission. |
| Capability changes before dispatch and invalidate the request | Explicit revision/conflict failure, not a silent model/effort switch. |
| Security revocation | Host denial/cancellation remains effective despite an earlier capability snapshot. |

### 5.2 Mandatory error and terminal outcomes

A terminal reports business status and output completeness independently of upstream certainty. Cancellation acknowledgment cannot claim zero spend. A missing WS creation acknowledgment cannot be interpreted as non-submission. A midstream error cannot be hidden behind a successful terminator. An auth-refresh success cannot by itself authorize replaying generation.

After a local terminal, late usage belongs to an audit observation, not a second terminal or reopened business stream. A handle that has been consumed or has failed cannot create another upstream attempt merely because code enumerates it again.

## 6. Non-functional requirements

| ID | Requirement | Measurement / gate |
| --- | --- | --- |
| NFR-01 | Functional core and dependency isolation. | Pure reducers/codecs with injected effects; T22/T23 artifact and startup inspection. |
| NFR-02 | Bounded memory and fair concurrent execution. | Assert bytes/items at socket/transport/mailbox/request/connection boundaries; T07/T09. |
| NFR-03 | Deterministic local reproducibility. | Fixed fixtures, fault scripts, captured property seeds, no live-model output dependency; T01–T11. |
| NFR-04 | Account and secret isolation. | Malicious-input and cross-account tests; redacted logs/errors/events; T12/T20/T27. |
| NFR-05 | Honest execution and billing uncertainty. | Outbound-attempt probes, no implicit replay, complete/partial/unknown usage; T15/T18/T19. |
| NFR-06 | Compatibility and maintainability. | Separate version surfaces, golden-change review, thin temporary facades, explicit retirement gates. |
| NFR-07 | Observable failures without payload capture by default. | Stable telemetry schema, bounded diagnostics, no high-cardinality metric explosion; T18/T20. |
| NFR-08 | Independent deployment and host supervision. | Clean-process/consumer checks; no implicit network tasks or fixed host process names; T22/T23. |

The byte/concurrency values in design section 9 are starting test proposals, not measured SLOs. This revision does not invent latency or throughput targets. Release evidence must report environment, limits, concurrency, payload sizes, observed bounds, and remaining capacity constraints before making performance claims.

## 7. Product acceptance and evidence rules

### 7.1 Test oracles

The definitive acceptance catalog is T01–T28 in [design.md](design.md). Every supported protocol feature has an independent fixture. Self-encoding/self-decoding round trips cannot be the only oracle. Exact partition tests run at the decoder byte boundary; real-network tests assert semantic results rather than assuming TCP read boundaries match server writes.

Direct/WS parity uses the same deterministic upstream scenario. Compare ordered content, call/result relationships, usage, errors, warnings, completeness, and preserved opaque bytes. Only documented dynamic IDs, timestamps, chunk boundaries, and duration measurements may be excluded.

### 7.2 Required evidence by execution tier

| Tier | Required evidence | Restrictions |
| --- | --- | --- |
| Per change / PR | Core tests, relevant golden/property tests, local socket/fault tests, formatting and strict compilation. | No live credentials, external provider traffic, or billing by default. |
| Consumer integration | Real Backplane endpoint against fake upstream; Sigma and Synapsis regressions at pinned commits. | Fake Backplane-only tests cannot satisfy real integration. |
| Packaging | Install actual built package(s) in fresh Mix projects; inspect production deps and process tree. | No hidden sibling paths/root configuration; inspect TestKit as a separately consumable artifact too. |
| Live compatibility | Explicitly budgeted provider/Codex smoke with source and compatibility inputs recorded. | No exact generated-text assertions; no unattended quota-consuming probes. |
| Release | Supported version matrix, all required gates, remaining limitations, rollback/retirement record. | Skipped/blocked checks are not passes. |

### 7.3 Evidence statuses

Use `not_started`, `in_progress`, `passed`, `failed`, `blocked`, or `not_applicable` for acceptance tracking. Every `passed` entry references an actual command/report and source revision. `not_applicable` requires a declared-scope reason and cannot remove a full-V1 obligation. Historical notes and example test counts cannot populate a new pass result.

For authentication or compatibility requiring unavailable credentials, mark the live check blocked/not run and complete the deterministic tests. Do not remove the requirement to get a green dashboard.

## 8. Delivery gates

These are dependency gates, not time estimates. Parallel work is permitted under the implementation plan.

| Gate | Deliverable / result | Exit condition |
| --- | --- | --- |
| G0 — Foundation | Pinned baselines, isolated package shells, canonical/lifecycle/wire contracts, no production route change. | W0/W1 evidence; no unresolved critical semantics delegated silently to implementers. |
| G1 — Standalone direct preview | Bidirectional codecs, direct API-key client, effective model validation, deterministic TestKit/lab. | Relevant W2/W3/W5 suites plus T22/T23; actual implemented subset documented. |
| G2 — First consumer | Sigma's direct path uses the shared library through a thin facade. | T24 at pinned Sigma revision; no duplicate live shadow execution. |
| G3 — Gateway and auth | Real WS path, bounded flow control, auth/model lifecycle, Sigma WS parity. | W3/W4/W5 and relevant T09–T19; Codex status still tracked separately until validated. |
| G4 — Full integration | Synapsis and Backplane migrations, native preservation, explicit translation, Codex compatibility. | T25/T26 and all required scoped regressions. |
| G5 — Full V1 release | Verified production/TestKit artifacts, documented compatibility and rollout evidence. | T01–T28 and W8 release checklist complete for the full scope. |

Backplane WS development can run alongside G2 once its contracts/dependencies exist. Do not postpone the first real Sigma consumer until the entire gateway is rewritten.

## 9. Initial implementation boundary

The first assignment starts in Backplane and covers W0 plus the isolated W1 foundation/contract work selected in the implementation plan. It does not switch existing LLM production routes, remove legacy providers, change agent topology, introduce a database, or consume live quota.

W0 may inspect pinned Sigma/Synapsis source to build an accurate extraction inventory, but no cross-repository production edit is authorized by the initial task. Missing source access must be reported explicitly; it is not a reason to fabricate module paths or migration completion.

Required initial outputs are a source/dependency/caller inventory, actual baseline evidence, minimal standalone package checks, a contract decision list, and small follow-on work items. The plan contains a copy-ready starter assignment.

## 10. Risks, dependencies, and open decisions

The fourteen design risks R01–R14 remain active until their corresponding acceptance evidence exists. The most consequential are semantic loss in translation, false terminal/retry certainty, OAuth rotation races, Codex API conflation, WS resource behavior, and cross-account model capabilities.

Dependency decisions that must be resolved rather than guessed are the pinned source versions, WS backend, exact wire/control ordering, provider-specific auth compatibility inputs, final byte/concurrency limits, and host refresh-ownership/storage integration. Model capacities and effort strings must come from versioned sources or remain unknown; no hard-coded current-model table is specified by this PRD.

## 11. Success criteria

Full V1 succeeds when a clean consumer and both agents use the same semantic API, Backplane can observe without altering native traffic and translate its declared subset, failures and retries remain bounded and truthful, auth/model data is correctly scoped, Codex/native and non-target routes retain their behavior, and the resulting claims are backed by reproducible evidence.

A code move, a renamed namespace, an empty auth adapter, an always-green mock, or a successful umbrella build alone is not product completion.

## 12. Source traceability

| Confirmed objective | Requirements |
| --- | --- |
| U1 — Shared independent library | FR-01, FR-02, FR-03, FR-18, FR-19 |
| U2 — Gateway parsing/monitoring/translation | FR-04, FR-05, FR-06, FR-07, FR-15 |
| U3 — Direct and Backplane WS | FR-03, FR-08, FR-09, FR-17 |
| U4 — Auth and model capabilities | FR-10, FR-11, FR-12, FR-13, FR-14 |
| U5 — Test and consumer validation | FR-16, FR-17, FR-19; T01–T28 |
| U6 — Samgita deferred | Section 4 non-goals; no Samgita task in implementation plan |

External references and historical-source limitations are centralized in the source register of [design.md](design.md). This PRD does not introduce a new upstream research or repository-audit claim.
