# Backplane Observability v2 — Product Requirements Document

| Field | Value |
|---|---|
| Status | Draft for implementation |
| Repository | `gsmlg-opt/backplane` |
| Baseline | `main@938863b247fc0a42e2c2e181136696e7954c880f` |
| Date | 2026-09-03 |
| Product area | Backplane LLM Proxy and MCP Hub |
| Primary consumers | Backplane operator, maintainer, and coding agents |

## 1. Product Summary

Backplane Observability v2 provides domain-separated, correlated, privacy-safe operational records for the two core Backplane products:

1. LLM Proxy
2. MCP Hub/Proxy

The system gives an operator a durable answer to:

- Which requests were received?
- Which client initiated them?
- Which model, provider, tool, or upstream was selected?
- How long did each stage take?
- How much LLM usage was consumed?
- Where and why did a request fail?
- Which child tool/upstream calls belong to the same request?
- Is the logging pipeline healthy?
- Is sensitive payload content being captured?

The product does not turn Backplane into a general log analytics platform. It creates reliable domain records and leaves generic runtime log collection to normal deployment tooling.

## 2. Problem Statement

The current implementation has multiple overlapping logging paths:

- A catch-all telemetry logger for unrelated domains.
- Direct Logger output from MCP/tool event producers.
- A separate MCP HTTP request logger.
- MCP protocol debug logs.
- LLM usage records written through one Oban job per successful terminal event.
- Tool audit tables.
- Process-local ETS metrics.
- A Logs page that shows Oban jobs and transient PubSub tool events.

This causes:

- Duplicate and noisy runtime output.
- No stable cross-domain request timeline.
- Incomplete LLM records for early failures.
- No durable MCP request history.
- No durable MCP tool/upstream correlation.
- Inconsistent privacy behavior.
- No independent queue, retention, or sink policy per domain.
- Historical MCP dashboard data disappearing after process restart.
- A misleading Logs UI that does not represent the actual proxy request history.

## 3. Product Goals

### G1 — Domain separation

The operator can clearly distinguish:

- LLM Proxy
- MCP Proxy
- Audit
- Background Jobs
- Runtime/sink health

### G2 — Complete root records

Every completed LLM and MCP proxy operation produces one final durable access record, regardless of success or failure.

### G3 — Correlation

The operator can follow one request from ingress through route selection, tool/provider/upstream execution, streaming, and final response.

### G4 — Privacy by default

Prompt content, messages, tool arguments, tool results, resource content, and raw provider responses are not persisted by default.

### G5 — Operational safety

Observability failures never fail or materially delay an LLM or MCP request.

### G6 — Historical query

The admin UI and aggregate dashboards use durable data for historical LLM/MCP usage.

### G7 — Independent policy

LLM and MCP persistence, retention, sampling, and payload policy can be configured separately.

## 4. Non-Goals

The MVP does not provide:

- Arbitrary full-text search across payload content.
- SIEM functionality.
- A hosted multi-tenant analytics service.
- Guaranteed zero-loss persistence during abrupt machine/VM loss.
- PostgreSQL table partitioning.
- A complete OpenTelemetry backend.
- Long-term persistence of every MCP protocol frame.
- Raw payload capture enabled by default.
- A universal table for all application events.

## 5. Users

### 5.1 Backplane operator

Needs to identify failures, usage, slow providers/upstreams, and unhealthy writers without reading raw container logs.

### 5.2 Backplane maintainer

Needs precise request correlation, error categories, trace IDs, and implementation-level child calls when reviewing defects.

### 5.3 Coding agent

Needs a stable schema, bounded work packages, exact acceptance criteria, and deterministic tests when implementing or reviewing changes.

### 5.4 Security reviewer

Needs evidence that credentials and sensitive content are excluded or redacted, and that audit data is distinct from diagnostic data.

## 6. Primary User Workflows

### 6.1 Investigate an LLM request

1. Open Logs → LLM Proxy.
2. Filter by request ID, client, provider, model, outcome, or time.
3. Open the request.
4. Inspect requested/resolved model, provider route, HTTP status, timings, stream state, tokens, and normalized error.
5. Copy the trace ID to correlate runtime diagnostics or related agent work.

### 6.2 Investigate an MCP failure

1. Open Logs → MCP Proxy.
2. Filter by client, method, tool, upstream, protocol version, outcome, or time.
3. Open the root request.
4. Inspect parser/auth/protocol result.
5. Inspect linked tool-call and upstream child records.
6. Determine whether the failure was validation, scope, cache, timeout, upstream protocol, connection, or internal execution.

### 6.3 Review usage

1. Open LLM Usage or MCP Usage.
2. Select a time range.
3. Review request count, error rate, latency, model/tool/provider/upstream breakdown, and token usage.
4. Drill into matching access records.

### 6.4 Review observability health

1. Open Logs → Sinks.
2. Review queue depth, persistence lag, dropped events, writer failures, last successful flush, and retention status.
3. Identify the affected domain without impacting other domains.

### 6.5 Review payload policy

1. Open observability settings.
2. Confirm payload mode per domain.
3. Verify that the request detail page reports “not captured,” “hash only,” or a controlled payload reference.
4. Confirm payload expiration where capture is enabled.

## 7. MVP Scope

The MVP includes:

- Common event/correlation contract.
- LLM root access records.
- MCP root access records.
- MCP tool-call child records.
- Domain writers and self-metrics.
- Shared credential redaction and content minimization.
- Domain retention.
- Admin overview, list, filters, and detail pages.
- Historical usage backed by durable records.
- Legacy compatibility and staged cleanup.

The MVP implements payload modes `none` and `hash`. Encrypted sampled/full payload capture is a post-MVP extension.

## 8. Functional Requirements

### FR-1 — Common request correlation

The system must assign:

- `request_id`
- `trace_id`
- root `span_id`

before LLM/MCP domain execution.

Child tool/provider/upstream operations must retain the same trace ID and have their own span IDs.

Acceptance:

- A request detail page displays request ID and trace ID.
- Every MCP tool row links to one MCP root row.
- A trace ID query returns all matching durable domain records.

### FR-2 — One root access record per operation

The system must persist one root record for:

- LLM API request.
- MCP JSON-RPC request.
- MCP SSE stream lifecycle.
- MCP session deletion.

The record is finalized at operation completion or exception.

Acceptance:

- A successful request creates one row.
- A rejected request creates one row.
- A duplicate terminal event does not create a second row.
- Start events do not create root database rows.

### FR-3 — LLM request coverage

The LLM record must support:

- OpenAI-compatible endpoints.
- Anthropic Messages endpoint.
- Embeddings.
- Catch-all `/v1/*` forwarding.
- Streaming and non-streaming.
- Model aliases/automatic routing.
- Provider API selection.
- Credential/rate-limit/validation/upstream failures.

Required display fields:

```text
time
request_id
trace_id
client
operation/API surface
requested model
resolved model
provider
status/outcome
duration
TTFT when available
input/output/total tokens
error category
```

### FR-4 — MCP request coverage

The MCP root record must support:

- Modern and legacy protocol eras.
- Streamable HTTP POST.
- Legacy SSE GET lifecycle.
- Session DELETE.
- Malformed body.
- Request-too-large.
- Rate limit.
- Auth/scope rejection.
- Protocol validation error.
- JSON-RPC success/error.
- Internal callback failure.

Required display fields:

```text
time
request_id
trace_id
operation
JSON-RPC ID
method
protocol version
era
transport
session
client
auth kind
HTTP status
JSON-RPC error code
duration
outcome/error category
```

### FR-5 — MCP tool-call child records

For `tools/call`, the system must record:

```text
tool name
namespace
execution kind
original upstream tool name
upstream name/prefix
upstream transport/version
cache status
timeout
attempt count
duration
outcome/error category
argument hash
```

Arguments and results must not be stored in the access table.

### FR-6 — Runtime diagnostic sink

The system must continue emitting runtime diagnostics through Elixir Logger.

Runtime messages must:

- Carry domain and correlation metadata.
- Avoid duplicate access messages.
- Apply shared credential redaction.
- Avoid unrestricted payload inspection.
- Remain available before database startup.

### FR-7 — Domain writer isolation

LLM and MCP persistence must use separate supervised writers or independent writer lanes.

Each writer must expose:

- Queue depth.
- Accepted count.
- Persisted count.
- Duplicate count.
- Dropped count.
- Failure/retry count.
- Persistence lag.
- Last successful flush.

### FR-8 — Non-blocking request path

The request process must not perform observability database or file I/O.

Acceptance:

- Telemetry callbacks do not call `Repo`, Oban insertion, file write, or network I/O.
- Writer outage does not change the proxy response.
- Queue full behavior is immediate and measurable.

### FR-9 — Idempotent persistence

Each terminal record must contain `event_id` with a unique database constraint.

Retries and duplicate deliveries must use `on_conflict: :nothing` or equivalent deterministic conflict handling.

### FR-10 — Privacy and redaction

The system must redact credentials in:

- Headers.
- maps/keyword lists.
- JSON strings.
- form data.
- embedded Basic/Bearer values.
- normalized error messages.

The system must classify the following as payload:

- LLM messages/prompts/input/content.
- MCP arguments/results/resource content.
- Raw provider/upstream request and response.
- Cookies and auth material.

Default behavior is metadata-only.

### FR-11 — Payload hash mode

When `payload_mode = hash`, the system stores:

- Byte count.
- Deterministic content hash.
- Truncation indicator where applicable.

It does not store content.

### FR-12 — Independent policy

The operator can configure LLM and MCP independently:

```text
enabled
persist
retention_days
payload_mode
sample_rate
writer queue/batch overrides
```

Operational settings are stored in `system_settings`.

### FR-13 — Retention

Retention jobs must:

- Run on a configured schedule.
- Delete in bounded batches.
- Continue until the current cutoff is complete.
- Publish deleted counts and status.
- Never execute in the request path.

Default retention:

- LLM proxy: 90 days.
- MCP proxy/tool calls: 30 days.
- Audit: 180 days.
- Payload: 7 days when enabled.

### FR-14 — Logs navigation

The Logs product area must provide:

```text
Overview
LLM Proxy
MCP Proxy
Audit
Background Jobs
Sinks
```

Runtime file contents are not read through the web UI.

### FR-15 — Filtering and pagination

LLM filters:

```text
time
request_id
trace_id
client
provider
API surface
requested/resolved model
stream
status
outcome
```

MCP filters:

```text
time
request_id
trace_id
client
operation
method
tool
upstream
transport
protocol version
era
outcome
```

Lists use keyset pagination and a bounded default time range.

### FR-16 — Request detail timeline

LLM detail shows:

```text
ingress
route decision
provider/upstream
first chunk
stream completion
usage
final outcome
```

MCP detail shows:

```text
ingress
protocol/auth result
tool dispatch
cache result
upstream call
final JSON-RPC result
```

The timeline may combine durable root/child records with available trace events. It must clearly label non-durable runtime-only events.

### FR-17 — Durable usage dashboards

LLM usage reads the durable LLM access model.

MCP historical usage reads durable MCP request/tool records rather than only process-local ETS counters.

ETS remains the source for current-process health values.

### FR-18 — Compatibility

During rollout:

- Existing LLM usage query callers continue to work through a compatibility facade.
- Existing runtime telemetry configuration maps to the new runtime sink.
- Existing tool and skill audit tables remain queryable.
- `backplane_mcp_protocol` remains independently buildable.

### FR-19 — Observability health alerting

The admin overview must visually flag:

- Root access-record drops.
- Sustained writer failures.
- Persistence lag above configured threshold.
- Queue capacity above threshold.
- Retention worker failures.
- Redaction failures.

### FR-20 — Export and identifiers

List/detail pages must make it easy to copy:

- Request ID.
- Trace ID.
- Record ID.
- Provider/upstream request ID when present.

A generic bulk export is not required in the MVP.

## 9. Admin UX Requirements

### 9.1 Overview

Required cards:

- LLM requests/error rate.
- MCP requests/error rate.
- LLM p95 duration/TTFT.
- MCP p95 duration/tool duration.
- Writer health summary.
- Root dropped-record count.
- Last retention result.

Required tables:

- Slowest providers.
- Failing MCP upstreams.
- Top models.
- Top tools.
- Recent critical failures.

### 9.2 LLM list

Columns:

```text
time
client
requested → resolved model
provider
status/outcome
stream
duration
tokens
```

Default sort: newest first.

### 9.3 MCP list

Columns:

```text
time
client
method/operation
tool
upstream
protocol
outcome
duration
```

Default sort: newest first.

### 9.4 Detail pages

Detail pages must:

- Avoid rendering raw payload by default.
- Bound error text.
- Display a “payload not captured” status.
- Link root and child records.
- Preserve filter/back navigation.
- Render times through the existing local-time component.
- Use `phoenix_duskmoon` components and current Backplane UI conventions.

## 10. Security and Privacy Requirements

### SEC-1

No authorization header, cookie, API key, credential, client secret, token, or code verifier may be persisted or rendered.

### SEC-2

No prompt, message, tool argument, tool result, or resource content is persisted under default settings.

### SEC-3

Hashes must be deterministic only for the same configured hashing version and must not use a secret as an identifier in logs.

### SEC-4

Error messages must be redacted and size-bounded before enqueue.

### SEC-5

Payload capture, when later implemented, must be encrypted, explicitly enabled, separately retained, and visibly marked.

### SEC-6

Access records and audit records must not be silently merged. Audit retention may be longer.

### SEC-7

Admin UI queries must use domain query APIs and must not expose unrestricted JSON metadata.

## 11. Non-Functional Requirements

### NFR-1 — Availability

A sink, writer, retention, or metrics failure must not alter the LLM/MCP protocol response.

### NFR-2 — Request-path overhead

Event construction and enqueue must perform no database/file/network I/O.

The added p95 CPU time for root event creation/enqueue should remain below 1 ms in repository load tests.

### NFR-3 — Bounded resources

Every writer has a configured capacity. No observability component may rely on an unbounded mailbox or unbounded payload encoding.

### NFR-4 — Persistence freshness

Under normal load and healthy PostgreSQL, 95% of accepted root terminal events should be queryable within 5 seconds.

### NFR-5 — Isolation

A failure or overload in one domain writer must not restart another domain writer.

### NFR-6 — Idempotency

Repeated delivery of the same event ID creates no duplicate access record.

### NFR-7 — Query performance

With the default bounded time range, list pages should render without full-table scans. Required filters must have supporting indexes.

### NFR-8 — Upgrade safety

Migrations must preserve existing `llm_logs`, `tool_call_log`, and `skill_load_log` data.

### NFR-9 — Independent protocol package

`apps/backplane_mcp_protocol` tests and packaging must pass without Ecto/Postgrex or Backplane domain persistence dependencies.

### NFR-10 — Testability

All writers, clocks, ID generation, and persistence boundaries must support deterministic test doubles or dependency injection consistent with existing functional module patterns.

## 12. Data and Index Requirements

### LLM

Required unique/index coverage:

```text
unique(event_id)
inserted_at
trace_id
request_id
client_id + inserted_at
provider_id + inserted_at
requested_model + inserted_at
resolved_model + inserted_at
api_surface + inserted_at
outcome + inserted_at
```

### MCP root

```text
unique(event_id)
inserted_at
trace_id
request_id
client_id + inserted_at
rpc_method + inserted_at
protocol_version + inserted_at
outcome + inserted_at
session_id + inserted_at
```

### MCP tool

```text
unique(event_id)
mcp_request_id
trace_id
tool_name + inserted_at
upstream_name + inserted_at
outcome + inserted_at
```

Indexes must be validated against actual query plans before adding redundant combinations.

## 13. Acceptance Scenarios

### AC-1 — Successful OpenAI-compatible request

Given a valid client and provider, when a non-stream chat request completes, one LLM root row contains requested/resolved model, provider, status, duration, bytes, and usage.

### AC-2 — Early LLM rejection

Given an unknown model, when routing rejects the request before an upstream call, one LLM root row has `outcome = error` and `error_kind = routing`.

### AC-3 — Streaming LLM request

Given a streaming provider response, when the stream completes, one row contains total duration, TTFT when observed, stream state, chunk count, and tokens when supplied by the provider.

### AC-4 — Malformed MCP request

Given malformed JSON, when `/mcp` returns a parse error, one MCP root row exists even though no Dispatch call occurred.

### AC-5 — MCP local tool success

Given `tools/call` for a local tool, one MCP root row and one linked tool row are created. No raw arguments or result are stored.

### AC-6 — MCP upstream timeout

Given an upstream tool timeout, the child row identifies the upstream, timeout, duration, and normalized timeout error; the root row identifies the final JSON-RPC outcome.

### AC-7 — Cache hit

Given a cacheable tool call already in cache, the child record reports `cache_status = hit` and no upstream child call is required.

### AC-8 — Duplicate event

Given the same terminal event delivered twice, only one database row exists and the duplicate metric increments.

### AC-9 — Writer outage

Given the MCP writer is stopped or PostgreSQL is unavailable, MCP protocol behavior remains correct and the writer health state becomes unhealthy.

### AC-10 — Privacy default

Given prompts, messages, tool arguments, and tool results, none of their content appears in the access tables, Logger output, or admin page under default settings.

### AC-11 — Domain isolation

Given MCP writer overload, LLM writer queue depth and persistence continue normally.

### AC-12 — Retention

Given rows older than the configured cutoff, the retention worker deletes bounded pages and records its outcome without a long request-path transaction.

### AC-13 — Restart

Given the admin endpoint restarts, existing LLM/MCP history remains visible. Only explicitly transient runtime events may be absent.

### AC-14 — Protocol package independence

Given the standalone MCP protocol app test/package task, it succeeds without loading Backplane Repo.

## 14. Success Metrics

The release is successful when:

- Durable root records match proxy request counters within documented drop/error conditions.
- Duplicate runtime access messages are removed.
- Root access-record drop count remains zero in normal operation.
- No sensitive payload regression is found in automated redaction tests.
- MCP historical usage survives application restart.
- Operators can identify provider/upstream/tool failure from one request detail page.
- Retention executes on schedule and reports bounded deletions.
- `backplane_mcp_protocol` remains independently releasable.

## 15. Rollout Requirements

### Release stage 1

- Event contract and context behind feature flag.
- V2 writers enabled in test/development.
- Legacy reads/writes retained.

### Release stage 2

- Production dual-write.
- Compare counters and persisted rows.
- Validate queue and database behavior.
- Enable new admin pages.

### Release stage 3

- Switch LLM/MCP historical queries to v2 records.
- Disable old LLM usage writer.
- Remove direct MCP request Logger duplication.

### Release stage 4

- Remove catch-all legacy logger and obsolete settings.
- Update AGENTS, CLAUDE, README, operations documentation, and screenshots.

## 16. Open Product Decisions

The following are intentionally deferred and must not block the MVP:

1. Whether the physical `llm_logs` table is renamed after rollout.
2. Whether encrypted payload capture is implemented in the same release.
3. Whether audit tables are later unified into a generic `audit_events` model.
4. Whether external OpenTelemetry export is added.
5. Whether high-volume deployments enable monthly PostgreSQL partitions.
