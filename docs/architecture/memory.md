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

## Not yet built

Automatic distillation by a memory maintenance agent, host-side collectors and
the Codex / Cursor / Claude Code / Sigma / Synapsis plugins are described in the
spec and are delivered in later plans.

## Historical documents

Files under `docs/memory/` describe the retired design and carry a
"Superseded" header; they are kept for history only.
