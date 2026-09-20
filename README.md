# Backplane

[![GitHub Release](https://img.shields.io/github/v/release/gsmlg-opt/backplane?logo=github)](https://github.com/gsmlg-opt/backplane/releases/latest)
[![Docker Image](https://img.shields.io/github/v/release/gsmlg-opt/backplane?label=docker&logo=docker)](https://github.com/orgs/gsmlg-dev/packages/container/package/backplane)
[![Hex.pm](https://img.shields.io/github/v/release/gsmlg-opt/backplane?label=hex.pm&logo=elixir&color=purple)](https://hex.pm/packages/backplane_mcp_protocol)

Backplane is a private, self-hosted gateway for agent infrastructure.

It has exactly two gateway features:

- **MCP Hub**: one MCP Streamable HTTP endpoint at `POST /mcp` that aggregates upstream MCP servers and built-in managed services.
- **LLM Proxy**: a credential-injecting, model-routing reverse proxy for LLM APIs, with provider health checks and usage tracking.

Operational configuration is managed through the Phoenix admin UI and persisted in PostgreSQL.

Skills, memory capture/recall, host-agent integration, and authentication are supporting services and HTTP surfaces, not separate gateway products. Tool-specific concerns are delivered through upstream MCP servers or managed MCP services.

## Umbrella Apps

This repository is an Elixir umbrella project. The main application boundaries are:

- `apps/backplane`: boot orchestration, managed-service registration, upstream startup, and Oban job configuration.
- `apps/backplane_system`: shared repository and migrations, settings, credentials, client tokens, configuration, and tool registry.
- `apps/backplane_mcp`: MCP transport, upstream proxy, native hub/admin tools, managed-service adapters, and math runtime.
- `apps/backplane_llama`: LLM routing, provider credentials, model aliases, embeddings, rate limiting, and access logs.
- `apps/backplane_api`: Phoenix public/API endpoint for `/`, `/mcp`, `/v1/*`, `/skills/*`, `/skill-protocol/v1/*`, `/api/memory/*`, `/host-agent/*`, OAuth routes, and host-agent sockets.
- `apps/backplane_admin`: Phoenix admin UI endpoint on its own port, with routes rooted at `/`.
- `apps/backplane_auth`: OAuth/OIDC, resource bearer authentication, and identity/RBAC support.
- `apps/backplane_skills`: archive-backed skill library, skill protocol API, and host-agent skill synchronization.
- `apps/backplane_memory`: memory ingestion, projections, recall, replay, and governance.
- `apps/backplane_host_agent`: host-side skill synchronization and durable memory capture; also built as the independent `host_agent` release.
- `apps/backplane_monitor`: provider monitoring and plan usage.
- `apps/backplane_telemetry`: Observability v2 settings, runtime sink, bounded buffers, and retention support.
- `apps/relayixir`: HTTP/WebSocket reverse proxy library used internally by the LLM proxy.
- `apps/day_ex`: date/time utility library exposed through the `day::` managed MCP tools.
- `apps/math_ex`: math expression engine used by the managed math service.

Protocol/runtime support lives in `apps/backplane_mcp_protocol`, `apps/backplane_skill_protocol`, `apps/backplane_ai_protocol`, and `apps/backplane_agent_runtime`. Shared test support lives in `apps/backplane_data_case` and `apps/backplane_ai_protocol_testkit`.

## Requirements

- Elixir `~> 1.18` / OTP 28+
- PostgreSQL with pgvector >= 0.7 (`halfvec` support); devenv provisions PostgreSQL 17 with pgvector
- Bun
- Tailwind CSS 4
- Rust/Cargo, a C build toolchain, pkg-config, and OpenSSL development libraries for native dependency source builds (as provisioned in CI)

The recommended local environment is [devenv](https://devenv.sh/), which provisions Elixir, PostgreSQL, Bun, Tailwind, and related development tools.

## Local Development

Enter the development shell:

```bash
direnv allow
# or
devenv shell
```

Install dependencies and prepare the database:

```bash
mix deps.get
mix ecto.setup
```

Start the Phoenix server:

```bash
mix phx.server
```

In development the API endpoint listens on:

```text
http://localhost:4220
```

The admin endpoint listens on:

```text
http://localhost:4221
```

Useful routes:

- `POST /mcp`: MCP JSON-RPC endpoint
- `GET /mcp`: legacy MCP SSE notification stream
- `DELETE /mcp`: legacy MCP session cleanup
- `HEAD /mcp`: returns `204` without opening an SSE stream
- `/v1/*`: LLM proxy routes
- `/v1/messages`: Anthropic Messages-compatible route
- `/v1/chat/completions`, `/v1/responses`, `/v1/embeddings`: OpenAI-compatible routes
- `/v1/providers/:provider_name/*`: provider-scoped Codex Responses proxy supporting `GET models`, `POST responses`, and `POST responses/compact`
- `/skills/*`: skill library API routes
- `/skill-protocol/v1/*`: authenticated skill document/bundle protocol
- `/api/memory/*`: memory API with resource bearer authentication
- `/host-agent/*`: host-agent API routes
- `/host-agent/socket`: host-agent WebSocket connection
- `/oauth/*`, `/.well-known/*`: OAuth/OIDC and protected-resource discovery
- Admin endpoint `/`: admin UI redirect
- Admin endpoint `/dashboard/overview`: dashboard
- Admin endpoint `/mcp/managed`: managed service toggles and tool lists
- Admin endpoint `/system/credentials`: credentials vault

## Common Commands

```bash
mix deps.get
mix ecto.setup
mix ecto.migrate
mix ecto.reset
mix test
mix test apps/backplane_mcp/test/backplane/transport/mcp_era_router_test.exs
mix credo
mix dialyzer
mix phx.server
mix agent.run
```

Asset build aliases build the split API and admin Phoenix assets:

```bash
mix assets.deploy
```

## Configuration

Development config lives in `config/dev.exs`.

Production boot config is read from `backplane.toml` by default. Set `BACKPLANE_CONFIG` to use another file:

```bash
MIX_ENV=prod BACKPLANE_CONFIG=/etc/backplane/backplane.toml mix phx.server
```

Use `config/backplane.toml.example` as a starting point:

```toml
[backplane]
host = "0.0.0.0"
port = 4100

[database]
url = "postgres://localhost/backplane_dev"
```

For production, also set:

```bash
SECRET_KEY_BASE="$(mix phx.gen.secret)"
PHX_HOST="your-host.example.com"
BACKPLANE_API_PORT=4100
BACKPLANE_ADMIN_PORT=4101
```

Export these environment variables before starting the process. For an installed OTP release, also set `PHX_SERVER=true` to enable the HTTP endpoints. `BACKPLANE_API_URL` and `BACKPLANE_ADMIN_URL` set the canonical resource/OAuth URLs; their defaults use `PHX_HOST` and the respective listen ports.

Production public/API HTTP binding is controlled by `BACKPLANE_API_PORT`, `BACKPLANE_PORT`, or `PORT`; if none is set, it defaults to `4100`.
Production admin HTTP binding is controlled by `BACKPLANE_ADMIN_PORT`; if it is not set, it defaults to `4101`.
Development binds the admin endpoint to `0.0.0.0:4221`. Production binds both endpoints to `0.0.0.0`; restrict admin access at the network or reverse-proxy boundary. The TOML `[backplane]` host/port fields do not override the Phoenix endpoint bindings above.

Boot-only TOML settings currently cover database URL, legacy MCP auth token, optional boot-time upstreams, optional pre-seeded clients, cache, and audit settings. Day-to-day operational configuration is stored in PostgreSQL and mostly edited through the admin endpoint, including:

- upstream MCP servers
- client tokens and scopes
- LLM providers
- model aliases
- credentials
- managed service toggles

Native math limits and timeouts live in the singleton `mcp_native_math_config` table. Web search backend defaults and provider credentials use DB-backed settings and credentials rather than boot-only TOML.

## MCP Auth

`Backplane.Auth.ResourceAuthPlug` accepts these MCP bearer credentials concurrently:

- **OAuth resource tokens**: verified for the MCP protected resource, with token scopes passed to tool authorization.
- **Opaque client tokens**: verified against PostgreSQL-backed clients and scoped to allowed tools.
- **Legacy tokens**: configured bearer tokens retain all-tool access, even when client rows exist.

A request without a bearer credential is allowed only when there is no enabled OAuth client for the resource, no database client, and no configured legacy token. Invalid supplied credentials are rejected even in this open configuration. Open access is convenient for local development but should not be used for exposed deployments.

The LLM `/v1` and `/skill-protocol/v1` surfaces use the same resource authentication layer with their own authorization checks. This does not add login protection to the admin endpoint.

## MCP Protocol Compatibility

Backplane's public `POST /mcp` endpoint defaults to the legacy `2025-11-25`
protocol. It continues to accept the complete legacy set through initialization:
`2024-11-05`, `2025-03-26`, `2025-06-18`, and `2025-11-25`. Legacy clients
retain initialization, session headers, the GET notification stream, and DELETE
session cleanup.

Requests explicitly marked with `MCP-Protocol-Version: 2026-07-28` use the
modern stateless protocol. Modern clients use `server/discover` and POST-only
requests with the required request metadata and mirrored routing headers; they
do not initialize or create an MCP session.

Each configured upstream selects its protocol independently:

| Upstream preference | Behavior |
| --- | --- |
| `2025-11-25` | Default. Strict legacy initialization and session-era behavior. |
| `2026-07-28` | Strict modern discovery and stateless requests; no legacy fallback. |
| `auto` | Attempts modern discovery. Legacy fallback is allowed for an unrecognized HTTP 400/404 response, a recognized HTTP `method_not_found` discovery error (raw JSON-RPC errors must have a matching non-null request ID), or a stdio discovery error classified as `parse_error`, `invalid_request`, `method_not_found`, `invalid_params`, or `request_timeout`. A valid `unsupported_protocol_version` error can retry a mutually supported modern version with loop protection; it does not trigger legacy fallback. Other errors remain terminal. |

The downstream client era and an upstream server's era are independent. A
modern client can call a namespaced tool backed by a legacy upstream, and a
legacy client can call a tool backed by a modern upstream.

## Tool Namespacing

All MCP tools use `::` as the namespace separator:

```text
<prefix>::<tool_name>
```

Examples:

- `day::now`
- `math::evaluate`
- `web::fetch`
- `web::search`
- `skill::list`
- `hub::discover`
- `prefix::upstream_tool`

Upstream tools use their configured prefix. Managed services and hub tools use fixed prefixes.

## Managed Services

Managed services are built into Backplane and can be viewed from the admin endpoint at `/mcp/managed`.

- `day::*`: date/time tools backed by `apps/day_ex`
- `web::fetch`: fetch an HTTP(S) URL as Markdown directly or through configured Firecrawl
- `web::search`: advanced Exa and Tavily search; Exa is the default, while Ollama and MiniMax are basic-search backups that require explicit enablement
- `web::x_search`: X search through xAI credentials
- `math::evaluate`: parse and evaluate math expressions through the native math engine
- `skill::*`: archive-backed skill search, list, load, download, and publish tools; registered only when `services.skill.enabled` is explicitly `true`

The math service accepts either an infix expression such as `2 * (3 + 4)` or a canonical JSON AST. Input is parsed into `Backplane.Math.Expression.Ast` before execution, then dispatched through `Backplane.Math.Router` into the native engine under `Backplane.Math.Sandbox` timeouts and complexity limits.

`web::search` supports common domain filters and optional bounded page content. Exa adds search type, category, publication dates, summaries, and cache age controls. Tavily adds search depth, topic, date windows, answers, chunks, and published-date filtering. The service rejects provider-specific options on another backend instead of silently dropping them. Snippets are limited to 1,500 characters; requested content defaults to 5,000 characters and is capped at 10,000. A truncated field is accompanied by `snippet_truncated` or `content_truncated`.

Normalized results can include score, author, highlights, summary, and publication date. Provider metadata is whitelisted as snake-case fields, including Exa request/cost/search-time metadata and Tavily request/response-time/usage metadata; Tavily requests usage explicitly. Exa's deprecated `resolvedSearchType` response is preserved as `resolved_search_type` when supplied for compatibility, but Backplane does not use it for routing or behavior.

## Admin UI

The admin UI is available on the admin endpoint at `/` and includes:

- Dashboard: overview and LLM/MCP/plan usage
- Llama: providers, embedding, and model aliases
- MCP: upstreams, managed services, agents, and inspector
- Memory: activity, sessions, recall, replay, and governance
- Skills: browse, metadata, upstreams, drafts, and uploads
- Auth: OAuth clients/providers/tokens, RBAC, and audit
- System: clients, logs, sink health, monitoring, credentials, and host agents

The admin UI, including Memory and Auth management, is intentionally a trusted-operator surface and does not require application-level authentication. Keep it on a private network or behind a trusted reverse proxy; do not expose the admin port on public ingress.

### API Usage Monitoring

**System → Monitor → API Usage** (`/system/monitor/api-usage`) lists and configures
API accounts independently of subscription Plan Usage. Add a named OpenRouter
or DeepSeek account using an existing LLM/service API-key credential from the
vault. Account definitions store credential names, not keys. This configuration
page does not display usage figures or request usage snapshots.

**Dashboard → API Usage** (`/dashboard/usage/api`) displays balances, spending,
limits, availability, last-success timestamps and errors, with manual refresh.

- **OpenRouter:** key spending and limits; an optional management-key credential
  also supplies account spending and credits. Account-credit failures do not hide
  successful key usage.
- **DeepSeek:** available, granted, and topped-up balances with their currencies.
  Usage totals are explicitly unavailable rather than reported as zero.

**System → Config** (`/system/config`) provides the global API information
fetching switch (`monitor.api_usage.enabled`, default enabled). Disabling it
stops automatic and manual fetching and cancels in-flight requests, without
changing account activation or subscription Plan Usage. Cached successful values
remain visible on the dashboard with a disabled indication. Re-enabling fetches
the current active account definitions; no additional migration is required for
this setting.

Active accounts refresh every five minutes when fetching is enabled. Paused
accounts do not poll. After a refresh fails, the last successful values remain
visible with the error and success timestamp. Snapshots are held in memory, not
stored as billing history. Run `mix ecto.migrate` before starting an upgraded
deployment to create `monitor_api_accounts`.

Restart the running application after upgrading, including in development.
Phoenix code reloading recompiles modules but does not update existing GenServer
state or add the new `Backplane.Monitor.ApiUsageServer` child to an already-running
supervision tree.

## Testing

Run the full suite:

```bash
mix test
```

The umbrella includes database-backed tests, LiveView tests, MCP transport tests, managed service tests, LLM proxy tests, Relayixir proxy tests, and DayEx utility tests.

## Project Notes

- PostgreSQL stores runtime configuration, credentials, upstream definitions, clients, skills, provider metadata, model aliases, and usage logs.
- Oban handles background jobs such as usage writing and retention.
- Observability v2 policy is stored under `observability.*` settings. The runtime sink and bounded LLM/MCP/audit writers provide persistence; the legacy usage-writing path is disabled when LLM persistence is enabled. Admin `/system/logs/sinks` reports writer/buffer health.
- Native math config is stored in the singleton `mcp_native_math_config` table and cached by `Backplane.Math.Config`.
- Relayixir is embedded as a library; its standalone server is disabled in Backplane.
- Phoenix LiveView uses the DuskMoon UI component system.

## Further Documentation

- `docs/deploy/backplane.md`: gateway deployment and release configuration
- `docs/deploy/host_agent.md`: host-agent deployment
- `docs/proxy-llm/backplane-openai-codex-direct-proxy-task.md`: provider-scoped Codex Responses proxy design
- `docs/usage/openai-codex.md`: direct-token Codex usage polling and stability caveats
- `docs/skill-protocol/contract-v1.md`: skill protocol compatibility contract
- `docs/operations/memory-v2.md`: memory operations and security boundary
- `docs/deploy/memory-v2-release.md`: memory migration and release safety
- `docs/observability/verification-and-production-rollout.md`: observability validation and rollout
