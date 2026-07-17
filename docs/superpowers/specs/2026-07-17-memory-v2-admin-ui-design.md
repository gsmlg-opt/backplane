# Memory V2 Admin Console Design

**Status:** Approved design
**Date:** 2026-07-17
**Scope:** Replace the legacy Memory admin pages with a V2-first operations console.

## Context

The Memory V2 foundation provides ordered streams and events, atomic
observation/event dual-write, rollout gates, timeline queries, ingestion
telemetry, and hook-based ingestion. The existing admin UI still presents V1
projection tables such as memories, observations, and legacy sessions. It has
no route that reads `bpm_streams` or `bpm_events`, and it does not expose the
three rollout gates that currently affect production behavior.

This design makes the authoritative V2 event model the admin product surface.
It does not remove V1 projection tables or backend contexts because atomic
dual-write, existing MCP responses, and legacy workers still depend on them.

## Goals

- Make streams, ordered events, event health, and rollout state the primary
  Memory admin experience.
- Replace nine legacy Memory destinations with four focused V2 destinations.
- Keep filters and selected records URL-addressable and bookmarkable.
- Expose only rollout controls that have production consumers.
- Provide live event visibility without polling or weakening transaction
  boundaries.
- Fix the confirmed public event-append facade defect before the UI depends on
  the V2 event boundary.
- Use Phoenix LiveView and DuskMoon components exclusively.

## Non-goals

- No UI for V1 memories, observations, graph, actions, audit, or legacy
  sessions.
- No deletion, replay, retry, editing, or manual closure of events or streams.
- No implementation of Window Summary, Session Summary V2, fact extraction,
  procedure extraction, or Recall V2.
- No public event-timeline MCP tool or new public HTTP API.
- No removal of V1 tables, contexts, workers, tools, or response contracts.
- No content search or arbitrary JSON-path search in the event explorer.

## Decisions

1. The console is V2-first and replaces the legacy Memory UI.
2. Removed legacy routes return 404. They do not redirect and do not remain as
   hidden compatibility pages.
3. The navigation has exactly four destinations: Overview, Streams, Events,
   and Pipeline.
4. Streams and events are inspect-only. Ingestion and hooks own stream
   lifecycle.
5. The Pipeline page can edit only:
   - `memory.pipeline.enabled`
   - `memory.events.enabled`
   - `memory.events.dual_write`
6. The five later-stage flags are visible as unavailable stages and cannot be
   edited.
7. Live event updates use a lightweight post-commit PubSub notification. The
   database remains authoritative.
8. Admin LiveViews do not query `Backplane.Repo` or schemas directly. A Memory
   operations context owns the read model and rollout mutations.

## Information Architecture

| Route | Live action | Purpose |
|---|---|---|
| `/memory` | `MemoryOverviewLive, :index` | Rollout state, persisted activity, runtime ingestion health, active streams |
| `/memory/streams` | `MemoryStreamsLive, :index` | Filterable, cursor-paginated stream inventory |
| `/memory/streams/:stream_id` | `MemoryStreamsLive, :show` | Stream identity, closure state, and ordered sequence window |
| `/memory/events` | `MemoryEventsLive, :index` | Filterable global event feed with live-tail behavior |
| `/memory/events/:event_id` | `MemoryEventsLive, :show` | Event content, payload, provenance, and identity details |
| `/memory/pipeline` | `MemoryPipelineLive, :index` | Guarded rollout controls and unavailable future stages |

The Memory navigation contains only Overview, Streams, Events, and Pipeline.

The following routes are removed and must return 404:

```text
/memory/browse
/memory/stats
/memory/observations
/memory/sessions
/memory/graph
/memory/actions
/memory/audit
/memory/config
```

## Domain Boundary

Add `Backplane.Memory.Operations` as the admin-facing facade for V2 inspection
and rollout control. The LiveViews depend on this facade rather than Ecto
schemas, the repository, Metrics, or Settings directly.

The initial public surface is:

```elixir
overview() :: overview_regions()
list_streams(filters) :: {:ok, page(Stream.t())} | {:error, term()}
get_stream(stream_id) :: {:ok, Stream.t()} | {:error, :not_found}
stream_events(stream_id, opts) :: {:ok, sequence_page(Event.t())} | {:error, term()}
timeline(filters) :: {:ok, cursor_page(Event.t())} | {:error, term()}
get_event(event_id) :: {:ok, Event.t()} | {:error, :not_found}
rollout_state() :: rollout_state()
set_gate(gate, boolean) :: :ok | {:error, term()}
```

The facade returns domain structs for individual streams/events and bounded
maps for aggregate/page results. It normalizes web input before calling event
queries; query modules never receive blank strings or numeric strings.

`overview/0` returns a map of tagged, independently loadable regions:
`:pipeline`, `:persisted_counts`, `:event_volume`, `:runtime_metrics`,
`:recent_events`, and `:active_streams`. Each value is
`{:ok, region_data}` or `{:error, reason}`. This makes partial failure explicit
without turning unavailable persisted data into zero or hiding healthy regions.

### Event facade correction

`Backplane.Memory.Events.append/1` and `append_batch/1` currently normalize and
return in-memory structs without persistence. Correct the contract as part of
this work:

- `Events.append/1` delegates to persistent `Store.append/1`.
- `Events.append_batch/1` delegates to persistent `Store.append_batch/1`.
- Normalization and privacy filtering move behind an internal preparation seam
  used by `Store.append_multi/3` and batch persistence.
- Tests prove successful facade calls allocate a sequence and create rows.

## Page Design

### Overview

The overview is a dense operational instrument panel:

- Effective Pipeline, Events, and Dual Write status.
- Persisted open-stream count and event count for the last 24 hours.
- Persisted event-volume buckets for the last 60 minutes, rendered without a
  client-side chart dependency.
- Runtime appended, duplicate, and ingestion-error counters explicitly labeled
  "since process start".
- Recent persisted events.
- Most recently active open streams.
- A compact unavailable-stage rail for Window Summary, Session Summary V2,
  facts, procedures, and Recall V2.

The overview never converts a query failure into a zero. Each failed region
shows an explicit error state while independent regions may continue to render.

### Streams

The stream inventory supports these filters:

- open or closed;
- project;
- agent;
- host;
- session;
- run.

Rows are ordered by `last_event_at DESC, stream_id DESC` and use an opaque
keyset cursor. Each row shows stream ID, project, session or run identity,
current sequence, last activity, and closure state.

The stream cursor encodes the `last_event_at` and `stream_id` tuple from the
last returned row. Advancing applies a strict tuple comparison below that key;
the boundary row is not repeated. Streams without an event timestamp sort last
with a deterministic `stream_id DESC` tie-break. A non-null cursor selects
strictly lower tuples plus subsequent `last_event_at IS NULL` rows. A null
cursor selects only `last_event_at IS NULL AND stream_id < cursor_stream_id`.
The opaque cursor records which branch applies, avoiding SQL null-comparison
gaps.

The show action retains the inventory and opens a shareable detail view. It
shows immutable identity metadata, first/last activity, closure state, and a
bounded sequence window. The initial window contains the latest 100 events.
Windows render in ascending sequence order. `before=<first_sequence>` loads up
to 100 events with strictly lower sequences; `after=<last_sequence>` loads the
next 100 events with strictly higher sequences. The boundary event is excluded
in both directions, so older/newer round trips neither duplicate nor skip a
sequence. The UI never loads an unbounded stream.

### Events

The global explorer supports URL-backed filters for:

- stream;
- project;
- agent;
- session;
- run;
- event type;
- tool;
- status;
- time range.

Results use the existing `occurred_at DESC, id DESC` cursor contract with a
maximum page size of 100 in the admin UI. "Load older" advances the opaque
cursor.

When viewing the newest page, a matching insertion triggers an authoritative
reload of the first page. This preserves `occurred_at DESC, id DESC` ordering
for delayed events with caller-supplied timestamps and keeps the collection
bounded; a delayed event appears only if its sort key belongs in the visible
top 100. When filters are active, notifications are matched against normalized
filters before reloading. When viewing an older cursor, the page shows a "new
events available" indicator instead of moving the current result set.

The show action is URL-addressable and displays:

- event type, status, sequence, and timestamps;
- stream, project, agent, host, client, session, and run identity;
- tool, actor, role, importance, namespace, and correlation identifiers;
- idempotency and causation identifiers;
- escaped content;
- formatted, escaped payload JSON;
- `_backplane` truncation and linkage metadata when present.

### Pipeline

The three implemented gates use accessible DuskMoon switches and literal
boolean writes.

`rollout_state/0` returns both the configured boolean and the effective
master-gated value for each gate. Switches reflect configured values; status
badges reflect effective values.

Dependency rules are enforced in both directions:

```text
enable:  Pipeline -> Events -> Dual Write
disable: Dual Write -> Events -> Pipeline
```

- A child cannot be enabled until its parent is effective.
- A parent cannot be disabled while its child is configured on.
- Enabling Dual Write requires an explicit confirmation.
- Disabling a gate is immediate once its dependency rule is satisfied.
- A failed write leaves the previous state visible and renders an error alert.
- Settings PubSub changes reload the displayed effective state.

If an installation already contains an inconsistent hierarchy, the page shows
the configured-but-blocked child explicitly. It permits disabling that child,
but refuses to enable a parent while any blocked descendant remains configured
on. This prevents enabling one gate from unexpectedly activating descendants.

The five later flags appear in a separate "Later stages" section with an
Unavailable badge and no form control:

- `memory.window_summaries.enabled`
- `memory.session_summary_v2.enabled`
- `memory.fact_extraction_v2.enabled`
- `memory.procedure_extraction_v2.enabled`
- `memory.recall_v2.enabled`

The UI must not imply that those stages have production consumers.

## Live Event Notifications

Publish a lightweight notification on `memory:v2:events` only after the
enclosing transaction commits and only for newly inserted events. Duplicates
do not appear as new activity.

The PubSub notification contains only fields needed to decide whether to reload
or mark a historical view stale:

```elixir
%{
  id: event.id,
  stream_id: event.stream_id,
  event_type: event.event_type,
  project: event.project,
  agent_id: event.agent_id,
  session_id: event.session_id,
  run_id: event.run_id,
  tool_name: event.tool_name,
  status: event.status,
  occurred_at: event.occurred_at
}
```

It contains no content or payload. To make the commit boundary exact, each
newly inserted event issues a transactional PostgreSQL `NOTIFY` containing only
its event ID. PostgreSQL releases the notification on commit and discards it on
rollback, including an enclosing transaction owned by a caller. A supervised
`Backplane.Memory.EventNotifier` listener fetches the now-visible row, builds
the safe summary above, and broadcasts it on `memory:v2:events`. Store-owned
append paths, observation/session dual-write paths, and batch insertion all use
this one transactional mechanism.

On connected mount, each LiveView subscribes before performing its
authoritative persisted reload. An event committed before subscription is
included by the reload; an event committed after subscription is delivered as
a notification. PubSub is an acceleration path, never a durability mechanism.

## Visual System

The aesthetic is an operational instrument panel rather than a generic
dashboard:

- dense information hierarchy with restrained spacing;
- DuskMoon surface elevation for structure;
- primary/cyan accents reserved for event flow and selection;
- success green for effective gates and successful events;
- warning/error colors only for actual degraded states;
- monospaced treatment for IDs, sequences, event types, and timestamps;
- plain body typography for explanation and content.

Use existing DuskMoon components:

- `dm_card` and `dm_stat` for overview regions;
- compact `dm_table` with hover and zebra treatment for streams/events;
- `dm_badge` for event type, status, and closure state;
- `dm_input` and `dm_select` for filter controls;
- `dm_switch` for rollout gates;
- `dm_timeline` for the bounded stream sequence;
- `dm_alert` for query and mutation failures;
- `dm_btn` for pagination and confirmation actions.

Do not introduce a drawer custom element. Stream/event detail uses a responsive
two-column LiveView layout that stacks below the list on narrow screens. This
avoids adding an unregistered custom element to the admin bundle.

The interface must work in both `sunshine` and `moonlight` themes. On narrow
screens, filters wrap, details stack, and tables remain horizontally
scrollable with headers visible.

## Error and Empty States

- Database or query failure: render a visible error alert; never substitute a
  misleading empty count.
- Invalid URL filter or cursor: discard the invalid value, patch to the
  canonical URL, and show a concise flash.
- Unknown stream or event detail: return the admin not-found response.
- PubSub interruption: retain persisted results and reload on reconnect.
- No streams/events: render an intentional empty state with current rollout
  status and a link to Pipeline.
- Gate dependency violation: keep state unchanged and explain the required
  transition order.

## Security and Privacy

- Memory V2 routes use a fail-closed browser pipeline. Extend
  `Backplane.Web.AdminAuthPlug` with a required mode (or an equivalent dedicated
  plug): valid configured credentials pass, invalid credentials receive 401,
  and missing credentials receive a 503 configuration error rather than
  anonymous access.
- Apply the documented TOML admin username/password in production and support
  `BACKPLANE_ADMIN_USERNAME` and `BACKPLANE_ADMIN_PASSWORD` for remote
  development.
- The development admin endpoint listens on IPv4 `0.0.0.0:4221`, as required
  for remote development, but Memory V2 remains unavailable until credentials
  are configured.
- No V2 UI route mutates events or streams.
- Content and payload are always escaped; payload is never rendered as raw
  HTML.
- Live notifications contain no content or payload.
- The UI displays already-sanitized persisted event data but continues to
  treat it as potentially sensitive operational information.
- Dual Write activation requires explicit confirmation because it changes the
  persistence path.

## Legacy UI Removal

Delete the legacy LiveViews for Browse, Stats, Observations, Sessions, Graph,
Actions, Audit, and Config. Rewrite the existing Overview LiveView for V2.
Remove their navigation entries, routes, and UI-specific tests.

Do not delete the underlying domain contexts, schemas, migrations, MCP tools,
workers, or projection behavior.

## Testing Strategy

Implementation follows red-green-refactor.

### Memory application tests

- `Operations.overview/0` returns persisted and runtime values with honest
  labels.
- Persisted event-volume buckets use stable UTC boundaries.
- Stream listing filters, stable keyset pagination, and cursor validation.
- Latest/older/newer sequence windows remain bounded and ordered with no
  duplicated or skipped boundary sequence.
- Event timeline filter normalization and status filtering.
- Stream/event not-found behavior.
- Gate writes accept only booleans and enforce dependency order.
- Pre-existing configured-but-ineffective gate states can only move toward a
  safe, consistent hierarchy.
- `Events.append/1` and `append_batch/1` persist and allocate sequences.
- Post-commit notifications fire for inserted events, not duplicates or rolled
  back outer transactions.
- Subscribe-before-reload closes the reconnect notification gap.

### Admin LiveView tests

- All four navigation destinations render.
- Legacy Memory routes return 404.
- Overview shows effective gates and distinguishes persisted from runtime
  metrics.
- Stream and event filters are reflected in canonical URLs.
- Detail routes are shareable and show the expected identity fields.
- Pagination remains bounded.
- Live insertions reload only the newest matching view and preserve sort order
  for delayed `occurred_at` values.
- Historical views show "new events available".
- Switches enforce dependency order and Dual Write confirmation.
- Query and settings failures show alerts rather than zero-value fallbacks.
- Independent overview regions survive another region's query failure.
- Unimplemented stages have no editable controls.
- Remote Memory routes reject anonymous requests and fail closed when admin
  credentials are absent.

### Browser verification

Verify against the running admin endpoint:

- both DuskMoon themes;
- desktop and narrow viewport layouts;
- keyboard traversal and visible focus;
- accessible switch labels and confirmation flow;
- event/stream filter usability;
- detail layout and large bounded payload rendering;
- live event arrival without page refresh.

## Rollout

Add a schema migration with descending keyset indexes for
`bpm_streams (last_event_at DESC NULLS LAST, stream_id DESC)` and
`bpm_events (occurred_at DESC, id DESC)`. This is an index-only migration with
no row rewrite. Create and drop both indexes concurrently with the Ecto
migration DDL transaction disabled so existing ingestion is not write-blocked.

Fresh installations start with all three gates disabled. Existing
installations display their persisted configured values and separately show
their effective values, including any configured-but-blocked hierarchy.
Operators move inconsistent state toward safety or enable disabled gates in
dependency order from Pipeline.

The UI does not auto-enable V2 during deployment. Deployment and rollback
remain safe because disabling the gates in reverse order restores the legacy
write path while the V1 projections remain present.

## Acceptance Criteria

- The Memory navigation contains only Overview, Streams, Events, and Pipeline.
- Every removed legacy route returns 404.
- Overview and list/detail pages read the V2 stream/event model through
  `Backplane.Memory.Operations`.
- Streams and events remain inspect-only.
- The three implemented gates are editable with dependency enforcement.
- Five future stages are visible but unavailable.
- Live event notifications occur only after commit and contain no content or
  payload.
- Newest-page live updates remain correctly sorted for delayed events, and
  reconnect cannot miss a commit between subscription and reload.
- Event facade append calls persist.
- Error states are explicit and never masquerade as zero data.
- Keyset indexes support the declared stream and global event orderings.
- Memory V2 routes fail closed without configured admin credentials while the
  development endpoint listens on `0.0.0.0:4221`.
- Both themes and narrow layouts pass browser verification.
- V1 backend projections and public contracts remain intact.
