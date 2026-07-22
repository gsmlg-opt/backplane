# Deploying the Backplane Host Agent {{VERSION}}

The host agent runs on any machine that should sync skills from a Backplane
hub, expose local `day::`/`math::`/`memory::` tools, and proxy every other
tool call back to the hub over an authenticated channel.

## 1. Download

Grab the tarball for your platform from this release page:

- `host_agent-<version>-linux-x64.tar.gz`
- `host_agent-<version>-linux-arm64.tar.gz`
- `host_agent-<version>-macos-x64.tar.gz`
- `host_agent-<version>-macos-arm64.tar.gz`

Linux tarballs are built on Ubuntu 22.04 and require glibc 2.35 or newer.

Verify the matching `.sha256`, then extract:

```sh
tar -xzf host_agent-<version>-<platform>.tar.gz -C ~/.local/opt
```

## 2. Register the host on the hub

In the Backplane admin UI (`/admin` → System → Host agents), create a host to
obtain its `host_id` and auth `token`.

## 3. Configure

The agent reads YAML from `$BACKPLANE_HOST_AGENT_CONFIG`, defaulting to
`~/.config/backplane/host_agent.yaml`. Starting the agent without a config
writes a commented sample there. Minimal config:

```yaml
agent:
  host_id: <host id from the hub>
  machine_name: my-workstation
  hub_url: https://backplane.example.com
  token: <host auth token>
  interval_ms: 60000
  work_dir: ~/.local/share/backplane/host_agent
  # Local MCP/memory HTTP API; set http_port to 0 to disable.
  http_bind: 127.0.0.1
  http_port: 4222

memory:
  enabled: true

targets:
  - name: agents
    runtime: agent-skills
    path: ~/.local/share/backplane/host_agent/skills
    enabled: true
```

## 4. Run

```sh
~/.local/opt/host_agent/bin/host_agent start
```

The agent connects to the hub over WebSocket, heartbeats, syncs assigned
skills into the configured targets, and serves the local MCP endpoint at
`http://127.0.0.1:4222/memory/:agent_id/mcp`.
Tools not handled locally are forwarded to the hub with the host token.

## 5. Install memory plugins

The host-agent release packages the OpenClaw and Hermes memory plugins. Install
one through the local MCP endpoint:

```sh
curl http://127.0.0.1:4222/memory/host_agent/mcp \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"host_agent::install_plugin","arguments":{"plugin":"memory","runtime":"hermes"}}}'
```

Use `"runtime":"openclaw"` for OpenClaw. The installer writes
`backplane-memory` under the runtime's default plugin directory in the current
user's home directory and replaces an older copy by default.
