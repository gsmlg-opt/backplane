# Backplane Observability v2 — Implementation Plan

| Field | Value |
|---|---|
| Status | Ready for task decomposition |
| Repository | `gsmlg-opt/backplane` |
| Baseline | `main@938863b247fc0a42e2c2e181136696e7954c880f` |
| Date | 2026-09-03 |
| Delivery style | Small bounded PRs; LLM and MCP workstreams parallel after the common foundation |

## 1. Implementation Strategy

The implementation must avoid a large cross-umbrella rewrite.

The sequence is:

1. Freeze and test the current contracts.
2. Add common correlation/event/redaction infrastructure without persistence changes.
3. Implement LLM and MCP durable records in parallel.
4. Add policy, retention, self-observability, and admin query surfaces.
5. Switch reads and writes.
6. Remove duplicate legacy paths.

The physical `llm_logs` table remains in place initially. MCP receives new root and child tables. `backplane_mcp_protocol` stays database-independent.

## 2. Workstream Dependency Graph

```text
PR-00 Baseline and contract tests
              │
              ▼
PR-01 Common observability foundation
      ┌───────┼──────────────────────┐
      ▼       ▼                      ▼
PR-02 LLM   PR-03 MCP root        PR-04 Writer policy,
access       access                health, settings
records      records                   │
              │                        │
              ▼                        │
         PR-05 MCP tool/upstream       │
              └─────────┬──────────────┘
                        ▼
                 PR-06 Admin UI and
                 historical aggregates
                        │
                        ▼
                 PR-07 Audit hardening
                 and optional payloads
                        │
                        ▼
                 PR-08 Legacy cleanup
```

After PR-01:

- PR-02 and PR-03 can run in parallel.
- PR-04 can run in parallel with domain implementation once the buffer/event APIs are stable.
- PR-05 depends on the MCP root schema/API from PR-03.
- PR-06 depends on the query models from PR-02, PR-03, and PR-05.
- PR-07 can be split into audit and payload sub-PRs.
- PR-08 is last.

## 3. Cross-Cutting Guardrails

Every PR must preserve these rules:

1. No observability database/file/network I/O in a request-process telemetry callback.
2. No new raw prompt/message/argument/result persistence.
3. No Backplane Repo dependency in `backplane_mcp_protocol`.
4. No universal JSONB logs table.
5. No cross-app test-support dependency.
6. No use of an unbounded logical queue.
7. No observability error may change a proxy response.
8. Every durable writer uses unique `event_id` conflict handling.
9. Every new admin query is exposed through a domain query module.
10. New UI uses `phoenix_duskmoon`.
11. Each PR updates tests before removing compatibility behavior.
12. Commit scopes follow repository conventions, for example `feat(observability):`, `feat(llm):`, `feat(mcp):`, `test(observability):`, and `docs:`.

## 4. PR-00 — Baseline, Inventory, and Contract Tests

### Objective

Create a stable regression baseline before changing event names or persistence.

### Production behavior

No intentional production behavior change.

### Tasks

#### 4.1 Event inventory

Create:

```text
docs/observability/current-event-inventory.md
```

Inventory:

- `[:backplane, :llm, :request]`
- `[:backplane, :mcp_request, :start]`
- tool call start/stop/exception
- SSE stream events
- memory events consumed by Metrics/TelemetryLogger
- host-agent events
- `[:backplane_mcp_protocol, ...]` events
- direct Logger access messages
- PubSub tool events
- database audit/usage writers

For each event, document:

```text
producer
consumers
measurements
metadata
persistence
runtime output
privacy risk
replacement event
```

#### 4.2 Baseline tests

Add or strengthen tests for:

- LLM usage event → existing usage row.
- MCP RequestLogger metadata.
- `Backplane.Telemetry.span_tool_call/2`.
- TelemetryLogger event capture.
- MCP protocol redaction.
- current LogsLive job/tool rendering.
- `DashboardUsageLive` LLM and MCP data sources.

#### 4.3 Test helpers

Each owning app may add local helpers to capture telemetry events synchronously in tests. Do not create a new shared cross-app test-support dependency.

#### 4.4 Feature flags

Add temporary application flags with safe defaults:

```text
observability_v2_enabled
observability_v2_llm_write
observability_v2_mcp_write
observability_v2_runtime_sink
```

Use application configuration in tests. Operational dynamic settings are added in PR-04.

### Likely files

```text
apps/backplane_telemetry/test/*
apps/backplane_llama/test/*
apps/backplane_mcp/test/*
apps/backplane_mcp_protocol/test/*
apps/backplane_admin/test/*
config/test.exs
docs/observability/current-event-inventory.md
```

### Validation

```bash
mix format --check-formatted
mix test apps/backplane_telemetry
mix test apps/backplane_llama
mix test apps/backplane_mcp
mix test apps/backplane_mcp_protocol
mix test apps/backplane_admin
mix test
```

### Exit criteria

- Existing behavior is covered before replacement.
- Inventory identifies every duplicate Logger/telemetry/persistence path.
- No production output changes.

## 5. PR-01 — Common Observability Foundation

### Objective

Introduce the common event envelope, correlation context, redaction contract, bounded enqueue primitive, and runtime sink.

### 5.1 Add public observability modules

Create under `apps/backplane_telemetry/lib/backplane/observability/`:

```text
event.ex
context.ex
context_plug.ex
error.ex
id.ex
redaction.ex
buffer.ex
runtime_sink.ex
sink/logger.ex
sink/jsonl.ex
```

Add the facade:

```text
apps/backplane_telemetry/lib/backplane/observability.ex
```

### 5.2 Event API

The API must support:

```text
new root event
new child span
emit start
emit stop
emit exception
normalize error
sanitize attributes
validate registered domain/phase
```

No public API should require Ecto.

### 5.3 ID generation

Generate:

- 128-bit event IDs.
- trace IDs.
- span IDs.

The generator must:

- Avoid Ecto dependency.
- Be deterministic only in tests through an injectable module/function.
- Use stable string formats.

### 5.4 Context plug

Modify:

```text
apps/backplane_api/lib/backplane/api/endpoint.ex
```

Insert `Backplane.Observability.ContextPlug` after `Plug.RequestId` and before `Backplane.LLM.ProxyPlug`.

The plug must:

- Reuse existing request ID.
- Create/read trace context.
- Assign context to conn.
- Set only bounded scalar Logger metadata.
- Avoid modifying protocol responses.

Add `:backplane_telemetry` dependency to `backplane_api` if not already present.

### 5.5 Redaction

Move common credential/content classification into `Backplane.Observability.Redaction`.

Do not break the standalone MCP protocol package. Use one of these bounded approaches:

- Keep `Backplane.McpProtocol.Logging.Redaction` and delegate to a dependency-free common module only if package dependency rules remain valid.
- Otherwise keep protocol redaction local and add conformance tests that both implementations satisfy the same credential cases.

Do not introduce a dependency from the protocol package to `backplane_system`.

### 5.6 Bounded buffer

Implement a strict capacity reservation before sending an event to a writer.

Required behavior:

- `try_enqueue` returns `:ok` or `{:error, :full | :unavailable}`.
- Capacity counter cannot grow without bound.
- Writer consumption releases capacity.
- Process death cannot leave a permanently unusable counter after restart.
- Overflow is observable.
- Producer never waits for persistence.

### 5.7 Runtime sink

Replace the catch-all logger behavior behind the feature flag with:

- domain-aware event formatting.
- shared redaction.
- Logger metadata.
- optional JSONL runtime sink.
- sink health.

Do not remove the legacy TelemetryLogger yet.

### Tests

Add:

```text
event schema tests
ID format/uniqueness tests
context propagation tests
inbound trace validation tests
redaction property/fixture tests
error normalization tests
buffer capacity/overflow/restart tests
runtime Logger sink tests
JSONL sink failure tests
```

Use StreamData where helpful for arbitrary nested redaction terms.

### Exit criteria

- Both `/v1/*` and `/mcp` receive request and trace IDs.
- No Repo/Oban/file write occurs in event producer callbacks.
- Buffer remains bounded in stress tests.
- Existing proxy behavior remains unchanged.
- Legacy logger can still be enabled for comparison.

## 6. PR-02 — LLM Proxy Access Records

### Objective

Turn the existing `llm_logs` table into the complete logical LLM proxy access record without renaming the physical table.

### 6.1 Migration

Create a new migration under:

```text
apps/backplane_system/priv/repo/migrations/
```

Add missing v2 fields, including:

```text
event_id
trace_id
operation
http_method
path
outcome
error_kind
error_code
upstream_duration_ms
ttft_ms
stream_duration_ms
stream_chunks
cached_tokens
reasoning_tokens
finish_reason
provider_request_id
attempt_count
```

Reuse existing fields where possible:

```text
request_id
client_id
client_ip
api_surface
provider fields
requested_model
resolved_model
status
duration_ms
request_bytes
response_bytes
input_tokens
output_tokens
total_tokens
metadata
```

Add indexes only for defined query paths. Add a unique index on `event_id`.

Do not drop raw request/response columns in this PR.

### 6.2 Logical schema

Create:

```text
apps/backplane_llama/lib/backplane/llm/proxy_request.ex
```

Use `schema "llm_logs"`.

Keep `Backplane.LLM.UsageLog` as a temporary compatibility module or delegate. New code uses `ProxyRequest`.

### 6.3 Writer and query modules

Create:

```text
Backplane.LLM.LogWriter
Backplane.LLM.AccessEvent
Backplane.LLM.LogQuery
```

`LogWriter`:

- Starts under `BackplaneLlama.Application`.
- Uses bounded buffer.
- Batch inserts with `event_id` conflict handling.
- Exposes health/snapshot.
- Applies configured persistence policy.
- Does not store raw payload.

`LogQuery` supports:

- list with keyset pagination.
- get by ID.
- get by request/trace ID.
- aggregate usage.
- percentile-ready duration queries or bounded aggregate helpers.

### 6.4 Instrument all LLM paths

Modify:

```text
apps/backplane_llama/lib/backplane/llm/router.ex
apps/backplane_llama/lib/backplane/llm/model_resolver.ex
apps/backplane_llama/lib/backplane/llm/rate_limiter.ex
apps/relayixir/* only when required for first-byte/chunk callbacks
```

Ensure terminal records for:

- success.
- model extraction error.
- model not found.
- API mismatch.
- rate limit.
- credential error.
- rewrite error.
- upstream timeout/connection/error.
- stream completion/interruption.
- embeddings.

Prefer one root lifecycle state passed through functional transformations rather than scattered map mutation.

### 6.5 Streaming measurements

Extend the current stream usage accumulator or replace it with a bounded request-local accumulator that captures:

```text
first_chunk_monotonic_time
chunk_count
input_tokens
output_tokens
cached/reasoning tokens when supported
finish_reason
provider_request_id
```

The accumulator must be stopped/cleaned on every terminal path.

### 6.6 Remove request-process Oban insertion

Stop using `UsageCollector` to call `Oban.insert` from the synchronous telemetry handler.

Do not delete the old modules yet. Disable them behind the write switch.

Move collector attachment out of:

```text
apps/backplane/lib/backplane/application.ex
```

and into the LLM app's own supervision/initialization.

### 6.7 Compatibility query

Change `Backplane.LLM.UsageQuery` to delegate to `LogQuery.aggregate/1` while preserving the existing return shape used by `DashboardUsageLive`.

### Tests

Required cases:

```text
OpenAI non-stream success
Anthropic non-stream success
embedding success
unknown model
API surface mismatch
rate limited
missing credential
upstream 4xx/5xx
connection failure
timeout
stream success
stream without provider usage
stream disconnect
Codex compatibility path
Moonshot compatibility path
event duplicate
writer database failure
payload absence
```

### Exit criteria

- Every LLM terminal branch produces one v2 root row.
- Existing usage dashboard remains functional.
- Raw request/response fields are not populated by v2.
- No per-request Oban usage job is inserted when v2 is active.
- Writer failure does not alter the proxy response.

## 7. PR-03 — MCP Root Access Records

### Objective

Create durable MCP root operations and replace the direct request Logger path.

### 7.1 Migration and schema

Create:

```text
mcp_proxy_requests
```

with the fields and indexes defined in the design document.

Create:

```text
apps/backplane_mcp/lib/backplane/mcp/proxy_request.ex
apps/backplane_mcp/lib/backplane/mcp/log_query.ex
apps/backplane_mcp/lib/backplane/mcp/log_writer.ex
apps/backplane_mcp/lib/backplane/mcp/access_event.ex
```

### 7.2 Root finalizer

Replace or refactor:

```text
apps/backplane_mcp/lib/backplane/transport/request_logger.ex
```

Suggested target:

```text
Backplane.Transport.McpObservability
```

Responsibilities:

- Start root event before rate limit/auth/parser/dispatch.
- Register response finalization.
- Measure total duration.
- Capture request and response sizes without content.
- Extract operation and JSON-RPC method/ID when available.
- Read protocol version/era/session/client/auth assigns.
- Parse final JSON-RPC error code from a bounded response envelope when available.
- Finalize malformed, request-too-large, auth, rate-limit, and protocol failures.
- Emit runtime access messages only through the v2 runtime sink.

### 7.3 MCP Plug integration

Modify:

```text
apps/backplane_mcp/lib/backplane/transport/mcp_plug.ex
```

Place the root recorder early enough to observe all terminal paths.

Cover:

```text
POST JSON-RPC
GET SSE open/close
DELETE session
HEAD short-circuit where policy requires a runtime event only
parser rescue paths
```

A HEAD health probe does not require a durable MCP logical request row unless product policy explicitly enables transport access records for probes.

### 7.4 Context enrichment

Use existing assigns and modern request context fields. Do not add database behavior to the protocol executor.

Where the generic protocol package returns an envelope, the Backplane transport layer extracts only bounded result metadata.

### 7.5 Runtime duplicate removal

When the v2 MCP root recorder is active:

- `RequestLogger` no longer calls Logger directly.
- `Backplane.Telemetry.emit_mcp_request/2` no longer creates a second direct access message.
- Protocol debug logging remains independently configurable.

Keep compatibility switches until PR-08.

### Tests

Required cases:

```text
legacy initialize
modern request
tools/list
tools/call success
method not found
invalid params
insufficient scope
malformed JSON
request too large
rate limit
auth failure
callback failure
SSE connect/disconnect
session DELETE
duplicate event
writer outage
no raw body persistence
```

### Exit criteria

- Durable MCP request history survives restart.
- One root row exists for each covered operation.
- Historical MCP usage can be computed from the table.
- Direct duplicate MCP request Logger output is disabled under v2.
- Protocol-package independence is preserved.

## 8. PR-04 — Writer Policy, Settings, and Self-Observability

### Objective

Make domain writers dynamically configurable and operationally visible.

### 8.1 Settings keys and defaults

Add typed accessors in `Backplane.Settings` or a dedicated context:

```text
Backplane.Observability.Settings
```

Keys:

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

Rules:

- Safe defaults if Settings is unavailable.
- Invalid values retain the last valid configuration.
- Dynamic changes are broadcast through PubSub or the existing settings update mechanism.
- Domain writers apply changes without restart where safe.

### 8.2 Writer health API

Expose:

```text
Backplane.LLM.LogWriter.health/0
Backplane.MCP.LogWriter.health/0
Backplane.Observability.health/0
```

Return bounded maps suitable for admin rendering.

### 8.3 Metrics integration

Update:

```text
apps/backplane_system/lib/backplane/metrics.ex
```

Attach to v2 events and writer events. Keep compatibility counters during dual-write.

### 8.4 Runtime sink bootstrap

Keep boot-critical Logger configuration in application/runtime environment config.

Map legacy telemetry options to the runtime sink for one release. Do not add new operational sections to `backplane.toml.example`.

### 8.5 Retention scheduling foundation

Add Oban queues only if needed; prefer existing `default`, `llm`, or a clear `observability` queue.

Add Cron entries for enabled retention workers in root config. Ensure existing audit/LLM retention workers that were previously unscheduled are either replaced or explicitly scheduled.

### Tests

```text
default settings
dynamic update
invalid setting rollback
writer batch/flush update
queue capacity update
health snapshot
metrics increments
legacy config mapping
settings unavailable at boot
```

### Exit criteria

- LLM/MCP policy changes independently.
- Writer health is queryable.
- Root drop and persistence-lag metrics exist.
- TOML remains boot-only.
- Legacy runtime config is supported but deprecated.

## 9. PR-05 — MCP Tool and Upstream Child Records

### Objective

Create durable child records for tool dispatch and upstream execution, linked to the root MCP request.

### 9.1 Migration and schema

Create:

```text
mcp_tool_calls
```

Create:

```text
apps/backplane_mcp/lib/backplane/mcp/tool_call.ex
```

Add unique/index constraints from the design.

### 9.2 Tool span

Refactor:

```text
apps/backplane_system/lib/backplane/telemetry.ex
apps/backplane_mcp/lib/backplane/mcp/dispatch.ex
```

Move MCP tool access instrumentation into the MCP domain.

The root Dispatch call must receive explicit observability context. Do not depend solely on Logger metadata.

Record:

```text
tool name/namespace
execution kind
argument hash
cache status
timeout
duration
outcome/error
```

### 9.3 Upstream span

Modify:

```text
apps/backplane_mcp/lib/backplane/proxy/upstream.ex
```

Record:

```text
upstream name/prefix
transport
negotiated protocol version
original tool name
timeout
duration
connection/protocol outcome
attempt count
```

The upstream GenServer call must receive the parent context with the tool call request.

### 9.4 Cache classification

Modify the Dispatch/cache path to return or annotate:

```text
hit
miss
bypass
```

Do not create a separate durable cache-event table.

### 9.5 Audit bridge

Continue writing existing `tool_call_log` according to audit policy.

Add trace/root identifiers to audit records only through a backward-compatible migration if required. Do not replace audit records with access records.

### Tests

```text
native tool success/crash
managed tool success/error
upstream tool success
upstream protocol error
upstream connection error
upstream timeout
cache hit/miss/bypass
unknown tool
scope rejection
argument validation rejection
duplicate child event
root/child linkage
no argument/result content
```

### Exit criteria

- Every executed `tools/call` has one linked child record.
- Upstream details are present when applicable.
- Cache behavior is visible.
- Existing tool audit behavior remains available.
- Tool instrumentation no longer writes a duplicate direct access Logger message.

## 10. PR-06 — Admin Logs and Historical Usage

### Objective

Replace the current limited Logs page with domain-separated durable views and switch historical usage to database query models.

### 10.1 Routes

Update:

```text
apps/backplane_admin/lib/backplane/admin/router.ex
```

Add:

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

Keep `/system/logs` as overview or redirect.

### 10.2 LiveViews

Create bounded LiveViews/components, for example:

```text
logs_overview_live.ex
logs_llm_live.ex
logs_mcp_live.ex
logs_audit_live.ex
logs_jobs_live.ex
logs_sinks_live.ex
logs_components.ex
```

Do not keep all behavior in one enlarged `LogsLive`.

### 10.3 LLM query UI

Use `Backplane.LLM.LogQuery`.

Implement:

- default bounded time range.
- filters.
- keyset pagination.
- detail page.
- trace/request copy controls.
- payload status.
- error display with bounded text.

### 10.4 MCP query UI

Use `Backplane.MCP.LogQuery`.

Implement:

- root list.
- tool/upstream filter.
- detail timeline.
- child table.
- protocol/session/auth metadata.
- no raw arguments/results.

### 10.5 Jobs and audit

Move existing Oban job view into the Jobs route.

Query existing tool/skill audit tables through `Backplane.Audit` query functions rather than raw LiveView Ecto where possible.

Transient PubSub events may remain as a small “live activity” panel, clearly marked non-durable. They are not the primary Tool Calls tab.

### 10.6 Usage dashboards

Modify:

```text
apps/backplane_admin/lib/backplane/admin/live/dashboard_usage_live.ex
```

- LLM historical usage delegates to `Backplane.LLM.LogQuery`.
- MCP historical usage delegates to `Backplane.MCP.LogQuery`.
- Current writer/queue/system health may still use `Backplane.Metrics`.

### 10.7 UI requirements

- Use `phoenix_duskmoon`.
- Use existing local-time component.
- Provide loading/empty/error states.
- Avoid unrestricted metadata rendering.
- Add screenshots to the PR.

### Tests

```text
route tests
filter parsing
keyset pagination
LLM list/detail
MCP list/detail
root/child timeline
audit/jobs pages
sink health page
empty/error states
payload hidden
local time rendering
```

### Exit criteria

- Admin restart does not erase LLM/MCP history.
- Operators can inspect LLM and MCP independently.
- Historical MCP usage no longer depends only on ETS.
- Existing jobs functionality is preserved in a dedicated page.

## 11. PR-07A — Audit Writer Hardening

### Objective

Replace fire-and-forget audit `Task.start` writes with a supervised, observable, idempotent writer.

### Tasks

Modify:

```text
apps/backplane_system/lib/backplane/audit.ex
```

Create:

```text
Backplane.Audit.Writer
```

Requirements:

- Supervised under `BackplaneSystem.Application`.
- Bounded queue.
- Unique audit event ID.
- Batch or controlled inserts.
- Health metrics.
- Controlled-shutdown drain.
- Existing synchronous test APIs retained or replaced with explicit test persistence helpers.

Add optional correlation fields:

```text
event_id
request_id
trace_id
mcp_request_id
```

Preserve existing data and table semantics.

### Tests

```text
tool audit
skill audit
duplicate audit
writer restart
database failure
queue overflow
correlation fields
argument hash only
```

### Exit criteria

- No naked fire-and-forget `Task.start` audit write remains.
- Audit is still independent from MCP access records.
- Audit retention is scheduled.

## 12. PR-07B — Optional Payload Artifact Store

### Objective

Implement encrypted payload capture only if it remains in the selected release scope.

This PR may be deferred without blocking Observability v2 MVP.

### Tasks

Create migration/table:

```text
proxy_payloads
```

Create:

```text
Backplane.Observability.PayloadPolicy
Backplane.Observability.PayloadWriter
Backplane.Observability.Payload
```

Requirements:

- Disabled by default.
- `none`, `hash`, `sampled`, `full` policy.
- Encryption at rest.
- Strict max bytes.
- Redaction before encryption where policy requires.
- Short independent retention.
- Access control and explicit warning in admin UI.
- No payload in Logger.

### Exit criteria

- Default deployment stores no payload.
- Enabled capture is encrypted and expires.
- Access record contains reference only.

## 13. PR-08 — Legacy Cleanup and Documentation

### Objective

Remove duplicate paths after v2 write/read switches have been validated.

### 13.1 Remove or retire legacy modules

Candidates:

```text
BackplaneTelemetry.TelemetryLogger
Backplane.LLM.UsageCollector
Backplane.Jobs.UsageWriter
Backplane.Transport.RequestLogger
duplicate Logger calls in Backplane.Telemetry
legacy event formatters/tests
```

Do not remove `UsageQuery` if an external/internal caller still needs its compatibility facade.

### 13.2 Event migration

- Stop emitting legacy LLM/MCP event names after all consumers move.
- Keep memory/skills/host-agent legacy names until their own domain migration.
- Remove compatibility adapters only when no test or runtime consumer remains.

### 13.3 Configuration cleanup

- Remove deprecated legacy runtime telemetry mapping after one documented compatibility release.
- Remove stale TOML parsing paths for operational telemetry only when consistent with the broader config cleanup.
- Keep boot Logger configuration.

### 13.4 Documentation

Update:

```text
AGENTS.md
CLAUDE.md
README.md
config documentation
admin navigation documentation
operations/runbook
database schema documentation
```

Correct outdated references such as old app ownership or old LLM usage table names while preserving actual physical-table notes.

### 13.5 Validation

```bash
mix format --check-formatted
mix credo --strict
mix dialyzer
mix test
```

Run focused load tests:

```text
LLM terminal event burst
MCP request burst
MCP tool-call burst
writer database outage/recovery
queue overflow
controlled shutdown drain
redaction fixture corpus
```

### Exit criteria

- One runtime access message per configured policy.
- No legacy per-request Oban usage job.
- No catch-all all-domain logger process.
- Full umbrella tests pass.
- Standalone MCP protocol app tests/package pass.
- Documentation matches the final supervision and data model.

## 14. Migration Plan

### Migration 1 — LLM v2 columns

- Alter `llm_logs`.
- Backfill `event_id` for existing rows only if required for uniform query behavior.
- Existing rows may have `trace_id = nil`.
- Do not synthesize provider/model fields not present in historical rows.
- Add indexes concurrently only if deployment migration policy supports it; otherwise document expected lock behavior.

### Migration 2 — MCP root

- Create `mcp_proxy_requests`.
- Add indexes.
- No historical backfill is possible because no equivalent root record exists.

### Migration 3 — MCP tool

- Create `mcp_tool_calls`.
- Existing `tool_call_log` remains audit and is not copied automatically unless a separate one-time migration has a clear product need.

### Migration 4 — Audit correlation

- Add event/correlation fields without dropping old rows.
- Existing rows remain valid with nullable IDs.

### Migration 5 — Payload

- Optional and independent.

### Rollback rules

- Feature flags can disable v2 writers while retaining schemas.
- Migrations are additive until PR-08.
- Do not drop legacy columns/tables in the same release that switches writes.
- Read compatibility remains until production validation is complete.

## 15. Test Matrix

| Area | Unit | Integration | Failure | Privacy | Load |
|---|---:|---:|---:|---:|---:|
| Event/context | Yes | Endpoint | Invalid trace | Metadata bounds | ID/enqueue burst |
| Redaction | Yes | Logger/DB | Encoding failure | Required | Nested term corpus |
| LLM root | Yes | Proxy/provider | Route/upstream/stream | No payload | Terminal burst |
| MCP root | Yes | Plug/protocol | Parse/auth/callback | No body | Request burst |
| MCP tool | Yes | Dispatch/upstream | timeout/connection | Hash only | Tool burst |
| Writer | Yes | Repo | outage/restart/full | fallback redaction | queue/flush |
| Retention | Yes | Oban/Repo | partial failure | payload expiry | large bounded pages |
| Admin | Component | LiveView | query unavailable | hidden content | pagination |
| Protocol package | Existing | Standalone | Existing | Redaction | Existing |

## 16. Load and Failure Qualification

Before write switch, qualify:

### 16.1 Healthy database

Measure:

- request-path enqueue CPU time.
- accepted-to-persisted lag.
- batch sizes.
- queue depth.
- database transaction rate.
- root/child record count.

### 16.2 Database outage

Verify:

- proxy responses remain correct.
- retry batch remains bounded.
- failure count increments.
- recovery drains the retained batch.
- no duplicate rows after recovery.

### 16.3 Writer crash

Verify:

- only the domain writer restarts.
- other domains continue.
- capacity state resets safely.
- health reports restart/failure.

### 16.4 Queue overflow

Verify:

- low-priority events drop first.
- root drop metric is explicit.
- no unbounded mailbox growth.
- runtime error is rate limited.

### 16.5 Shutdown

Verify:

- controlled shutdown requests writer drain.
- drain timeout is bounded.
- proxy shutdown cannot hang indefinitely.

## 17. Review Checklist for Every PR

### Architecture

- Does ownership remain in the correct umbrella app?
- Is the protocol package still independent?
- Is context passed explicitly across process boundaries?
- Does the change add a duplicate source of truth?

### Performance

- Is there any Repo, Oban insert, file write, or network I/O in a telemetry callback?
- Is every queue bounded?
- Are payloads and errors byte-bounded?
- Are database writes batched?

### Privacy

- Could any prompt, message, argument, result, resource, header, cookie, or credential enter Logger/DB?
- Is redaction applied before enqueue?
- Does fallback behavior redact rather than expose?

### Data

- Is `event_id` unique?
- Is retry idempotent?
- Are indexes tied to actual queries?
- Is historical data preserved?

### Tests

- Is every terminal branch tested?
- Are writer outage and overflow tested?
- Are duplicate events tested?
- Are standalone MCP protocol tests run?

### UI

- Are queries delegated to domain modules?
- Is pagination keyset-based?
- Is metadata bounded?
- Are screenshots included?

## 18. Final Definition of Done

Observability v2 is complete when all of the following are true:

1. LLM and MCP requests receive shared request/trace context at ingress.
2. Every covered operation produces one durable root access record.
3. MCP tool calls and upstream calls link to the root request.
4. LLM records cover early rejection, upstream failure, and stream completion.
5. No raw LLM/MCP payload is persisted under default policy.
6. LLM and MCP writers are bounded, independent, supervised, and observable.
7. Persistence is idempotent.
8. Historical LLM and MCP usage uses durable records.
9. Logs UI is separated by domain.
10. Retention jobs are scheduled and bounded.
11. Audit writes are supervised.
12. Duplicate direct access Logger paths are removed.
13. `backplane_mcp_protocol` remains standalone.
14. Full format, test, Credo, and Dialyzer validation passes.
15. AGENTS/CLAUDE/README and operational documentation match implementation.
