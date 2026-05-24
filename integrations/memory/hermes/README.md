# Backplane Memory for Hermes Agent

Persistent cross-session memory for [Hermes Agent](https://github.com/NousResearch/hermes) backed by the Backplane host agent's local Memory HTTP API.

## How it works

```
Hermes ──HTTP──▶ Backplane host agent ──WebSocket──▶ Backplane hub ──Postgres+pgvector
        :4221                                       (memory::* tools)
```

The host agent runs locally, authenticates to the Backplane hub once with a host token, then exposes `/memory/:agent_id/...` on `127.0.0.1` for any process on the machine. This plugin is a thin HTTP client that follows Hermes' `MemoryProvider` contract.

## Prerequisites

1. Backplane hub running and reachable.
2. Backplane host agent running locally with `agent.http_port` set in `~/.config/backplane/host_agent.yaml`, for example:

   ```yaml
   agent:
     machine_name: my-laptop
     hub_url: https://backplane.example.com
     token: <host-token-from-admin-ui>
     http_bind: 127.0.0.1
     http_port: 4221
   ```

   Start it with `mix agent.run` (from a Backplane checkout). See [the Host Agents admin page](http://localhost:4220/admin/system/host-agents) for the full setup walkthrough.

## Install

```bash
cp -r integrations/memory/hermes ~/.hermes/plugins/backplane-memory
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
| `BACKPLANE_MEMORY_URL` | `http://127.0.0.1:4221` | Host agent base URL |
| `BACKPLANE_MEMORY_AGENT_ID` | `hermes` | Logical agent id used in the URL path |

The plugin also reads `~/.config/backplane/host_agent_client.env` (or `$XDG_CONFIG_HOME/backplane/host_agent_client.env`) at import time using `os.environ.setdefault`, so anything you set explicitly in the shell wins.

## What Hermes gets

| Hook | Backplane call |
|---|---|
| `system_prompt_block()` | `list` (most-recent N memories for the cwd scope) |
| `prefetch(query)` | `recall` with the user query |
| `queue_prefetch(query)` | fire-and-forget `recall` |
| `sync_turn(user, assistant)` | `remember` (`type=episodic`) |
| `on_pre_compress(messages)` | `recall` + inject context before compaction |
| `on_memory_write(action, target, content)` | `remember` (`type=semantic`) |
| Tool: `memory_recall` | `recall` |
| Tool: `memory_save` | `remember` |
| Tool: `memory_list` | `list` |
| Tool: `memory_forget` | `forget` |

## Troubleshooting

**`hermes memory status` reports unavailable** — the plugin's `is_available()` only validates the URL syntax; check that the host agent is actually running and listening with `curl http://127.0.0.1:4221/memory/hermes/mcp -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' -H 'content-type: application/json'`.

**503 "host agent is not connected"** — the host agent is up but its WebSocket channel to the Backplane hub isn't joined yet. Check the agent's logs.

**Plaintext warning to a non-loopback host** — set `BACKPLANE_MEMORY_URL` to an `https://` URL or tunnel over SSH; the plugin warns once on stderr but still sends.

## License

Apache-2.0 (same as Backplane).
