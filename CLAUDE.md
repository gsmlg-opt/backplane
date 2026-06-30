# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Backplane is a private, self-hosted gateway with exactly two features:

1. **MCP Hub** — A single MCP Streamable HTTP endpoint (`POST /api/mcp`) that aggregates N upstream MCP servers plus built-in managed services. Connect once, access everything. Tools from all sources are namespaced as `prefix::tool_name`.
2. **LLM Proxy** — A credential-injecting, model-routing reverse proxy for LLM APIs (Anthropic/OpenAI format) with usage tracking.

Everything else — git access, documentation search, skill libraries — is delivered as either an upstream MCP server or a managed MCP service. Backplane proxies tool calls to services that implement those concerns.

Module namespace: `Backplane`. Target: Elixir >= 1.18 / OTP 28+.

Dev server listens on `http://localhost:4220`. Production defaults to port 4100.

### Key Routes

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/api/mcp` | MCP JSON-RPC endpoint |
| `GET` | `/api/mcp` | MCP SSE notification stream |
| `DELETE` | `/api/mcp` | MCP session cleanup |
| `GET` | `/health` | Health check JSON |
| `GET` | `/metrics` | Runtime metrics |
| `*` | `/api/v1/*` | LLM proxy (OpenAI-compatible) |
| `*` | `/api/anthropic/*` | LLM proxy (Anthropic Messages) |
| `*` | `/api/llm/*` | LLM admin API (providers, aliases) |
| `*` | `/api/skills/*` | Skills REST API |
| `*` | `/api/host-agent/*` | Host agent API |
| `*` | `/admin` | Admin UI (LiveView) |

### MCP Auth Modes

- **Client mode** (active when `clients` table has rows): bearer tokens verified against DB, scoped to allowed tools.
- **Legacy mode** (no clients exist): falls back to TOML-configured bearer token for all-tool access.
- **Open mode** (no clients, no legacy token): MCP access is unrestricted. Local dev only.

## Umbrella Structure

This is an umbrella project. Config lives at the umbrella root (`config/`). Core config uses `config :backplane, ...`, web config uses `config :backplane_web, ...`.

**Core apps:**

- **`apps/backplane_system`** (`:backplane_system`) — Low-level shared infrastructure: Repo, PubSub, Settings, ToolRegistry, Metrics, Credentials vault, OAuth state. Started first; all other apps depend on it.
- **`apps/backplane_mcp`** (`:backplane_mcp`) — MCP transport, math engine, upstream proxy pool, response cache, session/task management.
- **`apps/backplane_llama`** (`:backplane_llama`) — LLM reverse proxy: provider routing, credential injection, model resolution, rate limiting, usage tracking. Uses `relayixir` for HTTP forwarding.
- **`apps/backplane_memory`** (`:backplane_memory`) — Self-hosted agent memory: observations, sessions, knowledge graph, facets, profiles, coordination, `memory::*` managed service.
- **`apps/backplane_skills`** (`:backplane_skills`) — Skill storage, search, sync, host management, `skills::*` managed service.
- **`apps/backplane_monitor`** (`:backplane_monitor`) — Subscription plan monitoring (z.ai, MiniMax, etc.), per-plan GenServer polling.
- **`apps/backplane_telemetry`** (`:backplane_telemetry`) — Unified telemetry logger for LLM requests and MCP tool calls.
- **`apps/backplane`** (`:backplane`) — Top-level application: orchestrates Oban jobs, registers native/managed tools at boot, starts configured upstreams, seeds client cache.
- **`apps/backplane_web`** (`:backplane_web`) — Phoenix admin UI: LiveViews, components, assets.
- **`apps/backplane_host_agent`** (`:backplane_host_agent`) — Standalone host agent runner that connects back to Backplane over Phoenix channels to sync skills and execute tasks.

**Library apps:**

- **`apps/relayixir`** (`:relayixir`) — HTTP reverse proxy library (embedded; standalone server disabled).
- **`apps/day_ex`** (`:day_ex`) — Date/time utility library (`day::*` managed service tools).
- **`apps/backplane_data_case`** (`:backplane_data_case`) — Shared `DataCase` base for DB-backed tests.

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

**Transport (backplane_mcp)**
- `Backplane.Transport.McpPlug` — JSON-RPC entry point for `POST /api/mcp`
- `Backplane.Transport.McpHandler` — Method dispatcher (initialize, tools/list, tools/call, ping)
- `Backplane.Transport.AuthPlug` — Client bearer token validation with scope filtering
- `Backplane.Transport.Session` / `TaskManager` — SSE session and async task lifecycle

**Tool Registry (backplane_system)**
- `Backplane.Registry.ToolRegistry` — ETS-backed unified tool registry (upstream + managed + hub + native)

**Upstream Proxy (backplane_mcp)**
- `Backplane.Proxy.Pool` — DynamicSupervisor managing upstream MCP connections
- `Backplane.Proxy.Upstream` — GenServer per upstream (stdio Port or HTTP; lifecycle, reconnect, tool discovery)
- `Backplane.Proxy.Upstreams` — Ecto context for `mcp_upstreams` table

**Managed Services**
- `Backplane.Services.Day` — `day::*` tools via `day_ex`
- `Backplane.Services.WebFetch` — `web::fetch`
- `Backplane.Services.WebSearch` — `web_search::search` (Ollama/MiniMax/Z.ai/BigModel backends)
- `Backplane.Services.Math` — `math::evaluate` via native math engine
- `Backplane.Skills.*` — `skills::*` tools (in `backplane_skills`)
- `BackplaneMemory.Service` — `memory::*` tools (in `backplane_memory`)

**LLM Proxy (backplane_llama)**
- `Backplane.LLM.*` — Provider, ModelResolver, CredentialPlug, RateLimiter, UsageLog, UsageCollector, ApiRouter
- `Backplane.Embedding` — Embedding provider/model context

**System Infrastructure (backplane_system)**
- `Backplane.Settings` — Runtime key-value store (ETS-cached, `system_settings` table)
- `Backplane.Settings.Credentials` — AES-256-GCM encrypted secret store (`credentials` table)
- `Backplane.Settings.OAuthStateStore` — OAuth PKCE state tracking
- `Backplane.Clients` — Client access control (bearer tokens, scopes, ETS-cached)
- `Backplane.Config` — TOML config loader (`backplane.toml`), read at boot via `runtime.exs`
- `Backplane.Metrics` — ETS-based metrics collector

**Memory (backplane_memory)**
- `BackplaneMemory.Observations` / `Graph` / `Memories` / `Facets` / `Profiles` — storage contexts
- `BackplaneMemory.Coordination` — leases, signals, actions for multi-agent coordination

**Monitor (backplane_monitor)**
- `Backplane.Monitor` / `PlanServer` — subscription plan polling and snapshot storage

**Host Agent (backplane_host_agent)**
- `Backplane.HostAgent` — channel-based connection to Backplane, skill bundle install, task execution

### Supervision Tree

Each app has its own supervisor; start order follows OTP dependency declarations.

```
BackplaneSystem.Supervisor (apps/backplane_system) — starts first
├── Backplane.Repo (Ecto/PostgreSQL)
├── Phoenix.PubSub
├── Backplane.Settings.TokenCache (ETS)
├── Backplane.Settings.Credentials.Vault
├── Backplane.Settings.OAuthStateStore
├── Backplane.Settings (ETS-cached system settings)
├── Backplane.Registry.ToolRegistry (ETS)
└── Backplane.Metrics

BackplaneMcp.Supervisor (apps/backplane_mcp)
├── Backplane.Transport.Session
├── Backplane.Transport.TaskManager
├── Backplane.Math.Supervisor (native math engine)
├── Backplane.Proxy.Pool (DynamicSupervisor for upstream MCP connections)
└── Backplane.Cache (ETS response cache)

BackplaneLlama.Supervisor (apps/backplane_llama)
├── Relayixir (HTTP proxy for LLM forwarding)
├── Backplane.LLM.ModelResolver (ETS)
├── Backplane.LLM.RouteLoader
└── Backplane.LLM.RateLimiter (ETS sliding window)

BackplaneSkills.Supervisor (apps/backplane_skills)
├── Backplane.Skills.Registry (ETS)
├── Registry (keys: :unique, name: Backplane.Skills.AgentManage.Registry)
├── DynamicSupervisor (Backplane.Skills.AgentManage.DynamicSupervisor)
└── Backplane.Skills.AgentManage.Bootstrap

BackplaneMemory.Supervisor (apps/backplane_memory) — registers memory::* tools
BackplaneTelemetry.Supervisor (apps/backplane_telemetry)
└── BackplaneTelemetry.TelemetryLogger

BackplaneMonitor.Supervisor (apps/backplane_monitor)
├── Registry (Backplane.Monitor.PlanRegistry)
├── Task.Supervisor (Backplane.Monitor.TaskSupervisor)
└── Backplane.Monitor.PlanSupervisor

Backplane.Supervisor (apps/backplane) — top-level orchestrator
└── Oban (background jobs: UsageWriter, UsageRetention)

BackplaneWeb.Application (apps/backplane_web)
└── BackplaneWeb.Endpoint (Bandit HTTP server)
```

After `Backplane.Supervisor` starts: native tool registration (hub, admin), managed service tool registration, configured/DB upstream connections, usage collector telemetry attachment, and client cache seeding.

### Data Storage

PostgreSQL. Key table groups:

**System**
- `system_settings` — Runtime key-value config (ETS-cached)
- `credentials` — AES-256-GCM encrypted secret store
- `clients` — MCP client access tokens and scopes
- `mcp_upstreams` — DB-managed upstream MCP server definitions
- `agent_mcp_servers` — Agent-specific MCP server configs
- `mcp_native_math_config` — Singleton math engine limits/timeouts
- `tool_call_log` — MCP tool call audit log

**LLM Proxy**
- `llm_providers` / `llm_provider_apis` / `llm_provider_models` / `llm_provider_model_surfaces` — Provider definitions and model surfaces
- `llm_auto_models` / `llm_auto_model_routes` / `llm_auto_model_targets` — Auto-routing rules
- `embedding_providers` / `embedding_models` — Embedding provider/model definitions
- `llm_logs` — Insert-only LLM request usage records

**Skills**
- `skills` — Skill records (tsvector + GIN full-text indexes)
- `skill_sources` — Upstream skill source definitions
- `skill_hosts` / `skill_host_statuses` / `skill_host_assignments` / `skill_host_auth_tokens` / `skill_host_agent_tokens` — Host agent tracking
- `skill_load_log` — Skill install/sync audit

**Memory** (backplane_memory)
- `bpm_memories` / `bpm_observations` — Core memory and observation records
- `memory_sessions` / `memory_profiles` / `memory_facets` / `memory_facet_dimensions` — Session and facet tagging
- `memory_graph_nodes` / `memory_graph_edges` — Knowledge graph
- `memory_leases` / `memory_signals` / `memory_actions` / `memory_action_edges` / `memory_slots` — Multi-agent coordination
- `memory_summaries` / `memory_audit_log` — Summaries and audit trail

**Monitor**
- `monitor_plans` — Subscription plan monitoring definitions (z.ai, MiniMax, etc.)

### Configuration

TOML (`backplane.toml`) is boot-only. It covers: server bind address/port, database URL, and `secret_key_base`. See `config/backplane.toml.example` for reference.

All operational configuration — upstream MCP servers, LLM providers, credentials, managed service toggles, client tokens — is stored in PostgreSQL and managed through the admin UI at `/admin`. No TOML entries are needed for operational concerns.

### Releases

Two Mix releases are defined:

- **`backplane`** — Main server (includes `backplane`, `backplane_web`, `backplane_memory`, and all supporting apps).
- **`host_agent`** — Standalone host agent runner (`backplane_host_agent`). Uses `config/host_agent_runtime.exs`. Run with `mix agent.run`.

Build both with `mix release`; build one with `mix release backplane` or `mix release host_agent`.

### Production Environment Variables

| Variable | Purpose |
|----------|---------|
| `BACKPLANE_CONFIG` | Path to TOML config file (default: `backplane.toml`) |
| `SECRET_KEY_BASE` | Phoenix secret for cookies/sessions |
| `PHX_HOST` | Public hostname for the server |
| `BACKPLANE_PORT` | HTTP listen port (falls back to `PORT`, then 4100) |

### Admin UI Navigation

The admin UI is organized into five sections under `/admin`:

- **Dashboard** (`/admin/dashboard/*`) — Overview, LLM usage, MCP usage, plan usage stats
- **Llama** (`/admin/llama/*`) — LLM providers, embedding providers, model aliases, auto-routing
- **MCP** (`/admin/mcp/*`) — Upstream servers, managed services, managed service settings, tool detail, MCP inspector, agent MCP servers
- **Memory** (`/admin/memory/*`) — Overview, observations, sessions, knowledge graph, actions, audit, config, browse, stats
- **Skills** (`/admin/skills/*`) — Browse, metadata, upstream sources, drafts, uploads
- **System** (`/admin/system/*`) — Clients, logs, monitor plans, credentials vault, host agents, OAuth callbacks

### Key Dependencies

Plug + Bandit (HTTP), Jason (JSON), Req (HTTP client), Ecto + Postgrex (DB), Oban (jobs), toml (config), file_system (filesystem watching).

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

- `Backplane.DataCase` — base case for DB-backed tests (Ecto sandbox); lives in `apps/backplane_data_case`. `setup_sandbox/1` uses `shared: not tags[:async]`, so async tests get isolated sandboxes.
- `Backplane.ConnCase` — base case for HTTP/MCP transport tests. Provides `mcp_request/3`, `mcp_request_conn/3`, and `raw_mcp_request/2` helpers for JSON-RPC testing.
- `BackplaneWeb.LiveCase` — base case for LiveView tests (in `apps/backplane_web`).
- Upstream MCP connections use custom mock modules (`MockMcpPlug`, `MockSSEMcpServer`, `MockSSEHttpPlug`) for test isolation.
- Only mark tests `async: true` when they avoid shared state, processes, ports, and database sandbox behavior.
- Run scoped tests with `mix test apps/<app>/test/` to limit to one app.

## Commit Conventions

Use Conventional Commits with a scope prefix: `feat(mcp):`, `fix(hub):`, `test(day_ex):`, `docs:`, `ci:`. Pull requests should describe behavior changes, list validation commands, and include screenshots for admin UI changes.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **backplane** (3806 symbols, 6857 relationships, 274 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/backplane/context` | Codebase overview, check index freshness |
| `gitnexus://repo/backplane/clusters` | All functional areas |
| `gitnexus://repo/backplane/processes` | All execution flows |
| `gitnexus://repo/backplane/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
