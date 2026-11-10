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

## Distillation

A background memory agent turns captured sessions into records.

- **Trigger**: a session closing as `completed` or `abandoned` schedules a row
  in `memory_distillations` (one per session), due after
  `memory.distill_delay_seconds`. A reopened session returns to `pending`.
- **Scheduler and worker**: a scheduler claims due rows (at most
  `memory.distill_max_concurrency` running) and runs each through the memory
  agent over the proxy using `memory.llm_model`.
- **Modes**: `distill` for a fresh session; `review` when the agent already
  wrote records for it, so it reconciles instead of duplicating.
- **Chunking**: long sessions are split into event chunks, one agent run each;
  `source_event_ids` come only from the chunk being processed. Candidates are
  idempotent through a content-derived `request_key`.
- **Agent tools**: act only on the memory domain (no git, shell or workspace).
  Merge rules: facts supersede by subject and property, procedures merge via
  `Records.replace/2`, worklogs are append-only.
- **Failures are never silent**: a failed or blocked run stores `last_error`
  and logs a warning. A missing `memory.llm_model` marks due rows `blocked`
  (`memory.llm_model not configured`); setting it unblocks them. The admin
  Overview shows alerts for failed/blocked counts; the Sessions page shows
  status, mode, error and records written, with a manual Retry.
- **Settings**: `memory.llm_model`, `memory.distill_delay_seconds`,
  `memory.distill_max_concurrency` (Config page).

## Recall

`memory::search` combines Postgres full-text search with vector similarity when
`memory.embed_model` is configured; records are embedded in the background and
the two rankings are fused with Reciprocal Rank Fusion. If no embedding model
is configured, the proxy errors, or vectors are missing, search falls back to
full-text results only.

## Host collectors

Host agents scan local state (git checkouts, Docker containers, systemd
services, launchd jobs, host facts) and upload only changes as
`host.snapshot.collected` events (`integration`/`client_id` `host_collector`, no
session). The payload is `{collector, unit, complete, items, host_label}` plus,
for `git`, `unscanned`: `unit` is the scan root for `git` and `"local"`
otherwise; `complete` is true only when the whole unit was scanned; `host_label`
is the agent's `machine_name` (or its hostname) and names the host in fact
content, while fact subjects always use the host id; `unscanned` lists
directories below the root that could not be read. A repository whose git
commands fail unexpectedly is dropped and the root marked incomplete. Strings
are sanitized to valid UTF-8; commit subjects and branches are truncated to 200
characters, and a snapshot that would exceed the capture `batch_bytes` limit
keeps only its leading items and is marked incomplete. Host info reports IPv4
addresses of physical interfaces and non-ephemeral listening ports; it is not
reported at all when the listening scan fails. The agent remembers each unit's
fingerprint in `collector_state.json` next to the capture spool (keyed by host
id); deleting that file forces one full re-report, which the gateway diff turns
into a no-op for unchanged items. The gateway validates the event like any other, then
`Backplane.Memory.Workers.HostSnapshotWorker` (queue `:memory`, unique per
event) applies it asynchronously; the job is enqueued in the same transaction
as the insert, so an accepted event always has its job.

`Backplane.Memory.HostSnapshots.apply/1` is deterministic (no LLM). One state
row per (host, collector, unit) records the fact slots of the last applied
snapshot (slot = `property|subject keys`). Applying diffs against it in one
transaction: new or changed slots are written as `host_collector` facts
(`writer`/`integration` `host_collector`, `host_id` = reporting host),
unchanged slots are left alone, and vanished slots are forgotten.

- Only facts whose writer is `host_collector` are ever invalidated; `agent` and
  `user` facts are never touched.
- Disappearance counts only when the unit's scan was `complete`. A disabled
  collector, a removed or unreadable root, or a partial failure never
  invalidates anything. Items at or below an `unscanned` directory are kept
  even in a complete scan.
- Ordering uses `occurred_at`. A snapshot older than the applied one (offline
  spool, retries) is ignored as stale. Host clocks ahead of the gateway are
  clamped to the gateway time so later snapshots are not mistaken for stale.
- Invalid payloads are cancelled with a warning (no retry, no records); other
  failures, including a failed forget (which rolls the whole apply back), retry.

## Plugins

Packages live under `integrations/memory/` and ship inside the host-agent
release (`priv/integrations/memory`). All five clients reach memory through the
local host agent (`127.0.0.1:4222`): MCP at `/memory/:agent_id/mcp`, direct tool
calls at `/memory/:agent_id/call/:method`, capture at
`/capture/v1/hooks/:integration/:hook`. Agent ids: `claude-code`, `codex`,
`cursor`, `hermes`, `openclaw`.

**Hook client.** `shared/bin/backplane-memory-hook <integration> <hook>` is a
POSIX shell script that streams hook stdin to the capture endpoint with
`curl --max-time 2`, discards all output and always exits 0, so a down or slow
host agent never affects the agent. The base URL comes from
`$BACKPLANE_HOST_AGENT_URL`, else the URL baked in at install, else the
default. For Cursor `beforeSubmitPrompt` it prints `{"continue":true}`. Cursor
events are normalized host-side (`conversation_id`, `workspace_roots`,
camelCase event names).

**Instruction source.** `shared/INSTRUCTIONS.md` is the single resident
instruction (after finishing work, call `memory::remember` if something is worth
keeping; no blocking Stop hook). It is shipped in each package's skill, served
as `instructions` in MCP `initialize`, and a test fails on drift.

**Install** (via `host_agent::install_plugin` with `plugin: "memory"`; the
installer copies files only and never runs other CLIs, results carry
`next_steps`). `<data>` is `~/.local/share/backplane`; every install also copies
the hook client to `<data>/bin/backplane-memory-hook`.

| Runtime | Installed to | Next steps |
| --- | --- | --- |
| `claude_code` | marketplace `<data>/plugins/claude` | `claude plugin marketplace add <data>/plugins/claude`, then `claude plugin install backplane-memory@backplane-local` |
| `codex` | marketplace `<data>/plugins/codex` | `codex plugin marketplace add <data>/plugins/codex`, then `codex plugin add backplane-memory@backplane-local`; then start Codex interactively once and trust the plugin hooks when prompted (Codex does not run plugin hooks until trusted) |
| `cursor` | merged into `~/.cursor/hooks.json` and `~/.cursor/mcp.json` (one-time `*.backplane-backup`; `remove` restores the user's own entries) | restart Cursor |
| `hermes` | `~/.hermes/plugins/backplane-memory` | enable `memory: provider: backplane-memory` (or `hermes memory setup backplane-memory`), restart Hermes |
| `openclaw` | `~/.openclaw/extensions/backplane-memory` | set `plugins.slots.memory`, the entry's `enabled` and `hooks.allowConversationAccess` in `~/.openclaw/openclaw.json`, restart OpenClaw |

`remove` results carry the client-side uninstall commands instead (for example
`claude plugin uninstall backplane-memory@backplane-local`); run them before or
right after removing so no client keeps calling a deleted hook client.

**Hermes and OpenClaw** keep native plugins that recall and write through the
global tools. They surface memory only in a live, owner-private session and fail
closed otherwise (OpenClaw requires an unsandboxed `owner-private` audience;
see each README). A down or older host agent, or `gateway_unavailable`, degrades
to no recall context without raising into the agent; writes are queued by the
host.

CI: `.github/workflows/memory-plugins.yml` runs the package, installer and hook
tests and verifies the packaged release (`shared/bin/backplane-memory-hook`
executable, `INSTRUCTIONS.md`, `claude_code`, `codex`, `cursor`).

Sigma and Synapsis plugins are tracked as `internal request` issues in their
own repositories: gsmlg-opt/sigma#3 and gsmlg-opt/Synapsis#25.

## Historical documents

Files under `docs/memory/` describe the retired design and carry a
"Superseded" header; they are kept for history only.
