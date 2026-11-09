# Memory architecture (current state)

Authoritative design: [docs/superpowers/specs/2026-11-09-memory-simplification-design.md](../superpowers/specs/2026-11-09-memory-simplification-design.md).
The partitioned/memory-space design (spaces, entitlements, edge sync, replay,
crystals, lessons, graph, slots, leases, qualification tooling) was retired.

## Model

Backplane Memory serves a single user and is one **global store**. There is no
partition, space or ownership boundary: any client holding the normal
`memory.read` / `memory.write` resource scopes sees every record. Host, agent,
integration and session are recorded as **provenance**, never as access control.

## Records

`memory_records` (owned by `apps/backplane_memory`, migrated in
`apps/backplane_system`) holds one row per memory:

- `kind`: `fact | procedure | worklog | note`
- `subjects`: list of `{type, key}` (host, repo, service, path, project)
- `property` (facts): same subjects + property means a newer fact supersedes
  the older one; "newer" is by `observed_at`, so a fact observed earlier than
  the active one (e.g. a late offline upload) is stored already superseded.
  Status changes bump `updated_at` so host pulls pick them up
- `status`: active, superseded (points at the replacement) or forgotten
  (reason and time kept; never physically deleted)
- provenance: host, agent, integration, session, source event ids, writer
  (`agent`, `memory_agent`, `user`, `host_collector`)
- records written via a host agent carry `client = <host id>`, because the
  host is the authenticated principal
- full-text search column; embeddings optional

Context module: `Backplane.Memory.Records`.

## MCP tools

`Backplane.Memory.Tools` registers five managed tools under the `memory::`
prefix: `search`, `get`, `recent`, `remember`, `forget`. Recall is pulled by the
agent when it needs it; nothing is auto-injected per turn.

## Capture path

```
agent hook -> host agent POST /capture/v1/hooks/:integration/:hook
  -> durable host spool (offline-safe)
  -> channel `memory_events`
  -> gateway ingest -> bpm_events -> session projections
```

Sessions close on an explicit SessionEnd or on an idle sweep. Host agents also
forward `memory::*` calls to the gateway (`/memory/:agent_id/call/:method`).

## Admin

`/memory`: Overview, Records, Events, Sessions, Config.

## Offline host memory

Each host agent keeps a local store (host schema V9, `Memory.Local`) so
`memory::*` calls keep working while the gateway is unreachable. Local tables:
`local_records`, `memory_outbox`, `memory_sync_state`.

- **Writes**: `remember` / `forget` go to the gateway first and are cached
  locally on success. Only when the call fails with a transport error (gateway
  unavailable or timeout) is the write queued in the durable on-disk outbox; its
  result is marked `"sync": "pending"`. A caller-supplied or generated
  `request_key` (`"host-agent:" <> UUIDv7`, created before the first attempt and
  reused on each retry) makes retries idempotent, so a resend after a timeout
  returns the same gateway record (no duplicates).
  While earlier writes are still pending in the outbox, new `remember` /
  `forget` calls are queued behind them (and a sync is triggered) even when the
  gateway is reachable, so uploads stay in order; reads still go to the gateway.
  Queued `remember` entries keep their original `observed_at`, which the
  gateway honours. Queued writes are validated like the gateway tools first.
- **Outbox flush** (`Memory.OutboxSync`): entries flush in order on each sync tick while the host channel is connected (and immediately on reconnect).
  A `forget` of a record not yet synced waits for its `remember` and then uses
  the resolved `remote_id`. Transport errors keep the entry pending; other
  gateway errors (e.g. validation) mark it `failed` with `last_error`, without
  blocking later entries. The outbox survives host restarts.
- **Pull**: after the outbox drains, the host calls the gateway `memory_pull`
  (`Records.changed_since/3`) with a cursor stored in `memory_sync_state`, and
  mirrors records whose `host_id` is this host (including superseded/forgotten
  status changes). Other hosts' memories are not mirrored. Pulled records carry
  `request_key`, so a pulled copy lands on its pending local row; provenance
  (host, agent, client, source event ids) is kept on local rows.
- **Offline reads**: `search` / `get` / `recent` read the local store and return
  `"offline": true, "source": "local"`. `search` excludes non-active records
  unless `include_inactive`; `recent` always returns only active worklogs; `get`
  returns the record in any status, as the gateway does.
- **Health**: the host reports `outbox_pending`, `outbox_failed`,
  `local_records`, `last_sync_at`, `last_error` and `last_failed_error` (the
  newest failed upload's reason); the admin Host Agents page (host detail,
  Memory health card) shows them.

## Not yet built

Automatic distillation by a memory maintenance agent, host-side collectors and
the Codex / Cursor / Claude Code / Sigma / Synapsis plugins are described in the
spec and are delivered in later plans.

## Historical documents

Files under `docs/memory/` describe the retired design and carry a
"Superseded" header; they are kept for history only.
