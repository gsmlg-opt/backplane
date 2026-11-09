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
  the older one
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

Each host agent keeps a local store (host schema V8, `Memory.Local`) so
`memory::*` calls keep working while the gateway is unreachable.

- **Writes**: `remember` / `forget` are applied locally first and appended to a
  durable on-disk outbox. Results of offline writes carry `"sync": "pending"`.
  Every `remember` carries a `request_key` (`"host-agent:" <> UUIDv7`) created
  before the first attempt and reused on each retry, so a resend after a
  timeout returns the same gateway record (no duplicates).
- **Outbox flush** (`Memory.OutboxSync`): entries flush in order on reconnect.
  A `forget` of a record not yet synced waits for its `remember` and then uses
  the resolved `remote_id`. Transport errors keep the entry pending; other
  gateway errors (e.g. validation) mark it `failed` with `last_error`, without
  blocking later entries. The outbox survives host restarts.
- **Pull**: after the outbox drains, the host calls the gateway `memory_pull`
  (`Records.changed_since/3`) with a cursor stored in `memory_sync_state`, and
  mirrors records whose `host_id` is this host (including superseded/forgotten
  status changes). Other hosts' memories are not mirrored.
- **Offline reads**: `search` / `get` / `recent` read the local store and return
  `"offline": true, "source": "local"`; non-active records are excluded by
  default.
- **Health**: the host reports `outbox_pending`, `outbox_failed`,
  `local_records`, `last_sync_at` and `last_error`; the admin Memory page shows
  them.

## Not yet built

Automatic distillation by a memory maintenance agent, host-side collectors and
the Codex / Cursor / Claude Code / Sigma / Synapsis plugins are described in the
spec and are delivered in later plans.

## Historical documents

Files under `docs/memory/` describe the retired design and carry a
"Superseded" header; they are kept for history only.
