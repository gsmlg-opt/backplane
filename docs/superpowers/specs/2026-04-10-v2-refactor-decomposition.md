# Backplane v2 Refactor — Sub-Project Decomposition

**Date:** 2026-04-10
**Source:** [docs/design_v2.md](../../design_v2.md)

## Overview

The v2 refactor reshapes Backplane from a multi-engine gateway (MCP + git + docs + skills + embeddings) into a focused two-feature product: **MCP Hub** and **LLM Proxy**. Everything else is either an upstream MCP server or a managed service inside the hub.

This document decomposes the refactor into 6 independent sub-projects, each with its own spec → plan → implementation cycle.

## Key Decisions

These apply across all sub-projects:

- **No migration compatibility.** The project has never been published. All existing migrations are deleted and rewritten from scratch.
- **No TOML for operational config.** TOML is boot-only (host, port, DB URL, secret_key_base). All operational config (upstreams, providers, credentials, skills) lives in PostgreSQL.
- **Remove everything cleanly.** Deleted modules, tests, and migrations are gone. Git history is the archive.
- **Break backward compatibility freely.** No transition period, no dual-mode config.

---

## SP-1: Clean Slate — Remove Dead Code

**Goal:** Delete all modules, tests, and migrations for subsystems that no longer exist in v2. Create a clean foundation for subsequent sub-projects.

### Removes

**Modules (apps/backplane/lib/):**
- `Backplane.Git.*` — provider, resolver, cached_provider, rate_limit_cache, providers/github, providers/gitlab
- `Backplane.Docs.*` — ingestion, parser, parsers/*, chunker, indexer, search, doc_chunk, project, reindex_state
- `Backplane.Embeddings.*` — anthropic, openai, ollama, similarity
- `Backplane.Jobs.Reindex`, `Jobs.WebhookHandler`, `Jobs.EmbedChunks`, `Jobs.EmbedSkills`
- `Backplane.Tools.Git`, `Tools.Docs`
- `Backplane.Skills.Sources.Git`, `Skills.Sources.Local`, `Skills.Sync`, `Skills.Deps`, `Skills.Versions`, `Skills.SkillVersion`
- `Backplane.Config.Watcher`
- `Backplane.Transport.WebhookPlug`
- `Backplane.Notifications` (evaluate — remove if unused after cleanup)
- `Backplane.Analytics` (evaluate — remove if only tied to docs/git)

**LiveViews (apps/backplane_web/lib/):**
- `DocsLive`, `ProjectsLive`, `GitProvidersLive`

**Tests:** All corresponding test files for the above modules.

**Migrations:** Delete all files in `apps/backplane/priv/repo/migrations/`.

**Config:** Remove TOML sections for `[github]`, `[gitlab]`, `[[projects]]`, `[[upstream]]`, `[[skills]]` from example and runtime config loading. Simplify `Backplane.Config` to only load `[backplane]` and `[database]` sections.

### Keeps

- `Backplane.Skills.Skill` (schema, simplified)
- `Backplane.Skills.Registry` (in-memory catalog)
- `Backplane.Skills.Loader` (SKILL.md parser)
- `Backplane.Skills.Sources.Database` (DB source)
- `Backplane.Skills.Search` (query skills)
- `Backplane.Tools.Skill` (MCP tool for skills)
- `Backplane.Tools.Hub`, `Tools.Admin`
- All LLM modules (modified in SP-4)
- All proxy modules (modified in SP-3)
- All transport modules (except WebhookPlug)
- All client modules

### Depends on

Nothing — this is the first sub-project.

---

## SP-2: Settings + Credentials Store

**Goal:** Build the runtime configuration layer (system_settings table, ETS cache, PubSub broadcast) and the centralized encrypted credential store.

### New Modules

- `Backplane.Settings` — GenServer, ETS cache for system_settings, `get/1`, `set/2`, PubSub broadcast on change
- `Backplane.Settings.Credentials` — `store/4`, `fetch/1`, `delete/1`, `list/0`, `exists?/1`
- `Backplane.Settings.Encryption` — AES-256-GCM, derived from `secret_key_base` in TOML

### New Tables (fresh migrations)

- `system_settings` — key (text PK), value (jsonb), value_type (text), description (text), updated_at
- `credentials` — id (uuid PK), name (text unique), kind (text), encrypted_value (bytea), metadata (jsonb), timestamps

### Behavior

- On boot: seed defaults for all known setting keys, populate ETS
- `get/1` reads from ETS (fast path)
- `set/2` writes to DB, updates ETS, broadcasts `{:setting_changed, key, value}`
- Credentials never return plaintext in list operations
- Encryption uses `secret_key_base` from TOML boot config

### Settings Catalog

As defined in design_v2.md Section 3.3 — general, MCP hub, LLM proxy, managed services, observability settings.

### Depends on

SP-1 (clean codebase, no old migrations)

---

## SP-3: MCP Hub Restructure

**Goal:** Move upstream MCP server definitions from TOML to DB. Restructure skills as a managed service. Add Day as a managed service. Update tool registry for origin tracking.

### New/Modified Modules

- `Backplane.Proxy.Pool` — boot from DB query, respond to PubSub config changes
- `Backplane.Proxy.Upstream` — credential injection via `Settings.Credentials`
- `Backplane.Services.Skills.*` — moved from `Backplane.Skills.*`, implements managed service pattern with `register/0`
- `Backplane.Services.Day` — wraps day_ex, registers tools into ToolRegistry
- `Backplane.Registry.ToolRegistry` — add origin tracking: `:native`, `{:upstream, name}`, `{:managed, prefix}`

### New Table

- `mcp_upstreams` — id (uuid PK), name (text unique), prefix (text unique), transport (text), url (text nullable), command (text nullable), args (text[] nullable), credential (text nullable), timeout_ms (integer), refresh_interval_ms (integer), enabled (boolean), timestamps

### Behavior

- On app start, after Repo ready: Pool queries `mcp_upstreams` for enabled entries, starts Upstream GenServer per entry
- Admin UI create/update/delete → PubSub broadcast → Pool adjusts
- Managed services respect `services.<name>.enabled` from Settings
- All tools (upstream + managed + hub) register in same ToolRegistry with origin metadata

### Depends on

SP-2 (credentials store for upstream auth, settings for service toggles)

---

## SP-4: LLM Proxy — Credential References

**Goal:** Modify LLM providers to reference credentials by name instead of storing encrypted API keys directly.

### Modified Modules

- `Backplane.LLM.Provider` — replace `api_key_encrypted` (bytea) with `credential` (text) column
- `Backplane.LLM.CredentialPlug` — call `Settings.Credentials.fetch(provider.credential)` instead of `Provider.decrypt_api_key/1`
- Remove `Backplane.LLM.Encryption` — replaced by shared `Settings.Encryption`

### Modified Table

- `llm_providers` — drop `api_key_encrypted`, add `credential` (text, references credentials.name)

### Credential Injection Flow

1. Model resolver identifies target provider
2. `CredentialPlug` calls `Settings.Credentials.fetch(provider.credential)`
3. Inject `x-api-key` (Anthropic) or `Authorization: Bearer` (OpenAI)
4. If credential not found → 503 "provider credential not configured"

### Depends on

SP-2 (credentials store). Independent of SP-3.

---

## SP-5: Admin UI Modules

**Goal:** Restructure admin UI into 6 modules using DuskMoon components exclusively. Build shared component library.

### 6 Admin Modules

| Module | Route Prefix | Description |
|--------|-------------|-------------|
| Dashboard | `/admin` | System health overview, aggregate stats, quick actions |
| MCP Hub | `/admin/hub/*` | Upstream CRUD, managed services, tool browser, test calls |
| LLM Providers | `/admin/providers/*` | Provider CRUD with credential dropdown, aliases, usage, health |
| Clients | `/admin/clients/*` | Client management (existing, minimal changes) |
| Logs | `/admin/logs/*` | Tool calls, LLM requests, Oban jobs — tabbed view |
| Settings | `/admin/settings/*` | Grouped settings editor, credential management UI |

### Shared Components

`BackplaneWeb.Components.Admin` module providing:
- Form field component (wrapping DuskMoon inputs)
- Data table with sortable columns
- Detail drawer (slide-out panel)
- Stat card, status badge, action button (wrapping `.dm_*`)
- Credential selector dropdown
- Empty state component

### Removes

- `DocsLive`, `ProjectsLive`, `GitProvidersLive` (already removed in SP-1)
- `SkillsLive` (merged into MCP Hub module)
- `ToolsLive` (merged into MCP Hub module as tool browser)

### Depends on

SP-2, SP-3, SP-4 (all backend changes in place)

---

## SP-6: Client Access Control + Polish

**Goal:** Update client scope evaluation, verify end-to-end flows, update documentation.

### Scope

- Update client scope matching for new tool naming: `prefix::*`, `prefix::tool_name`
- Verify scope evaluation works for upstream tools, managed service tools, and hub meta tools
- Update `backplane.toml.example` to boot-only config
- Update `CLAUDE.md` to reflect v2 architecture
- Update `design_v2.md` with any changes discovered during implementation
- End-to-end smoke tests

### Depends on

SP-5 (everything else done)

---

## Dependency Graph

```
SP-1 (Clean Slate)
  └──▶ SP-2 (Settings + Credentials)
         ├──▶ SP-3 (MCP Hub Restructure)  ─┐
         │                                  ├──▶ SP-5 (Admin UI) ──▶ SP-6 (Polish)
         └──▶ SP-4 (LLM Proxy Credentials) ┘
```

SP-3 and SP-4 are independent and can be worked in parallel after SP-2 completes.

## Per-Sub-Project Process

Each sub-project follows its own cycle:
1. **Spec** — detailed design document for that sub-project
2. **Plan** — implementation plan with tasks
3. **Implement** — execute the plan
4. **Verify** — tests pass, app boots, affected features work

The next step is to spec SP-1 (Clean Slate).