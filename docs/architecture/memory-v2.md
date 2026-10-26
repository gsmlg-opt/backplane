# Backplane Memory architecture

The [2026-10-21 operator browsing clarification](../memory/adr-memory-space-partition.md#operator-browsing-clarification-2026-10-21) supersedes any requirement to choose source provenance before browsing. The trusted admin reads the central collection across existing canonical spaces, with optional host/repository filters. Public-client partition authorization remains enforced. Local checkout paths and Git repository identities are distinct provenance; neither is ownership.

Status: historical PR 0B/PR 1 architecture record, with the Feature controls and
Authority and routing sections updated for the current implementation. Earlier
dual-write and compatibility stages below describe the original rollout, not
available runtime modes. Current source/capture and command contracts are in the
[Hermes integration review](../memory/hermes-memory-integration.md) and
[host protocol](../memory/host-memory-v2-protocol.md).

## Runtime identity and boundary

Memory has two stable identities with different purposes:

- `:backplane_memory` is the OTP application name. It remains the app declared
  by [`apps/backplane_memory/mix.exs`](../../apps/backplane_memory/mix.exs), and
  the `backplane` release continues to start it as `:permanent` in
  [`mix.exs`](../../mix.exs).
- `Backplane.Memory.*` is the Elixir module namespace. New implementation code
  and in-repository callers use this namespace; changing it does not rename the
  OTP application, release entry, database tables, settings, or MCP tools.

Memory runs inside Backplane as an in-process managed service. At application
startup, [`Backplane.Memory.Application`](../../apps/backplane_memory/lib/backplane/memory/application.ex)
registers the tools returned by
[`Backplane.Memory.Service`](../../apps/backplane_memory/lib/backplane/memory/service.ex)
in the shared `Backplane.Registry.ToolRegistry`. Clients reach those tools
through Backplane's shared MCP transport. There is no standalone Memory MCP
server, separate Memory listener, or separate Memory network boundary.

The Memory service registration decision is boot-only. Startup reads
`services.memory.enabled` once; changing that setting later does not
dynamically register or deregister tools, and PR 0B adds no handler-level guard.
`Backplane.Settings` creates its ETS table synchronously but performs database
default seeding and loading from a subsequent `:seed_and_load` message. There is
therefore no readiness barrier guaranteeing that persisted settings have been
loaded before Memory makes its startup registration decision. This is an
existing startup-order caveat, not a settings-readiness redesign in this
milestone.

## Frozen MCP surface

The stable namespace is `memory::`. With the default tool selection, the
managed service exposes these exact 31 core tools:

```text
memory::facet_tag
memory::facet_query
memory::remember
memory::recall
memory::list
memory::forget
memory::stats
memory::profile
memory::profile_refresh
memory::expand_query
memory::file_history
memory::team_share
memory::team_feed
memory::lease
memory::signal_send
memory::signal_read
memory::action_create
memory::action_update
memory::frontier
memory::next
memory::smart_search
memory::sessions
memory::patterns
memory::timeline
memory::export
memory::relations
memory::compress_file
memory::audit
memory::governance_delete
memory::diagnose
memory::heal
```

When `memory.tools` is exactly the string `"all"`, these nine extended tools
are added for an exact full surface of 40:

```text
memory::graph_query
memory::graph_stats
memory::consolidate
memory::verify
memory::slot_read
memory::slot_write
memory::slot_list
memory::enrich
memory::access_log
```

PR 0B freezes the names, input schemas, managed-handler result shapes, and MCP
wire behavior of that surface. PR 1 may change how ingestion is persisted, but
it must not rename these tools or change successful observation, session, or
recall responses.

Compatibility is explicit and narrow:

- New code uses `Backplane.Memory.*` only.
- `BackplaneMemory`, `BackplaneMemory.Memory`,
  `BackplaneMemory.Observations`, and `BackplaneMemory.Service` remain as
  logic-free delegates for existing callers.
- Old persisted or externally enqueued Oban jobs remain executable through
  compatibility modules for `AccessWritebackWorker`, `EmbedWorker`,
  `EpisodicWorker`, `EvictionWorker`, `FallbackSweepWorker`,
  `GraphExtractWorker`, `LeaseCleanupWorker`, `ProceduralWorker`,
  `ProfileBuildWorker`, and `SummaryWorker`.
- Compatibility modules are not extension points for new implementation code.
  They can be removed only after external callers have migrated and old jobs
  can no longer reference the legacy names.

## Current full-text-search contract

The existing lexical recall path is retained as-is. The original
`bpm_memories` migration defines `search_tsv` as a PostgreSQL generated, stored
column:

```sql
to_tsvector('english', coalesce(content, ''))
```

The same migration creates the named GIN index
`bpm_memories_search_tsv_gin_idx`. The current search query refers to
`m.search_tsv` through Ecto's query binding in alias-aware fragments; it does
not hard-code `bpm_memories.search_tsv`, which would break once Ecto aliases the
table. When embedding search is unavailable, fails, or yields no eligible
rows, public recall falls back to ranked lexical matches using this generated
column and index.

The implementation anchors are
[`20260523000011_create_bpm_memories.exs`](../../apps/backplane_system/priv/repo/migrations/20260523000011_create_bpm_memories.exs)
and
[`Backplane.Memory.Memories.Search`](../../apps/backplane_memory/lib/backplane/memory/memories/search.ex).
PR 0B adds regression coverage but does not add or alter an FTS migration.

## Authoritative event target beginning in PR 1

PR 0B documents the target boundary; it does not implement it. At the end of
PR 0B there is no `bpm_streams` table, no `bpm_events` table, no event write
path, and no observation/event dual-write.

Beginning in PR 1, the ordered event stream becomes the authoritative record
of agent and session activity. The layers have these roles:

```text
ordered events                 authoritative ingestion history
    |
    +-- observations           legacy compatibility projection
    +-- memories               searchable derived projection
    +-- window/session summary derived projection (later milestones)
```

"Authoritative" means downstream state can carry provenance back to ordered
events and can be rebuilt or re-derived from them. It does not mean PR 1
deletes the current observation, memory, or summary tables. During migration,
those tables remain the compatibility and retrieval surfaces used by existing
callers.

The PR 1 dual-write target is atomic, not best-effort. Event insertion and the
legacy observation insertion are composed in one `Ecto.Multi` transaction. A
failure rolls back both writes; a success preserves the existing
`{:ok, %Observation{}}` return shape. Session lifecycle events are composed
with their corresponding legacy session transition under the same principle.
The existing legacy summary enqueue remains after a successful commit.

Event ingestion itself is deliberately bounded to normalization, privacy
filtering, sequence allocation, and database persistence. It performs no
inline LLM request, embedding request, or Oban enqueue inside the event
transaction. Existing post-commit workers for embeddings, summaries,
consolidation, access writeback, and other legacy behavior remain available;
the ingestion constraint keeps those asynchronous projections outside the
authoritative transaction rather than removing them.

## Feature controls

[`Backplane.Memory.Config`](../../apps/backplane_memory/lib/backplane/memory/config.ex)
exposes strict boolean controls backed by real defaults in
[`Backplane.Settings`](../../apps/backplane_system/lib/backplane/settings.ex).
Pipeline, session-summary, fact-extraction, recall and host-sync defaults are
boolean `true`; optional generation controls retain their own defaults.
An ETS or database value of the string `"true"` does not enable a feature.
Only the unversioned keys below are supported: old configuration names are not
read, aliased or migrated. A disabled recall returns `recall_disabled`, and sync
negotiation accepts only the current contract; neither falls back to an older
implementation.

| Setting | Accessor | Effective condition |
|---|---|---|
| `memory.pipeline.enabled` | `pipeline_enabled?/0` | its value is exactly `true` |
| `memory.window_summaries.enabled` | `window_summaries_enabled?/0` | pipeline and its value are exactly `true` |
| `memory.session_summary.enabled` | `session_summary_enabled?/0` | pipeline and its value are exactly `true` |
| `memory.fact_extraction.enabled` | `fact_extraction_enabled?/0` | pipeline and its value are exactly `true` |
| `memory.procedure_extraction.enabled` | `procedure_extraction_enabled?/0` | pipeline and its value are exactly `true` |
| `memory.recall.enabled` | `recall_enabled?/0` | its value is exactly `true`, independent of processing |
| `memory.host_sync.enabled` | `host_sync_enabled?/0` | its value is exactly `true`; controls mirror delivery only |

The dependency tree is therefore:

```text
memory.pipeline.enabled (background processing only)
|-- memory.window_summaries.enabled
|-- memory.session_summary.enabled
|-- memory.fact_extraction.enabled
`-- memory.procedure_extraction.enabled
```

Canonical event capture, projection repair, Access-bound commands and recall do
not depend on the background-processing switch. The earlier event-capture and
observation dual-write selectors are retired. Disabling mirror delivery withholds
delivery capability and offline leases while authenticated Access and commands
remain available. `memory.embed_model` is the only embedding selection shared by
storage and query generation; changing it resets the existing cosine cutoff
atomically, without copying any retired setting.

`services.memory.enabled` remains the separate, existing boot-time control for
registering the managed MCP service. `memory.tools` remains the separate
boot-time tool-catalog selector. Neither is replaced by the processing master gate.

## Authority and routing

The current host authority and routing contract is
[`host-memory-v2-protocol.md`](../memory/host-memory-v2-protocol.md). Backplane
owns canonical events, memories, partition/entitlement, governance, and edge
revisions; host capture, provisional commands, and the bounded edge mirror are
separate stores. Connected `memory::recall` uses the authorized canonical recall
pipeline; only classified transport failures permit stale mirror fallback.
The older [`host-agent-memory-design-final.md`](../host-agent-memory-design-final.md)
is historical context; its local-first memory authority and private legacy
uploader have been superseded. Server migrations through `20261026000002` retire
legacy runtime storage and preserve provable event identities. Host command-store
V7 quarantines unbound historical commands without inventing authority or replaying
them. All new default, private and shared writes use `memory_commands.v2`.

[`docs/memory-design.md`](../memory-design.md) remains useful context for the V1
schema, retrieval, embedding, consolidation, and host-agent goals that the
current implementation grew from. This record is the V2 evolution of that
design and supersedes it where the two documents differ.

The in-process module identity remains applicable. The earlier tool-count,
dual-write and compatibility milestones above retain their historical scope;
they do not restore retired selectors, schemas, workers or search implementations.
Use the current source and linked integration/protocol reviews to assess the
implemented canonical capture, extraction, evidence and recall paths.
