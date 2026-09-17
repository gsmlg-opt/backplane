# AGENTS.md

This file provides repository-specific guidance to coding agents working in Backplane.

## Project Overview

Backplane is a private, self-hosted gateway with exactly two features:

1. **MCP Hub** — A single MCP Streamable HTTP endpoint (`POST /mcp`) that aggregates N upstream MCP servers plus built-in managed services. Connect once, access everything. Tools from all sources are namespaced as `prefix::tool_name`.
2. **LLM Proxy** — A credential-injecting, model-routing reverse proxy for LLM provider protocols with usage tracking.

Supporting umbrella apps implement authentication, skills, host agents, memory, monitoring, and protocol libraries. Keep gateway orchestration in `apps/backplane` and domain implementation in its owning app. Git access and external documentation search are delivered through upstream MCP servers, not new gateway subsystems.

Module namespace: `Backplane`. Target: Elixir >= 1.18 / OTP 28+.

The public dev endpoint listens on `http://localhost:4220`; the admin dev endpoint listens on `http://localhost:4221`. Production defaults to public port 4100 and admin port 4101.

### Key Routes

| Method | Path | Surface | Purpose |
|--------|------|---------|---------|
| `POST` | `/mcp` | Public (`dev 4220`) | MCP JSON-RPC endpoint |
| `GET` | `/mcp` | Public (`dev 4220`) | Legacy MCP SSE notification stream |
| `DELETE` | `/mcp` | Public (`dev 4220`) | Legacy MCP session cleanup |
| `*` | `/v1/*` | Public (`dev 4220`) | LLM proxy (OpenAI-compatible) |
| `POST` | `/v1/messages` | Public (`dev 4220`) | LLM proxy (Anthropic Messages) |
| `*` | `/skills/*` | Public (`dev 4220`) | Skill library HTTP surface |
| `*` | `/host-agent/*` | Public (`dev 4220`) | Host-agent HTTP surface |
| `*` | `/skill-protocol/v1/*` | Public (`dev 4220`) | Authenticated skill protocol API |
| `*` | `/api/memory/*` | Public (`dev 4220`) | Memory API, authenticated as the MCP resource |
| `*` | `/oauth/*` | Public (`dev 4220`) | OAuth/OIDC authorization and token endpoints |
| `*` | `/` | Admin (`dev 4221`) | Admin UI (LiveView) |

### Authentication Boundaries

- `Backplane.Auth.ResourceAuthPlug` validates OAuth resource access tokens, DB client bearer tokens, and configured legacy bearer tokens. Client/OAuth access is scoped; legacy tokens retain unrestricted compatibility access even when DB clients exist.
- Missing credentials are accepted only when the resource has no enabled OAuth client, no DB clients exist, and no legacy token is configured. Open access is for local development only; invalid supplied credentials are rejected.
- The admin endpoint is intentionally a trusted-operator surface without application-level authentication. Restrict it through network/deployment controls; do not treat public API authentication as admin protection.

### MCP Protocol Compatibility

The public endpoint defaults to legacy `2025-11-25` and accepts legacy initialization versions `2024-11-05`, `2025-03-26`, `2025-06-18`, and `2025-11-25`. Explicit `MCP-Protocol-Version: 2026-07-28` requests use stateless, POST-only modern discovery without initialization or sessions. Preserve required request metadata and mirrored routing headers.

Upstreams independently select `2025-11-25`, `2026-07-28`, or `auto`. Strict modern mode does not fall back. `auto` falls back only for transport-classified legacy discovery failures; preserve this boundary and test both downstream/upstream eras when changing transport code.

## Umbrella Structure

This is an umbrella project. Key apps include:

- **`apps/backplane`** (`:backplane`) — Core orchestrator: Oban jobs, native/managed tool registration, upstream boot
- **`apps/backplane_system`** — Shared Repo, migrations, settings, credentials, clients, accounts, registries, and audit
- **`apps/backplane_auth`** — OAuth/OIDC, resource authentication, and authorization
- **`apps/backplane_api`** — Public Phoenix endpoint and API controllers; dev port 4220
- **`apps/backplane_mcp`** — MCP transport, upstream pooling, managed service adapters, and MCP logging
- **`apps/backplane_llama`** — LLM providers, routing, authorization, proxying, and usage logging
- **`apps/backplane_skills`** — Skills, revisions, sources, host assignments, and agent MCP management
- **`apps/backplane_memory`** — Memory ingestion, projections, replay, summaries, and crystals
- **`apps/backplane_host_agent`** — Standalone host agent and its release/runtime configuration
- **`apps/backplane_monitor`** — Subscription-plan and API-account monitoring and usage checks
- **`apps/backplane_telemetry`** (`:backplane_telemetry`) — Observability v2: event envelopes, runtime sink, bounded writers, retention, admin health/metrics
- **`apps/backplane_admin`** (`:backplane_admin`) — Phoenix admin UI endpoint on its own port with routes rooted at `/`; dev port 4221.
- **`apps/relayixir`** (`:relayixir`) — HTTP reverse proxy library used internally by the LLM proxy to forward requests to upstream LLM providers.
- **`apps/day_ex`** (`:day_ex`) — Date/time utility library providing the `day::` managed service tools.
- **`apps/math_ex`** — Native math engine used by the managed math service
- **`apps/backplane_mcp_protocol`**, **`apps/backplane_ai_protocol`**, **`apps/backplane_skill_protocol`** — Reusable protocol libraries; AI conformance helpers live in `apps/backplane_ai_protocol_testkit`
- **`apps/backplane_agent_runtime`** — Embedded OTP runtime for bounded independent agents
- **`apps/backplane_data_case`** — Shared, repository-agnostic test sandbox helper

Config lives at the umbrella root (`config/`). `Backplane.Repo` belongs to `:backplane_system`; migrations live in `apps/backplane_system/priv/repo/migrations`. Endpoint config belongs to `:backplane_api` or `:backplane_admin`; many shared operational flags still use `:backplane`. Check ownership before adding config.

## Development Environment

Uses [devenv](https://devenv.sh/) with Nix for reproducible setup. Enter the dev shell via `direnv allow` or `devenv shell`.

The devenv provides Elixir (BEAM 28), Bun, pnpm, Tailwind CSS 4, elixir-ls, Rust/Cargo, OpenSSL, watchman, and inotify-tools (Linux). PostgreSQL 17 includes pgvector and initializes `backplane_dev` and `backplane_test`. `devenv up` starts PostgreSQL and the gateway, creating/migrating the development database before serving.

## Common Commands

```bash
mix deps.get            # Install dependencies
mix ecto.setup          # Create DB and run migrations through backplane_system
mix ecto.reset          # Drop, create, migrate (destructive)
mix compile --warnings-as-errors
mix format --check-formatted
mix test                # Run all tests
mix test apps/backplane_mcp/test/path/to_test.exs  # Target an owning app's test
mix do --app backplane_mcp cmd mix test           # Run one app's suite
mix credo --strict      # Static analysis / linting
mix dialyzer            # Type checking
mix backplane.run       # Start both Phoenix endpoints (alias for phx.server)
mix agent.run           # Start the standalone host agent
mix assets.deploy      # Build public and admin assets
MIX_ENV=prod mix release backplane
MIX_ENV=prod mix release host_agent
```

Bare `mix release` assembles both releases. Host-agent release config is `config/host_agent_runtime.exs`; keep it independent of gateway-only runtime dependencies.

## Architecture

### Tool Namespacing

All tools use `::` as the namespace separator: `<prefix>::<tool_name>` (e.g., `skill::list`, `day::now`, `hub::discover`, `fs::read_file`). This is a fixed convention. Upstream tools use their configured prefix; managed services use a fixed prefix; hub meta tools use `hub`.

### Key Internal Modules

- `Backplane.Transport.McpPlug` — JSON-RPC entry point for `POST /mcp`
- `Backplane.Transport.McpHandler` — Method dispatcher (initialize, tools/list, tools/call, ping)
- `Backplane.Auth.ResourceAuthPlug` — Resource bearer authentication (in `backplane_auth`)
- `Backplane.Registry.ToolRegistry` — ETS-backed unified tool registry (upstream + managed + hub + native)
- `Backplane.Proxy.Pool` — DynamicSupervisor managing upstream MCP connections
- `Backplane.Proxy.Upstream` — GenServer per upstream (stdio Port or HTTP; lifecycle, reconnect, tool discovery)
- `Backplane.Proxy.Upstreams` — Ecto context for `mcp_upstreams` table (DB-managed upstream definitions)
- `Backplane.Services.Day` — Managed service wrapping `day_ex` datetime tools (`day::*`)
- `Backplane.Services.Web` — Managed web fetching, backend search, hosted live search, and X search (`web::*`)
- `Backplane.Services.Math` — Managed service for math expression evaluation (`math::*`)
- `Backplane.Services.Skills` — Managed service adapter for archive-backed skill tools (`skill::*`)
- `Backplane.Tools.*` — Native Hub/Admin modules plus the Skills implementation delegated by `Backplane.Services.Skills`
- `Backplane.LLM.*` — LLM reverse proxy: Provider, ModelAlias, ModelResolver, CredentialPlug, RateLimiter, UsageLog, LogWriter, AccessEvent
- `Backplane.Monitor.ApiAccount` / `ApiAccounts` — API-account schema and CRUD context (in `backplane_monitor`)
- `Backplane.Monitor.ApiUsageServer` / `ApiUsageFetcher` — Ephemeral API-usage cache and provider polling (OpenRouter/DeepSeek)
- `Backplane.Observability.*` — Observability v2 flags, settings, runtime sink, buffers, retention (in `backplane_telemetry`)
- `Backplane.Settings` — Runtime key-value store (ETS-cached, backed by `system_settings` table)
- `Backplane.Settings.Credentials` — Encrypted secret store (AES-256-GCM, backed by `credentials` table)
- `Backplane.Clients` — Client access control (bearer tokens, scopes, ETS-cached)
- `Backplane.Config` — TOML config loader (`backplane.toml`), read at boot via `runtime.exs`

### Supervision Ownership

- `BackplaneSystem.Application` owns Repo, PubSub, settings/vault/token caches, tool/prompt registries, metrics, and the conditional audit writer.
- `BackplaneMcp.Application` owns sessions/tasks, math supervision, upstream/client pools and leases, response cache, and conditional MCP writers.
- `BackplaneLlama.Application` owns Relayixir, model resolution, route loading, rate limiting, and conditional LLM writing.
- `BackplaneSkills.Application` owns the skills registry and agent MCP management supervision.
- `BackplaneMonitor.Application` owns plan supervision, the monitor TaskSupervisor, and `Backplane.Monitor.ApiUsageServer`.
- `Backplane.Application` supervises Oban and performs gateway boot reconciliation.
- `Backplane.Api.Application` and `Backplane.Admin.Application` own their separate Phoenix endpoints.
- `BackplaneTelemetry.Supervisor` owns observability settings and the runtime sink when v2 policy is active.

After its supervisor starts, the gateway registers native hub/admin tools, reconciles managed services fail-closed, starts configured/DB upstreams, and seeds the client cache/configured clients. Keep writer lifecycle changes in the owning domain app, not in the gateway orchestrator.

### API Usage Monitoring

- API Usage is independent of subscription plans and LLM routing. System → Monitor → API Usage is configuration-only: table and CRUD, no usage figures, refresh controls, or snapshot reads. Dashboard → API Usage displays usage and supports asynchronous manual refresh. Active accounts refresh every five minutes and requests do not overlap per account. Snapshots are in-memory, not durable. The dashboard reloads cached states every five seconds while refreshing, otherwise every thirty seconds.
- System → Config controls `monitor.api_usage.enabled` (default true) in the existing Settings store. Runtime policy prevents all provider requests while disabled, cancels in-flight requests, and retains last-success data. Re-enable reconciles authoritative definitions and refreshes active accounts. Individual account activation still applies; subscription Plan Usage is unaffected. Restart after upgrading supervision or GenServer state; Phoenix dev code reload does not update either automatically.
- Account definitions store vault credential names only. Eligible credentials have kind `llm` or `service` and metadata `auth_type` absent/nil or `api_key`; forms use safe metadata, and secrets are resolved only during provider polling. The optional management credential applies only to OpenRouter. Never render or audit plaintext keys or raw provider responses; CRUD/toggle audit records contain action, entity type, and ID only.
- OpenRouter key usage/limits are key-scoped; optional management-key credits, remaining balance, and account spending are account-wide. Management-credit failures must not hide successful key usage. DeepSeek supplies per-currency total/granted/topped-up balances and API availability, not spending totals. Unsupported or missing fields are unavailable, never fabricated zero; preserve decimal strings and currencies. Refresh errors retain last-success data with a stale-data indication and separate last-attempt/last-success timestamps.

### Observability v2

Operational policy lives in `system_settings` keys under `observability.*` (LLM/MCP proxy enable+persist, audit, writer tuning). Boot-time app env flags under `:backplane_telemetry` remain for tests and emergency rollback (`:use_legacy_telemetry_logger` forces the deprecated `BackplaneTelemetry.TelemetryLogger`).

- **Runtime sink** — `Backplane.Observability.RuntimeSink` replaces the legacy catch-all logger when v2 is active.
- **LLM persistence** — `Backplane.LLM.LogWriter` (+ `AccessEvent`); legacy `UsageCollector`/`UsageWriter` Oban path disabled when persist is on.
- **MCP persistence** — `Backplane.MCP.LogWriter`, `Backplane.MCP.ToolLogWriter`, `Backplane.Transport.McpObservability`.
- **Audit** — `Backplane.Audit.Writer` for `tool_call_log` / `skill_load_log` (hash-only arguments).
- **Admin** — `/system/logs` (records) and `/system/logs/sinks` (writer/buffer health).

### Data Storage

PostgreSQL with pgvector. Core tables include:

- `system_settings` — Runtime key-value configuration (ETS-cached)
- `credentials` — AES-256-GCM encrypted secret store (referenced by upstreams and LLM providers)
- `mcp_upstreams` — DB-managed upstream MCP server definitions
- `skills` — Skill records (id, name, description, content, tags; tsvector + GIN indexes)
- `clients` — MCP client access tokens and scopes
- `llm_providers` — LLM provider definitions (references credential by name)
- `llm_model_aliases` — Global model alias → provider/model mapping
- `llm_logs` — Insert-only LLM proxy access records (Observability v2 durable writes)
- `mcp_native_math_config` — Singleton native math limits/timeouts
- `monitor_api_accounts` — UUID, unique name, provider, API-key/optional management credential names, active flag, and timestamps; schema/context belong to `backplane_monitor`, migration to `backplane_system`
- `bpm_memory_spaces`, `bpm_observations`, `bpm_memories` — Memory spaces and projected memory data; replay, summary, and crystal tables belong to the memory domain

Use the shared Repo through app-owned contexts. Schema and migration changes belong in the relevant domain and `backplane_system` migration directory respectively.

### Configuration

TOML (`backplane.toml`) is boot-only. The minimal example covers gateway host/port and database URL. The loader also supports legacy auth tokens, boot upstreams/client seeds, cache, and audit settings; see `Backplane.Config` and `config/runtime.exs` for the supported schema. Production endpoint binding and secrets use environment variables.

All operational configuration — upstream MCP servers, LLM providers, credentials, managed service toggles, client tokens — is stored in PostgreSQL and managed through the admin endpoint. No TOML entries are needed for operational concerns.

### Production Environment Variables

| Variable | Purpose |
|----------|---------|
| `BACKPLANE_CONFIG` | Path to TOML config file (default: `backplane.toml`) |
| `SECRET_KEY_BASE` | Phoenix secret for cookies/sessions |
| `PHX_HOST` | Public hostname for the server |
| `PHX_SERVER` | Enable Phoenix servers in releases (`true` or `1`) |
| `BACKPLANE_API_PORT` | Public HTTP listen port (defaults to 4100; precedes fallbacks) |
| `BACKPLANE_ADMIN_PORT` | Admin HTTP listen port (defaults to 4101) |
| `BACKPLANE_PORT` | Legacy public HTTP listen port fallback |
| `PORT` | Public HTTP listen port fallback |
| `BACKPLANE_API_URL` / `BACKPLANE_ADMIN_URL` | Canonical external URLs used by runtime configuration |

### Admin UI Navigation

```
Dashboard  |  Llama  |  MCP  |  Memory  |  Skills  |  Auth  |  System
```

Key admin routes (see `apps/backplane_admin/lib/backplane/admin/router.ex`):
- **Dashboard** (`/dashboard/overview`) — Health overview of upstreams, providers, and aggregate stats
- **MCP Hub** (`/mcp/managed`, `/mcp/upstreams`, `/mcp/inspector`) — Managed day/web/math/skill services, upstream servers, and protocol inspection
- **LLM Providers** (`/llama/providers`) — Provider CRUD, model aliases, usage panel, health status
- **Clients** (`/system/clients`) — MCP client token and scope management
- **Dashboard → Usage** — Plan Usage (`/dashboard/usage/plans`) and API Usage (`/dashboard/usage/api`) display provider figures and support refresh
- **System → Config** (`/system/config`) — Persistent global API information fetching switch
- **System → Monitor** — Plan Usage (`/system/monitor/plans`) and API Usage (`/system/monitor/api-usage`); API Usage supports add/edit/pause/delete with `/system/monitor/api-usage/new` and `/system/monitor/api-usage/:id/edit` patch routes
- **Auth** (`/auth/overview`) — OAuth providers/clients, RBAC, and authentication audit
- **Skills** (`/skills`) — Browse, sources, drafts, metadata, and uploads
- **Memory** (`/memory`) — Spaces, observations, replay, summaries, and crystals
- **Logs** (`/system/logs`) — LLM/MCP access records, audit trails, Oban job history; `/system/logs/sinks` shows Observability v2 writer/buffer health
- **Settings** (`/system/credentials`) — System settings editor, credentials vault, managed service toggles

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

- `BackplaneDataCase` owns repository-agnostic `setup_sandbox/2`.
- Each app owns its `DataCase`/`ConnCase`/`LiveCase` and domain helpers; do not depend on another app's test support modules.
- `Backplane.DataCase` belongs only to `apps/backplane`.
- Upstream MCP connections use custom mock modules (`MockMcpPlug`, `MockSSEMcpServer`, `MockSSEHttpPlug`) for test isolation.
- Only mark tests `async: true` when they avoid shared state, processes, ports, and database sandbox behavior.

## Commit Conventions

Use Conventional Commits with a scope prefix: `feat(mcp):`, `fix(hub):`, `test(day_ex):`, `docs:`, `ci:`. Pull requests should describe behavior changes, list validation commands, and include screenshots for admin UI changes.

## Working Rules

- Keep changes surgical and preserve unrelated worktree edits. Do not commit, push, or create branches unless explicitly requested.
- Place new worktrees under this project's `.trees/` directory.
- Parallelize independent tasks with disjoint file ownership; serialize explicit dependencies.
- For PRD work, modify only the specified scope and run only scoped tests. If out-of-scope tests fail, report and stop rather than fixing them. Stop when in-scope tests and the PRD checklist pass.
- Run focused verification first. CI also checks warnings-as-errors compilation, formatting, strict Credo, Dialyzer, and `mix run --no-start test/ci_workflow_test.exs`; do not claim checks you have not run.
- Route dependency bugs/features hosted under `gsmlgorg`, `gsmlg-dev`, `duskmoon-dev`, `gsmlg-app`, `Gao-OS`, `gsmlg-opt`, `gsmlg-ci`, `gsmlg-games`, or `gsmlg-com` upstream via `gh issue create`: issue type `Bug`/`Feature`, label `internal request` (create if missing), title `[internal] ...`, requesting repo/branch, reproduction or expected behavior, and severity (`blocker`, `needed`, or `nice-to-have`). Identify the upstream from its package source and add `TODO(upstream): org/repo#issue` at the callsite. Blockers prohibit local workarounds; lesser-severity workarounds require `WORKAROUND(upstream): org/repo#issue`.
- Omit generated-by text and Claude co-author trailers from commit messages.

## Agent note

After we add new feature, change architecture or fix issues we write agent note.
When save note to agent-note, should add label:
- `project: backplane`
