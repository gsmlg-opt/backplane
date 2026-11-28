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

The agent reads one TOML or YAML configuration file. Use
`BACKPLANE_HOST_AGENT_CONFIG` to select an explicit path. The installed agent
looks in `$XDG_CONFIG_HOME/backplane` (normally `~/.config/backplane`) for
`host_agent.toml` first, then `host_agent.yaml`. Starting with a missing
explicit path writes a sample in the format indicated by its extension.

A minimal `host_agent.toml` looks like this.

```toml
[agent]
host_id = "<host id from the hub>"
machine_name = "my-workstation"
hub_url = "https://backplane.example.com"
token = "<host auth token>"
interval_ms = 60000
work_dir = "~/.local/share/backplane/host_agent"
manifest_path = "~/.local/share/backplane/host_agent/manifest.json"
http_bind = "127.0.0.1"
http_port = 4222  # Set to 0 to disable the local HTTP listener.

[memory]
enabled = true
bound_scope = "proj_local"

[[targets]]
name = "agents"
runtime = "agent-skills"
path = "~/.local/share/backplane/host_agent/skills"
enabled = true
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

### Connect an agent to Chrome DevTools

Start a dedicated Chrome or Chromium profile on the host. Every client of the
host-agent MCP endpoint can operate pages in this profile. Keep both listeners
on loopback when using it locally.

```sh
chromium --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 \
  --user-data-dir="$HOME/.local/share/backplane/chrome-cdp"
```

Add the following section to the active `host_agent.toml` and restart the host
agent. In a YAML configuration, the same keys go under a top-level `cdp:` map.

```toml
[cdp]
enabled = true
port = 9222
# Optional existing directories for saved artifacts and input files
artifact_dir = "./chrome-artifacts"
upload_dir = "./chrome-inputs"
```

`port` selects Chrome’s loopback debugging port. `agent.http_port` selects
the MCP listener. Setting `enabled = true` defaults Chrome's port to 9222,
and specifying a port alone also enables CDP. Set `enabled = false` to disable
the local service even when a debugging port is set in the environment.

Relative CDP directories resolve from the configuration file’s directory.
For omitted settings, `BACKPLANE_CDP_PORT`, `BACKPLANE_CDP_ARTIFACT_DIR` and
`BACKPLANE_CDP_UPLOAD_DIR` are supported as per-field fallbacks. CDP is off
when neither an enable flag nor a debugging port is configured.

Use an explicit path when running the agent from the source checkout.

```sh
BACKPLANE_HOST_AGENT_CONFIG=./host_agent.toml mix agent.run
```

Point your agent's Streamable HTTP MCP client at the local endpoint.

```text
http://127.0.0.1:4222/mcp/chrome-devtools
```

The endpoint exposes bare Chrome DevTools tool names. It returns an
`Mcp-Session-Id` header on initialization, which the MCP client sends on
subsequent requests. Each session has its own page IDs, selected page, snapshot
UIDs and event history. All sessions operate the same configured Chrome profile.
The aggregate `/mcp` route also serves these tools under the `cdp::` prefix.

Call `list_pages` for a numeric page ID, then `take_snapshot` for element UIDs.
For example, an agent can fill a field with these tool arguments:

```json
{"name":"fill","arguments":{"pageId":1,"uid":"1_4","value":"Hello"}}
```

Tool descriptors come from the published `chrome-devtools-mcp` 1.14.0 default
catalog. The dedicated endpoint exposes all 33 descriptors.

- `evaluate_script` reads the selected document in an isolated JavaScript world
  with Chrome's side-effect checks. Use inline functions such as
  `(element) => element.innerText` with snapshot UIDs, or pass a classic script
  with `format: "script"`. The result can be a synchronous value or an already
  settled promise. Chrome rejects operations with possible side effects. Page
  application globals live in a separate world. `sourcePath` reads a regular
  UTF-8 file up to 128 KiB from `cdp.upload_dir`. `filePath` saves JSON.
- `set_logpoints` replaces the page's logpoints. For example,
  `["src/cart.ts:42 'total', cart.total"]` logs to `list_console_messages` on
  each hit. Pass `[]` to clear them. Expressions accept literals, variable
  names and dotted properties. Locations can use a served script or a v3
  source map. Original-source positions rebind after a bundle reload. Use
  runtime variable names for minified code. The resolver reads up to 16 inline
  or same-origin maps of 512 KiB each.
- `take_heapsnapshot` requires a new filename under `cdp.artifact_dir`.
  Chrome streams the snapshot into a private staging file. A successful capture
  publishes a DevTools-compatible `.heapsnapshot`. The capture limits are
  64 MiB and 120 seconds.
- `lighthouse_audit` uses Chrome's bundled Lighthouse engine. Choose
  `navigation` to reload the page or `snapshot` to audit its current state.
  Both accept `desktop` or `mobile`. The response includes category scores,
  failing audits and paths to HTML and JSON reports. Reports use temporary
  files by default. To save `report.html` and `report.json`, pass the
  configured artifact directory as `outputDirPath` with both names available.
  This tool requires a Chrome build with the Lighthouse panel and the CDP
  methods `Target.getDevToolsTarget` and `Target.openDevTools`.

Other host-specific behavior includes the following.

- Network inspection retains request metadata. Headers, cookies, request bodies,
  response bodies, and body file export are unavailable.
- Performance traces export Chrome trace data. The native insight processor
  reports DocumentLatency and DOMSize when Chrome records those measurements.
- CSS inspection returns computed values and matched rules. Its formatting and
  cascade annotations differ from DevTools. MP4 recording requires a Chrome
  version that provides `Page.startScreenRecording`.
- To save a named snapshot, screenshot, recording or trace, set
  `cdp.artifact_dir` to an existing output directory. Choose a new
  filename in that directory. For file inputs, set `cdp.upload_dir`
  to an existing directory containing the files available for upload.
- Script injection on navigation is unavailable. Pages opened by MCP use HTTP,
  HTTPS or `about:blank`.

The host release includes the native Elixir MCP implementation and uses
`http_web_socket` to talk to Chrome. The release CLI reads the same host
configuration and uses Chrome target IDs from its own `list_pages` output.

```sh
~/.local/opt/host_agent/bin/host_agent cdp --help
~/.local/opt/host_agent/bin/host_agent cdp new_page about:blank
~/.local/opt/host_agent/bin/host_agent cdp take_snapshot CHROME_TARGET_ID
```

From the source checkout, the standalone `mix cdp` task in `apps/backplane_cdp`
uses `BACKPLANE_CDP_PORT`. Run `mix cdp --help` for its command list.
Chrome runs independently and keeps its pages when the CLI or agent exits.

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
