# Backplane PR #32 — Codex Remediation and First-Consumer Integration

| Field | Value |
| --- | --- |
| Prepared | 2026-09-11 |
| Repository | `gsmlg-opt/backplane` |
| Pull request | [#32 — feat(ai-protocol): add W1 foundation][S0] |
| Historical reviewed head | `9bfa152da0971e029173876134cc3761eef3f298` |
| Historical base | `bd5bc83005fded6f67beefe3fa8abac31eae506a` |
| Suggested repository location | `docs/ai-protocol/pr32-remediation-handoff.md` |
| Delivery | Correct the foundation **and** make the existing Backplane LLM proxy a real consumer |
| Review recommendation | Request changes; revalidate each finding against the checked-out revision |

## 0. Assignment and evidence boundary

Implement the remediation in this document. Do not return another design-only proposal or stop after creating interfaces.

This handoff consolidates the preceding static PR review and the user's subsequent requirement that **Backplane's own LLM proxy must use the package before this delivery is considered complete**. It is not a new checkout, new test run, or assertion about the current remote PR head. The historical code observations below refer to the pinned commit above. The original design note was reread while preparing this handoff; it still describes the earlier migration order.

Start by recording the actual branch, HEAD, PR base where available, worktree changes, toolchain, and lockfile identity. Reproduce findings on that revision. A finding already fixed needs verification and regression coverage, not an unnecessary rewrite. Do not reset, overwrite, or discard unrelated work to reproduce an older revision.

### 0.1 Approved scope change

The original plan placed the first Sigma consumer before Backplane business-path migration. For this delivery, change that order to:

**Foundation repairs → minimum required shared protocol implementation → existing Backplane native proxy integration → real-entry-point acceptance → later Sigma/Synapsis adoption.**

Bring forward the relevant subset of W7.1, supported by the necessary W2 and W5 work. Keep full cross-protocol translation, the complete HTTP client, OAuth/catalog migration, WebSocket client/server, and cross-repository migrations separately tracked. Do not pretend this smaller milestone completes full V1.

The earlier instruction not to change any existing Backplane proxy path is superseded **only for the narrowly scoped integration below**. It is not permission for a wholesale proxy rewrite.

### 0.2 Two mandatory delivery gates

**Gate A — trustworthy foundation:** repair the validation, serialization, affinity, preflight, execution/wire contracts, dependencies, lab, and evidence issues described here.

**Gate B — Backplane first consumer:** at least one explicitly identified, existing proxy protocol/profile path uses shared package parsing/reduction in its normal application path; the resulting facts feed actual Backplane business output; real-endpoint integration tests prove this.

Passing Gate A alone is not completion. Neither a dependency declaration, a struct reference, an unused adapter, nor a successful lab build satisfies Gate B. A partial migration must name its exact scope, not claim the entire proxy migrated.

### 0.3 Read before editing

Read the checked-out `AGENTS.md` and applicable nested instructions, then:

- `docs/ai-protocol/design.md`, `prd.md`, and `implement_plan.md`.
- `docs/ai-protocol/evidence/`, especially the foundation report and acceptance ledger.
- Both protocol packages, the independent Protocol Lab, and the actual proxy call path.

Historical source candidates include `apps/backplane_llama/lib/backplane/llm/`, `apps/backplane_api/`, and `apps/relayixir/`. Confirm their current locations and callers rather than assuming an inventory is current. [S9]

The attached Synapsis daemon discussion is not a Backplane implementation assignment. Do not import its daemon topology, schedules, heartbeat, storage design, or tool execution into this package.

## 1. Change boundaries

| Area | Permitted work |
| --- | --- |
| `apps/backplane_ai_protocol/` | Targeted repairs; public protocol/framing/reducer functionality required by the selected consumer path |
| `apps/backplane_ai_protocol_testkit/` | Independently consumable test support; only the fixtures/fault helpers needed for this milestone |
| `examples/protocol_lab/` | A committed, executable independent consumer exercising real public APIs |
| Existing LLM application | Dependency declaration, a thin integration adapter, shared-result consumption, and scoped regression tests |
| Existing API application | Real-entry-point tests and narrowly necessary wiring; no alternate demonstration-only endpoint |
| Relayixir | Preserve transport; add a minimal observation seam only if inspection proves one is missing |
| Root build, lockfile, workflows | Necessary dependency/CI changes; maintain strict gates and production/test isolation |
| `docs/ai-protocol/` | Scope amendment, migration matrix, exact evidence, remaining limitations, rollback instructions |

Credential storage, authentication ownership, account authorization, routing policy, model selection, and durable logging remain host responsibilities. Do not move Ecto schemas, Phoenix endpoints, agent loops, MCP/skills, or tool execution into core.

Do not change Sigma, Synapsis, or Samgita in this assignment. Do not replace native Codex transport, import personal credential files, perform live login/generation, modify deployed configuration, or spend provider quota. Package/dependency downloads are distinct from provider traffic and must not weaken the default no-live-provider test boundary.

Do not commit, push, publish, merge, or deploy unless separately authorized. Local implementation and local test configuration are the intended work.

## 2. Review findings and required repairs

The findings are historical source observations, not claims of reproduced production incidents. Suggested fixes and acceptance tests are implementation requirements. Additional constructor checks in R02 are explicitly identified as regression audits, not separately reproduced findings.

### R01 — P1: Recursive validation does not enforce its advertised bounds

**Historical locations:** `validation.ex`, especially `strings/3`, `term/5`, and `bounded_map/2`. [S1]

The atom-key branch changes the internal accumulator from `{:ok, bytes}` to `:ok`. That can end the map traversal before its values are checked while the public result still looks successful. Scalar branches reset accumulated bytes to zero. `bounded_map/2` checks only the number of top-level entries.

**Implement:**

1. Use one internal success shape for recursive budget accounting. Preserve cumulative bytes across every scalar, collection, and map-key branch; only the public boundary converts success to `:ok`.
2. Check nested values, key types, maximum depth, collection sizes, string sizes, and aggregate budget at every applicable entry point. Include a total-node/work bound where string-byte accounting alone cannot bound traversal.
3. Define supported values explicitly. Reject functions, PIDs, references, unsupported tuples, and unapproved structs at portable boundaries. Tagged canonical values must have explicit validators, not fall through a generic acceptance clause.
4. Separate safe schema normalization from arbitrary atom creation. Use finite mappings for known fields/enums; never convert arbitrary external strings to atoms or load executable modules from payloads. `Code.ensure_loaded?/1` is not an atom-safety policy.
5. Apply an encoded-input byte cap before JSON decoding, then structural budgets before downstream processing. State what is bounded: post-decode checks alone do not prevent initial decoder allocation.
6. Distinguish logical validation budgets from actual UTF-8 wire-envelope bytes. Do not silently substitute a universal 1 MiB constructor cap for every transport limit, or loosen all limits to make one long input pass. Document the context-specific relationship.

**Required tests:** atom-keyed and string-keyed deep maps; mixed keys; one-entry oversized extensions; aggregate-over-limit payloads made of individually valid strings separated by numbers/booleans/null; exact limit boundaries; unsupported process terms; excessive node counts; valid canonical input. Validators used on untrusted input must return structured errors rather than crash on malformed nested shapes.

### R02 — P1: Generic serialization can bypass opaque/trusted-data isolation

**Historical location:** `serialization.ex`, `to_json/1` and `normalize/1`. Top-level opaque checks do not protect recursive structures because the general map branch precedes struct rejection. [S2]

**Implement:**

1. Handle struct identity before general maps at every recursive level. Reject unknown structs by default.
2. Reject `ExecutionContext`, opaque provider state, and opaque reasoning from generic serialization whether direct, nested in a map, or nested in a list. Do not leak `__struct__` or internal credential fields.
3. Use explicit, validated public projections for approved portable types. Necessary same-origin provider-state encoding belongs to an explicit protocol-specific path, not a permissive generic serializer. Preserve approved opaque bytes exactly.
4. Do not claim arbitrary maps are automatically secret-free. Host observability must select safe fields and redact sensitive data; converting a trusted struct to a map must not be used as a bypass.
5. Reject ambiguous atom/string field collisions during normalization rather than silently overwrite one value. Keep JSON encoder failures consistent with the public structured-error contract.
6. Decide and test the boundary between atom-keyed canonical constructors and string-keyed wire decoding. A valid known JSON enum can be safely mapped by a finite table; rejecting all valid JSON requests is not evidence of atom safety.

**Required tests:** nested denied structs at several depths, safe maps, supported public projections, duplicate normalized keys, invalid UTF-8/JSON handling, and a provider-state-specific positive preservation case. Keep generic rejection and explicit native-state support separate.

**Related constructor regression audit:** inspect composition and normalization while fixing these boundaries. The supplied diff warrants tests that explicit `ContentBlock.extensions` survive construction, validated tools/state references are stored in the agreed canonical form, and nested constructor-produced structs can be composed without accidental `__struct__` rejection. Also test missing/invalid required error enums rather than relying on `is_atom/1`, which includes `nil`. These are targeted audit checks, not permission to redesign every type or claim they were independently reproduced in the earlier review. [S10]

### R03 — P1: Provider-state affinity is reduced to protocol equality

**Historical location:** `translation.ex`, `check_provider_state/2`. It compares source/target protocol and scans only top-level provider-state input items. [S3]

**Implement:**

- Collect provider-bound state through every declared carrier: input items, content blocks, and `provider_state_references`.
- Validate the applicable profile/protocol/endpoint/account/workspace/model bindings against the host-resolved target. Define which dimensions each supported state kind requires; missing required target information is not a match.
- Reject contradictory source metadata and affinity. Public affinity is a compatibility constraint, not evidence of caller authorization or proof of payload authenticity.
- Preserve same-origin opaque values; never convert signed/encrypted state into display text to make a plan pass. A downgrade flag cannot bypass origin restrictions or host policy.
- Keep credential identifiers private. No new credential store or auth ownership is needed for this repair.

**Required tests:** identical protocol with different profile, account, endpoint, workspace, or bound model; missing required binding; conflicting source/affinity; all carrier locations; accepted fully compatible state; byte-exact preservation. Include positive cases so the repair cannot pass by rejecting all state.

### R04 — P1: Preflight can approve requirements it never examined

**Historical location:** `translation.ex` and `translation_plan.ex`. The planner checks a limited set of content categories, does not apply its policy argument, collapses missing capability to unsupported, and loses concrete downgrade-rule identity. [S3]

**Implement:**

1. Enumerate all requested semantics in the declared translation subset: roles/order, tools and results, settings, output constraints, state/reference requirements, and critical extensions. Reject unsupported or unverified required semantics before submission; do not ignore them.
2. Preserve `supported`, `unsupported`, and `unknown`. Strict execution cannot treat unknown required support as established. Any explicitly permitted unverified-budget behavior must be distinct, documented, and host-controlled.
3. Apply trusted host policy as well as caller downgrade permission. Caller permission cannot override a host denial. A host default must not silently invent caller consent to a lossy change.
4. Preserve exact rule ID and revision, affected field path, requested/effective values, and source/target identity. Use one documented capability representation rather than accidental compatibility between enum atoms and `Capability` structs.
5. An executable plan must contain a real supported mapping or defined executable operations. Do not return the original unsupported request with only a generic warning. Reserve or reject unimplemented rules.
6. Keep planning pure. A name such as `image_to_text` does not authorize an extra model request, implicit fetching, or an invented description. Opaque reasoning remains origin-bound.
7. Snapshot the relevant route/capability/rule identity without building a new catalog service. Keep subsequent host authorization checks effective.

**Required tests:** unsupported structured output despite supported text; unsupported role/tool-result semantics; explicit unsupported effort/settings; unknown required capability; host-denied downgrade; exact permitted rule retention; unimplemented/unknown rule; state restrictions; and accepted known-safe input. Test static refusal with an emission counter showing zero generation attempts in an appropriate execution test double. Do not claim real translation-route coverage until such a route exists.

### R05 — P1: Runtime dependency and independent-consumption evidence are incomplete

**Historical locations:** core `mix.exs`, `serialization.ex`, TestKit manifest, and the lab. Serialization calls Jason while the dependency is dev/test-only and optional. [S2][S4][S10]

**Implement:**

- Make the actually used JSON implementation a proper production dependency. Prefer the existing compatible Jason requirement over an unnecessary backend abstraction. Remove or explicitly justify hidden build-project-based backend selection.
- Prove both packages can be consumed outside the umbrella. TestKit's standalone artifact must not require an unshipped sibling via `in_umbrella: true`; provide and test a valid umbrella/standalone dependency arrangement.
- Do not declare every relative Mix path a defect without checking how dependency compilation handles it. Verify real artifact consumption and eliminate the assumptions the test exposes.
- Preserve one-way `TestKit → Protocol` dependency. Consumer test support must not enter production. Production core may have legitimate JSON dependencies but no implicit Backplane, database, Phoenix, or network startup.
- Supply package manifests/source notices sufficient for the actual shipped files. Do not copy source with unresolved provenance merely to accelerate extraction.

**Artifact gate:** build actual package payloads, record hashes, unpack/install them into fresh consumer projects outside the repository layout, and exercise public APIs. Do not substitute an in-repository path dependency. Run a production-mode consumer without explicitly adding Jason to mask a missing transitive dependency. Separately test the TestKit artifact in test scope and inspect a production consumer release/startup.

Once the host genuinely depends on core, its production release is expected to include core and legitimate runtime dependencies. The requirement is to exclude TestKit, ExUnit, and fake servers—not to keep the old release composition literally unchanged.

### R06 — P2: Execution can be claimed after it has finished

**Historical location:** `execution_gate.ex`. `claim/1` does not independently reject `finished: true`; `open → finish → claim` can succeed when no prior claim occurred. [S5]

**Implement:** terminal state must be absorbing for claiming/execution. Define cancellation-before-consumption, repeated cancellation, and repeated terminal transitions. Idempotent local cancellation must not emit another business terminal. Distinguish content completion, protocol completion, business terminal, and late audit observations.

Retain `completed`, `incomplete`, `failed`, `cancelled`, and `interrupted` meanings and explicit upstream certainty. Freeze how response completeness maps to wire completeness; do not accidentally alternate incompatible enum vocabularies.

An immutable reducer by itself cannot guarantee single use across copied states. Keep it pure, and test ownership through a serializing local owner/test double. The host integration must separately prove real request counts; do not add distributed locks or an agent runtime to solve this.

**Required tests:** every claim/finish ordering, cancel before claim, repeated cancel, completion/cancel race, interrupted outcome, late usage as audit only, and repeated consumption against one owned handle. Cleanup assertions must run before test-framework shutdown hides leaks.

### R07 — P2: Protocol Lab entry point and verification report disagree

**Historical locations:** lab `mix.exs` names `ProtocolLab.CLI`, but the reviewed tree contains only an empty `ProtocolLab` module. The report claims the escript build and execution passed. [S6][S7]

**Implement:** commit the actual CLI entry point and exercise meaningful public APIs: construct a valid portable request, run safe JSON encoding/decoding, and inspect a fixture-derived result without provider traffic. Do not implement an alternative parser inside the lab.

Inspect the unanchored `protocol_lab` ignore pattern shown in the diff: it must not hide a future `lib/protocol_lab/` source directory. Anchor the generated executable ignore appropriately and verify the CLI source is tracked and not ignored. Remove the accidental `inspect_content_block.beam` build artifact if still present; do not execute it. [S10]

Run from clean tracked source with clean build output. Update the evidence to the actual tested revision/state. A cached or untracked CLI is not valid delivery evidence.

### R08 — P2: Wire state does not yet support its claimed frozen contract

**Historical location:** `wire.ex`. The reviewed terminal lacks request correlation in its returned object; arbitrary IDs can accumulate credit; send size uses fixed defaults; capacity exhaustion returns success-shaped retirement without accepting the new ID. [S8]

**Implement the pure contract, not a full WebSocket stack:**

- Define a uniform versioned envelope with message identity, request correlation, per-request sequencing where applicable, and explicit payload/control/terminal classification. A documented outer envelope may supply correlation, but test the final encoded object.
- Make handshake/admission state explicit. Enforce non-empty bounded request IDs, distinct active-request and lifetime seen-ID limits, and negotiated limits.
- Reject or safely ignore credit for unknown/terminal requests according to a written rule without allocating unbounded new records. Validate finite non-negative integer credit/count values and release active credit state on termination.
- Measure data credit from the encoded UTF-8 data envelope at the producer boundary, not an untrusted claimed payload size. Honor negotiated limits instead of fixed defaults.
- At seen-ID capacity, return an explicit rejection/draining outcome with the necessary state. Do not silently evict IDs, report a nonaccepted request as accepted, or kill accepted requests without terminal/incompleteness handling.
- Define bounded control/terminal ordering when data is pending. No fake successful completion after dropping undelivered content; no generation replay on reconnect.

**Required tests:** invalid limit/credit types, pre-handshake admission, negotiated small limits, unknown-ID floods, request termination cleanup, concurrent versus lifetime bounds, capacity-edge rejection, draining accepted requests, terminal correlation, and duplicate/sequence errors. Mark transport/backpressure integration and the W1.6 backend spike unverified unless actually performed.

### R09 — P2: CI and acceptance evidence need current, attributable results

The previous review observed successful compile/format checks, failed Credo/Dialyzer/workflow-contract jobs, and a workflow-contract failure caused by the ordering of the two new matrix entries. Other failures were not all attributed to this PR. The prior runs are historical evidence, not current status. [S11]

**Implement:** restore the required matrix ordering and keep strict assertions. Inspect current Credo, Dialyzer, formatting, and test failures; fix introduced issues. Compare an isolated base checkout under the same toolchain before calling an unrelated failure pre-existing. Never disable a check or broaden ignores merely to get green.

Replace stale evidence with exact commands, exit codes, test counts, toolchain, source/tree identity, lock/artifact hashes, and fixture provenance. When testing uncommitted work, record HEAD plus a sanitized patch/tree fingerprint; the base SHA alone is not the identity of tested changes. Do not call skipped live tests passed, or count a partial protocol slice as a full T01–T28 pass.

## 3. R10 — P1 delivery requirement: integrate the existing Backplane LLM proxy

This is the user's new acceptance requirement, not a retroactive assertion that the original W1-only boundary was an implementation regression. The historical PR report explicitly excluded codecs, transport, and production route changes. That scope is no longer sufficient for this delivery. [S7]

### 3.1 Choose and identify the first complete path

Default first slice: the **existing ordinary OpenAI Responses native proxy path**, including non-streaming responses, SSE responses, usage, errors, and observation termination. Confirm its actual route, provider/profile classification, and current consumer chain before implementation.

If current source makes a different existing protocol path the appropriate first slice, record the reason and select an equivalently complete path. Do not introduce a demonstration-only endpoint or silently narrow the result to a unit test. Distinguish ordinary Responses from Codex-specific compatibility even if they share a URL or part of a router.

Name the supported profile/protocol path precisely. The real route must select shared parsing/reduction through ordinary application wiring for this supported slice, not only because a test-only switch enables it. An explicit operational rollback mechanism may exist; leaving shared use permanently disabled by default does not satisfy the normal-path requirement. Changing deployed production configuration is not authorized by this assignment.

### 3.2 Responsibilities and integration shape

| Component | Responsibility |
| --- | --- |
| Backplane host | Request admission/auth, route/model resolution, credential binding, local lifecycle ownership, persistent usage/log projection, operational policy |
| Existing Relayixir transport | Existing native HTTP/SSE forwarding and connection behavior |
| Shared protocol core | Reusable request recognition/decoding where needed, bounded framing, native response/event decoding, usage/error/stop interpretation, pure observation reduction |
| Thin host adapter | Pass protocol context and received bytes into public core APIs; map returned facts into host records/events |
| TestKit or isolated test support | Deterministic raw upstream responses, recorded request counts, faults, independent expected facts |

The data path should be:

**Real Backplane HTTP entry → existing admission/routing/credential binding → existing transport → native upstream/downstream forwarding**, with a bounded observation path from the same bytes into **shared framing/decoding/reduction → existing Backplane usage/error/log consumers**.

The observer must never submit a second generation. Keep public package contracts neutral; do not leak Plug connections, Ecto records, host process names, or Backplane schema formats into core.

### 3.3 Minimum shared functionality required now

Implement only the subset required by the selected native path, but implement it for real. This typically brings forward bounded SSE framing, a selected native codec/observer, canonical observation/lifecycle events, and usage/error reducers from W2, plus deterministic fixture support from W5.

Define the public observation seam before splitting work. Its lifecycle must include explicit initialization from host-supplied context/limits, feeding non-streaming bodies or incremental bytes, protocol/EOF/error finalization, and returning normalized facts/diagnostics. Reuse any already-correct public APIs instead of adding parallel abstractions. Avoid prescribing names until current source has been inspected.

The native observer need not reconstruct every vendor extension into a canonical request. Its request-side recognition may be deliberately partial. Document known, unsupported, and unknown observation fields; never mistake incomplete observation for request invalidity on a native-forwarding path.

The shared parser/reducer, not a duplicate in a host adapter, owns protocol-specific JSON event names, SSE framing, usage inclusion rules, and stop/error interpretation for the migrated path. A host `UsageAccumulator` process may remain as a thin owner, but must delegate the migrated protocol logic. Do not retain the old parser as the real source of facts while the new package merely emits unused diagnostics.

No complete standalone HTTP client, new OAuth coordinator, model catalog service, or WebSocket endpoint is necessary to prove native proxy reuse. Those workstreams remain separate.

### 3.4 Preserve native forwarding

Treat native forwarding and active translation as different modes:

**Native observation mode:** preserve the native payload and transport contract, including unknown provider extensions. Package observation can become partial/unknown without silently replacing or corrupting forwarded payloads. Do not force native bytes through a lossy generic IR encoder. Existing required host rewrites, credential stripping/injection, hop-by-hop header behavior, and mandatory security policies remain in force and must be captured in the baseline.

When comparing response payloads, compare reconstructed application-body bytes where raw preservation is promised. Do not assume TCP reads, transfer chunks, or compressed wire frames remain identical.

**Translation mode:** strict decode/plan/encode is required in both directions; unknown required semantics must not be passed through as if verified. A future translated route cannot forward the original upstream SSE unchanged after translating only the request. Do not advertise translation support without its own fixture matrix and real-route tests.

This milestone's mandatory Gate B may be satisfied by authoritative native observation for the selected path. Cross-protocol translation remains explicitly separate. Do not spend the milestone implementing all six translation pairs instead of shipping the required Backplane consumer.

### 3.5 Consume shared results as real business data

Feed package-derived usage, error classification, stop/completeness, and observation status into the existing host output that operators actually use. Reuse existing logging/usage schemas where practical. Any genuinely necessary persistence change must be narrow and justified.

For a migrated path, usage should have one authoritative interpretation. Old/new comparisons may replay the same captured bytes locally, but must not produce duplicate accounting or duplicate upstream requests. Preserve attempt identity, snapshot/delta semantics, unknown versus zero, and the provider's cache/reasoning inclusion rules. Do not fabricate currency cost or subscription quota from tokens.

Prefer decoding supported raw bytes to package facts to host records over wrapping an already-computed legacy usage total in a new struct. The latter does not prove shared protocol ownership.

### 3.6 Distinguish upstream outcomes from observation outcomes

A native upstream success with an unrecognized observation event is not automatically a failed user generation. Conversely, the observer must not invent complete usage or canonical success when parsing was incomplete.

Record observation completeness separately from transport status and business delivery. A parse failure or observer size limit must produce a bounded, sanitized diagnostic. Do not attach prompts, credentials, raw opaque state, or entire response bodies to errors/logs.

Keep observer buffers bounded at all handoff points. Avoid an unbounded mailbox or tee that retains the full stream. On observer overflow, stop/limit observation and record incompleteness while preserving forwarding unless existing mandatory host policy explicitly requires fail-closed behavior. A host-required audit policy must not be weakened by migration.

Content completion is not protocol termination. Finalize protocol observations using the selected codec's actual terminal rules and retain usage that arrives after content completion. Do not invent an extra protocol event after a provider terminal just to satisfy a generic fixture.

When the downstream disconnects, verify host/transport cleanup, terminate observation appropriately, and do not replay generation. Cancellation cannot assert the upstream performed no work or incurred no cost.

### 3.7 Demonstrate actual dependency on the shared implementation

Provide both:

1. Independent raw fixtures with expected host-observable values, exercising the real package implementation through the real endpoint.
2. An isolated proof that the intended shared public seam is invoked and its output is consumed. A scoped spy/test seam or isolated bypass check is acceptable if it does not replace the parser in the primary semantic tests.

A package-name telemetry label, a static import search, or a passing adapter mock alone is not sufficient. Tests should detect accidental reversion to the old parser on the selected route. Avoid process-global monkey patches that make concurrent tests unreliable.

### 3.8 Preserve non-target routes and compatibility

Inventory the baseline paths before changing shared host wiring. Preserve native Codex Responses, models/discovery, and compact behavior where already present, and preserve nonselected ordinary protocols. Do not equate generic Responses fixture success with Codex compatibility or live OAuth support.

Use existing deterministic host regression fixtures or add sanitized synthetic ones for the affected routing/header/native-forwarding seams. No live provider call is authorized. If a required compatibility check cannot run, report it explicitly and do not delete or replace that path.

Maintain a migration table with these columns:

| Protocol/profile path | Prior implementation | Shared modules now used | Host consumer of results | Native/translated | Normal-path enabled | Tests | Remaining legacy |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Selected ordinary path | Discover | Implement | Name actual usage/log/error consumer | Native | Required | Exact test paths | Explicit |
| Other ordinary paths | Discover | Unchanged unless explicitly migrated | Existing | Existing behavior | Record | Regression tests | Explicit |
| Codex/native special paths | Discover | Preserve | Existing | Native | Preserve | Dedicated regression evidence | Explicit |

This table is a template, not an assertion that migration has happened.

## 4. End-to-end acceptance suite

Use the real Backplane application endpoint, actual routing and credential-binding path, and an isolated local fake upstream over real sockets. Test accounts/credentials must be ephemeral synthetic values. A bypassed auth plug, direct adapter call, or fake Backplane server cannot alone satisfy this gate.

The IDs below are supplementary milestone tests; they do not replace or renumber T01–T28.

| ID | Required scenario and result |
| --- | --- |
| BP01 | **Real entry and single submission.** An HTTP request enters the actual selected route and reaches the fake upstream once. Capture applicable host rewrites and header binding; no unintended credential forwarding. |
| BP02 | **Non-streaming parity.** Valid native response payload is preserved as promised. Shared-derived output/usage/error facts appear in the real host consumer, including tools when supported by the selected fixture. |
| BP03 | **Streaming fidelity.** Split/coalesced SSE, UTF-8 boundaries, and relevant line endings yield correct facts without altering native application payload. Exact partition tests target the framer; socket tests do not assume packet boundaries. |
| BP04 | **Content versus protocol completion.** Protocol-valid usage/metadata after content completion is retained, and the locally observed lifecycle does not issue duplicate business terminals. |
| BP05 | **Tools and partial arguments.** Parallel calls keep their identities; truncated/invalid arguments never become executable completed calls. Core/host observation does not execute tools. |
| BP06 | **Refusal and output limits.** Preserve native body and protocol stop meaning; do not collapse refusal, incomplete output, and transport failure into one success/error flag. |
| BP07 | **Upstream failure.** Exercise non-success HTTP and protocol error bodies/events; preserve the native error contract and produce sanitized package-derived classification. |
| BP08 | **Observation failure.** Malformed/unknown observation semantics and truncation are explicitly incomplete/unknown. Native forwarding is not silently rewritten; no fabricated complete usage. |
| BP09 | **Downstream disconnect.** Client close interrupts delivery, triggers existing transport/observer cleanup, and causes no automatic new generation. Assert cleanup before test teardown. |
| BP10 | **Usage integrity.** Distinguish zero/unknown, repeated snapshots versus deltas, and cache/reasoning inclusion for the selected protocol. One attempt produces no duplicate durable accounting. |
| BP11 | **Bounded observer.** Oversized frames/state and slow observation cannot create unbounded queues. Assert configured byte/item limits and defined incomplete/fail-closed behavior without pretending transport buffers are automatically bounded. |
| BP12 | **Shared implementation is load-bearing.** The real package processes raw fixture data and its results reach host output. An independent scoped invocation/bypass assertion catches falling back to legacy parsing. |
| BP13 | **Non-target preservation.** The affected routing/native-header seams retain Codex/compact and other nonmigrated behavior according to pinned regression fixtures. Missing live evidence stays not run. |
| BP14 | **Release and routing reality.** Normal supported-route wiring chooses the shared path without a test-only toggle. Production composition includes core and required runtime dependencies but excludes TestKit/fake servers. |

Cross-protocol tests are not implicitly passed by this table. Pure preflight-negative cases belong to R04; real zero-submission translation-route tests are added only when a translated route is implemented and claimed.

The package/lab gate additionally requires clean production artifact consumption, actual CLI execution, portable schema tests, and TestKit test-only isolation. A real host can reveal business integration defects but cannot prove standalone packaging.

## 5. Execution order and ownership

Deliver in small dependency-complete work packages. These may become separate commits or PRs only when such writes are separately authorized. Do not stop at the first package and label the whole assignment complete.

| Package | Work | Dependencies and completion condition |
| --- | --- | --- |
| A0 — Baseline and integration map | Inspect current head, reproduce historical findings, identify actual host path/consumers, define exact first slice and public seam | First; produce evidence, not speculative paths |
| A1 — Validation and serialization | R01/R02; canonical composition regression tests | A0; core input/output invariants pass |
| A2 — Packaging, Lab, CI repair | R05/R07/R09; independent manifests and production smoke | Can start beside A1; final acceptance uses corrected public APIs |
| A3 — Affinity and preflight | R03/R04; coherent policy and mapping diagnostics | Agreed A1 data contracts; one owner for `translation.ex` |
| A4 — Execution and wire invariants | R06/R08; absorbing terminals, explicit state/admission contracts | Agreed core contracts; no full WS service required |
| B1 — Shared native protocol slice | Real bounded framing, selected codec/observer, usage/error reducers, independent fixtures | A1 and relevant A3/A4 contracts; sufficient behavior for selected host path |
| B2 — Existing proxy consumer | Thin host adapter, normal-route wiring, actual shared-result consumption, legacy parser bypass for selected slice | B1 and A2 dependency readiness; do not replace Relayixir |
| C — Integrated acceptance and handoff | BP01–BP14, artifacts/lab, affected host regressions, current CI, migration table and rollback | All preceding relevant work; evidence supports both gates |

The coordinator owns shared type/schema changes and the integration boundary. Packaging/CI work can proceed independently; affinity/preflight should not be split between agents concurrently editing the same planner. An independent test author can prepare raw fixtures and expected results while implementation proceeds; expected outputs must not be generated by the codec under test.

Full TestKit support is not a prerequisite for the first fake upstream. Use minimal isolated host-local test support where necessary, then share only useful stable helpers. Core's own tests must not acquire a reverse TestKit dependency.

### Checkpoint rules

At each checkpoint report completed fixes, exact tests/results, changed paths, and unresolved prerequisites. Continue with the next dependency-ready package. An unavailable live credential is not a blocker for deterministic local work, and absence of optional future W3/W4 features is not a reason to skip B2.

If a genuine environment or source blocker prevents a required gate, finish independent work and report the precise failing command/prerequisite and unfinished scope. Do not substitute a stub or a smaller test while claiming the original gate passed.

## 6. Verification and evidence requirements

Discover current project-supported commands first. The following are required categories and candidate commands inherited from the reviewed workflow, not claims they already pass:

| Check | Required execution/evidence |
| --- | --- |
| Formatting | Root formatting plus explicit coverage of changed child/example files; `mix format --check-formatted` where applicable |
| Compilation | Clean scoped package builds and affected host compilation with warnings treated as errors |
| Core tests | Focused regression tests for every repaired finding, boundary/property cases, and an additional seed where useful |
| Host integration | Real local endpoint/upstream BP suite; actual outbound-count and cleanup assertions |
| Workflow contract | Repository-supported contract command, historically `mix run --no-start test/ci_workflow_test.exs` |
| Static analysis | Current `mix credo --strict` and applicable Dialyzer gate; diagnose, do not blanket-ignore |
| Protocol Lab | Clean dependencies/build, `mix compile --warnings-as-errors`, `mix escript.build`, and actual escript invocation exercising core APIs |
| Artifact consumers | Actual built core/TestKit payloads, fresh external consumer directories, runtime API calls, production dependency/release/startup inspection |
| Regression baseline | Same toolchain/config against isolated base for unrelated failures; compare scope and result rather than reuse old totals |

Record commands with working directory, relevant nonsecret environment, exit code, toolchain, source/tree identity, lockfile hash, fixture identity, and result. Capture sanitized logs without credentials, prompt bodies, or opaque state. Keep exact failures and not-run checks visible.

Run tests against tracked source without relying on stale `_build` content or untracked CLI files. Avoid destructive cleaning in the user's working tree; use disposable copies/worktrees for clean-checkout/artifact verification.

Required documents to update:

| Document | Required update |
| --- | --- |
| `design.md` | Backplane-first native consumer sequence, authoritative observation boundary, host/core responsibilities |
| `prd.md` | Mandatory actual Backplane consumer acceptance, independent from standalone lab/package acceptance |
| `implement_plan.md` | Bring forward selected W7.1 with the necessary W2/W5 subset; leave remaining work tracked |
| `evidence/acceptance_matrix.md` | Exact scoped T coverage and BP evidence; distinguish implemented, passed, failed, blocked, and not run |
| `evidence/w1_1_report.md` or its clearly superseding report | Correct source identity, package/Lab evidence, current failures, and honest phase status |
| A proposed `evidence/pr32_remediation_report.md` | Findings disposition, changed paths, actual integration call graph, migration matrix, commands/results, and rollback |

Retain the original T01–T28 obligations and published work-package IDs. Add a **Backplane first-consumer checkpoint** instead of renumbering away unfinished work. G0/foundation completion does not mean this broader delivery is complete; Gate B is additionally required. A partial native codec is not full bidirectional codec/translation acceptance, and unperformed W1.6 transport spike work remains visible.

## 7. Rollout and rollback

Scope adoption by verified protocol/profile, not a global switch that changes all providers. For the selected supported path, ship the normal integration and document an explicit rollback that changes observation implementation for subsequent requests only. Do not replay an uncertain in-flight generation through a legacy path.

Keep original transport and credential ownership. On observer-only failure, mark monitoring incomplete rather than issue another request or silently calculate authoritative usage through an untracked second implementation. Any optional old/new comparison uses one captured stream and cannot double-write accounting.

Do not delete all legacy modules. Retain those needed by nonmigrated paths and remove only confirmed unreachable duplicates for a completed slice. Document remaining callers. Production deployment/configuration changes require separate authorization.

## 8. Definition of done and final response from Codex

The delivery is complete only when **both foundation repairs and the real Backplane consumer are verified**. A correctly scoped partial PR can be reported as partial, but cannot satisfy the whole assignment.

The final report must contain:

1. **Revision and finding disposition:** actual source/tree identity; R01–R10 status; for already-fixed findings, the verifying test; for unresolved findings, the exact blocker.
2. **Actual integration:** selected route/profile, host-to-public-package call graph, shared modules handling raw bytes, business consumers of normalized results, normal-route selection, and remaining legacy scope.
3. **Evidence:** commands/exit codes, core regression results, BP01–BP14 status, artifact hashes and clean-consumer results, actual lab output, affected host regressions, and CI failure attribution.
4. **Boundaries:** no duplicate upstream calls, no new credential owner/agent runtime, no silent native-payload reconstruction, and explicit unverified live/provider/WS/translation capabilities.
5. **Reviewable changes:** files changed, design/PRD/plan amendments, rollback for new requests, and any genuinely remaining work.

Do not say “Backplane uses the package” merely because compilation links it. Show which real request path uses it, which facts it computes, where those facts become business output, and which tests would fail if shared use were removed.

## Source register

These references identify the materials used for this handoff. Pinned repository links are historical sources; they are not evidence of a new fetch or test run during document preparation. The most recent user instruction controls the Backplane-first delivery change; earlier documents remain authoritative for boundaries not explicitly changed here.

- **S0:** PR metadata and scope from the earlier connected GitHub read; reviewed head `9bfa152…`, base `bd5bc830…`.
- **S1–S8:** Pinned code and foundation report read during the earlier review, linked below.
- **S9:** The PR's source inventory and design/implementation documents, used as historical path and responsibility candidates.
- **S10:** The complete PR diff supplied in the earlier review, including constructors, TestKit manifest, lab ignore pattern, and accidental BEAM artifact.
- **S11:** Prior CI job records: run `34550951550` and Test run `34550951562`; workflow-contract job `103113548943`. Their current status was not rechecked for this handoff. Prior review did not attribute every other failing job.
- **Design note:** Agent Note `67dda4ce-869c-4746-811a-016f23b5ebc4`, revision 1, “Backplane AI Protocol — 统一 API、双向翻译、Auth/Models 与 TestKit 设计（Proposed）”, reread for this handoff. Its proposed sequence is amended only as stated in section 0.1.
- **User decisions:** Backplane must itself consume the package as an actual-project validation; foundational repairs and actual proxy integration are both in this delivery. The preceding discussion accepted a scoped native path first, with full translation tracked separately.

[S0]: https://github.com/gsmlg-opt/backplane/pull/32
[S1]: https://github.com/gsmlg-opt/backplane/blob/9bfa152da0971e029173876134cc3761eef3f298/apps/backplane_ai_protocol/lib/backplane/ai_protocol/validation.ex
[S2]: https://github.com/gsmlg-opt/backplane/blob/9bfa152da0971e029173876134cc3761eef3f298/apps/backplane_ai_protocol/lib/backplane/ai_protocol/serialization.ex
[S3]: https://github.com/gsmlg-opt/backplane/blob/9bfa152da0971e029173876134cc3761eef3f298/apps/backplane_ai_protocol/lib/backplane/ai_protocol/translation.ex
[S4]: https://github.com/gsmlg-opt/backplane/blob/9bfa152da0971e029173876134cc3761eef3f298/apps/backplane_ai_protocol/mix.exs
[S5]: https://github.com/gsmlg-opt/backplane/blob/9bfa152da0971e029173876134cc3761eef3f298/apps/backplane_ai_protocol/lib/backplane/ai_protocol/execution_gate.ex
[S6]: https://github.com/gsmlg-opt/backplane/tree/9bfa152da0971e029173876134cc3761eef3f298/examples/protocol_lab
[S7]: https://github.com/gsmlg-opt/backplane/blob/9bfa152da0971e029173876134cc3761eef3f298/docs/ai-protocol/evidence/w1_1_report.md
[S8]: https://github.com/gsmlg-opt/backplane/blob/9bfa152da0971e029173876134cc3761eef3f298/apps/backplane_ai_protocol/lib/backplane/ai_protocol/wire.ex
[S9]: https://github.com/gsmlg-opt/backplane/tree/9bfa152da0971e029173876134cc3761eef3f298/docs/ai-protocol
[S10]: https://github.com/gsmlg-opt/backplane/commit/9bfa152da0971e029173876134cc3761eef3f298
[S11]: https://github.com/gsmlg-opt/backplane/actions/runs/34550951550
