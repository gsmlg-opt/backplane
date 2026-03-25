# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Backplane is a self-hosted MCP (Model Context Protocol) gateway written in Elixir. It presents a single MCP Streamable HTTP endpoint (`POST /mcp`) that aggregates five capabilities:

1. **MCP Proxy** — connects N upstream MCP servers (stdio or HTTP), namespaces their tools, forwards calls
2. **Skills Hub** — curated prompt/instruction packages (SKILL.md files) discoverable and loadable by agents
3. **Doc Server** — documentation search over indexed projects (parsed, chunked, ranked via PostgreSQL tsvector)
4. **Git Platform Proxy** — unified GitHub + GitLab API access with centralized token management
5. **Hub Meta** — cross-cutting discovery: search across all tools/skills/docs in one query

Module namespace: `Backplane`. Target: Elixir >= 1.18 / OTP 28+.

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

All tools use `::` as the namespace separator: `<prefix>::<tool_name>` (e.g., `docs::query-docs`, `git::repo-tree`, `fs::read_file`). This is a fixed convention, not configurable.

### Key Internal Modules

- `Backplane.Transport.Router` — Plug.Router handling `/mcp` and `/webhook/:provider` endpoints
- `Backplane.Transport.McpHandler` — JSON-RPC dispatcher (initialize, tools/list, tools/call, ping)
- `Backplane.Registry.ToolRegistry` — ETS-backed tool registry with namespacing
- `Backplane.Proxy.Pool` — DynamicSupervisor managing upstream MCP connections
- `Backplane.Proxy.Upstream` — GenServer per upstream (stdio Port or HTTP via Req)
- `Backplane.Docs.*` — Ingestion pipeline: clone -> parse -> chunk -> index into PostgreSQL
- `Backplane.Git.Provider` — Behaviour implemented by `Providers.Github` and `Providers.Gitlab`
- `Backplane.Skills.*` — Skill catalog with three sources: git repos, local filesystem, database
- `Backplane.Hub.*` — Cross-engine discovery (`hub::discover`, `hub::inspect`, `hub::status`)
- `Backplane.Config` — TOML config loader (`backplane.toml`), read at boot via `runtime.exs`

### Supervision Tree

```
Backplane.Application
├── Backplane.Repo (Ecto/PostgreSQL)
├── Oban (background jobs: reindex, skill sync, webhooks)
├── Backplane.Registry.ToolRegistry (ETS)
├── Backplane.Skills.Registry (ETS)
├── Backplane.Proxy.Pool (DynamicSupervisor for upstream MCP connections)
└── Bandit (HTTP server)
```

### Data Storage

PostgreSQL with four core tables: `projects`, `doc_chunks` (with tsvector full-text search), `reindex_state`, `skills` (with tsvector + GIN indexes on tags). Embeddings/pgvector are deferred — tsvector is the initial search strategy.

### Configuration

Single TOML file (`backplane.toml`) loaded at boot. Sections: `[backplane]` (host/port/auth), `[database]`, `[github.*]`/`[gitlab.*]` (credentials), `[[projects]]` (repos to index), `[[upstream]]` (MCP servers to proxy), `[[skills]]` (skill sources). See `config/backplane.toml.example` for reference.

### Key Dependencies

Plug + Bandit (HTTP), Jason (JSON), Req (HTTP client), Ecto + Postgrex (DB), Oban (jobs), toml (config), file_system (filesystem watching). Mox for test mocking.

## Testing Conventions

- `Backplane.DataCase` — base case template for DB-backed tests (Ecto sandbox)
- `Backplane.ConnCase` — base case template for HTTP tests, provides `mcp_request/3` helper
- Git provider and upstream connections use Mox-based behaviours for test isolation
