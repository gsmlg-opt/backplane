# Backplane Observability v2 — Architecture and Technical Design

| Field | Value |
|---|---|
| Status | Proposed |
| Repository | `gsmlg-opt/backplane` |
| Baseline | `main@938863b247fc0a42e2c2e181136696e7954c880f` |
| Date | 2026-09-03 |
| Scope | LLM proxy, MCP proxy, runtime diagnostics, audit, metrics, and future domain observability |

## 1. Executive Summary

Backplane currently has several independent mechanisms that are all described as logging:

- Elixir `Logger` output for runtime diagnostics.
- `:telemetry` events for LLM, MCP, memory, skills, host agents, and jobs.
- A catch-all `BackplaneTelemetry.TelemetryLogger` that subscribes to unrelated domains and writes Logger, console, or a single JSONL file.
- PostgreSQL records such as `llm_logs`, `tool_call_log`, and `skill_load_log`.
- ETS metrics in `Backplane.Metrics`.
- MCP protocol wire logging in `backplane_mcp_protocol`.
- Transient PubSub events rendered by the admin Logs page.

These mechanisms have different reliability, privacy, retention, and query requirements. Treating them as one logging concern creates duplicate output, weak correlation, incomplete records, and a single high-volume failure domain.

Observability v2 separates the system into five data products:

1. **Runtime logs** for operator diagnostics.
2. **Proxy access records** for durable LLM and MCP request history.
3. **Trace events** for request-internal execution timelines.
4. **Audit events** for security-relevant actions.
5. **Metrics** for aggregate health and performance.

Payload content is a sixth, separately controlled artifact type. Prompts, messages, tool arguments, tool results, and resource content are not access-record fields and are not persisted by default.

The first implementation milestone focuses on two durable domains:

- **LLM Proxy Requests**
- **MCP Proxy Requests and Tool Calls**

Other domains continue to emit telemetry and runtime logs, then adopt the same contract incrementally.

## 2. Current Repository State

This design is based on the repository baseline identified above.

### 2.1 Unified telemetry logger

`apps/backplane_telemetry/lib/backplane_telemetry/telemetry_logger.ex` subscribes to LLM, MCP, tool call, memory, skills, and host-agent events. A single GenServer sanitizes terms, JSON-encodes events, writes a single optional JSONL file, optionally writes directly to stdout, and emits human-readable Logger messages.

This has four architectural consequences:

- All domains share one mailbox and one failure boundary.
- Domain-specific persistence and retention policies cannot be expressed.
- High-volume proxy events can delay unrelated lifecycle events.
- Sanitization only provides JSON compatibility; it does not implement a complete privacy policy.

### 2.2 Duplicate event and Logger paths

`apps/backplane_system/lib/backplane/telemetry.ex` emits telemetry and directly writes Logger messages for MCP requests and tool calls.

`apps/backplane_mcp/lib/backplane/transport/request_logger.ex` independently writes an HTTP/MCP request log.

`apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/logging.ex` adds protocol message, server, client, and transport logs.

The catch-all telemetry logger then turns some of the same telemetry events back into Logger messages. A single request may therefore be represented multiple times without a common trace identifier or a clear source of truth.

### 2.3 LLM persistence is richer than the active schema and collector

`apps/backplane_system/priv/repo/migrations/20260430000001_create_llm_provider_redesign.exs` created `llm_logs` with request, client, API surface, provider API/model, requested and resolved model, byte counts, token counts, raw request/response, and metadata fields.

The active Ecto schema at `apps/backplane_llama/lib/backplane/llm/usage_log.ex` exposes only a subset. `UsageCollector` maps an even smaller terminal event into one Oban job per request.

The active collector therefore does not fully use the existing database model and misses early failures, route decisions, resolved model information, and complete request correlation.

### 2.4 MCP has context but no durable request record

Modern MCP request processing already constructs a rich request context containing protocol version, client information, transport, remote IP, authorization context, request metadata, and JSON-RPC ID.

The current durable table `tool_call_log` is an audit-oriented record with tool name, client, duration, result, error, and argument hash. It cannot represent the MCP transport, protocol version, session, JSON-RPC request, cache behavior, or upstream call.

MCP usage in `DashboardUsageLive` is currently sourced from process-local ETS counters rather than a durable query model.

### 2.5 Admin Logs is not a durable proxy log browser

`apps/backplane_admin/lib/backplane/admin/live/logs_live.ex` displays recent Oban jobs and the latest in-memory PubSub tool events. Tool events are capped in the LiveView process and disappear after restart.

The page does not provide durable LLM/MCP request filtering, request details, cross-domain correlation, or sink health.

## 3. Goals

Observability v2 must provide the following properties:

1. Separate LLM proxy, MCP proxy, audit, runtime, metrics, and payload concerns.
2. Produce exactly one durable root access record for each completed proxy operation.
3. Correlate HTTP requests, JSON-RPC requests, tool calls, provider calls, upstream MCP calls, and host-agent work.
4. Record success, validation rejection, authorization failure, rate limiting, timeout, cancellation, upstream failure, and internal exception outcomes.
5. Keep persistence and file I/O outside proxy request processes.
6. Bound memory and mailbox growth under overload.
7. Preserve proxy availability when observability sinks fail.
8. Make persistence idempotent.
9. Keep raw payload capture disabled by default.
10. Keep `backplane_mcp_protocol` independently publishable and free of Backplane database dependencies.
11. Expose durable query models and admin views.
12. Support independent retention policies by domain.

## 4. Non-Goals

The first implementation does not include:

- A general-purpose log analytics engine.
- Full-text search over prompt or tool-result content.
- Replacement of external systems such as Loki, Elasticsearch, or OpenTelemetry collectors.
- Automatic storage of raw prompts, messages, arguments, responses, or resources.
- Database persistence of every low-level MCP protocol message.
- Immediate PostgreSQL partitioning.
- A single universal `logs` table.
- Renaming the physical `llm_logs` table in the first migration.
- Rewriting the MCP protocol implementation.

## 5. Terminology and Data Boundaries

| Data type | Purpose | Default destination | Reliability |
|---|---|---|---|
| Runtime log | Human/operator diagnosis | Elixir Logger and optional JSONL sink | Best effort |
| Proxy access record | One final record per LLM/MCP operation | Domain PostgreSQL table | Buffered, idempotent persistence |
| Trace event | Internal operation timeline | Telemetry, metrics, optional external trace sink | Best effort unless promoted |
| Audit event | Security-sensitive actor/action history | PostgreSQL audit tables | Durable, idempotent |
| Metric | Aggregate health and performance | ETS/Prometheus-compatible exporter | Best effort aggregation |
| Payload artifact | Prompt, arguments, result, response, resource content | Optional encrypted store | Disabled by default |

An access record describes **what happened**. A payload artifact contains **what was sent or returned**. These must remain distinct.

## 6. Design Principles

### 6.1 Domain ownership

Each domain owns its durable schema, writer, query API, and retention logic.

- LLM records belong to `backplane_llama`.
- MCP records belong to `backplane_mcp`.
- Audit records belong to `backplane_system`.
- Admin rendering belongs to `backplane_admin`.
- Common event, context, redaction, and runtime sink infrastructure belongs to `backplane_telemetry`.

### 6.2 Telemetry is an event bus, not the database

`:telemetry` remains the low-coupling event transport. It must not perform database or file I/O in the producer process.

A telemetry event can feed several consumers:

- Domain access-record writer.
- Runtime Logger sink.
- Metrics collector.
- External trace exporter.

No consumer is the sole definition of the event.

### 6.3 One durable root record

Each logical proxy operation has one root access record:

- One LLM request.
- One MCP JSON-RPC request.
- One MCP SSE stream open/close lifecycle.
- One MCP session delete operation.

Tool calls and upstream calls are child records linked by `trace_id`, `span_id`, and root record ID.

### 6.4 Correlation before detail

Every root operation must receive correlation identifiers before additional fields are collected. A minimal correlated record is more useful than a rich uncorrelated record.

### 6.5 Payload minimization

Metadata, byte counts, hashes, model names, tool names, status, timing, and error categories are first-class fields.

Content is excluded unless an explicit payload policy authorizes capture.

### 6.6 Independent failure domains

LLM and MCP collectors use independent processes, queues, metrics, and database batches. An MCP event burst must not block LLM records, memory telemetry, or runtime logging.

### 6.7 Availability over observability

Observability failure must never change an LLM HTTP response or MCP JSON-RPC response.

Queue overflow, encoding failure, database failure, and sink failure are exposed as metrics and rate-limited runtime errors, but proxy execution proceeds.

## 7. Target Application Architecture

```text
Backplane.Api.Endpoint
  │
  ├─ Plug.RequestId
  ├─ Backplane.Observability.ContextPlug
  │
  ├─ /v1/* ──────────────────────────────────────────────────────────┐
  │                                                                  │
  │   Backplane.LLM.Router                                           │
  │     ├─ request span                                               │
  │     ├─ model/provider route spans                                 │
  │     ├─ upstream span                                              │
  │     └─ stream/usage finalization                                  │
  │                                                                  ▼
  │                                                    Backplane.LLM.LogWriter
  │                                                       └─ llm_logs
  │
  └─ /mcp ───────────────────────────────────────────────────────────┐
                                                                     │
      Backplane.Transport.McpPlug                                    │
        ├─ root MCP access span                                      │
        ├─ protocol executor                                         │
        ├─ Backplane.MCP.Dispatch child spans                        │
        └─ Backplane.Proxy.Upstream child spans                      │
                                                                     ▼
                                                       Backplane.MCP.LogWriter
                                                         ├─ mcp_proxy_requests
                                                         └─ mcp_tool_calls

All domain events
  ├─ Backplane.Observability.RuntimeSink
  ├─ Backplane.Metrics
  └─ optional future OTLP/external sink
```

### 7.1 `:backplane_telemetry`

The OTP app remains lightweight and must not depend on Ecto, Postgrex, Oban, or domain apps.

Proposed public modules:

```text
Backplane.Observability
Backplane.Observability.Event
Backplane.Observability.Context
Backplane.Observability.ContextPlug
Backplane.Observability.Error
Backplane.Observability.Redaction
Backplane.Observability.Buffer
Backplane.Observability.RuntimeSink
Backplane.Observability.Sink.Logger
Backplane.Observability.Sink.JSONL
```

Responsibilities:

- Generate and validate event envelopes.
- Generate trace/span identifiers.
- Propagate request context.
- Apply common redaction and field classification.
- Provide bounded non-blocking enqueue support.
- Route runtime events to configured runtime sinks.
- Expose sink health.

It does not write LLM or MCP database rows.

### 7.2 `:backplane_llama`

Proposed modules:

```text
Backplane.LLM.ProxyRequest
Backplane.LLM.AccessEvent
Backplane.LLM.LogWriter
Backplane.LLM.LogQuery
Backplane.LLM.RetentionWorker
```

`BackplaneLlama.Application` starts the domain writer and attaches its terminal-event collector. The root `Backplane.Application` no longer manually attaches `UsageCollector`.

### 7.3 `:backplane_mcp`

Proposed modules:

```text
Backplane.MCP.ProxyRequest
Backplane.MCP.ToolCall
Backplane.MCP.AccessEvent
Backplane.MCP.LogWriter
Backplane.MCP.LogQuery
Backplane.MCP.RetentionWorker
Backplane.MCP.ProtocolTelemetryAdapter
```

`BackplaneMcp.Application` starts independent root-request and child-call writers, or one supervisor containing both writer lanes.

### 7.4 `:backplane_mcp_protocol`

The protocol package keeps its own generic telemetry and redaction implementation.

It must not:

- Depend on `Backplane.Repo`.
- Know about `mcp_proxy_requests`.
- Know about Backplane admin UI.
- Call Backplane domain writers.

`Backplane.MCP.ProtocolTelemetryAdapter` may attach to selected protocol events and translate them into Backplane metrics or trace events.

### 7.5 `:backplane_system`

`backplane_system` continues to own:

- `Backplane.Repo`
- `Backplane.Settings`
- `Backplane.Metrics`
- Audit schemas and writer
- Shared retention scheduling

Operational observability settings are stored in `system_settings`. Boot-critical Logger formatting remains application/environment configuration because it must work before the database is available.

## 8. Canonical Event Envelope

The common event representation is logically:

```text
schema_version
event_id
occurred_at
domain
operation
phase
severity
context
measurements
attributes
error
payload_ref
```

### 8.1 Required fields

| Field | Type | Rule |
|---|---|---|
| `schema_version` | positive integer | Starts at `1` |
| `event_id` | opaque 128-bit identifier | Unique across nodes |
| `occurred_at` | UTC datetime with microseconds | Captured in producer process |
| `domain` | atom/string | Registered domain |
| `operation` | string | Stable operation name |
| `phase` | atom/string | `start`, `stop`, `exception`, or `event` |
| `severity` | Logger level | Derived from outcome unless explicitly set |
| `context` | map | Correlation and actor context |
| `measurements` | map | Numeric measurements only where possible |
| `attributes` | map | Sanitized structured metadata |
| `error` | map or nil | Standard error summary |
| `payload_ref` | string or nil | Reference only; never inline payload |

### 8.2 Context fields

| Field | Source |
|---|---|
| `request_id` | Existing `Plug.RequestId` |
| `trace_id` | Existing inbound trace context or generated internally |
| `span_id` | Generated for each operation |
| `parent_span_id` | Parent operation |
| `client_id` | Auth/client assigns |
| `project_id` | Optional project context |
| `agent_id` | Optional agent context |
| `session_id` | MCP/host-agent/session context |
| `run_id` | Optional autonomous run context |
| `node` | BEAM node name |
| `service` | Producing OTP app/domain |

Trace IDs should use a stable hexadecimal form compatible with future distributed tracing. V1 does not require forwarding trace headers to LLM or MCP upstreams.

### 8.3 Error fields

All domains normalize errors to:

| Field | Description |
|---|---|
| `kind` | Stable category such as `validation`, `auth`, `rate_limit`, `timeout`, `upstream`, `internal` |
| `code` | Provider, JSON-RPC, HTTP, or internal stable code |
| `message` | Sanitized bounded message |
| `source` | `backplane`, provider name, or upstream name |
| `retryable` | Boolean or nil |

Stacktraces, exception structs, complete upstream bodies, and credentials are excluded from access records.

### 8.4 Lifecycle invariants

For every span:

1. One `start` event may be emitted.
2. Exactly one terminal event is emitted: `stop` or `exception`.
3. The terminal event repeats all fields required to create the durable record.
4. The terminal event includes duration.
5. A terminal event has a stable `outcome`.
6. Domain collectors persist root terminal events only.
7. Duplicate `event_id` values are ignored by database conflict handling.

## 9. Event Naming

Domain events use:

```text
[:backplane, <domain>, <operation>, <phase>]
```

### 9.1 LLM proxy

```text
backplane.llm_proxy.request.start
backplane.llm_proxy.request.stop
backplane.llm_proxy.request.exception

backplane.llm_proxy.route.selected
backplane.llm_proxy.route.rejected

backplane.llm_proxy.upstream.start
backplane.llm_proxy.upstream.stop
backplane.llm_proxy.upstream.exception

backplane.llm_proxy.stream.first_chunk
backplane.llm_proxy.stream.stop
backplane.llm_proxy.stream.exception
```

### 9.2 MCP proxy

```text
backplane.mcp_proxy.request.start
backplane.mcp_proxy.request.stop
backplane.mcp_proxy.request.exception

backplane.mcp_proxy.tool_call.start
backplane.mcp_proxy.tool_call.stop
backplane.mcp_proxy.tool_call.exception

backplane.mcp_proxy.upstream.start
backplane.mcp_proxy.upstream.stop
backplane.mcp_proxy.upstream.exception

backplane.mcp_proxy.session.created
backplane.mcp_proxy.session.closed
backplane.mcp_proxy.session.expired
```

### 9.3 Other domains

```text
backplane.memory.*
backplane.skills.*
backplane.plugins.*
backplane.host_agent.*
backplane.system.*
backplane.security_audit.*
```

Existing event names are supported temporarily through compatibility adapters. New code must not add more events to the legacy catch-all logger contract.

## 10. Correlation Propagation

### 10.1 Public HTTP entry point

Insert `Backplane.Observability.ContextPlug` immediately after `Plug.RequestId` in `Backplane.Api.Endpoint`, before `Backplane.LLM.ProxyPlug` and before forwarding to `/mcp`.

The plug:

- Reads the existing request ID.
- Reads a valid inbound trace context when present.
- Generates a trace ID otherwise.
- Stores a root context in `conn.assigns`.
- Stores bounded scalar fields in `Logger.metadata`.
- Never stores auth headers or request bodies in Logger metadata.

### 10.2 LLM execution

LLM functions receive or recover context from `conn.assigns`. When a provider/model is selected, the returned conn or explicit access state is enriched functionally.

Provider routing, upstream forwarding, and streaming use child spans whose parent is the LLM request span.

### 10.3 MCP execution

`McpPlug` owns the root operation. It records HTTP and transport data and registers finalization before downstream plugs.

The MCP request context receives the root trace and request identifiers. `Dispatch` and `Proxy.Upstream` create child spans using that context.

The generic protocol package may continue emitting its own events. The Backplane adapter adds correlation only where the transport context already contains it.

### 10.4 Process boundaries

When work crosses into:

- `Task.Supervisor`
- GenServer
- Oban
- host-agent channel
- upstream client process

the caller must explicitly include the observability context in the message/job arguments. Logger process metadata is not considered a reliable cross-process propagation mechanism.

## 11. LLM Proxy Access Record

### 11.1 Root owner

`Backplane.LLM.Router` owns the logical LLM request lifecycle.

All terminal branches must finalize a record, including:

- Invalid JSON or model extraction failure.
- Model not found.
- API surface mismatch.
- Disabled/unavailable provider.
- Missing credential.
- Rate limit rejection.
- Request rewrite failure.
- Upstream connection failure.
- Upstream timeout.
- Upstream non-2xx response.
- Streaming disconnect or mapper failure.
- Successful non-stream response.
- Successful stream completion.
- Embedding request.

### 11.2 Logical schema

The first migration keeps the physical `llm_logs` table but introduces the logical Ecto model `Backplane.LLM.ProxyRequest`.

Required fields:

```text
id
event_id
request_id
trace_id
client_id
client_ip

operation
api_surface
http_method
path

provider_id
provider_name
provider_api_id
provider_model_id
provider_model_surface_id
requested_model
resolved_model

stream
status
outcome
error_kind
error_code
error_message

duration_ms
upstream_duration_ms
ttft_ms
stream_duration_ms
stream_chunks
request_bytes
response_bytes

input_tokens
output_tokens
total_tokens
cached_tokens
reasoning_tokens
finish_reason
provider_request_id
attempt_count

metadata
inserted_at
```

Not every provider supplies every field. Missing provider values remain `nil`; they are not synthesized.

### 11.3 Deprecated raw columns

Existing `raw_request`, `raw_response`, and truncation columns remain nullable during migration for compatibility, but v2 writers do not populate them by default.

A later cleanup may move authorized captures into `proxy_payloads` and remove or deprecate the raw columns.

### 11.4 Streaming semantics

For streaming requests:

- `duration_ms` measures the full proxy lifecycle.
- `ttft_ms` is measured at the first upstream response chunk.
- `stream_duration_ms` measures first chunk to final chunk/close.
- `stream_chunks` counts forwarded chunks.
- Token usage is extracted from provider-supported final events.
- Client disconnect produces `outcome = cancelled` or `client_disconnect`, not a successful completion.
- Missing token usage remains `nil`; it is not treated as zero in raw records.

### 11.5 Usage aggregation

`Backplane.LLM.UsageQuery` becomes a compatibility facade over `Backplane.LLM.LogQuery`.

Aggregates continue to expose:

- Request count.
- Input/output/total tokens.
- Average and percentile latency.
- Error rate.
- Model/provider/API-surface breakdown.
- Streaming and non-streaming breakdown.

## 12. MCP Proxy Access Records

### 12.1 Root owner

`Backplane.Transport.McpPlug` owns the root MCP access operation because it observes:

- HTTP method and path.
- request/response byte counts.
- remote IP.
- parser result.
- compression.
- rate limiting.
- authorization.
- protocol era selection.
- final HTTP status.
- JSON-RPC request and response envelope.
- SSE stream lifetime.
- session deletion.

The current `RequestLogger` is replaced by an access recorder that emits structured events and no longer directly writes a duplicate request Logger message.

### 12.2 `mcp_proxy_requests`

Required fields:

```text
id
event_id
request_id
trace_id

operation              # jsonrpc | sse_open | session_delete
rpc_id                 # stored as text
rpc_method
protocol_version
era
transport
session_id

client_id
client_name
client_version
auth_kind
remote_ip

http_method
path
http_status
jsonrpc_error_code

request_bytes
response_bytes
duration_ms

outcome
idempotency_status
error_kind
error_code
error_message

metadata
inserted_at
```

`rpc_method` is nullable for transport-only operations and malformed requests.

### 12.3 `mcp_tool_calls`

Required fields:

```text
id
event_id
mcp_request_id
trace_id
span_id
parent_span_id

tool_name
tool_namespace
original_tool_name
execution_kind          # native | managed | upstream
upstream_name
upstream_prefix
upstream_transport
upstream_protocol_version

arguments_hash
cache_status            # hit | miss | bypass
timeout_ms
attempt_count
duration_ms

outcome
error_kind
error_code
error_message

metadata
inserted_at
```

Tool arguments and results are excluded. The argument hash is calculated after stable JSON canonicalization or a documented deterministic encoding.

### 12.4 Child operation boundaries

- `Backplane.MCP.Dispatch` owns the tool-call child span.
- `Backplane.Proxy.Upstream` owns the upstream child span.
- Cache lookup is represented as attributes on the tool span in v1.
- Protocol encode/decode and wire events remain trace/metrics events and are not separate database rows by default.
- Resource reads and prompt gets remain root MCP request records; optional child models can be added later only when a concrete query requirement exists.

### 12.5 Audit separation

Existing `tool_call_log` remains an audit data set during v2 rollout.

The access record answers:

> How did the MCP request execute?

The audit record answers:

> Which client invoked which tool, and was the action accepted?

The two records may share a trace ID after migration but must not be conflated.

## 13. Additional Domain Classification

The initial release does not create general access tables for all domains.

### 13.1 Memory

Memory continues to use its event stream, activity, recall trace, replay, and audit models. Observability v2 provides shared correlation and runtime sink behavior only.

Memory records must not be duplicated into a universal logs table.

### 13.2 Skills and plugins

Skills/plugin events use the common envelope for:

- Resolve.
- Validate.
- Install/update.
- Load.
- Execute.
- Sync.
- Compatibility failure.

Durable plugin lifecycle audit can be added when agent-plugin support is implemented.

### 13.3 Host agents

Host-agent connect/disconnect, command, memory synchronization, and trace ingestion receive shared correlation.

Existing `agent_trace_events` remains the durable host-agent trace model.

### 13.4 Background jobs

`oban_jobs` remains the source for job execution state. The Logs UI may render it, but jobs are not copied into proxy access tables.

## 14. Writer and Backpressure Architecture

### 14.1 Non-blocking producer rule

A telemetry callback may:

- Capture a timestamp.
- Construct a bounded event map.
- Apply bounded redaction.
- Attempt a bounded enqueue.
- Increment an in-memory metric.

It may not:

- Call `Repo`.
- Insert an Oban job.
- Open/write a file.
- Perform network I/O.
- Encode an unbounded payload.
- Wait for a writer response.

### 14.2 Bounded enqueue

`Backplane.Observability.Buffer` provides a non-blocking `try_enqueue` mechanism backed by a process plus an atomic capacity counter.

The counter is reserved before sending the event. If capacity is exhausted, the event is rejected immediately and a drop metric is incremented. This prevents an unbounded GenServer mailbox from becoming the effective queue.

Each domain has independent capacity.

### 14.3 Batch persistence

Domain writers:

- Drain up to a configured batch size.
- Use `Repo.insert_all`.
- Use `event_id` as a unique conflict target.
- Flush on batch size or interval.
- Retain a failed batch and retry with bounded exponential backoff.
- Report queue depth, persistence lag, insert failures, and duplicate count.
- Flush during controlled application shutdown.
- Never crash the proxy request process.

Recommended initial defaults:

| Setting | LLM | MCP root | MCP tool |
|---|---:|---:|---:|
| Queue capacity | 10,000 | 20,000 | 50,000 |
| Batch size | 100 | 200 | 500 |
| Flush interval | 250 ms | 250 ms | 250 ms |

These are safe defaults, not fixed protocol constants.

### 14.4 Overflow behavior

Event priority:

1. Security audit.
2. Root terminal access records.
3. Child terminal records.
4. Start/trace events.
5. Protocol wire/debug events.

Low-priority events are never allowed to consume capacity reserved for root records. A non-zero root-record drop metric is an operational fault and must be visible in the admin health view.

### 14.5 Delivery guarantees

V2 provides:

- Idempotent database persistence.
- At-least-once behavior after a writer accepts an event into its retry batch.
- Best-effort handling before enqueue and during abrupt VM/host loss.
- Controlled-shutdown flush.

A disk-backed spool can be added later if crash-loss requirements become stricter. It is not required for the first release.

## 15. Redaction and Payload Policy

### 15.1 Shared redaction

The MCP protocol redactor already recognizes common authorization and token forms. V2 extracts or wraps the reusable behavior as a shared policy while preserving protocol-package independence.

Shared sensitive keys include:

```text
authorization
proxy_authorization
cookie
set-cookie
token
access_token
refresh_token
id_token
client_secret
client_assertion
code_verifier
authorization_code
api_key
x-api-key
credential
password
```

Domain-specific sensitive content includes:

```text
messages
prompt
input
content
arguments
result
resource
raw_request
raw_response
```

Credential redaction and content minimization are separate rules.

### 15.2 Capture modes

Each domain supports:

| Mode | Behavior |
|---|---|
| `none` | Metadata only; production default |
| `hash` | Metadata, byte count, and content hash |
| `sampled` | Bounded redacted payload for sampled requests |
| `full` | Explicitly enabled encrypted capture with short retention |

The MVP implements `none` and `hash`. `sampled` and `full` require the payload-artifact workstream.

### 15.3 Optional `proxy_payloads`

A later optional table stores authorized payload captures:

```text
id
domain
record_id
direction
content_type
content_hash
encrypted_payload
truncated
redaction_version
expires_at
inserted_at
```

Access tables contain only `payload_ref` or a boolean indicating authorized capture.

### 15.4 Error messages

Error messages are:

- Bounded by byte size.
- Sanitized through shared redaction.
- Classified before persistence.
- Never populated from an entire upstream body.
- Never populated from `inspect(conn)` or unrestricted exception metadata.

## 16. Runtime Logging

Runtime Logger output remains useful for:

- Process crashes.
- Startup/shutdown.
- Upstream connect/reconnect/degradation.
- Writer failures.
- Queue overflow.
- Retention failures.
- Invalid configuration.

Runtime output should include scalar metadata:

```text
domain
operation
request_id
trace_id
span_id
client_id
provider
upstream
tool
status
outcome
duration_ms
error_kind
```

The runtime sink decides the human or JSON format. Domain code emits events and does not compose duplicate human-readable access messages.

The current single JSONL path may remain as a runtime event sink, but it is not the durable source of LLM/MCP records.

## 17. Metrics

`Backplane.Metrics` continues as the initial in-process collector and attaches to v2 events.

Required observability self-metrics:

```text
observability.events.accepted.<domain>
observability.events.persisted.<domain>
observability.events.duplicate.<domain>
observability.events.dropped.<domain>
observability.writer.failures.<domain>
observability.writer.retries.<domain>
observability.writer.queue_depth.<domain>
observability.writer.persistence_lag_ms.<domain>
observability.redaction.failures
```

Required LLM metrics:

```text
llm_proxy.requests.total
llm_proxy.requests.success
llm_proxy.requests.error
llm_proxy.requests.<provider>
llm_proxy.tokens.input
llm_proxy.tokens.output
llm_proxy.duration
llm_proxy.ttft
```

Required MCP metrics:

```text
mcp_proxy.requests.total
mcp_proxy.requests.<method>
mcp_proxy.requests.error
mcp_proxy.tool_calls.total
mcp_proxy.tool_calls.error
mcp_proxy.tool_calls.<tool>
mcp_proxy.upstream.duration
```

Database-backed dashboard aggregates replace ETS counters where historical accuracy is required. ETS remains appropriate for current process health.

## 18. Retention

Default policy:

| Data set | Default |
|---|---:|
| LLM proxy requests | 90 days |
| MCP proxy requests | 30 days |
| MCP tool calls | 30 days |
| Tool/skill audit | 180 days |
| Optional payload artifacts | 7 days |
| Runtime Logger output | Managed by deployment sink |
| Oban jobs | Managed by Oban configuration |

Retention workers use bounded pages and continuation jobs rather than one unbounded `DELETE`.

Each worker reports:

- Cutoff.
- Deleted row count.
- Remaining continuation state.
- Duration.
- Failure category.

PostgreSQL range partitioning is deferred. Query and retention APIs must avoid assumptions that would prevent monthly partitioning later.

## 19. Configuration

### 19.1 Source of truth

The repository treats TOML as boot-only configuration. Operational observability policy therefore belongs in `system_settings` and the admin UI.

Suggested keys:

```text
observability.llm_proxy.enabled
observability.llm_proxy.persist
observability.llm_proxy.retention_days
observability.llm_proxy.payload_mode
observability.llm_proxy.sample_rate

observability.mcp_proxy.enabled
observability.mcp_proxy.persist
observability.mcp_proxy.retention_days
observability.mcp_proxy.payload_mode
observability.mcp_proxy.sample_rate

observability.audit.enabled
observability.audit.retention_days

observability.writer.batch_size
observability.writer.flush_interval_ms
observability.writer.queue_capacity
```

Domain-specific values override shared writer defaults.

### 19.2 Boot-time runtime sink

Logger format and level must work before Repo/Settings are available. They remain in root application configuration and may be controlled by environment variables.

The runtime sink starts with safe defaults, then may apply dynamic level/sink changes after settings load.

### 19.3 Legacy compatibility

Existing `:backplane_telemetry, BackplaneTelemetry.TelemetryLogger` options are mapped to the runtime sink for one compatibility release:

- `log_to_logger`
- `log_to_console`
- `log_to_file`

They do not control domain database persistence.

The legacy TOML telemetry section, where still parsed, is deprecated rather than expanded.

## 20. Admin UI and Query Architecture

### 20.1 Routes

Proposed routes:

```text
/system/logs
/system/logs/llm
/system/logs/llm/:id
/system/logs/mcp
/system/logs/mcp/:id
/system/logs/audit
/system/logs/jobs
/system/logs/sinks
```

### 20.2 Overview

The overview displays:

- LLM/MCP request rate and error rate.
- p50/p95 latency.
- Provider and upstream breakdown.
- Writer queue depth and persistence lag.
- Dropped root/trace event counts.
- Last successful writer flush.
- Last successful retention run.

### 20.3 LLM browser

Filters:

```text
time range
request_id
trace_id
client
provider
api_surface
requested_model
resolved_model
stream
outcome
status
```

Detail view:

```text
request summary
routing
provider/upstream
stream timing
usage
error
correlated child events
payload-capture status
```

### 20.4 MCP browser

Filters:

```text
time range
request_id
trace_id
client
operation
rpc_method
tool
upstream
transport
protocol_version
era
outcome
```

Detail view:

```text
transport and auth summary
JSON-RPC result
tool-call children
cache result
upstream result
timing timeline
error
payload-capture status
```

### 20.5 Query requirements

- Keyset pagination, not large offset pagination.
- Bounded date range by default.
- Query modules owned by the LLM/MCP apps.
- Admin LiveViews do not construct raw Ecto queries over domain tables.
- Request detail lookups support ID and trace ID.
- Runtime JSONL files are not read by LiveView.

## 21. Failure Modes

| Failure | Required behavior |
|---|---|
| Runtime sink unavailable | Disable/degrade sink, emit health metric, continue proxy |
| Domain writer unavailable | Drop according to priority, rate-limit Logger error, continue proxy |
| PostgreSQL unavailable | Retain bounded retry batch, expose lag/failure, continue proxy |
| Queue full | Drop low-priority first; root drop increments critical metric |
| Redaction failure | Replace sensitive value/event detail with `[REDACTED]` |
| Encoding failure | Persist bounded fallback metadata only |
| Duplicate event | Ignore by `event_id`, increment duplicate metric |
| Writer crash | Supervisor restarts only that domain writer |
| Retention failure | Retry through Oban; never block request path |
| Invalid dynamic setting | Keep last known safe value and expose configuration error |
| Abrupt node loss | Unflushed in-memory events may be lost; existing rows remain valid |

## 22. Migration and Rollout

### Phase A — Dual observation

- Introduce event envelope, context, and writers behind feature flags.
- Keep legacy runtime output.
- Persist v2 records while existing LLM usage and tool audit behavior remains.

### Phase B — Read switch

- Switch LLM usage queries to the new logical `ProxyRequest` schema.
- Switch MCP usage dashboard from ETS-only history to durable records.
- Add new Logs pages.

### Phase C — Write switch

- Stop `UsageCollector` and one-job-per-request `UsageWriter`.
- Stop direct MCP request Logger duplication.
- Keep compatibility telemetry adapters temporarily.

### Phase D — Cleanup

- Remove catch-all `TelemetryLogger`.
- Remove duplicate direct Logger calls from event producers.
- Remove obsolete tests and configuration.
- Optionally rename `llm_logs` in a later schema cleanup after all code uses `ProxyRequest`.

Rollout metrics must show no unexplained gap between proxy request counters and persisted root records.

## 23. Rejected Alternatives

### 23.1 One universal `logs` table

Rejected because LLM and MCP have different fields, retention, query patterns, cardinality, and privacy controls. A generic JSONB table would move schema discipline into application code and weaken indexes.

### 23.2 Multiple file loggers only

Rejected because splitting JSONL files does not provide durable query models, correlation, retention enforcement, or admin request details.

### 23.3 Database writes inside telemetry callbacks

Rejected because telemetry handlers execute synchronously in the producer process and would add database latency to the proxy path.

### 23.4 One Oban job per event

Rejected as the default high-volume pipeline because it adds a second durable row and transaction for every record. Oban remains appropriate for retention and bounded background work.

### 23.5 Make `backplane_mcp_protocol` own persistence

Rejected because the package is independently publishable and must remain usable without Backplane Repo/admin dependencies.

### 23.6 Persist all wire messages

Rejected because it creates high volume and high payload risk without a primary operator requirement. Wire logging remains debug-only and sampled.

## 24. Architectural Decisions

1. The initiative is named **Backplane Observability v2**, not merely “split log files.”
2. `:backplane_telemetry` is a lightweight shared observability library and runtime-sink app.
3. Durable records remain domain-owned.
4. `llm_logs` is retained physically during the initial migration.
5. MCP receives new `mcp_proxy_requests` and `mcp_tool_calls` tables.
6. Existing `tool_call_log` remains audit data during rollout.
7. Root request records are terminal-event projections.
8. Raw payload capture is disabled by default.
9. Operational policies are stored in `system_settings`.
10. The proxy path never waits for observability persistence.
11. `backplane_mcp_protocol` remains database-independent.
12. Admin historical usage reads durable domain tables, not only ETS metrics.

## 25. Definition of Done

The architecture is implemented when:

- Every LLM and MCP operation has a request ID and trace ID.
- Every completed operation produces one durable root record.
- MCP tool/upstream calls link to the root record.
- LLM early failures and streaming outcomes are represented.
- No prompt, message, argument, tool result, or resource content is stored by default.
- All runtime sinks apply shared credential redaction.
- Domain writers are independent, bounded, supervised, and observable.
- Duplicate events cannot create duplicate database records.
- Retention jobs are scheduled and bounded.
- The admin UI exposes domain-separated durable logs.
- Legacy duplicate Logger paths are removed.
- `backplane_mcp_protocol` remains independently buildable and testable.
