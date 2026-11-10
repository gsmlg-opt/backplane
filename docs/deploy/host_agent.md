# Deploying the Backplane Host Agent {{VERSION}}

The host agent runs on any machine that should sync skills from a Backplane
hub, expose local `day::`/`math::`/`memory::` tools, and proxy every other
tool call back to the hub over an authenticated channel. It can also export
host-local inference and embedding APIs to the hub through that connection.

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

On the trusted Backplane admin endpoint (port `4101`,
`/system/host-agents`), create a host to obtain its `host_id` and auth `token`.
Do not expose the admin endpoint on public ingress.

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
  bound_scope: proj_local # Must match the host's memory_scope in Backplane Admin.

targets:
  - name: agents
    runtime: agent-skills
    path: ~/.local/share/backplane/host_agent/skills
    enabled: true
```

Set `memory.bound_scope` to exactly the host's registered `memory_scope` in
Backplane Admin. A mismatch is rejected as `memory_scope_mismatch`. After
correcting the configuration, restart the complete host-agent process. A plugin
restart does not reload host configuration. Correcting the scope does not
automatically rebind existing records or replay rejected commands.

Memory writes reported as pending have been accepted locally and still await
canonical acknowledgment from Backplane. A successful plugin read probe confirms
API readability, not synchronization health or successful synchronization of
earlier writes.

## 4. Run

For local development, `devenv up` starts PostgreSQL, Backplane, and a `host-agent`
process together. It registers and validates a development host/token and writes
`.devenv/state/host-agent/host_agent.yaml` before starting the gateway. The agent
uses that generated configuration, reuses its identity and token on subsequent
starts, and disables EPMD. See [Local Development](../../README.md#local-development).

For an installed release:

```sh
~/.local/opt/host_agent/bin/host_agent start
```

The agent connects to the hub over WebSocket, heartbeats, syncs assigned
skills into the configured targets, and serves the local MCP endpoint at
`http://127.0.0.1:4222/memory/:agent_id/mcp`.
Tools not handled locally are forwarded to the hub with the host token.

The host-agent release defaults to `RELEASE_DISTRIBUTION=none` and disables
automatic EPMD startup. Manage its lifecycle with your process manager (for
example, launchd or systemd); `rpc`, `remote`, and the RPC-based `stop` command
are unavailable with the default distribution mode. Existing runtime VM options
are preserved, and the gateway release keeps its existing distribution defaults.

### Configure host-local API services

Apply the gateway database migrations when installing this version, and run an
agent version offering `host_api.v1`. An older agent can keep its existing
functions, but cannot forward these API requests.

In Backplane Admin, open **System → Host Agents → your host → API Services**
(`/system/host-agents/:id/services`). Add a service and fill in the complete
endpoint URL for each API it supports. Leave unsupported APIs empty. For example:

| API | Example endpoint URL |
| --- | --- |
| OpenAI Embeddings | `http://127.0.0.1:8001/v1/embeddings` |
| OpenAI Chat Completions | `http://127.0.0.1:8000/v1/chat/completions` |
| OpenAI Responses | `http://127.0.0.1:8000/v1/responses` |
| Anthropic Messages | `http://127.0.0.1:8000/v1/messages` |

URLs are interpreted on the host and used exactly as configured, including the
path and query. Configure the APIs actually implemented by the service; the
underlying server can be Ollama, SGLang, vLLM, or any compatible implementation.
The host's local IP/port need not be reachable from the gateway. Endpoint changes
are delivered over the existing authenticated WebSocket connection; they need no
agent YAML changes or restart. Inventory replacement retires in-flight calls on
that host, and the agent acknowledges the new configuration before further calls.

To use inference, create a **Llama → Providers → Custom** provider, choose the
**Host API Service**, and enable its declared API protocols. Add models manually
in the provider detail page, including the API surfaces on which each is usable.
Automatic model discovery is disabled for host services. To use embeddings,
choose the service in **Llama → Embedding** and configure its model. Requests keep
the normal `provider/model` routing; Memory can select the embedding model in its
existing embedding configuration.

A vault credential is optional for an unauthenticated host-local service. For a
service requiring authentication, select the provider's vault credential and
configure its normal default headers. Credentials are resolved only for the
request and excluded from the service inventory. Client authentication headers
and cookies are stripped before the selected provider headers are injected.

Calls support ordinary JSON and SSE streaming. Upstream HTTP error statuses and
bodies are preserved. Disconnects, cancellation and configuration replacement
stop remote forwarding; ambiguous inference requests are not automatically
replayed. The initial transport supports POST calls for the four declared APIs.
Responses lifecycle operations and Responses WebSocket transport are unavailable
for host-linked providers; disable those options before moving an existing
provider to a host service.

Limits: 64 configured services per host, 2,048 bytes per endpoint URL, eight
concurrent calls per connection, 384 KiB request bodies, 50,000,000-byte responses,
and acknowledged response chunks of at most 48 KiB. Calls use a 120-second request
deadline/idle limit; each channel frame acknowledgment has a 30-second timeout.
An unavailable or unregistered host returns an API error without direct HTTP
fallback. Request bodies over the transport limit return HTTP 413.

## 5. Install memory plugins

The host-agent release packages the memory plugins for Claude Code, Codex,
Cursor, Hermes and OpenClaw. Install one through the local MCP endpoint, setting
`runtime` to `claude_code`, `codex`, `cursor`, `hermes` or `openclaw`:

```sh
curl http://127.0.0.1:4222/memory/host_agent/mcp \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"host_agent::install_plugin","arguments":{"plugin":"memory","runtime":"claude_code"}}}'
```

The installer only writes files under the user's home directory and replaces an
older copy by default. It also installs the shared hook client at
`~/.local/share/backplane/bin/backplane-memory-hook`. The result lists
`next_steps`; run them yourself:

| Runtime | Next steps |
| --- | --- |
| `claude_code` | `claude plugin marketplace add ~/.local/share/backplane/plugins/claude` then `claude plugin install backplane-memory@backplane-local` |
| `codex` | `codex plugin marketplace add ~/.local/share/backplane/plugins/codex` then `codex plugin add backplane-memory@backplane-local`. Then start Codex interactively once and trust the backplane-memory plugin hooks when prompted; Codex does not run plugin hooks until they are trusted. |
| `cursor` | Restart Cursor. Hooks and MCP are merged into `~/.cursor/hooks.json` and `~/.cursor/mcp.json`; the first change keeps a `*.backplane-backup` copy, and removing the plugin restores your own entries. |
| `hermes` | Installs to `~/.hermes/plugins/backplane-memory`. Enable the provider in the Hermes profile config (`memory: provider: backplane-memory`) or run `hermes memory setup backplane-memory`, then restart Hermes. |
| `openclaw` | Installs to `~/.openclaw/extensions/backplane-memory`. In `~/.openclaw/openclaw.json` set `plugins.slots.memory` to `"backplane-memory"`, and on `plugins.entries.backplane-memory` set `enabled` and `hooks.allowConversationAccess` to `true` (see the plugin README); then restart OpenClaw. |

After reinstalling Claude Code's plugin with a different host-agent URL, run
`claude plugin update backplane-memory@backplane-local` and restart Claude Code:
Claude caches installed plugins by version, so the new URL is not picked up
otherwise.

### Remove

Remove the plugin from the client first (or immediately after removing it
through the host agent). Removing deletes the installed package and, when no
other client still uses it, the shared hook client; a client that still has the
plugin enabled would then call a deleted hook client on every hook. Remove with
`host_agent::remove_plugin` (same arguments as install); its `next_steps` list
the client-side commands:

| Runtime | Client-side removal |
| --- | --- |
| `claude_code` | `claude plugin uninstall backplane-memory@backplane-local` then `claude plugin marketplace remove backplane-local` |
| `codex` | `codex plugin remove backplane-memory@backplane-local` then `codex plugin marketplace remove backplane-local` |
| `cursor` | Restart Cursor (Backplane's hook and MCP entries are removed from `~/.cursor/*.json`). |
| `hermes` | `hermes memory off`, then restart Hermes. |
| `openclaw` | Remove `plugins.slots.memory` and `plugins.entries.backplane-memory` from `~/.openclaw/openclaw.json`, then restart OpenClaw. |

Capture hooks never block or fail the agent when the host agent is down. Set
`BACKPLANE_HOST_AGENT_URL` to override the host-agent URL for the hook client.
See [Memory architecture](../architecture/memory.md#plugins).
