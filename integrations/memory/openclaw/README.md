# Backplane Memory for OpenClaw

This package uses OpenClaw **2026.10.7** public plugin APIs and Node
**24.22.1** (`>=24.22.1 <25 || >=26.12.1`). It integrates a local Backplane
host agent with canonical Backplane Memory. Source changes, conversation evidence
and provider facts retain separate ownership and delivery states.

See [the integration review](../../../docs/memory/openclaw-memory-integration.md)
for release qualification and real-host evidence. Changing this source package
does not update an installed user plugin.

## Install and authorize

Install through the existing host-agent plugin installer, or copy **every file**
in this directory into the OpenClaw extension directory. The package has no npm
dependencies; the SQLite journal uses `node:sqlite`.

The host agent must expose its existing Memory HTTP API, normally on loopback
port 4222, and have a valid canonical host binding. Obtain the existing authorized
access UUID using the operator's `source_capabilities` diagnostic; labels, cwd and
the URL agent ID cannot create a grant:

```bash
curl --fail http://127.0.0.1:4222/memory/main/call/source_capabilities \
  -H 'content-type: application/json' -d '{"integration":"openclaw"}'
```

Configure `~/.openclaw/openclaw.json` and restart OpenClaw:

```json
{
  "plugins": {
    "slots": {"memory": "backplane-memory"},
    "entries": {
      "backplane-memory": {
        "enabled": true,
        "hooks": {"allowConversationAccess": true},
        "config": {
          "base_url": "http://127.0.0.1:4222",
          "profile_id": "default",
          "bindings": [
            {"agent_id": "main", "memory_access_id": "<existing authorized access UUID>"}
          ],
          "token_budget": 2000,
          "native_sync": true,
          "fallback_on_error": true,
          "timeout_ms": 5000
        }
      }
    }
  }
}
```

`hooks.allowConversationAccess` belongs beside `config`, under the plugin entry.
Missing or denied permission registers no automatic conversation hooks and emits
an actionable diagnostic. Tools and provider-runtime calls use their independent
caller and tool authorization. Setting `config.enabled=false` registers no active
provider, hooks, tools or worker and preserves the journal.

The Backplane canonical and host peers must negotiate `memory_sources.v1`,
`openclaw_source.v1` and `openclaw_capture.v1` as appropriate. An older
Hermes-only peer does not qualify. Unsupported source/capture operations defer or
refuse; they never fall back to append-only `remember`.

## Audience and policy

Version 1 accepts only a live host-minted **owner-private** audience matching the
actual `ctx.agentId` and an explicitly configured existing access UUID. Missing,
conversation/group/thread, cross-agent and sandboxed audiences are refused before
I/O. Explicitly configuring several owner agents with the same access allows
intentional sharing under that existing grant. This package does not create a
new administrative partition hierarchy.

The plugin rechecks public audience/invocation assertions before I/O, local
admission and result release. It consumes finalized tool authority for automatic
work: search permits recall, save permits capture, and save/correct/withdraw
together permit native synchronization. Read-only granted access can search/get
without source write readiness. Capture and native synchronization require the
selected access to equal the host's negotiated default capture binding.

The host HTTP API trusts local processes. This adapter does not claim isolation
against hostile local processes, modified plugins or a modified OpenClaw runtime.
Sessionless host/operator provider handles offer content-free health only.

## Capture and native files

`before_prompt_build(event, ctx)` durably admits the original request, separately
from its model-only recall projection. It records actual session ID/key, run ID,
agent, origin and an immutable preturn fence. `agent_end` admits only the verified
new assistant/tool suffix; it never combines a new question with an old answer.
Unknown or changed boundaries fail explicitly. Tool-only and empty assistant
turns cannot borrow earlier prose. Input provenance remains distinct from user
role; synthetic input is not human confirmation.

Canonical extraction excludes explicitly synthetic inputs from user assertions
and corrections. Missing input origin remains unknown and may support only
candidate inference; OpenClaw user confirmation additionally requires explicit
`external_user` provenance.

The stable embedded host does not supply a durable message cursor through these
hooks. The adapter uses its verified preturn fence and real run identity; it does
not invent native message IDs or session IDs. A crash before an observation hook
runs can leave an unobserved suffix; there is no private transcript import.
`session_end` sends a content-free closure only for an exact previously admitted
session, using its frozen original binding. It does not read the ended transcript
or turn session closure into a new content grant.

Native synchronization reads only workspace `USER.md` and `MEMORY.md` at an
authorized prompt boundary. Startup/re-enable recovery replays admitted work;
the next authorized prompt performs the fresh native scan. Each whole document
has a durable entry UUID across edits, sessions and process restarts. Complete
stable snapshots reuse source mutations and begin/page/commit reconciliation.
Files over 262144 UTF-8 bytes, symlinks, invalid UTF-8, concurrent changes and
unreadable inventories are deferred whole and cannot cause mass withdrawal.
Successfully read empty files and confirmed deletion can withdraw their source.

Synchronization is one-way. Provider tools never rewrite native files. Correct a
native-backed record through OpenClaw's authoritative file workflow, then allow a
new authorized prompt to reconcile it. Provider-owned facts have independent
source entry IDs. Withdrawing one contribution preserves independent support;
explicit global forget suppresses the canonical record across later snapshots.

The local egress policy removes well-formed `<private>...</private>` blocks and
recognized credential patterns. Malformed/nested private blocks fail closed.
Host capture filtering still applies. Regex redaction does not identify every
possible secret; operators control whether these sources may leave OpenClaw.
Capture completeness (`original_length`, `original_sha256`, `coverage: full`)
describes the entire admitted, redacted wire content. It does not claim a full
archive or hash of the original text before privacy removal. Model-only recall
projections are excluded from original user capture.
The SDK's trusted `trigger: memory` identifies detached pre-compaction maintenance.
It has no guaranteed original-input provenance, so automatic conversation capture
and recall skip that trigger. Its admitted provider search/save/correct tools
remain available and retain their own authorization and source provenance.

## Tools and provider runtime

| Tool | Behavior |
|---|---|
| `backplane_memory_search` | Authorized current recall, separating canonical and provisional results |
| `backplane_memory_get` | Exact online canonical UUID read; no list scan |
| `backplane_memory_save` | Durable provider-owned candidate; returns entry/event IDs and delivery state |
| `backplane_memory_correct` | Replace an exact provider entry ID |
| `backplane_memory_withdraw` | Withdraw only that exact provider source contribution |
| `backplane_memory_forget` | Explicit global canonical deletion, requiring `confirm_global=true` |
| `backplane_memory_status` | Delivery counts/errors and source IDs without memory bodies |

Provider-runtime search/get are caller-bound. Provisional references use
`pending:` opaque IDs and cannot masquerade as canonical UUIDs; summary/lesson
IDs are not advertised as canonical records. Pagination, project filtering,
session-transcript corpora and score-threshold filters are not advertised.
Search failure or denial is an error, never an unexplained empty success.

The provider-owned flush plan declares Backplane persistence and lookup tools.
Actual OpenClaw tool/audience/sandbox/timing policy still applies. A host-supplied
`memoryFlush.flushId` plus stable per-fact `fact_key` deduplicates retries;
changed immutable work conflicts. Search alone is not persistence. A legitimate
final `NO_REPLY` can complete a no-op. Optional flushing does not promise to block
compaction, and a host acceptance receipt does not prove canonical commitment.
Memory Core sidecar file writes are not Backplane persistence.

## Delivery and recall limits

The profile-local SQLite journal retains immutable payloads, original timestamps,
sequence allocation, binding fingerprints, source mappings and cursors. It is
never a recall store. It bounds pending work to 4096 events/32 MiB, caps database
pages, preserves stage order on lost ACKs, retries with backoff and reports
`local_pending`, `host_accepted`, `canonical_committed`, `deferred`, `rejected`
and `dead_letter` separately. Exhausted retries do not prove remote rejection.

Accepted historical work can replay after the live invocation ends. New work
and visible reads require live authority. Changed/revoked Backplane bindings
reject delivery under its original binding; queued work is never relabeled.
Shutdown aborts owned requests and closes the journal after its worker settles;
crash recovery does not depend on graceful shutdown. Disabling/rollback preserves
journals, source suppression and global-forget tombstones. Do not deploy older
readers that ignore effective source support after withdrawal.

`token_budget` defaults to 2000 and accepts 128–32768 **UTF-8 bytes**, a
conservative upper bound on byte-tokenizer tokens. The request budget and final
adapter budget both apply. All labels, IDs, citations and separators count;
oversized entries are skipped whole. Shared current-context eligibility and
calibrated relevance apply, with no adapter cache and no RRF/confidence threshold.
Irrelevant queries can inject nothing. `min_confidence` was reserved; it is now
deprecated and ignored with a migration diagnostic. `agent_id` is retained only
as a legacy configuration field; actual operations use the SDK agent identity.

## Legacy audit

Run the explicit local-operator read-only audit on at most 100 records per page:

```bash
node rollout.mjs --operator-read-only --base-url http://127.0.0.1:4222 \
  --agent-id main --access-id '<existing UUID>' --limit 25
```

Resume with the returned `next_cursor.offset` and `binding_fingerprint` using
`--offset` and `--binding-fingerprint`. It preserves canonical IDs and stored
session fields, reports unknown coverage and ambiguous origin, and has no apply,
delete or rejected-command replay path. The public list/get API does not expose
the old integration marker: an agent label alone cannot reliably identify legacy
OpenClaw data. Reliable import needs a trusted original export; old run IDs are
never guessed into real sessions and missing truncated text is never fabricated.
