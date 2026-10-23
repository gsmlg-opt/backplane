# Backplane Memory for Hermes Agent

Persistent cross-session memory for [Hermes Agent](https://github.com/NousResearch/hermes) backed by the Backplane host agent's local Memory HTTP API.

## How it works

```
Hermes ──HTTP──▶ Backplane host agent ──WebSocket──▶ Backplane hub ──Postgres+pgvector
        :4222                                       (memory::* tools)
```

The host agent runs locally, authenticates to the Backplane hub with a host token, then exposes `/memory/:agent_id/...` on `127.0.0.1` for processes on the machine. This plugin follows Hermes' `MemoryProvider` contract. The host controls the memory partition and bound scope; the plugin leaves scope unset by default. A Hermes working directory such as `/Users/gao/.dotfiles` is not a scope key and never overrides that binding. Local writes may remain provisional until the hub acknowledges them.

## Prerequisites

1. Backplane hub running and reachable.
2. Backplane host agent running locally with `agent.http_port` set in `~/.config/backplane/host_agent.yaml`, for example:

   ```yaml
   agent:
     machine_name: my-laptop
     hub_url: https://backplane.example.com
     token: <host-token-from-admin-ui>
     http_bind: 127.0.0.1
     http_port: 4222
   ```

   Start it with `mix agent.run` (from a Backplane checkout). See [the Host Agents admin page](http://localhost:4220/admin/system/host-agents) for the full setup walkthrough.

## Install

The host agent can install the packaged plugin:

```bash
curl http://127.0.0.1:4222/memory/hermes/mcp \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"host_agent::install_plugin","arguments":{"plugin":"memory","runtime":"hermes"}}}'
```

Then in `~/.hermes/config.yaml`:

```yaml
memory:
  provider: backplane-memory
```

Restart Hermes.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `BACKPLANE_MEMORY_URL` | `http://127.0.0.1:4222` | Host agent base URL |
| `BACKPLANE_MEMORY_AGENT_ID` | `hermes` | Logical agent id used in the URL path |

The plugin also reads `~/.config/backplane/host_agent_client.env` (or `$XDG_CONFIG_HOME/backplane/host_agent_client.env`) at import time using `os.environ.setdefault`, so anything you set explicitly in the shell wins.

## What Hermes gets

| Hook | Backplane call |
|---|---|
| `is_available()` | Read-only `list` probe (`limit=1`) |
| `system_prompt_block()` | `list` (most-recent N memories in the host-bound partition) |
| `prefetch(query)` | `recall` with the user query |
| `queue_prefetch(query)` | fire-and-forget `recall` |
| `sync_turn(user, assistant)` | `remember` (`type=episodic`) |
| `on_pre_compress(messages)` | `recall` + inject context before compaction |
| `on_memory_write(action, target, content)` | `remember` (`type=semantic`) |
| Tool: `memory_recall` | `recall` |
| Tool: `memory_save` | `remember` |
| Tool: `memory_list` | `list` |
| Tool: `memory_forget` | `forget` |

Memory tools return the full host result, including authority, consistency and the separate `provisional_results` list sideband. Pending entries do not change canonical list pagination. Prompt context displays pending local memories separately, and recalled pending entries carry a `[pending local memory]` label until canonical acknowledgment.

## Troubleshooting

**`hermes memory status` reports unavailable** — `is_available()` makes a read-only `list` request. Check that the host Memory API is running and its partition is configured. A successful probe confirms a read at that moment; it does not prove write permission or canonical synchronization.

**`invalid_scope` / `invalid_arguments` with a working directory** — update the installed plugin. Older versions sent cwd as scope. The current plugin uses the host binding by default; an explicit `memory_list.scope` is still checked by the host and can be rejected.

**`memory_scope_mismatch`** — the host agent's YAML `memory.bound_scope` must exactly match the host's `memory_scope` registered in Backplane Admin. Correct the configuration and restart the complete host-agent process; restarting Hermes alone does not reload it. Scope correction does not automatically rebind stored records or replay rejected commands.

**Empty context or a failed tool call** — prompt hooks continue without injected memories on errors and print a redacted error code/status to stderr. Explicit memory tools return `success: false`, an error code, and the HTTP status when available. Request content and raw server errors are not included in diagnostics.

To exercise the actual packaged provider against a running host agent:

```bash
python3 integrations/memory/hermes/smoke_test.py \
  --base-url http://127.0.0.1:4222 --agent-id hermes \
  --cwd /Users/gao/.dotfiles
```

The script writes one uniquely tagged test record, checks list readback, recall and prompt injection, verifies that cwd cannot override scope, deletes the record, and checks that it is gone. Readback and deletion checks inspect both canonical results and the pending sideband. It exits nonzero on failure and attempts cleanup after a successful write. This verifies the selected host API, including provisional writes; canonical hub synchronization needs separate verification.

**503 "host agent is not connected"** — the host agent is up but its WebSocket channel to the Backplane hub isn't joined yet. Check the agent's logs.

**Plaintext warning to a non-loopback host** — set `BACKPLANE_MEMORY_URL` to an `https://` URL or tunnel over SSH; the plugin warns once on stderr but still sends.

## License

Apache-2.0 (same as Backplane).
