# Observability v2 — Verification and Production Rollout

| Field | Value |
|---|---|
| Status | Post-MVP operational plan |
| Baseline | `origin/main` @ `b73c7c2` |
| Date | 2026-09-04 |
| Audience | Operators / maintainers |
| Labels | `project: backplane` |

MVP (PR-00 → PR-08) is on `origin/main`. This document is the concrete next-step checklist: local/staging verification, production cutover, rollback, and explicitly deferred work.

> **Note:** `user-agent-note` MCP was unavailable when this plan was written; content lives here under `docs/observability/` so it stays next to the PRD/design/implementation docs.

---

## 0. Critical facts (read before enabling)

### Settings keys (seeded defaults)

Defaults live in `Backplane.Settings` (`@defaults`) and are typed by `Backplane.Observability.Settings`:

| Key | Default | Role |
|---|---|---|
| `observability.llm_proxy.enabled` | `true` | Emit LLM v2 events |
| `observability.llm_proxy.persist` | `true` | Start LLM `Buffer` + `LogWriter`; disable legacy `UsageCollector` |
| `observability.llm_proxy.retention_days` | `90` | LLM retention |
| `observability.llm_proxy.payload_mode` | `"none"` | Payload capture (MVP: keep `none`) |
| `observability.llm_proxy.sample_rate` | `1.0` | Sampling |
| `observability.mcp_proxy.enabled` | `true` | Emit MCP v2 events |
| `observability.mcp_proxy.persist` | `true` | Start MCP root/tool writers |
| `observability.mcp_proxy.retention_days` | `30` | MCP retention |
| `observability.mcp_proxy.payload_mode` | `"none"` | Keep `none` until PR-07B |
| `observability.mcp_proxy.sample_rate` | `1.0` | Sampling |
| `observability.audit.enabled` | `true` | Audit writer / pruning |
| `observability.audit.retention_days` | `180` | Audit retention |
| `observability.writer.batch_size` | `nil` | Shared override; `nil` → domain defaults |
| `observability.writer.flush_interval_ms` | `250` | Flush interval |
| `observability.writer.queue_capacity` | `nil` | Shared override; `nil` → buffer defaults |

**Seed behavior:** `Backplane.Settings` inserts a key **only if the row is missing** (`unless Repo.get(Setting, key)`). Existing DB rows with `observability.*=false` **do not auto-upgrade** to the new compile-time defaults. Operators must set them explicitly.

### Boot-time vs runtime

- `Flags.llm_write?()` / `Flags.mcp_write?()` / `Flags.runtime_sink?()` are evaluated when starting writers / RuntimeSink / TelemetryLogger.
- Changing `enabled`/`persist` at runtime updates emit decisions, but **writer children and RuntimeSink are chosen at application start**. After flipping persist or legacy logger flags, **restart the node** (or redeploy).

### LLM write path is exclusive (not true dual-write)

When `llm_write?()` is true:

- `Backplane.LLM.LogWriter` + buffer start
- `UsageCollector.attach()` is skipped

When false:

- Legacy `UsageCollector` → Oban `UsageWriter` path remains

Treat “dual-write” in the PRD as a **staged cutover with comparison**, not simultaneous writers on one node.

### App-env rollback / overrides (`:backplane_telemetry`)

| Flag | Purpose |
|---|---|
| `observability_v2_enabled` | Boot override master (with sibling flags) |
| `observability_v2_llm_write` / `_mcp_write` / `_runtime_sink` | Boot overrides (require master + flag) |
| `use_legacy_telemetry_logger` | Force legacy `TelemetryLogger`; suppress RuntimeSink |
| `observability_v2_test_disabled` | Test-only hard disable (do not use in prod) |

Compile defaults in `config/config.exs` keep app-env flags `false`; **operational policy comes from `system_settings`**.

### Admin routes (admin endpoint, root `/`)

| Path | Purpose |
|---|---|
| `/system/logs` | Overview |
| `/system/logs/llm` (+ `/:id`) | LLM access records |
| `/system/logs/mcp` (+ `/:id`) | MCP root + tool timeline |
| `/system/logs/audit` | Audit (`tool_call_log` / `skill_load_log`) |
| `/system/logs/jobs` | Oban jobs |
| `/system/logs/sinks` | Policy snapshot, flags, writer/buffer health, drop counters |

Dev admin typically: `http://localhost:4221`.

There is **no dedicated observability settings LiveView** yet; enable via IEx/`Backplane.Settings.set/2` (or SQL), then confirm on `/system/logs/sinks`.

---

## 1. Local / staging verification checklist

### 1.1 Preconditions

- [ ] Checkout `main` at or after `b73c7c2`
- [ ] `mix ecto.migrate` (dev) and `MIX_ENV=test mix ecto.migrate` (test)
- [ ] Confirm migrations present: `llm_logs` v2 columns, `mcp_proxy_requests`, `mcp_tool_calls`, audit correlation fields

### 1.2 Explicitly enable policy (existing DBs)

In IEx (`iex -S mix`):

```elixir
for key <- [
  "observability.llm_proxy.enabled",
  "observability.llm_proxy.persist",
  "observability.mcp_proxy.enabled",
  "observability.mcp_proxy.persist",
  "observability.audit.enabled"
] do
  :ok = Backplane.Settings.set(key, true)
end

# Keep payloads off for MVP
:ok = Backplane.Settings.set("observability.llm_proxy.payload_mode", "none")
:ok = Backplane.Settings.set("observability.mcp_proxy.payload_mode", "none")
```

- [ ] Restart the server after setting keys
- [ ] Open `/system/logs/sinks` → policy JSON shows `enabled`/`persist` true; writers report healthy (not missing)

### 1.3 Smoke traffic

- [ ] Send ≥3 LLM proxy requests (success + one error if easy)
- [ ] Send ≥3 MCP calls (`tools/list`, `tools/call` on a known tool, one failure)
- [ ] Confirm new rows:
  - `/system/logs/llm` — rows with `event_id` / `request_id` / `outcome`
  - `/system/logs/mcp` — root row; detail shows child tool timeline when applicable
  - `/system/logs/audit` — tool/skill audit entries (hash-only args)
- [ ] `/system/logs/sinks`: accepted counters increase; LLM/MCP **drop ≈ 0** under normal load
- [ ] Spot-check logs: no raw prompts/arguments; `payload_mode` remains `none`

### 1.4 Success criteria (staging)

| Check | Pass |
|---|---|
| Writers started | All four health cards on sinks page return maps (not error strings) |
| Persist lag | Accepted → visible in admin within ~1–2s at default flush |
| Drop rate | `observability.events.dropped.*` stays 0 under smoke load |
| Privacy | No prompt/body/arg plaintext in DB or Logger |
| Restart survival | Rows remain after process restart |
| Rollback drill | Section 3 succeeds on staging before prod |

### 1.5 Focused regression (optional same day)

```bash
mix test apps/backplane_telemetry
mix test apps/backplane_llama/test/backplane/llm
mix test apps/backplane_mcp/test/backplane/mcp
mix test apps/backplane_admin/test/backplane/admin/live/logs_live_test.exs
```

Do **not** block on known unrelated failures (section 4).

---

## 2. Production rollout

### Phase A — Deploy schema + binary (writers may stay off)

1. Deploy release that includes `b73c7c2` (or later) and run migrations.
2. Inspect `system_settings` for existing `observability.*` values.
3. If rows are `false` or missing unexpectedly, plan an explicit enable window (do not assume seed defaults applied).
4. Confirm `/system/logs/*` routes load even if empty.

**Exit:** Migrations applied; admin UI reachable; no writer pressure until Phase B.

### Phase B — Cutover write path (staged “dual-write” comparison)

MVP code path is **exclusive**. Practical comparison:

1. Snapshot baseline (optional): recent `llm_logs` count, MCP metrics, Oban usage job volume.
2. Set the five enable/persist/audit keys to `true` (and `payload_mode` to `none`).
3. **Restart** production nodes so `LogWriter` / MCP writers / RuntimeSink start and `UsageCollector` detaches.
4. Generate or wait for real traffic for an agreed window (e.g. 1–24h).
5. Compare:
   - Proxy/request counters vs durable row inserts
   - Sinks drop counters (must stay ~0)
   - Sample admin detail pages vs known requests
6. Keep `:use_legacy_telemetry_logger` **false** unless rolling back runtime sink.

**Exit:** Durable rows match traffic within documented drop conditions; sinks healthy.

### Phase C — Switch reads (operators)

1. Treat `/system/logs/llm`, `/system/logs/mcp`, `/system/logs/audit`, `/system/logs/sinks` as primary operational surfaces.
2. Stop relying on legacy catch-all Logger formatting for LLM/MCP access triage.
3. Dashboard / usage panels that already query `llm_logs` continue; prefer v2 fields (`event_id`, `outcome`, correlation IDs).

**Exit:** On-call can diagnose provider/upstream/tool failures from admin detail pages alone.

### Phase D — Retire legacy (only after Phase C soak)

Do **not** delete modules in the same change that first enables prod persist.

When soak criteria are met:

1. Confirm `UsageCollector` / Oban `UsageWriter` are idle with v2 persist on.
2. Confirm RuntimeSink is active (`use_legacy_telemetry_logger: false`).
3. Schedule a later PR to fully remove deprecated modules/tests/TOML telemetry mapping (section 4).
4. Document one compatibility release before hard deletion.

**Exit:** One runtime access path per policy; no per-request Oban usage insert under v2 persist.

---

## 3. Rollback

### Soft rollback (preferred)

```elixir
:ok = Backplane.Settings.set("observability.llm_proxy.persist", false)
:ok = Backplane.Settings.set("observability.mcp_proxy.persist", false)
# Optional: stop emission entirely
:ok = Backplane.Settings.set("observability.llm_proxy.enabled", false)
:ok = Backplane.Settings.set("observability.mcp_proxy.enabled", false)
```

Then **restart** so:

- LLM falls back to `UsageCollector`
- MCP writers stop
- RuntimeSink selection re-evaluates

### Emergency runtime logger rollback

In release config / runtime env for `:backplane_telemetry`:

```elixir
config :backplane_telemetry, use_legacy_telemetry_logger: true
```

Restart. Forces `TelemetryLogger`, suppresses RuntimeSink. Schemas remain; no migration rollback.

### Hard rules

- Do **not** drop v2 columns/tables as part of rollback.
- Do **not** set `payload_mode` to `full`/`sampled` in prod until PR-07B exists.
- Prefer Settings toggles + restart over redeploying older commits unless binary itself is broken.

---

## 4. Explicitly deferred (do not block rollout)

| Item | Why deferred | When to pick up |
|---|---|---|
| **PR-07B** encrypted `proxy_payloads` | Optional; MVP keeps `payload_mode=none` | Separate design + encryption review |
| **Full legacy module deletion** | Modules still useful for rollback/tests (`TelemetryLogger`, `UsageCollector`, `UsageWriter`, …) | After prod soak + documented compatibility release |
| **ex_turso arm64 NIF** | Host-agent / Turso tests fail on arm64 hosts (~170 failures); unrelated to observability | Upstream NIF / CI matrix work |
| **`MemoryOperatorPagesLiveTest`** | Known `invalid_partition` failure; unrelated to logs UI | Memory admin follow-up |
| Memory / skills / host-agent event rename | Out of MVP scope | Domain migrations later |
| `llm_logs` physical rename | Product decision | Post-rollout only |
| Monthly PG partitioning | Design allows later | High-volume only |

---

## 5. This-week ordered actions

1. **Day 1 — Local enable + smoke**  
   Migrate → set `observability.*.enabled/persist` true → restart → hit LLM/MCP → verify `/system/logs/{llm,mcp,sinks}`.

2. **Day 1–2 — Staging soak + rollback drill**  
   Run smoke under load; confirm drops ≈ 0; practice soft rollback + restart; re-enable.

3. **Day 2–3 — Production Phase A/B**  
   Deploy + migrate; inspect existing settings rows; enable persist; restart; compare counters for an agreed window.

4. **Day 3–5 — Phase C operator cutover**  
   Point triage at `/system/logs/*`; watch sinks daily; keep PR-07B and module deletion parked.

5. **Park** turso arm64 and `MemoryOperatorPagesLiveTest` as separate tickets; do not mix into observability hotfixes.

---

## 6. Quick reference commands

```bash
# Migrations
mix ecto.migrate
MIX_ENV=test mix ecto.migrate

# Focused tests
mix test apps/backplane_admin/test/backplane/admin/live/logs_live_test.exs
mix test apps/backplane_telemetry/test/backplane/observability

# Admin (dev)
# Public API :4220  |  Admin UI :4221
open http://localhost:4221/system/logs/sinks
```

```elixir
# Inspect effective policy after boot
Backplane.Observability.Settings.snapshot()
Backplane.Observability.Flags.snapshot()
Backplane.Observability.health()
```
