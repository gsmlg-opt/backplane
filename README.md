# Backplane

Backplane is a private, self-hosted gateway for agent infrastructure.

It provides two main surfaces:

- **MCP Hub**: one MCP Streamable HTTP endpoint at `POST /mcp` that aggregates upstream MCP servers and built-in managed services.
- **LLM Proxy**: a credential-injecting, model-routing reverse proxy for LLM APIs, with provider health checks and usage tracking.

Operational configuration is managed through the Phoenix admin UI and persisted in PostgreSQL.

## Umbrella Apps

This repository is an Elixir umbrella project:

- `apps/backplane`: core application, Ecto schemas, MCP transport, tool registry, upstream MCP proxy, managed services, native math engine, LLM proxy, clients, settings, credentials, Oban jobs.
- `apps/backplane_api`: Phoenix public/API endpoint for `/`, `/mcp`, `/v1/*`, `/llm/*`, `/skills/*`, `/host-agent/*`, `/health`, `/metrics`, and host-agent sockets.
- `apps/backplane_admin`: Phoenix admin UI endpoint on its own port, with routes rooted at `/`.
- `apps/relayixir`: HTTP/WebSocket reverse proxy library used internally by the LLM proxy.
- `apps/day_ex`: date/time utility library exposed through the `day::` managed MCP tools.

## Requirements

- Elixir `~> 1.18` / OTP 28+
- PostgreSQL
- Bun
- Tailwind CSS 4

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
- `GET /mcp`: MCP SSE notification stream
- `DELETE /mcp`: MCP session cleanup
- `GET /health`: health check JSON
- `GET /metrics`: runtime metrics
- `/v1/*`: LLM proxy routes
- `/v1/messages`: Anthropic Messages-compatible route
- `/llm/*`: LLM provider and alias API routes
- `/skills/*`: skill library API routes
- `/host-agent/*`: host-agent API routes
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
mix test path/to/test.exs
mix credo
mix dialyzer
mix phx.server
```

Asset build aliases build the split API and admin Phoenix assets:

```bash
mix assets.deploy
```

## Configuration

Development config lives in `config/dev.exs`.

Production boot config is read from `backplane.toml` by default. Set `BACKPLANE_CONFIG` to use another file:

```bash
BACKPLANE_CONFIG=/etc/backplane/backplane.toml mix phx.server
```

Use `config/backplane.toml.example` as a starting point:

```toml
[backplane]
host = "0.0.0.0"
port = 4100
# admin_username = "admin"
# admin_password = "changeme"

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

Production public/API HTTP binding is controlled by `BACKPLANE_API_PORT`, `BACKPLANE_PORT`, or `PORT`; if none is set, it defaults to `4100`.
Production admin HTTP binding is controlled by `BACKPLANE_ADMIN_PORT`; if it is not set, it defaults to `4101`.

Boot-only TOML settings currently cover database URL, legacy MCP auth token, optional boot-time upstreams, optional pre-seeded clients, cache, and audit settings. Day-to-day operational configuration is stored in PostgreSQL and mostly edited through the admin endpoint, including:

- upstream MCP servers
- client tokens and scopes
- LLM providers
- model aliases
- credentials
- managed service toggles

Native math limits and timeouts live in the singleton `mcp_native_math_config` table. Web search backend defaults and provider credentials use DB-backed settings and credentials rather than boot-only TOML.

## MCP Auth

Backplane supports two MCP authentication modes:

- **Client mode**: when client rows exist in PostgreSQL, bearer tokens are verified against the `clients` table and scoped to allowed tools.
- **Legacy mode**: when no clients exist, the configured TOML bearer token can allow access to all tools.

If no clients and no legacy tokens are configured, MCP access is open. This is convenient for local development but should not be used for exposed deployments.

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
- `skills::list`
- `hub::discover`
- `prefix::upstream_tool`

Upstream tools use their configured prefix. Managed services and hub tools use fixed prefixes.

## Managed Services

Managed services are built into Backplane and can be viewed from the admin endpoint at `/mcp/managed`.

- `day::*`: date/time tools backed by `apps/day_ex`
- `web::fetch`: fetch an HTTP(S) URL and convert readable content to Markdown
- `web::search`: search through configured Ollama or MiniMax backends
- `math::evaluate`: parse and evaluate math expressions through the native math engine

The math service accepts either an infix expression such as `2 * (3 + 4)` or a canonical JSON AST. Input is parsed into `Backplane.Math.Expression.Ast` before execution, then dispatched through `Backplane.Math.Router` into the native engine under `Backplane.Math.Sandbox` timeouts and complexity limits.

## Admin UI

The admin UI is available on the admin endpoint at `/` and includes:

- Dashboard
- MCP Hub
- Upstreams
- Managed services
- LLM Providers
- Clients
- Logs
- Settings

Admin basic auth is supported by `Backplane.Web.AdminAuthPlug` when `:admin_username` and `:admin_password` are present in application config. The example TOML includes placeholders for those fields, but the current runtime loader does not apply them yet.

## Testing

Run the full suite:

```bash
mix test
```

The umbrella includes database-backed tests, LiveView tests, MCP transport tests, managed service tests, LLM proxy tests, Relayixir proxy tests, and DayEx utility tests.

## Project Notes

- PostgreSQL stores runtime configuration, credentials, upstream definitions, clients, skills, provider metadata, model aliases, and usage logs.
- Oban handles background jobs such as usage writing and retention.
- Native math config is stored in the singleton `mcp_native_math_config` table and cached by `Backplane.Math.Config`.
- Relayixir is embedded as a library; its standalone server is disabled in Backplane.
- Phoenix LiveView uses the DuskMoon UI component system.
