# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Backplane is a private, self-hosted gateway with exactly two features:

1. **MCP Hub** — A single MCP Streamable HTTP endpoint (`POST /mcp`) that aggregates N upstream MCP servers plus built-in managed services. Connect once, access everything. Tools from all sources are namespaced as `prefix::tool_name`.
2. **LLM Proxy** — A credential-injecting, model-routing reverse proxy for LLM APIs (Anthropic/OpenAI format) with usage tracking.

Everything else — git access, documentation search, skill libraries — is delivered as either an upstream MCP server or a managed MCP service. Backplane proxies tool calls to services that implement those concerns.

Module namespace: `Backplane`. Target: Elixir >= 1.18 / OTP 28+.

## Umbrella Structure

This is an umbrella project with four apps:

- **`apps/backplane`** (`:backplane`) — Core business logic: MCP transport, tool registry, upstream proxy, managed services (skills, day), LLM proxy, clients, settings, credentials, DB (Ecto/Oban)
- **`apps/backplane_web`** (`:backplane_web`) — Phoenix admin UI: LiveViews, components, assets. Depends on `:backplane`.
- **`apps/relayixir`** (`:relayixir`) — HTTP reverse proxy library used internally by the LLM proxy to forward requests to upstream LLM APIs.
- **`apps/day_ex`** (`:day_ex`) — Date/time utility library providing the `day::` managed service tools.

Config lives at the umbrella root (`config/`). Core config uses `config :backplane, ...`, web config uses `config :backplane_web, ...`.

## Development Environment

Uses [devenv](https://devenv.sh/) with Nix for reproducible setup. Enter the dev shell via `direnv allow` or `devenv shell`.

The devenv provides: Elixir (BEAM 28), Bun, pnpm, Tailwind CSS 4, elixir-ls, watchman, inotify-tools (Linux).

## Common Commands

```bash
mix deps.get            # Install dependencies
mix ecto.setup          # Create DB, run migrations, seed
mix ecto.reset          # Drop, create, migrate, seed
mix test                # Run all tests
mix test path/to/test.exs           # Run single test file
mix test path/to/test.exs:42        # Run single test at line
mix credo               # Static analysis / linting
mix dialyzer            # Type checking
mix phx.server          # Start the server (or: iex -S mix)
```

## Architecture

### Tool Namespacing

All tools use `::` as the namespace separator: `<prefix>::<tool_name>` (e.g., `skills::list`, `day::now`, `hub::discover`, `fs::read_file`). This is a fixed convention. Upstream tools use their configured prefix; managed services use a fixed prefix; hub meta tools use `hub`.

### Key Internal Modules

- `Backplane.Transport.McpPlug` — JSON-RPC entry point for `POST /mcp`
- `Backplane.Transport.McpHandler` — Method dispatcher (initialize, tools/list, tools/call, ping)
- `Backplane.Transport.AuthPlug` — Client bearer token validation with scope filtering
- `Backplane.Registry.ToolRegistry` — ETS-backed unified tool registry (upstream + managed + hub)
- `Backplane.Proxy.Pool` — DynamicSupervisor managing upstream MCP connections
- `Backplane.Proxy.Upstream` — GenServer per upstream (stdio Port or HTTP; lifecycle, reconnect, tool discovery)
- `Backplane.Proxy.Upstreams` — Ecto context for `mcp_upstreams` table (DB-managed upstream definitions)
- `Backplane.Services.Day` — Managed service wrapping `day_ex` datetime tools (`day::*`)
- `Backplane.Services.Skills.*` — Managed service for skill upload, browse, serve (`skills::*`)
- `Backplane.Hub.*` — Cross-service meta tools (`hub::discover`, `hub::inspect`)
- `Backplane.LLM.*` — LLM reverse proxy: Provider, ModelAlias, ModelResolver, CredentialPlug, RateLimiter, HealthChecker, UsageLog, UsageCollector
- `Backplane.Settings` — Runtime key-value store (ETS-cached, backed by `system_settings` table)
- `Backplane.Settings.Credentials` — Encrypted secret store (AES-256-GCM, backed by `credentials` table)
- `Backplane.Clients` — Client access control (bearer tokens, scopes, ETS-cached)
- `Backplane.Config` — TOML config loader (`backplane.toml`), read at boot via `runtime.exs`

### Supervision Tree

```
Backplane.Application (apps/backplane)
├── Backplane.Repo (Ecto/PostgreSQL)
├── Oban (background jobs: UsageWriter, UsageRetention)
├── Phoenix.PubSub
├── Backplane.Settings (ETS-cached system settings)
├── Backplane.Registry.ToolRegistry (ETS)
├── Backplane.Skills.Registry (ETS)
├── Backplane.Proxy.Pool (DynamicSupervisor for upstream MCP connections)
├── Backplane.Cache (ETS response cache)
├── Backplane.Metrics
├── Relayixir (HTTP proxy for LLM forwarding)
├── Backplane.LLM.ModelResolver (ETS)
├── Backplane.LLM.RouteLoader
├── Backplane.LLM.RateLimiter (ETS sliding window)
└── Backplane.LLM.HealthChecker

BackplaneWeb.Application (apps/backplane_web)
└── BackplaneWeb.Endpoint (Bandit HTTP server)
```

### Data Storage

PostgreSQL. Core tables:

- `system_settings` — Runtime key-value configuration (ETS-cached)
- `credentials` — AES-256-GCM encrypted secret store (referenced by upstreams and LLM providers)
- `mcp_upstreams` — DB-managed upstream MCP server definitions
- `skills` — Skill records (id, name, description, content, tags; tsvector + GIN indexes)
- `clients` — MCP client access tokens and scopes
- `llm_providers` — LLM provider definitions (references credential by name)
- `llm_model_aliases` — Global model alias → provider/model mapping
- `llm_usage_logs` — Insert-only LLM request usage records

Removed tables (no longer present): `projects`, `doc_chunks`, `reindex_state`.

### Configuration

TOML (`backplane.toml`) is boot-only. It covers: server bind address/port, database URL, and `secret_key_base`. See `config/backplane.toml.example` for reference.

All operational configuration — upstream MCP servers, LLM providers, credentials, managed service toggles, client tokens — is stored in PostgreSQL and managed through the admin UI at `/admin`. No TOML entries are needed for operational concerns.

### Admin UI Navigation

```
Dashboard  |  MCP Hub  |  LLM Providers  |  Clients  |  Logs  |  Settings
```

Six top-level modules:
- **Dashboard** (`/admin`) — Health overview of upstreams, providers, and aggregate stats
- **MCP Hub** (`/admin/hub`) — Manage upstream servers, managed services (skills/day/docs), tool browser
- **LLM Providers** (`/admin/providers`) — Provider CRUD, model aliases, usage panel, health status
- **Clients** (`/admin/clients`) — MCP client token and scope management
- **Logs** (`/admin/logs`) — Tool call log, LLM request log, Oban job history
- **Settings** (`/admin/settings`) — System settings editor, credentials vault, managed service toggles

### Key Dependencies

Plug + Bandit (HTTP), Jason (JSON), Req (HTTP client), Ecto + Postgrex (DB), Oban (jobs), toml (config), file_system (filesystem watching). Mox for test mocking.

## UI Library

This project uses the DuskMoon UI system:

- **`phoenix_duskmoon`** — Phoenix LiveView UI component library (primary web UI)
- **`@duskmoon-dev/core`** — Core Tailwind CSS plugin and utilities
- **`@duskmoon-dev/css-art`** — CSS art utilities
- **`@duskmoon-dev/elements`** — Base web components
- **`@duskmoon-dev/art-elements`** — Art/decorative web components

Do NOT use DaisyUI or other CSS component libraries. Do NOT use `core_components.ex` — use `phoenix_duskmoon` components instead.
Use `@duskmoon-dev/core/plugin` as the Tailwind CSS plugin.

### Reporting issues or feature requests

If you encounter missing features, bugs, or need functionality not yet available in any DuskMoon package, open a GitHub issue in the appropriate repository with the label `internal request`:

- **`phoenix_duskmoon`** — https://github.com/gsmlg-dev/phoenix_duskmoon/issues
- **`@duskmoon-dev/core`** — https://github.com/gsmlg-dev/duskmoon-dev/issues
- **`@duskmoon-dev/css-art`** — https://github.com/gsmlg-dev/duskmoon-dev/issues
- **`@duskmoon-dev/elements`** — https://github.com/gsmlg-dev/duskmoon-dev/issues
- **`@duskmoon-dev/art-elements`** — https://github.com/gsmlg-dev/duskmoon-dev/issues

## Testing Conventions

- `Backplane.DataCase` — base case template for DB-backed tests (Ecto sandbox)
- `Backplane.ConnCase` — base case template for HTTP tests, provides `mcp_request/3` helper
- Upstream MCP connections use Mox-based behaviours for test isolation
