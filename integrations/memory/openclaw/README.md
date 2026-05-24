# Backplane Memory for OpenClaw

Persistent cross-session memory for [OpenClaw](https://github.com/openclaw/openclaw) backed by the Backplane host agent's local Memory HTTP API.

## How it works

```
OpenClaw ──fetch──▶ Backplane host agent ──WebSocket──▶ Backplane hub ──Postgres+pgvector
         :4221                                          (memory::* tools)
```

The host agent runs locally, authenticates to the Backplane hub once with a host token, then exposes `/memory/:agent_id/...` on `127.0.0.1` for any process on the machine. This plugin is a thin HTTP client that implements the OpenClaw memory-slot contract.

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

   Start it with `mix agent.run`. See [the Host Agents admin page](http://localhost:4220/admin/system/host-agents) for the full setup walkthrough.

## Install

```bash
mkdir -p ~/.openclaw/extensions
cp -r integrations/memory/openclaw ~/.openclaw/extensions/backplane-memory
```

Then in `~/.openclaw/openclaw.json`:

```json
{
  "plugins": {
    "slots": {
      "memory": "backplane-memory"
    },
    "entries": {
      "backplane-memory": {
        "enabled": true,
        "config": {
          "base_url": "http://127.0.0.1:4221",
          "agent_id": "openclaw",
          "token_budget": 2000,
          "min_confidence": 0.5,
          "fallback_on_error": true,
          "timeout_ms": 5000
        }
      }
    }
  }
}
```

Restart OpenClaw.

## What OpenClaw gets

- Claims the `plugins.slots.memory` slot via `api.registerMemoryCapability({ promptBuilder })`.
- `before_agent_start` — calls `recall` with the current prompt; prepends the top 5 matches as context.
- `agent_end` — persists each completed turn (`User:` + `Assistant:`) via `remember` (`type=episodic`).

## Configuration

| Key | Default | Description |
|---|---|---|
| `enabled` | `true` | Toggle the plugin without uninstalling it |
| `base_url` | `http://127.0.0.1:4221` | Host agent base URL |
| `agent_id` | `openclaw` | Logical agent id used in the URL path |
| `token_budget` | `2000` | Approximate context budget for the recall block |
| `min_confidence` | `0.5` | Reserved — currently informational |
| `fallback_on_error` | `true` | Swallow recall/remember errors silently instead of throwing |
| `timeout_ms` | `5000` | Per-request timeout |

## Troubleshooting

**Plugin validates but does not load** — ensure `package.json`, `openclaw.plugin.json`, and `plugin.mjs` are all present in the extension directory and that `plugins.slots.memory` is set to `backplane-memory`.

**Connection refused on port 4221** — the host agent is not running, or `http_port` is not set in `host_agent.yaml`. Add `http_port: 4221` and rerun `mix agent.run`.

**503 "host agent is not connected"** — the host agent is up but its WebSocket channel to the Backplane hub hasn't joined yet. Check the agent's logs.

**Plaintext warning to a non-loopback host** — set `base_url` to an `https://` URL or tunnel over SSH; the plugin warns once and still sends.

## License

Apache-2.0 (same as Backplane).
