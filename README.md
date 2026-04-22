# Backplane

Backplane is a private, self-hosted gateway for agent infrastructure.

It provides two main surfaces:

- **MCP Hub**: one MCP Streamable HTTP endpoint at `POST /mcp` that aggregates upstream MCP servers and built-in managed tools.
- **LLM Proxy**: a credential-injecting, model-routing reverse proxy for LLM APIs, with provider health checks and usage tracking.

Operational configuration is managed through the Phoenix admin UI and persisted in PostgreSQL.

## Umbrella Apps

This repository is an Elixir umbrella project:

- `apps/backplane`: core application, Ecto schemas, MCP transport, tool registry, upstream MCP proxy, managed services, LLM proxy, clients, settings, credentials, Oban jobs.
- `apps/backplane_web`: Phoenix admin UI, LiveView routes, endpoint, assets.
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

In development the web server listens on:

```text
http://localhost:4220
```

Useful routes:

- `POST /mcp`: MCP JSON-RPC endpoint
- `GET /mcp`: MCP SSE notification stream
- `DELETE /mcp`: MCP session cleanup
- `GET /health`: health check JSON
- `GET /metrics`: runtime metrics
- `/admin`: admin UI
- `/api/llm/*`: LLM proxy API routes

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

Asset build aliases are provided by `apps/backplane_web`:

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
BACKPLANE_PORT=4100
```

Production HTTP binding is controlled by `BACKPLANE_PORT` or `PORT`; if neither is set, it defaults to `4100`.

Boot-only TOML settings currently cover database URL, legacy MCP auth token, optional boot-time upstreams, optional pre-seeded clients, cache, and audit settings. Day-to-day operational configuration is stored in PostgreSQL and edited through `/admin`, including:

- upstream MCP servers
- client tokens and scopes
- LLM providers
- model aliases
- credentials
- managed service settings

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
- `skills::list`
- `hub::discover`
- `prefix::upstream_tool`

Upstream tools use their configured prefix. Managed services and hub tools use fixed prefixes.

## Admin UI

The admin UI is available at `/admin` and includes:

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

The umbrella includes database-backed tests, LiveView tests, MCP transport tests, LLM proxy tests, Relayixir proxy tests, and DayEx utility tests.

## Project Notes

- PostgreSQL stores runtime configuration, credentials, upstream definitions, clients, skills, provider metadata, model aliases, and usage logs.
- Oban handles background jobs such as usage writing and retention.
- Relayixir is embedded as a library; its standalone server is disabled in Backplane.
- Phoenix LiveView uses the DuskMoon UI component system.
