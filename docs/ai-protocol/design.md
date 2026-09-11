# Backplane AI Protocol — Design

| Field | Value |
| --- | --- |
| Status | Proposed; implementation has not been verified |
| Document revision | 0.2 — English implementation handoff |
| Date | 2026-09-10 |
| Owning repository | `gsmlg-opt/backplane` |
| Intended repository path | `docs/ai-protocol/design.md` |
| Production package | `backplane_ai_protocol` |
| Module namespace | `Backplane.AiProtocol` |
| Test-support package | `backplane_ai_protocol_testkit` |
| Companion documents | [Product requirements](prd.md) · [Implementation plan](implement_plan.md) |

## 0. Decision, provenance, and evidence boundary

Build an independently consumable AI protocol library **inside the Backplane repository**. Use `sigma_ai` as an extraction starting point, not as an API that must be copied unchanged. The library serves both inference clients and an API gateway. It is not a new agent runtime and does not require a running Backplane service.

The delivery consists of a canonical request/response/event model, bidirectional codecs, explicit translation planning, an HTTP/SSE client, a Backplane WebSocket contract and client, provider authentication mechanisms, model capability resolution, and reusable testing support.

Start with source inventory, isolated package foundations, and executable contracts. Do not begin by replacing Backplane's production LLM proxy. Sigma is the first real consumer; Backplane WebSocket integration may proceed in parallel after the contracts are frozen.

### 0.1 Basis of this revision

This document translates and organizes the supplied `backplane-ai-protocol-design.md` revision 0.1 and the subsequent decision to start library construction in Backplane. Risk IDs `R01–R14`, acceptance IDs `T01–T28`, and work-package IDs `W0–W8` are preserved. The PRD and implementation plan turn those decisions into requirements and bounded work items; they do not claim additional upstream compatibility.

The supplied design has SHA-256 `a7f9cf876c7bac157e0904eb59cdf8b4c6dda54c11c54eec55e1dd5d7ad9fa40`.

No repository checkout, compile, test execution, or new external-source verification was performed for this document conversion. Repository observations in the source document are historical inputs. W0 must obtain fresh, immutable source revisions and reproduce the relevant baseline. Reference links below are inherited reading material, not evidence of a fresh verification pass.

The attachment `Repo Analysis Request.txt` supplies the existing Synapsis execution boundary: QueryLoop, tools, daemon work, heartbeat, reflection, and scheduling remain in Synapsis. Its single-daemon proposal is not made a requirement of this shared library, and this project must not change Synapsis's agent topology. [A1]

### 0.2 Confirmed objectives

| ID | Objective |
| --- | --- |
| U1 | Maintain an independent shared library in Backplane, starting from `sigma_ai`, to remove duplicated protocol work. |
| U2 | Let Backplane parse, observe, forward, and translate OpenAI and Anthropic requests and responses. |
| U3 | Let Sigma and Synapsis use the same API for direct provider access and access through Backplane WebSocket. |
| U4 | Share authentication mechanisms, including a separately validated Codex OAuth integration, and model context/effort metadata. |
| U5 | Provide reusable test infrastructure and prove independent consumer use, not only internal unit-test success. |
| U6 | Leave Samgita integration for a future project. |

### 0.3 How to read the specification

“MUST” and “MUST NOT” describe project requirements. They do not claim that upstream providers already offer equivalent guarantees. Protocol support is always limited by a published compatibility matrix and fixture evidence.

This design owns architectural and lifecycle semantics. The PRD owns scope and acceptance obligations. The implementation plan owns sequencing, change boundaries, and evidence delivery. Any conflict between them must be resolved in a contract review before dependent implementation; an implementer must not silently choose the easiest interpretation.

## 1. Review findings and design decisions

These are design risks, not reproduced defects in the latest repository revision.

| ID | Priority | Risk | Required response |
| --- | --- | --- | --- |
| R01 | P0 | The canonical API becomes OpenAI-shaped data with renamed fields. | Preserve ordered items, content blocks, roles, tool relationships, and provider-bound state. |
| R02 | P0 | Parsing is mistaken for lossless translation; constraints or state disappear. | Preflight with `TranslationPlan`, field diagnostics, strict defaults, and named downgrade rules. |
| R03 | P0 | Content completion, stream termination, cancellation, and billing certainty are conflated. | Separate content lifecycle, local terminal state, late observations, and upstream-outcome certainty. |
| R04 | P0 | Credential CAS prevents stale writes but not simultaneous remote refresh-token consumption. | Single refresh owner plus atomic commit; uncertain refresh outcomes must not trigger blind replay. |
| R05 | P0 | Codex subscription auth or App Server is treated as the public OpenAI API. | Dedicated profile and compatibility gate; preserve native Codex routes and avoid hidden agent execution. |
| R06 | P0 | WebSocket has envelopes but no bounded flow control or disconnect semantics. | Version negotiation, per-request credit, correlation, one local terminal, and no generation replay in V1. |
| R07 | P0 | Shared model metadata leaks across accounts or overstates effective capabilities. | Scoped availability, provenance, tri-state capabilities, immutable execution snapshots, server validation. |
| R08 | P1 | Usage is added incorrectly and the first network chunk is labeled the first token. | Define cumulative/delta semantics, inclusion relationships, completeness, and observation boundaries. |
| R09 | P1 | Monitoring duplicates complete payloads or creates unbounded queues. | Bounded native observation, incomplete-monitoring diagnostics, no fabricated usage. |
| R10 | P1 | The package depends on umbrella configuration, global names, or ambient credentials. | Explicit dependencies and context; independent package installation and startup tests. |
| R11 | P1 | TestKit introduces a dependency cycle or self-validating codec tests. | One-way dependency; independent golden fixtures and real socket/integration tests. |
| R12 | P1 | A big-bang replacement breaks existing providers or persisted conversations. | Pinned baselines, thin compatibility adapters, route-specific rollout, legacy preservation. |
| R13 | P1 | Package, wire, fixture, metadata, and provider compatibility versions are conflated. | Version them separately and publish supported combinations. |
| R14 | P1 | Remote input selects arbitrary endpoints, credentials, or executable modules. | Keep trusted execution context outside portable requests; validate and bind it in the host. |

Resolve R01–R07 before expanding provider breadth.

## 2. Scope and non-goals

### 2.1 V1 scope

V1 covers generation requests, non-streaming responses, and streaming responses for three distinct codecs: `openai_chat`, `openai_responses`, and `anthropic_messages`. OpenAI Chat Completions and Responses are not interchangeable codec names.

The common translation subset includes text, directly representable image input, client-side function calls and results, usage, structured errors, and stop reasons. Structured-output constraints are supported only where the schema subset has explicit evidence. Native extensions retain their origin and may only travel on compatible paths.

V1 also includes direct HTTP/SSE and Backplane WebSocket access, API-key/bearer authentication, OAuth lifecycle and storage contracts, a concrete Codex compatibility workstream, model discovery and effective capabilities, bounded execution, telemetry, TestKit, and an independent CLI consumer.

Codex OAuth cannot be marked implemented by defining an empty behaviour. Generic API-key functionality may ship as a clearly scoped preview before Codex validation finishes; it is not the complete V1 milestone.

### 2.2 Responsibilities excluded from the library

Agent loops, subagents, inter-agent messaging, tool execution, MCP execution, skill selection, context-compression decisions, task scheduling, conversation databases, account-management UI, billing ledgers, and global route-selection policy remain in host applications.

Embeddings, image generation, TTS/ASR, realtime audio, comprehensive Files/Batch/Assistants compatibility, cross-provider remote-session migration, durable WebSocket event replay, generation resume, and distributed exactly-once execution are outside V1.

Existing native Backplane routes outside the canonical subset MUST remain available where already supported. An unmodeled feature is not permission to delete a working proxy route.

## 3. Packages and application boundaries

### 3.1 Delivery layout

| Location | Responsibility |
| --- | --- |
| `apps/backplane_ai_protocol` | Production library: canonical types, pure codecs/reducers, client, auth mechanisms, model contracts. |
| `apps/backplane_ai_protocol_testkit` | Separately consumable test helpers, fixtures, fake servers, fault injection, conformance suites. |
| `examples/protocol_lab` | Independent Mix CLI exercising only public APIs. |
| Backplane API application | Actual HTTP/WS endpoints, connection admission, authentication, host integration. |
| Backplane LLM application | Routing, credential storage, existing native proxy transport, account policy, persistent observations. |
| Sigma / Synapsis | Thin application-to-protocol mapping; existing agent and session responsibilities. |

The intended documentation directory is `docs/ai-protocol/`, containing these three documents and implementation evidence. Existing application paths must be confirmed during W0, not inferred solely from historical names.

### 3.2 Production library layers

| Layer | Suggested modules | Constraint |
| --- | --- | --- |
| Canonical contracts | `Request`, `Response`, `Message`, `Content`, `ToolCall`, `ToolResult`, `ProviderState`, `Event`, `Error` | Validated data; no secrets, functions, PIDs, or process references on the wire. |
| Functional core | `Codec`, `Framing.SSE`, `Reducer`, `Translation`, `RequestValidator` | Explicit state in, new state/data/diagnostics out; no network, database, or ambient configuration. |
| Connection/capability description | `ProviderProfile`, `ModelDescriptor`, `ModelCatalog`, `Capabilities` | Compose mechanisms without granting application authorization. |
| Effectful components | `Client`, `Transport`, `Connection`, `Auth.Flow`, `Auth.RefreshCoordinator` | Host-supervised, replaceable clock/store/transport, explicit ownership. |
| WebSocket contract | `Wire.V1`, `Wire.Validator`, `ConnectionState` | Standard WebSocket JSON; not the Phoenix Channels wire format. |

Req is the initial HTTP implementation direction inherited from the source design. JSON and telemetry dependencies should remain small. Exact versions must be fixed against W0 evidence. Select one default WS backend after a transport spike covering cancellation, proxies, TLS, bounded buffering, and ownership; do not ship two competing defaults.

The production library MUST NOT depend on Backplane Ecto schemas, Phoenix endpoints, an agent application, or hard-coded host supervisor names. Multiple independently configured clients must coexist. Pure-codec initialization performs no network activity. Authentication flows, model discovery, and connection pools start only through explicit calls or host child specifications.

### 3.3 TestKit and packaging

Dependency direction is `TestKit -> Protocol`. Protocol's own unit tests do not depend on TestKit. Full shared conformance suites run in TestKit or a consumer, avoiding a test dependency cycle.

Consumer applications use TestKit only for tests. Inspect production release manifests and process trees; an umbrella test dependency declaration alone is insufficient evidence of production isolation. Standalone consumers must not require the Backplane root configuration, a sibling application, or an unshipped fixture. [S11]

## 4. Distinct identities and connection concepts

| Concept | Meaning |
| --- | --- |
| Wire protocol | External serialization and semantics: Chat Completions, Responses, Messages, Backplane V1. |
| Provider profile | Auth, endpoint conventions, model discovery, and compatibility rules: `OpenAIPlatform`, `OpenAICodex`, `Anthropic`, `OpenAICompatible`, `Backplane`. |
| Endpoint / deployment | A particular service instance with deployment-specific limits. |
| Credential binding | A trusted host binding to account/workspace, grant revision, and auth generation. |
| Model identity | Provider model ID and optional snapshot; capability is not inferred from a name substring. |
| Public model selector | A Backplane-visible ID or alias that the host resolves. |
| Transport | HTTP/SSE or Backplane WebSocket; transport does not define model semantics. |

An OpenAI-compatible deployment needs explicit endpoint and capability declarations. It does not inherit the whole OpenAI product surface. A host may register trusted local profile modules; remote metadata cannot select or load executable modules.

## 5. Canonical data model

### 5.1 Request versus ExecutionContext

`Request` expresses portable caller intent: public model selector, ordered input items, tool definitions, generation settings, output constraints, provider-state references, named permitted downgrades, and bounded non-sensitive correlation metadata.

`ExecutionContext` is trusted host data: principal, permissions, resolved endpoint, credential binding, transport configuration, deadlines, route policy, capability revision, resource limits, and logging policy. A WebSocket payload cannot create or override it.

Reject unknown critical fields. Permit non-critical extensions only inside namespaced, bounded containers. JSON string keys cannot be converted into unbounded new Elixir atoms.

### 5.2 Ordered items, roles, and tools

Input includes typed messages, tool results, and provider-state items. Messages preserve role and block order. Output can contain text, image-related data supported by the path, reasoning content, function calls, refusals, and state items.

Do not flatten system, developer, user, and assistant roles into one text prompt. A target that cannot express a role requires an explicit translation decision.

Every tool call carries a stable canonical call ID, native-ID mapping, tool name, raw argument representation, and separately validated arguments. Parallel argument deltas correlate by item/call ID, never by “the most recent tool call.” Tool results preserve call linkage and success/error semantics. JSON-schema validation is not authorization to execute a tool.

The library describes, validates, and transports calls. It never executes a tool or starts a subsequent agent turn.

### 5.3 Provider-bound state

`ProviderState` records source profile/protocol, state kind, opaque payload/reference, affinity to endpoint/account scope, and known usability constraints. It is not ordinary display text or portable agent memory.

The supplied design references encrypted OpenAI reasoning state and Anthropic thinking signatures as examples of state that must be preserved rather than renamed across providers. [S5][S7] Preserve opaque bytes for allowed same-origin use. Cross-origin state use is rejected by default. A model, account, endpoint, or profile change requires affinity validation; do not silently turn state into lossy text.

Only host-approved state is persisted. Secrets and opaque reasoning are excluded from default logs and telemetry. A public state representation must not expose internal credential identifiers; exact public affinity encoding is a W1 contract-freeze item, not an invitation to serialize `ExecutionContext`.

### 5.4 Response, usage, and errors

`Response` preserves ordered output, stop reason, usage, warnings, resolved-model identity, and completeness. Normal completion, tool use, output limits, refusal, safety restrictions, and unknown native stop values remain distinguishable. An output-token limit is not automatically a transport failure.

`Error` includes kind, stage, optional HTTP status, provider code, sanitized message, retry hint, retry-after, request/attempt identity, `upstream_outcome`, partial-output state, and compatibility diagnostics.

`retry_hint` describes potential transience, not permission to replay. Classify structured failures before producing user-facing messages; do not parse explanatory prose to recover the error category.

## 6. Public API and execution ownership

Names are proposed public seams. W1 may settle arities without changing their semantics.

| Operation | Contract |
| --- | --- |
| `Translation.plan` | Pure preflight over request, source/target capability snapshots, and policy. Returns an executable plan or structured refusal. |
| `Client.open` | Validates locally and creates one execution handle, or fails before submission. |
| `Client.events` | Gives a single consumer events for that handle; a second consumption fails rather than submitting again. |
| `Client.complete` | Executes once and returns a full `Response`, including tools, usage, diagnostics, and completeness. |
| `Client.cancel` | Idempotently requests cancellation; acknowledgment is local acceptance, not proof of zero upstream execution/cost. |
| `ModelCatalog.refresh` | Explicitly performs scoped model discovery and returns a revisioned result. |
| `Capabilities.resolve` | Purely computes effective capabilities from metadata, path, and host constraints. |
| `Auth.begin / advance / cancel` | Drives an explicit auth flow with presentation and persistence supplied by the host. |

One handle represents one logical execution. Re-enumerating an Enumerable cannot trigger another paid request. A new intentional generation requires a new handle/request. Keep execution ownership in the effectful shell, not in a lazily re-executable encoder.

`complete` may use native non-streaming responses or aggregate a stream. Record actual wire mode. A buffered response delivered as one item is not a real token stream and does not have an observed first-token latency.

## 7. Bidirectional codecs and translation planning

### 7.1 Codec responsibilities

Each protocol codec implements request decode/encode, non-streaming response decode/encode, incremental stream decode/encode, native error mapping, and stop/usage interpretation. Decoder state must be explicit so the same parser works in clients, native-proxy observation, and tests.

There are two gateway modes:

| Mode | Behavior |
| --- | --- |
| Native forwarding with observation | Preserve the existing native transport and payload; parse a bounded observation stream without mandatory canonical re-encoding. |
| Explicit translation | Decode to canonical intent/events, validate the declared mapping, and encode the target protocol in both directions. |

Translating only an inbound request while returning an unchanged upstream SSE stream is not a supported translation implementation.

### 7.2 TranslationPlan

The plan contains source protocol, target profile/model, capability revision, mapping-rule revision, field-level `supported / lossy / unsupported / unknown` judgments, approved downgrade IDs, tool-ID mappings, state-affinity constraints, and effective upstream/downstream options.

Reject statically detectable incompatibilities before any generation submission. Report field paths, requested values, target constraints, and actionable diagnostics. Preflight is not proof that every future upstream event is representable; runtime translation must validate new semantics as they arrive.

Strict mode is the default. Downgrade permission is an allowlist of concrete rule IDs, not a global “best effort” flag. Every applied downgrade is present in response/event diagnostics and host audit observations.

### 7.3 V1 compatibility matrix

| Feature | Native path | Cross-protocol common path |
| --- | --- | --- |
| Text | Preserve supported native semantics; native proxy may forward unmodeled fields. | Required, provided roles and ordering are representable. |
| One output candidate | Preserve the native path's supported capacity. | Single candidate only; never silently take the first of `n > 1`. |
| Client function calls/results | Preserve known native semantics. | Required; validate schema subset, tool choice, and call/result mapping. |
| Image input | Preserve native interface support. | Only directly representable sources and MIME types; no implicit fetch, upload, or rehosting. |
| Structured output | Declared native subset. | Only independently tested schema/constraint mappings. |
| Thinking / effort | Native profile capability. | Only explicit validated mappings; equal names do not imply equal meaning. |
| Provider-hosted tools, remote state, signed/encrypted reasoning | Allowed same-source path. | Cross-provider transfer unsupported by default. |
| Logprobs, complex audio/video, multiple candidates, vendor controls | Existing native routes may retain them. | Outside the V1 common subset; reject explicitly. |
| Storage/retention requirements | Native semantics plus host policy. | Reject when equivalent handling cannot be guaranteed. |

Test every directed pair among the three codecs for its declared subset. Advertising that subset does not mean complete API compatibility.

### 7.4 Failures after output begins

Before downstream HTTP headers/body are committed, return the appropriate native error. After output begins, do not pretend an emitted HTTP 200 can be replaced. Use a target-protocol error event where supported; otherwise terminate the stream as incomplete. Never fabricate a successful terminator.

For native observation, an unknown event may leave forwarding unchanged while marking monitoring incomplete. Authentication, network-safety controls, and host authorization cannot be bypassed in the name of transparency.

## 8. Incremental framing, reduction, and lifecycle

### 8.1 Byte framing is separate from provider semantics

The SSE framer incrementally handles UTF-8 boundaries, LF/CRLF/CR line endings, optional field spaces, comments, event/id fields, multi-line data, coalesced events, and EOF. Decode JSON only after a complete frame is assembled. Bound frame bytes, decoder-buffer bytes, nesting depth, and tool-argument bytes. The inherited framing reference is WHATWG SSE. [S10]

A TCP chunk, SSE frame, model token, and UI delta are distinct units. Chunk count is not token count. Known keepalives may be ignored; non-critical extensions may produce diagnostics. Unknown content/state semantics fail translation but mark native observation incomplete. Malformed JSON is not a ping.

### 8.2 Canonical lifecycle

The event family includes `request.accepted`, `attempt.started`, `response.started`, `output_item.started`, `content.delta`, `tool_call.arguments.delta`, `output_item.finished`, `usage.updated`, `diagnostic`, and `request.finished`.

`request.finished` is the only business terminal event. Its status is one of:

| Status | Meaning |
| --- | --- |
| `completed` | The protocol completed and the requested result is complete according to its stop semantics. |
| `incomplete` | Output exists but an explicit limit or other completion condition leaves it incomplete. |
| `failed` | Validation, execution, decoding, or translation failed. |
| `cancelled` | Local cancellation ended business delivery; upstream certainty is reported separately. |
| `interrupted` | Connectivity/ownership loss prevents a reliable continuation or final result. |

W1 must freeze the exact status/stop-reason mapping, including refusal and output limits. Each surviving, observable local handle receives exactly one terminal. This is not an exactly-once network delivery promise, especially across process or connection failure.

Content completion is not protocol termination. Do not stop on a last text block or a finish-reason field when a protocol permits trailing usage. Each codec declares content-finished and protocol-finished conditions. The supplied design specifically notes cumulative usage, pings, errors, and extensible event types in Anthropic streams. [S5]

### 8.3 Cancellation and uncertain outcomes

Separate local acceptance of cancellation, successful transport cleanup/cancel transmission, and an upstream-confirmed stop. Use `upstream_outcome: not_submitted | known | unknown`, with cancellation-operation details and partial-output completeness.

Closing a connection or timing out is not proof that the upstream did no work or incurred no cost. After a local terminal, late usage or network facts may update a separate audit observation, not the completed business event stream. A late audit update is not another generation or a second terminal.

### 8.4 Ownership and bounded resources

Every execution has an owner and monitors. Consumer death triggers cleanup. Queues are bounded by both items and bytes. A slow consumer cannot grow a shared mailbox indefinitely or block all unrelated requests.

Streaming producers should not repeatedly retain the entire accumulated response. Full aggregation is optional and bounded at the requesting consumer. Complete-response bytes, individual frames, tool arguments, and opaque state each have separate limits and errors. Incomplete or invalid arguments cannot become an executable completed `ToolCall`.

A pull Enumerable is not sufficient evidence of network backpressure. The implementation must pause further transport reads where possible or cancel at a proven bound. Test socket delivery, asynchronous HTTP messages, producer mailboxes, shared WS queues, and consumer buffers end to end.

Cancellation/failure may discard not-yet-delivered data only while reporting incomplete output. It cannot skip content and then declare a complete success. Host agents retain tool-execution policy; the safe default is not to execute newly observed calls from an uncertain terminal result.

## 9. Backplane WebSocket V1

### 9.1 Protocol purpose

Proposed endpoint: `/ai/v1/ws`. Proposed subprotocol: `backplane.ai.v1`. These are new design targets, not existing route claims.

Use standard WebSocket JSON envelopes. Do not reuse Sigma's agent-control protocol or introduce session lifecycle, tool execution, or agent RPC here. Backplane V1 is not OpenAI's native Responses WebSocket protocol. [S8]

Native Elixir clients authenticate to Backplane during upgrade and use WSS in production. Upstream credentials never travel from client to gateway in the portable request. Browser authentication is not required for V1; any future browser mode needs a separate Origin/CSRF/short-lived-credential design. Long-lived tokens cannot be URL parameters.

### 9.2 Envelopes and operations

An envelope has wire major/minor, message type, message ID, optional request ID, per-request event sequence, and payload. It contains no process terms. Hello/welcome negotiates versions, limits, concurrency, extensions, and flow-control support before requests are accepted.

| Operation | Purpose |
| --- | --- |
| `request.create` | Submit canonical intent; the server revalidates authorization, model capabilities, and translation. |
| `request.cancel` | Cancel one request; acknowledgment means the command was accepted locally. |
| `request.credit` | Grant additional data-envelope byte credit to one request. |
| `models.list / models.get` | Paginated, principal-filtered effective-model queries. |
| `models.changed` | Notify a catalog revision change without pushing an unbounded catalog. |
| `error` | Command/connection failure, separate from an accepted generation's business terminal. |

Accepted requests receive identity and a bounded capability/route-snapshot summary. Events are ordered per request, not globally across requests. The schema-freeze work must define command responses, terminal/control classification, and forward-extension handling explicitly.

### 9.3 Flow control and initial limits

V1 uses per-request byte credit measured as the UTF-8 encoded data-envelope length. Credit is replenished when business data is consumed or a controlled buffer is explicitly released, not merely when a socket frame arrives.

Control traffic has a separate bounded reserve and rate limit. Cancel traffic must not be starved by data credit. Request event sequence follows enqueue order; enqueue is not evidence of delivery. If output cannot be retained, fail that request with explicit incompleteness rather than skip content and continue successfully.

The following are **initial test targets**, not measured capacity claims:

| Limit | Initial proposal |
| --- | --- |
| Inbound request JSON | 8 MiB |
| Individual data event | 64 KiB |
| Initial per-request credit | 256 KiB |
| Pending per-request outbound buffer | 512 KiB, also subject to the connection cap |
| Pending connection outbound buffer | 8 MiB |
| Concurrent requests per connection | 8, or a stricter host limit |
| Control reserve | 64 KiB, with additional rate limiting |

Negotiate and enforce limits consistently. Split text and argument deltas only where their semantics permit it. Do not duplicate the full response inside a terminal. Opaque state that cannot be split safely fails as `item_too_large`; do not truncate it. Large-image and long-context requests must pass explicit size tests; V1 does not introduce implicit remote-file uploads.

Credit stalls have a configurable deadline and structured backpressure error. Schedule eligible requests fairly, while acknowledging that a single TCP connection still has head-of-line blocking. W1/W4 must record the exact control/terminal ordering and partial-delivery rules before implementation; this document does not infer them from a WS library's defaults.

### 9.4 Disconnects and duplicate requests

V1 has no generation resume, durable event replay, or automatic `request.create` resubmission. Reconnection creates a transport for future requests only.

On disconnect, the client marks unresolved local executions interrupted; upstream outcome may be unknown. The gateway attempts cancellation. A creation acknowledgment is not durability or proof of upstream start; missing acknowledgment is not proof of non-submission.

Reject duplicate request IDs within one connection without executing again. Maintain a bounded seen-ID set; retire the connection gracefully when it reaches capacity rather than evict IDs while still promising duplicate prevention. No cross-connection/restart deduplication is promised. Persistent idempotency would require a future design for scope, fingerprints, retention, and storage.

## 10. HTTP, deadlines, retries, routing, and network policy

Support explicit connect, response-header, idle, and overall deadlines. Propagate remaining total budget to child operations. Use local monotonic clocks for durations; never compare monotonic timestamps across hosts.

Disable automatic transport retries for generation. Read-only model discovery may use bounded retries. Refreshing a credential is not permission to replay an already submitted generation. Safe replay depends on structured failure, submission certainty, upstream guarantees, exposed output, and host budget. Absence of output is not proof of non-submission.

Separate logical request IDs from real network attempt IDs. The gateway owns its upstream retry plan; the WS client does not replay generation independently. Do not multiply retries at multiple layers or switch providers invisibly after output has started.

Keep Backplane's existing native proxy transport; shared codecs do not require rewriting Relayixir using Req. Apply explicit proxy/TLS configuration consistently to auth, discovery, generation, and WS. Isolate connection pools according to endpoint, proxy, and any connection-bound authentication state.

Remote requests cannot choose `base_url`, proxy, token endpoint, upstream authorization headers, or credential references. Hosts resolve authorized profiles. Do not forward secrets to another origin after a redirect or blindly relay downstream auth headers to upstreams.

Codecs do not fetch image/file URLs. Future fetching belongs to a host resource service with destination, size, timeout, and redirect controls.

## 11. Authentication and credential lifecycle

### 11.1 Mechanism versus storage

Auth implements API-key/bearer encoding, OAuth state transitions, token exchange/refresh, expiry interpretation, and structured failures. Hosts implement login presentation, callback endpoints, encrypted persistence, account binding, authorization, and audit.

`CredentialStore` is an atomic storage contract, not a database bundled with the library. It supports reads, revision-checked updates, revocation/tombstones, and auth generation. Secrets are unwrapped only for the necessary operation and excluded from portable requests and public auth status.

Do not read `~/.codex/auth.json` by default or silently fall back to environment variables for an unspecified account. Default struct inspection, errors, telemetry, WS envelopes, and fixtures must not leak secrets.

### 11.2 OAuth flow controls

Use provider-supported authorization-code flows with transaction-specific state, PKCE S256, issuer/client/redirect binding, initiator binding, expiry, and one-time callback consumption. Device flow respects provider polling intervals, slowdown, expiry, and denial. Verify signature/issuer/audience/nonce when an ID token is used as an identity assertion; decoding arbitrary JWT contents is not authorization. [S9]

Reuse mature OAuth/OIDC primitives instead of inventing a full standards stack. Profiles implement necessary differences only. Do not assume every provider supports revocation, introspection, or both login flows.

### 11.3 Refresh ownership and uncertain token rotation

Single-flight merges refreshes inside its ownership scope. CAS prevents stale persistence but does not stop two independent owners from consuming the same remote refresh token.

Assign one refresh owner per grant. For one node, use a host-supervised coordinator. For multiple nodes, route the grant to an explicit refresh owner/service using host ownership/lease checks and atomic persistence. Do not hold long database transactions across remote calls.

Commit requires matching credential revision and auth generation. Logout or rebind advances generation; a late refresh cannot revive a revoked grant.

When the upstream rotates a token but its response is lost, neither CAS nor fencing can undo remote consumption. After owner failure or lease expiry, do not blindly reuse the previous refresh token. Enter `refresh_outcome_unknown`; continue only under a documented provider recovery guarantee, otherwise require reauthorization. No refresh exactly-once guarantee is made.

Choose host-managed or explicitly delegated credential ownership. Do not concurrently update a shared token file with an external Codex process.

### 11.4 Dedicated Codex profile

The inherited references distinguish ChatGPT sign-in from Platform API-key authentication, and describe App Server auth/model operations as their own interface. [S2][S3] These are compatibility boundaries, not permission to treat a subscription token as a Platform key or to replace inference with hidden App Server agent execution.

Preserve and validate Backplane's existing Codex auth, native routes, and discovery. W0 pins source commits, compatibility inputs, and fixtures. Never guess endpoint URLs, client IDs, account headers, or token formats from examples in this document.

Required evidence includes login/refresh, expired/revoked credentials, logout, account-header binding, live model discovery, native Responses, SSE, function calls, and the existing compact path. Undocumented differences remain isolated, versioned, and explicitly labeled. Retire legacy code only after the separate compatibility gate passes.

### 11.5 Backplane connection authentication

WS clients hold only Backplane credentials. The gateway owns upstream grants; downstream model/event responses do not reveal refresh tokens, internal credential IDs, or full upstream account details.

Authorize each request even on a previously authenticated connection. Host revocation and permission changes override frozen capability snapshots. V1 may close affected connections and require reauthentication instead of designing in-band long-lived token rotation.

## 12. Model metadata and effective capabilities

### 12.1 Three objects, not one global model list

| Object | Meaning |
| --- | --- |
| `ModelDescriptor` | Source model identity, limits, options, modalities, and native metadata. |
| `ModelAvailability` | Visibility and usability for a principal/account/workspace/endpoint, including operator disablement. |
| `ResolvedModel` | Effective immutable capability snapshot for a chosen route, profile, codec, deployment, account, and host policy. |

Discovery is not authorization. Model support is not automatically path support.

### 12.2 Metadata fields

Record provider/model/snapshot identity, public alias where appropriate, deployment identity, max input, max output, total context when defined, units and limit relationships, supported thinking modes, provider-native effort values, their scope/defaults, optional budgets and combination constraints, modalities, function tools, structured output, streaming, translation level, and state affinity.

Each field records source, observation time, metadata revision, staleness, and confidence. Discovery records pagination completeness, failures, missing fields, and conflicts.

Capabilities are `supported | unsupported | unknown`. Missing fields, schema-example zeros, and invalid negative limits cannot become invented capacities. The inherited references note differing schemas for OpenAI models, Codex `model/list`, and Anthropic models; implement separate discovery parsers. [S3][S4][S6]

### 12.3 Discovery, merging, and caches

Interpret discovered fields according to their source. Versioned metadata may fill unknown fields. Deployment settings express actual deployment limits; host policy can restrict them further. A generic override cannot turn confirmed unsupported into supported.

Use field-level conflict diagnostics, not a universal last-writer-wins merge. Preserve last-known-good data as stale on discovery failure. Incomplete pagination cannot disable models not yet seen. Discovery cannot re-enable operator-disabled models.

Scope cache keys by profile, endpoint/deployment, account/workspace, and API/compatibility version. Separate public description from account availability. TTL is not an authorization lifetime; revocation needs active invalidation. Revision/generation checks prevent late discovery from overwriting newer results or reviving revoked availability.

Unknown context size is not an invented 128K default. Where the caller does not require a verified budget and the host permits it, known basic generation may continue with `budget_validation: unknown`. Strict-budget requests and unverified explicitly requested capabilities/translation semantics fail before submission. The UI must not present these two outcomes as identical validated support.

### 12.4 Context, thinking, and effort

Keep input limit, output limit, and total-window constraints distinct. Only apply input-plus-reserved-output equations when the profile defines the relevant total and inclusion relationships. [S4]

A token counter is optional and returns `provider_count`, `local_estimate`, or `unknown`, plus tokenizer/model version. Remote counting is an explicit operation. Estimated counts do not become exact guarantees. Context compression remains agent policy.

Thinking mode, effort, and thinking budget are different fields. Preserve native effort strings, meaning, and applicability rather than inventing a cross-provider numeric ranking. The inherited Anthropic reference notes effects beyond thinking alone. [S7a]

Distinguish omitted values, explicit values, and host-injected defaults. Record requested/effective options. Unsupported effort fails unless a particular authorized downgrade rule applies.

### 12.5 Execution snapshots and aliases

Resolve capabilities and route revision at request admission and validate immediately before dispatch. Once an attempt starts, catalog refresh cannot change its model or parameter interpretation. An outdated client revision affecting validity causes a pre-submission conflict, not a silent effort change.

Security revocation remains effective despite a frozen snapshot. A multi-backend alias either advertises the common capability intersection or selects a backend satisfying the request's constraints and reports the actual selection. No model switch after public output; provider-bound state also constrains route selection.

## 13. Usage, observations, and telemetry

Usage contains input/output, cache read/write, reasoning, native total, source, snapshot/delta mode, and complete/partial/unknown status. Profiles define inclusion relationships: cache may already be in input, and reasoning may already be in output. Derive totals only when justified; never add every non-null field. Unknown is not zero.

Reduce by actual attempt. Client and gateway observations of one upstream call are two observations, not two charges. Multiple real attempts are separate. Do not infer hidden upstream attempts without evidence. Usage tokens, currency cost, and subscription quota are different; pricing and ledgers remain host responsibilities.

Record request start, headers, first body byte, first meaningful content, and finish, with client/gateway/upstream observation boundaries. A ping, role-only event, or control event is not meaningful content. Without token timestamps, label average output-token throughput and its denominator; do not claim exact instantaneous token speed.

Native observation is bounded and does not retain full chat payloads by default. Over-limit/unknown observations are explicitly incomplete; they cannot produce fabricated complete usage. Monitoring failure does not rewrite forwarded native data. If a host requires mandatory audit, its admission/failure policy must explicitly be fail-closed rather than silently creating an unbounded monitoring dependency.

Use a shared stable telemetry namespace. IDs belong in traces, not uncontrolled high-cardinality metric labels. Prompts, tokens, opaque reasoning, raw auth errors, and full bodies are redacted by default. Explicit diagnostic capture must be bounded, authorized, and sanitized.

## 14. TestKit and shared acceptance contracts

### 14.1 Test-support modules

| Module family | Purpose |
| --- | --- |
| `Fixtures / Scenario` | Independent wire samples, expected canonical data, provenance, versions, scenario definitions. |
| `ScriptedProvider` | Deterministic canonical events for host agent behavior tests. |
| `HTTPServer / WSServer` | Raw protocol servers for real client/codec tests, with isolated listeners. |
| `OAuthServer / MemoryCredentialStore / Clock` | Auth progression, expiry, refresh races, ownership loss, revision/generation tests. |
| `Conformance / ResponseProjection` | Reusable acceptance contracts and strict semantic comparison. |
| `Faults / Probe` | Fragmentation, delays, truncation, faults, slow consumers, submission counts, resource observations. |

A scripted provider proves host behavior, not external-protocol correctness. A fake Backplane server proves WS client behavior, not real gateway integration. Both are useful but require separate real-code-path acceptance.

Req.Test covers request construction, counts, and stubbed errors; it does not replace socket tests. [S12] Supervised ExUnit helpers clean up resources, but leak assertions run before that cleanup so the framework does not hide a production leak. [S13]

### 14.2 Fixtures and independent oracles

Use official examples, independently authored boundaries, and authorized sanitized recordings. Record source, collection date, profile/API compatibility input, and fixture-schema revision. Review expected results independently; do not generate them during a test with the implementation under test.

Synthetic signed/encrypted data demonstrates preservation only, not live provider validity. Round trips are useful but not the sole oracle. Snapshot changes require a protocol-change explanation, not blanket acceptance of new output.

### 14.3 Acceptance suite identifiers

The following IDs are normative across all three documents. The PRD maps them to requirements; the implementation plan maps them to work packages.

| ID | Required evidence |
| --- | --- |
| T01 | Independent request encode/decode, non-streaming response, and streaming fixtures for all three codecs. |
| T02 | Every declared directed translation pair passes text/tool/usage cases; unsupported features fail explicitly. |
| T03 | Role/order semantics, parallel call IDs, failed tool results, refusals, and output limits are preserved. |
| T04 | Valid JSON/UTF-8/newline fragmentation and coalescing preserve reduction; invalid sequences fail clearly. |
| T05 | Multi-line data, optional space, CR/LF variants, comments, unknown events, and EOF are covered. |
| T06 | Trailing usage is retained and a local handle receives exactly one terminal. |
| T07 | Cancel/complete races, consumer exit, timeouts, and transport failure release resources. |
| T08 | Truncated or invalid partial arguments cannot produce an executable complete tool call. |
| T09 | Credit exhaustion is isolated; control/terminal paths and all buffers remain bounded. |
| T10 | WS disconnect never replays generation; duplicates, version errors, and size violations are explicit. |
| T11 | Direct HTTP and the real Backplane WS path yield equivalent semantics for the same fixture. |
| T12 | Auth headers/endpoints and model directories remain correctly account-scoped. |
| T13 | State/PKCE, callback replay, expiry, cancellation, device slowdown, and denial are tested. |
| T14 | Concurrent refresh is coalesced; owner loss/multi-node handling never blindly reuses an uncertain token. |
| T15 | Lost response after upstream rotation becomes unknown; logout prevents stale refresh resurrection. |
| T16 | Discovery handles interrupted pagination, empty/error/stale data, operator disablement, and revocation. |
| T17 | Capability-revision/admission races, unknowns, conflicts, and unsupported effort are validated. |
| T18 | Usage snapshots, cache/reasoning inclusion, zero/unknown, and duplicate observations are correct. |
| T19 | Actual outbound counts demonstrate that retries are disabled or meet the declared policy. |
| T20 | Observation failure never mutates native payloads or leaks secrets, prompts, or opaque state. |
| T21 | Static preflight failure makes no generation submission; midstream incompatibility never fabricates success. |
| T22 | An independent consumer installs and runs without a database, Phoenix, or Backplane configuration. |
| T23 | Production dependency/release/process inspection excludes TestKit, ExUnit, and example servers. |
| T24 | Sigma persisted-data mapping, tool loop, message semantics, and cancellation do not regress. |
| T25 | Existing Synapsis providers, background work, and QueryLoop behavior do not regress. |
| T26 | Dedicated Codex native models/Responses/SSE/tools and existing compact compatibility pass. |
| T27 | Endpoint/credential injection, arbitrary atoms/modules, deeply nested JSON, and malicious oversized input are rejected. |
| T28 | Re-consuming one handle cannot initiate a second generation. |

Property tests generate fragmentation, state transitions, sequencing, and size boundaries. Store failing seeds and shrink to reproducible cases. [S14]

### 14.4 Semantic equivalence

Compare ordered content, role semantics, tool names/arguments/result relationships, stop reasons, error categories, usage semantics, warnings, and completeness. Only explicitly allowlisted dynamic IDs, timestamps, network fragment shapes, and observed durations may differ.

Preserve same-source opaque bytes exactly. Compare JSON arguments structurally without changing string contents. Do not ignore missing state, missing tools, role changes, or usage differences to make an equivalence test pass. Replay one deterministic fixture; do not ask a live model twice and compare its answers.

### 14.5 Test layers and execution rules

PR tests are offline except for isolated local sockets. They require no live credentials and incur no provider spend. Live smoke is explicitly enabled, has request/model/output budgets, reports compatibility inputs, and avoids exact-text assertions for model replies.

Cross-project CI must run a real Backplane endpoint against a deterministic fake upstream. WSServer-only tests cannot stand in for that gate.

Before publication, install the actual built package artifact into a fresh Mix project. Test the minimum supported dependency combination, the latest allowed combination, and pinned real consumer lockfiles. Umbrella-root test success alone does not prove portability.

## 15. Protocol Lab

`examples/protocol_lab` is an independent CLI using public APIs only. It does not contain alternate codecs/providers. It must list models and provenance, show effective context/effort, inspect a translation plan, replay a fixture, run one direct or WS request, cancel, and show canonical events/usage.

Default use targets local fake services. Real login and provider calls require explicit configuration. The lab does not auto-import accounts or persist production secrets. A chat UI is outside scope.

The lab tests documentation accuracy, dependency portability, diagnostics, and reproducibility, not merely demonstrates a happy path.

## 16. Versioning, compatibility, and publication

Version package SemVer, wire schema, canonical-data schema, fixture schema, model-metadata snapshots, and provider compatibility separately. Non-critical additive fields need not force a wire-major change; new required semantics need negotiation or rejection.

API shape, terminal meaning, error taxonomy, and usage methodology are compatibility surfaces. Namespaced extensions cannot override core or authorization fields. TestKit declares its supported Protocol range independently of Backplane's application release number.

Each package has its own README, CHANGELOG, source/license notices, and package manifest. W0 checks extracted-source licenses; do not assume all repositories have identical terms. Fixed Git ref/subdirectory dependencies are acceptable for development; independent package consumption is the publication target. External consumers resolve their own dependency locks. [S11]

No unconditional dependency on absent root config, sibling applications, repository-only support files, or unpackaged fixtures is allowed. Production startup must not launch OAuth, discovery, fake servers, or connection pools without explicit host action.

## 17. Migration and rollout

### 17.0 PR #32 remediation amendment

The first production consumer is now Backplane's ordinary OpenAI Responses native proxy path
(`POST /v1/responses`, excluding the `openai-codex` preset). This scoped decision supersedes the
earlier W1-only and Sigma-first ordering, but does not move routing, authorization, credential
storage, transport, or durable logging into the package.

The normal data path remains `Backplane.Api.Endpoint` -> `Backplane.LLM.ProxyPlug` ->
`Backplane.LLM.Router` -> Relayixir. Relayixir forwards the native response bytes and exposes the
same chunks to `Backplane.AiProtocol.OpenAIResponsesObserver`; `Backplane.LLM.AccessEvent` projects
the observer's usage, error, terminal, and observation-completeness facts into the existing
observability event and `llm_logs`. Observation never submits or replays a generation and never
rewrites the forwarded body.

Only bounded OpenAI Responses JSON/SSE observation is brought forward from W2. OpenAI Chat,
Anthropic Messages, Codex-specific Responses, active cross-protocol translation, OAuth/catalog
migration, and a complete WebSocket implementation remain on their existing paths.

### 17.1 Principles

Pin all three source repositories and inventory providers, codecs, auth, catalogs, callers, and persisted formats before extraction. Historical note test counts are not a fresh baseline. [N1]

Extract independently usable pure logic first. Add thin compatibility facades for application-specific data. A facade maps API/data; it must not become a permanent second parser. Give legacy paths explicit retirement gates.

One production request executes once. Shadow comparison uses recorded bytes or read-only observation, never duplicate live generations. Rollback changes routing for new requests; it does not retry an uncertain in-flight request through the old implementation.

### 17.2 Work packages

| Work package | Outcome | Integration dependencies |
| --- | --- | --- |
| W0 | Immutable source and scope baseline; isolated initial delivery boundary. | None |
| W1 | Canonical contracts, lifecycle, preflight, wire specification, package foundations. | W0 |
| W2 | Three bidirectional codecs, framing, reducers, independent fixtures. | W1 |
| W3 | HTTP client, auth contracts/coordinator, discovery/effective capabilities. | W1; codec integration requires W2 |
| W4 | WS client/flow control and actual Backplane endpoint. | W1/W2/W3; fake-service support from W5 |
| W5 | Reusable TestKit, lab, standalone installation and package checks. | Starts after W1; expands with W2–W4 |
| W6 | Sigma as the first real consumer. | W2/W3/W5; WS acceptance when W4 is ready |
| W7 | Synapsis and Backplane business-path migration, native observation, translation, Codex gate. | W3/W4/W5; migration pattern proven by W6 |
| W8 | Compatibility/release matrix, consumer evidence, publication and retirement documentation. | Required preceding work complete |

After contract freeze, codec, auth/catalog, transport, and TestKit work may proceed in parallel. A changed canonical or terminal contract requires coordinated review; parallel teams must not invent incompatible variants.

### 17.3 Rollout order and preservation

Start library construction in Backplane without changing production routes. Validate the standalone lab, then Sigma's direct path. The Backplane WS endpoint can develop in parallel. Extend Sigma's WS path, then migrate Synapsis and the remaining Backplane paths.

For Backplane, add read-only observation before active calls and explicit translation. Keep native Codex and non-target routes until their own gates pass. Existing Synapsis providers outside the initial codec set, including any Google path confirmed in W0, remain on their old implementation until separately supported. Samgita is not part of W6/W7.

## 18. Release gates and bounded open decisions

A full V1 claim requires all declared codecs/translations, auth and Codex scope, direct/WS client parity, bounded execution, isolation, independent installation, real Backplane integration, and Sigma/Synapsis regression evidence. Preview releases must publish a narrower, truthful support matrix.

| Open implementation choice | Owner/gate |
| --- | --- |
| Exact WS backend/version and transport pause/cancel behavior | W1 spike; W4 integration evidence |
| Exact wire schema, control/terminal ordering, public state affinity, status mappings | W1 contract freeze, with explicit fault cases |
| Codex compatibility inputs and existing implementation details | W0 inventory; W3/W7 dedicated validation |
| Missing provider context/effort metadata | Provenance-driven discovery; preserve unknown values |
| Final concurrency and byte limits | W4/W8 measured local tests and recorded environment |
| Host storage and multi-node refresh ownership backend | Host implementation of contracts; no new database dependency in the lib |
| Actual release dependency versions and source notices | W0/W5/W8 evidence |

Missing live credentials do not prevent offline work, but live checks remain `not run`. Missing source access does not justify an invented migration inventory. Report a precise blocker and complete independent work; never mark unverified functionality passed.

## Appendix A. Objective traceability

| Objective | Design areas | Primary acceptance |
| --- | --- | --- |
| U1 | Packages, public API, publication, migration | T22–T25, T28 |
| U2 | Codecs, translation, lifecycle, observation | T01–T06, T18–T21, T26 |
| U3 | Execution ownership, HTTP, WS, parity | T07–T11, T19, T28 |
| U4 | Profiles, auth, model capabilities | T12–T17, T26 |
| U5 | TestKit, lab, package and consumer gates | T01–T28 |
| U6 | Non-goals and migration preservation | No Samgita migration task in V1 |

## Appendix B. Source register

The following references were carried over from the supplied design, which reports a 2026-09-10 research date. They were not re-fetched for this English conversion. Recheck relevant official contracts when pinning fixtures and provider compatibility; preserve observations as evidence rather than treating a changing URL as a version.

| ID | Source | Use and limitation |
| --- | --- | --- |
| S1 | [Sigma repository](https://github.com/gsmlg-opt/sigma) | Historical application boundaries; W0 must pin actual source. |
| S2 | [Codex authentication](https://developers.openai.com/codex/auth/) | Distinct auth modes; not permission to reuse credentials across products. |
| S3 | [Codex App Server](https://developers.openai.com/codex/app-server/) | Its own account/model contracts; not generic inference HTTP. |
| S4 | [Anthropic Models API](https://platform.claude.com/docs/en/api/models/list) | Input/output limits and capabilities. |
| S5 | [Anthropic streaming](https://platform.claude.com/docs/en/build-with-claude/streaming) | Events, usage, state/signatures, errors. |
| S6 | [OpenAI list models](https://developers.openai.com/api/reference/resources/models/methods/list) | Basic catalog schema, not a complete capability registry. |
| S7 | [OpenAI reasoning](https://developers.openai.com/api/docs/guides/reasoning) | Reasoning-state preservation. |
| S7a | [Anthropic effort](https://platform.claude.com/docs/en/build-with-claude/effort) | Provider-specific effort semantics. |
| S8 | [OpenAI native WebSocket mode](https://developers.openai.com/api/docs/guides/websocket-mode) | Distinction from the proposed Backplane protocol. |
| S9 | [RFC 9700](https://www.rfc-editor.org/rfc/rfc9700.html) | OAuth security mechanisms, not claims that all providers support optional operations. |
| S10 | [WHATWG SSE](https://html.spec.whatwg.org/multipage/server-sent-events.html) | Framing reference. |
| S11 | [Mix dependencies](https://hexdocs.pm/mix/Mix.Tasks.Deps.html) | Independent package and dependency behavior. |
| S12 | [Req.Test](https://hexdocs.pm/req/Req.Test.html) | Stub/expectation facilities; not a pinned dependency version. |
| S13 | [ExUnit callbacks](https://hexdocs.pm/ex_unit/ExUnit.Callbacks.html) | Test-resource supervision. |
| S14 | [ExUnitProperties](https://hexdocs.pm/stream_data/ExUnitProperties.html) | Generated invariants, shrinking, reproducibility. |
| N1 | Agent Note: “OpenAI Codex direct proxy and dynamic model discovery repair”; note ID `c8df37b1-4b1e-4610-8117-7992263265a4`, historical revision 1 | Prior implementation report only. No private endpoints, account data, or historic test totals are treated as new verification. |
| A1 | Supplied `Repo Analysis Request.txt` | Existing Synapsis execution boundary only; no adoption of a single-agent topology into this project. |

Repository inputs for W0 are `https://github.com/gsmlg-opt/backplane`, `https://github.com/gsmlg-opt/sigma`, and `https://github.com/gsmlg-opt/Synapsis`. Their HEAD revisions are intentionally not guessed here.
