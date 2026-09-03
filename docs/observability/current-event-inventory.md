# Current Observability Event Inventory

| Field | Value |
|---|---|
| Status | Baseline for Observability v2 PR-00 |
| Repository | `gsmlg-opt/backplane` |
| Baseline | `main@938863b247fc0a42e2c2e181136696e7954c880f` |
| Date | 2026-09-03 |
| Purpose | Freeze and document every duplicate Logger/telemetry/persistence path before replacement |

Replacement event names refer to the Observability v2 contract in
`backplane-observability-v2-design.md`. Legacy names remain valid until PR-08 cleanup.

---

## 1. LLM proxy

### `[:backplane, :llm, :request]`

| Field | Value |
|---|---|
| Producer | `Backplane.LLM.Router` (`emit_telemetry/4`) in `apps/backplane_llama/lib/backplane/llm/router.ex` |
| Consumers | `Backplane.LLM.UsageCollector` → Oban `Backplane.Jobs.UsageWriter`; `BackplaneTelemetry.TelemetryLogger` |
| Measurements | `latency_ms`, `system_time` |
| Metadata | `provider_id`, `model`, `status`, `stream`, `input_tokens`, `output_tokens`, `client_ip`, `error_reason` |
| Persistence | PostgreSQL `llm_logs` via one Oban job per event (`queue: :llm`) |
| Runtime output | TelemetryLogger human/JSONL when enabled |
| Privacy risk | Metadata only today; schema has unused `raw_request`/`raw_response` columns that must stay unpopulated by default |
| Replacement event | `backplane.llm_proxy.request.stop` / `.exception` (terminal projection) |

Notes:

- Collector attaches from root `Backplane.Application`, not `BackplaneLlama.Application`.
- Active `UsageLog` schema writes a subset of the physical table columns.
- Early route rejections and some streaming failure paths may not emit this event.
- `UsageRetention` exists but is not registered in Oban cron.

### Direct LLM Logger access messages

| Field | Value |
|---|---|
| Producer | None dedicated beyond TelemetryLogger formatting of the LLM event |
| Consumers | Elixir Logger |
| Persistence | None |
| Privacy risk | TelemetryLogger sanitizes for JSON compatibility only; no credential redaction |
| Replacement event | Runtime sink formatting of LLM access events |

---

## 2. MCP request and tool call

### `[:backplane, :mcp_request, :start]`

| Field | Value |
|---|---|
| Producer | `Backplane.Telemetry.emit_mcp_request/2`; callers in MCP handler paths |
| Consumers | `Backplane.Metrics` (ETS); `BackplaneTelemetry.TelemetryLogger`; direct `Logger.info` in `emit_mcp_request/2` |
| Measurements | `system_time` |
| Metadata | `method` plus optional caller metadata |
| Persistence | None (ETS counters only) |
| Runtime output | Duplicate: TelemetryLogger + direct Logger.info `"MCP request"` |
| Privacy risk | Method name only; no body |
| Replacement event | `backplane.mcp_proxy.request.start` / terminal `.stop` / `.exception` |

### `[:backplane, :tool_call, :start \| :stop \| :exception]`

| Field | Value |
|---|---|
| Producer | `Backplane.Telemetry.span_tool_call/2`; caller `Backplane.MCP.Dispatch.call_tool/3` |
| Consumers | Metrics (all phases); TelemetryLogger (stop/exception only); direct Logger.info/error in `span_tool_call/2` |
| Measurements | `system_time` (start); `duration` (stop/exception) |
| Metadata | `tool`, `request_id` (from Logger metadata); stop adds `result`; exception adds `kind`, `reason` |
| Persistence | None on this path. `Backplane.Audit.log_tool_call/1` → `tool_call_log` exists but has **no production caller** |
| Runtime output | Duplicate: TelemetryLogger + direct Logger access messages |
| Privacy risk | Exception `reason` may carry exception structs; arguments/results are not in telemetry metadata today |
| Replacement event | `backplane.mcp_proxy.tool_call.start\|stop\|exception` |

### `[:backplane, :sse_stream, :start \| :stop]`

| Field | Value |
|---|---|
| Producer | `Backplane.Telemetry.emit_sse_start/1`, `emit_sse_stop/2`; MCP handler SSE paths |
| Consumers | `Backplane.Metrics` only |
| Measurements | `system_time` / `duration` |
| Metadata | `tool` |
| Persistence | None |
| Runtime output | None via TelemetryLogger |
| Privacy risk | Low |
| Replacement event | Covered by MCP root/session lifecycle events; keep as metrics/trace |

### `Backplane.Transport.RequestLogger`

| Field | Value |
|---|---|
| Producer | Plug in `McpPlug` pipeline (`apps/backplane_mcp/lib/backplane/transport/request_logger.ex`) |
| Consumers | Elixir Logger only |
| Measurements | `duration_us` in Logger metadata |
| Metadata | `method`, `path`, `status`, `duration_us`, `remote_ip`, optional `rpc_method` |
| Persistence | None |
| Runtime output | `"MCP <method> - <status> in <ms>ms"` or `"METHOD path - status in ms"` |
| Privacy risk | No body; path/method only |
| Replacement event | `Backplane.Transport.McpObservability` root access recorder + runtime sink |

### PubSub `tools:call`

| Field | Value |
|---|---|
| Producer | `Backplane.MCP.Dispatch` via `PubSubBroadcaster.broadcast_tools_call/2` (`:dispatched`, `:completed`, `:failed`) |
| Consumers | `Backplane.Admin.LogsLive` in-memory ring buffer (cap 100) |
| Persistence | None; lost on LiveView/process restart |
| Runtime output | Admin UI Tool Calls tab |
| Privacy risk | Tool name and failure reason string |
| Replacement event | Durable `mcp_tool_calls` + optional non-durable live panel |

### `tool_call_log` (audit)

| Field | Value |
|---|---|
| Producer | `Backplane.Audit.log_tool_call/1` (API present; **not called from production dispatch**) |
| Consumers | Audit queries/tests |
| Persistence | PostgreSQL `tool_call_log` |
| Privacy risk | Argument hash intended; must not store raw arguments |
| Replacement event | Remains audit; MCP access records are separate |

---

## 3. MCP protocol package

Prefix: `[:backplane_mcp_protocol | …]` via `Backplane.McpProtocol.Telemetry`.

| Event families | Producer areas | Consumers | Persistence | Runtime | Privacy | Replacement |
|---|---|---|---|---|---|---|
| Client init/request/response/terminate/error/notification/roots | Protocol client | None in Backplane Metrics/TelemetryLogger | None | Protocol `Logging` macros (debug) | Metadata redacted before execute | Optional `ProtocolTelemetryAdapter` → metrics/trace only |
| Server init/request/response/notification/error/terminate/tool_call/resource_read/prompt_get | Protocol server/session/executor | None | None | Protocol Logging | Redacted | Same |
| Server session created/terminated/cleanup | Session | None | None | Protocol Logging | Low | `backplane.mcp_proxy.session.*` at Backplane transport layer |
| Transport init/connect/send/receive/disconnect/error/terminate | stdio/sse/websocket/streamable_http | None | None | Protocol Logging | Wire risk if debug logs include payloads | Debug-only; not durable rows |
| Message encode/decode, progress update | Protocol codec/progress | None | None | Protocol Logging | Truncation + redaction | Trace/metrics only |

Redaction owner: `Backplane.McpProtocol.Logging.Redaction` (credential-aware). Independent of TelemetryLogger sanitize.

Constraint: package must remain free of Backplane Repo/admin/domain writer dependencies.

---

## 4. Memory

| Event | Producer | Consumers | Persistence | Runtime | Privacy | Replacement |
|---|---|---|---|---|---|---|
| `[:backplane, :memory, :access, :start\|:stop\|:exception]` | Memory domain spans | TelemetryLogger (stop/exception) | Existing memory models; not universal logs | TelemetryLogger | Domain-specific | Shared envelope + correlation only |
| `[:backplane, :memory, :event, :append\|:duplicate\|:error]` | Event store | Metrics + TelemetryLogger | Memory event store | TelemetryLogger | Content risk if metadata expands | Keep domain ownership |
| `[:backplane, :memory, :pipeline]` | Pipeline telemetry | None in TelemetryLogger/Metrics | Pipeline activity models | None unified | — | Shared correlation later |
| `[:backplane, :memory, :recall, :stage]` | Recall pipeline | None unified | Recall traces | — | — | Shared correlation later |
| `[:backplane, :memory, :crystal, …]` | Crystal worker | None unified | — | — | — | Shared correlation later |
| `[:backplane, :memory, :operation]` | Projection runner | None unified | — | — | — | Shared correlation later |
| Other memory purge/classifier events | Workers | None unified | Domain tables | — | — | Shared correlation later |

Do not duplicate memory into a universal logs table.

---

## 5. Skills and plugins

| Event | Producer | Consumers | Persistence | Runtime | Privacy | Replacement |
|---|---|---|---|---|---|---|
| `[:backplane, :skills, :access, :start\|:stop\|:exception]` | `Backplane.Skills` | TelemetryLogger (stop/exception) | `skill_load_log` via `Audit.log_skill_load` from Dispatch (separate path) | TelemetryLogger | Skill identifiers | `backplane.skills.*` envelope |

---

## 6. Host agent

| Event | Producer | Consumers | Persistence | Runtime | Privacy | Replacement |
|---|---|---|---|---|---|---|
| `[:backplane, :host_agent, :memory, :call, :start\|:stop\|:exception]` | Host-agent telemetry | TelemetryLogger (stop/exception); `Backplane.HostAgent.TelemetryLogger` | — | Dual Logger paths | — | Shared correlation |
| `[:backplane, :host_agent, :memory, :capture, …]` | Capture pipeline | Host-agent reporters | Capture/spool models | Host-agent logger | Capture content risk | Domain-owned |
| `[:backplane, :host_agent, :mcp, :request, …]` | Memory router | None in TelemetryLogger | — | — | — | Shared correlation |
| `[:backplane, :host_agent, :connect\|:disconnect]` | Agent manage | TelemetryLogger | — | TelemetryLogger | Host identifiers | Shared correlation |
| `agent_trace_events` | Host-agent ingest | Admin/query | Durable host-agent traces | — | Trace payload policy | Keep existing model |

---

## 7. Catch-all runtime logger

### `BackplaneTelemetry.TelemetryLogger`

| Field | Value |
|---|---|
| Producer | Subscribes in GenServer init via `:telemetry.attach_many` |
| Events | LLM request; MCP request start; tool_call stop/exception; memory access stop/exception; memory event append/duplicate/error; host-agent memory call stop/exception; skills access stop/exception; host-agent connect/disconnect |
| Persistence | Optional single JSONL file (`log_to_file`) |
| Runtime output | Logger and/or stdout JSON (`log_to_logger`, `log_to_console`) |
| Privacy risk | JSON-compatible sanitize only; **not** credential redaction |
| Replacement event | `Backplane.Observability.RuntimeSink` (+ Logger/JSONL sinks); domain DB writers are separate |

Config keys (boot/runtime): `log_to_logger`, `log_to_console`, `log_to_file`. Gate: `:backplane_telemetry, :start_logger`.

Architectural issues: one mailbox for unrelated domains; no per-domain retention; high-volume proxy events share failure boundary with lifecycle events.

---

## 8. Metrics

### `Backplane.Metrics`

| Subscribed events | Storage | Consumers |
|---|---|---|
| mcp_request start; tool_call *; sse_stream *; memory event *; Oban job * | Process ETS counters | `/metrics`, Prometheus adapter, `DashboardUsageLive` MCP tab |

Historical MCP usage currently depends on ETS and resets with the process. LLM historical usage already reads `llm_logs` via `UsageQuery`.

Replacement: attach to v2 events; durable historical aggregates from domain tables.

---

## 9. Admin surfaces

| Surface | Data source | Durable? | Replacement |
|---|---|---|---|
| `/system/logs` Background Jobs | Direct `oban_jobs` query | Yes (Oban) | Dedicated Jobs route |
| `/system/logs` Tool Calls | PubSub `tools:call` ring buffer | No | Durable MCP tool list + optional live panel |
| `/dashboard/usage/llm` | `UsageQuery` → `llm_logs` | Yes | `Backplane.LLM.LogQuery` facade |
| `/dashboard/usage/mcp` | `Metrics.snapshot()` ETS | No | `Backplane.MCP.LogQuery` |

---

## 10. Background jobs and audit writers

| Path | Mechanism | Notes |
|---|---|---|
| LLM usage write | Telemetry callback → `Oban.insert(UsageWriter)` | Sync Oban insert in producer process; rejected by v2 non-blocking rule |
| LLM usage retention | `UsageRetention` worker | Unscheduled in cron today |
| Skill audit | `Audit.log_skill_load` from Dispatch | Active |
| Tool audit | `Audit.log_tool_call` | Schema/tests only; fire-and-forget Task pattern to harden in PR-07A |
| Oban job state | Oban | Source of truth for job UI; not copied into proxy tables |

---

## 11. Relayixir (out of Backplane namespace)

| Event | Notes |
|---|---|
| `[:relayixir, :http, :request, …]` | HTTP plug; not consumed by Backplane Metrics/TelemetryLogger |
| `[:relayixir, :websocket, …]` | Bridge; same |

Out of Observability v2 MVP scope except as future correlation of LLM upstream spans.

---

## 12. Duplicate path matrix (proxy)

For a single MCP `tools/call` today an operator may see:

1. `RequestLogger` HTTP/MCP line
2. `emit_mcp_request` direct Logger.info
3. TelemetryLogger formatting of `mcp_request.start`
4. Metrics ETS increments
5. `span_tool_call` direct Logger.info/error
6. TelemetryLogger formatting of tool_call stop/exception
7. PubSub tool event in LogsLive (non-durable)
8. No durable MCP root row; audit tool row usually missing

For a successful LLM request:

1. `[:backplane, :llm, :request]` telemetry
2. UsageCollector → Oban → `llm_logs` (narrow fields)
3. TelemetryLogger formatting
4. No shared trace/request ID contract across admin and runtime

---

## 13. Feature flags introduced in PR-00

Application config under `:backplane_telemetry` (safe defaults = off):

| Flag | Default | Meaning |
|---|---|---|
| `observability_v2_enabled` | `false` | Master switch for v2 producers/adapters |
| `observability_v2_llm_write` | `false` | Persist LLM v2 access records |
| `observability_v2_mcp_write` | `false` | Persist MCP v2 access records |
| `observability_v2_runtime_sink` | `false` | Use v2 runtime sink instead of legacy logger path |

Accessor: `Backplane.Observability.Flags`. Dynamic `system_settings` land in PR-04.

---

## 14. Inventory gaps feeding later PRs

1. No durable MCP root/tool access tables.
2. LLM early failures and streaming outcomes incomplete.
3. `llm_logs` physical richness unused by collector.
4. Duplicate Logger + TelemetryLogger access messages.
5. TelemetryLogger lacks credential redaction.
6. `tool_call_log` unused in production dispatch.
7. Usage retention unscheduled.
8. Admin Logs is not a durable proxy browser.
9. MCP historical usage is ETS-only.
10. Request-path Oban insert violates v2 non-blocking rule.
