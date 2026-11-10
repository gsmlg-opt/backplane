# Backplane Memory for OpenClaw

This package uses OpenClaw **2026.10.10** public plugin APIs and Node
**24.22.1** (`>=24.22.1 <25 || >=26.12.1`). It connects OpenClaw to Backplane
Memory: one memory store shared by all of the user's agents and hosts, reached
through the local Backplane host agent. Changing this source package does not
update an installed plugin.

## Install

Install with the host-agent plugin installer (admin UI or host agent), which
copies every file in this directory plus the shared `INSTRUCTIONS.md` into
`~/.openclaw/extensions/backplane-memory`. To copy by hand, also copy
`../shared/INSTRUCTIONS.md` beside `plugin.mjs`. There are no npm dependencies;
the delivery journal uses `node:sqlite`.

The host agent must be running, normally on `http://127.0.0.1:4222`. Configure
`~/.openclaw/openclaw.json` and restart OpenClaw:

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
          "agent_id": "openclaw",
          "profile_id": "default",
          "token_budget": 2000,
          "search_limit": 8,
          "timeout_ms": 5000
        }
      }
    }
  }
}
```

| Setting | Default | Meaning |
|---|---|---|
| `base_url` | `http://127.0.0.1:4222` | Host agent URL. A non-loopback `http:` URL logs one `plaintext_remote_transport` warning. |
| `agent_id` | `openclaw` | Agent id in `/memory/<agent_id>/call/...`; recorded as the agent on memories saved from OpenClaw. |
| `profile_id` | `default` | Separates delivery journals of several OpenClaw profiles. |
| `journal_path` | plugin state dir | Override for the delivery journal location. |
| `token_budget` | `2000` | Automatic context budget in UTF-8 bytes (128–32768), header and labels included. |
| `search_limit` | `8` | Memories searched for automatic context each turn (1–50). |
| `timeout_ms` | `5000` | Per-request timeout (100–20000). |

`hooks.allowConversationAccess` belongs beside `config`, under the plugin entry.
Without it no automatic hooks are registered (the tools still work) and a
`conversation_access_required` warning is logged. `config.enabled=false`
registers nothing and keeps the journal.

**Upgrading from an earlier version:** remove every `config` key not listed
above (the old per-agent mapping list, `native_sync`, `min_confidence`,
`fallback_on_error`). If OpenClaw passes them anyway, the plugin ignores them
and names them in one warning. Existing delivery journals are
kept; queued conversation captures are still delivered.

## What the plugin does

- **Instructions.** The memory prompt section carries the shared Backplane
  instruction text (`INSTRUCTIONS.md`, the same text the host serves over MCP)
  plus the OpenClaw names of the five tools. The installed copy beside
  `plugin.mjs` is used; a source checkout falls back to `../shared/INSTRUCTIONS.md`.
- **Automatic context.** `before_prompt_build` calls
  `POST /memory/<agent_id>/call/search` with `{"query": <turn text>, "limit": 8}`
  and prepends the results as attributed data: each entry shows its kind, host,
  agent, observation time and id (labels are single-line and cannot open or close
  an entry). Entries are whole or skipped; inactive records are skipped; results
  answered from the host's offline cache are marked.
- **Tools.** Each tool calls the host's direct endpoint
  `POST /memory/<agent_id>/call/<tool>`:

  | OpenClaw tool | Backplane tool |
  |---|---|
  | `backplane_memory_search` | `memory::search` |
  | `backplane_memory_get` | `memory::get` |
  | `backplane_memory_recent` | `memory::recent` |
  | `backplane_memory_remember` | `memory::remember` (adds the current `session_id`) |
  | `backplane_memory_forget` | `memory::forget` (`id` and `reason` required) |

  Unknown arguments are dropped; host-stamped provenance (host, agent,
  integration, writer, request key, observed time) cannot be set from a tool
  call. A failed call returns `{"success": false, "error", "http_status"}` to
  the model instead of throwing.
- **Provider runtime.** OpenClaw's memory search/get runtime uses the same
  `search` and `get` calls. The compaction flush plan persists with
  `backplane_memory_remember` and looks up with search/get/recent.
- **Conversation capture.** The turn's original input (before any recalled
  context), the new assistant/tool messages from `agent_end` and a content-free
  `session_end` closure are queued in the local journal and posted to
  `/capture/v1/hooks/openclaw/<session-start|message|session-end>`
  (`openclaw_capture.v1`). Accepted events are settled through
  `/capture/v1/status`. `agent_end` only captures the verified new suffix of a
  turn whose input was captured; it never re-captures history or recalled text.

Automatic context and capture run only for a real conversation turn of the
owner: not for maintenance runs (`trigger: memory`), sandboxed callers,
conversations shared with other people, or when OpenClaw's tool policy disables
`backplane_memory_search` (context) or `backplane_memory_remember` (capture).

OpenClaw's own `USER.md` and `MEMORY.md` files are not mirrored into Backplane.

## Failure behaviour

The host agent being down, slow, older, or answering `gateway_unavailable`
(503) never breaks a turn: there is simply no memory context, one content-free
warning is logged per failed request, and nothing is thrown into OpenClaw.
Writes made through the host are queued by the host while the gateway is
offline. Captures stay in the journal and are retried in order with backoff; a
capture the host rejects (400/401/403/404/409/413/422) is marked rejected
without blocking later ones. After 12 failed attempts a capture is
dead-lettered.

## Privacy

The local egress policy removes well-formed `<private>...</private>` blocks and
recognised credential patterns from captured text and search queries. Malformed
or nested private blocks send nothing. Host capture filtering still applies.
Regex redaction does not catch every secret. The host HTTP API trusts local
processes.

## Delivery journal

The profile-local SQLite journal holds ordered, immutable capture payloads and
turn fences only — it is never a memory store. Pending work is bounded to 4096
events / 32 MiB. Shutdown aborts in-flight requests and closes the journal after
the worker settles; crash recovery does not depend on a graceful shutdown.
