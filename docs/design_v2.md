# Backplane v2 — Design Document

## 1. Product Definition

Backplane is a private, self-hosted gateway with exactly two features:

1. **MCP Hub** — One MCP endpoint aggregating N upstream MCP servers plus built-in managed services. Connect once, access everything.
2. **LLM Proxy** — Credential-injecting, model-routing reverse proxy for LLM APIs (Anthropic/OpenAI format) with usage tracking.

Everything else — git access, documentation search, skill libraries — is delivered as either an upstream MCP server or a managed MCP service. Backplane does not implement domain engines for these concerns; it routes tool calls to services that do.

### What Backplane Is Not

Backplane is not a git platform client. GitHub MCP SSE, GitLab MCP SSE, and gitmcp.io exist as standalone MCP servers. Backplane proxies them.

Backplane is not a documentation search engine. Context7 exists as an MCP server. Backplane will eventually offer a managed docs service, but that is a managed MCP service — not a core feature.

Backplane is not a skill authoring platform. Skills are uploaded through the admin UI or fetched from external sources, then served as MCP tools. The skill system is a managed service inside the MCP Hub.

---

## 2. Architecture

### 2.1 System Boundary

```
MCP Clients                    Backplane                         Backends
───────────                    ─────────                         ────────

                          ┌────────────────────────┐
                          │     Transport Layer     │
 Synapsis ──┐  POST /mcp  │  ┌──────────────────┐  │
            ├────────────▶│  │  MCP Plug         │  │  ┌─────────────────┐
 Claude Code│             │  │  JSON-RPC Dispatch│  │  │ Upstream MCP    │
            │             │  └────────┬─────────┘  │  │ github-mcp-sse  │
 Cursor ────┘             │           │            │  │ context7         │
                          │           ▼            │  │ custom-server    │
                          │  ┌──────────────────┐  │  └─────────────────┘
                          │  │    MCP Hub        │  │
                          │  │  ┌─────────────┐  │  │
                          │  │  │ Proxy       │──┼──┼──▶ Upstream MCP Servers
                          │  │  ├─────────────┤  │  │
                          │  │  │ Managed     │  │  │  (in-process)
                          │  │  │  skills::   │  │  │
                          │  │  │  day::      │  │  │
                          │  │  │  docs::     │  │  │  (planned)
                          │  │  ├─────────────┤  │  │
                          │  │  │ Hub Meta    │  │  │
                          │  │  └─────────────┘  │  │
                          │  └──────────────────┘  │
                          │                        │
 Any HTTP    POST /llm/*  │  ┌──────────────────┐  │  ┌─────────────────┐
 Client ─────────────────▶│  │   LLM Proxy      │──┼──▶ Anthropic API   │
                          │  │  Model Routing   │  │  │ OpenAI API      │
                          │  │  Credential Inj. │  │  │ Custom LLM      │
                          │  │  Usage Tracking  │  │  └─────────────────┘
                          │  └──────────────────┘  │
                          │                        │
              Browser     │  ┌──────────────────┐  │
            ─────────────▶│  │  Admin UI        │  │
                          │  │  Phoenix LiveView│  │
                          │  └──────────────────┘  │
                          └────────────────────────┘
```

### 2.2 Configuration Model

TOML is boot-only infrastructure. All operational configuration lives in PostgreSQL, managed through the admin UI.

**TOML (boot, immutable at runtime):**
- Server bind address and port
- Database connection URL
- `secret_key_base` for encryption

**PostgreSQL (runtime, mutable via admin UI):**
- Credentials (encrypted secret store)
- MCP upstream server definitions
- Managed service configuration
- LLM provider definitions and model aliases
- Client access tokens and scopes
- System settings (timeouts, retention, toggles)

There is no TOML configuration for upstreams, LLM providers, git tokens, skill sources, or any operational concern. The admin UI is the single management interface.

### 2.3 Internal Module Map

After refactor, the module namespace is:

```
Backplane
├── Application              # OTP supervision tree
├── Repo                     # Ecto
├── Settings                 # System settings (key-value, ETS-cached)
│   ├── Credentials          # Encrypted credential store
│   └── Encryption           # AES-256-GCM (shared by all encrypted storage)
│
├── Transport                # MCP endpoint
│   ├── McpPlug              # JSON-RPC entry point
│   ├── McpHandler           # Method dispatch (tools/list, tools/call, etc.)
│   ├── SSE                  # Streaming support
│   ├── AuthPlug             # Client bearer token validation
│   ├── CORS, Compression    # HTTP middleware
│   ├── HealthPlug           # /health
│   └── MetricsPlug          # /metrics
│
├── Registry                 # Unified tool registry
│   ├── ToolRegistry         # ETS-backed, serves both upstream and managed tools
│   ├── Tool                 # Tool struct
│   └── InputValidator       # JSON Schema validation
│
├── Proxy                    # Upstream MCP connection management
│   ├── Pool                 # DynamicSupervisor for upstream connections
│   ├── Upstream             # GenServer per upstream (lifecycle, reconnect, tool discovery)
│   └── Namespace            # Prefix:: namespacing and deduplication
│
├── Services                 # Managed MCP services (register tools into ToolRegistry)
│   ├── Skills               # Skill upload, browse, serve
│   │   ├── Registry         # In-memory skill catalog
│   │   ├── Loader           # SKILL.md parser
│   │   └── Store            # DB-backed skill storage
│   ├── Day                  # day_ex datetime tools
│   └── Docs                 # (planned) documentation search
│
├── Hub                      # Cross-service meta tools
│   ├── Discover             # Search across all registered tools
│   └── Inspect              # Tool introspection
│
├── LLM                      # LLM API proxy
│   ├── Provider             # Ecto schema + context (references credential by name)
│   ├── ModelAlias           # Global alias → provider/model mapping
│   ├── ModelExtractor       # Extract/replace model field in JSON body
│   ├── ModelResolver        # ETS-cached name/alias → provider resolution
│   ├── CredentialPlug       # Injects provider API key from Settings.Credentials
│   ├── Router               # Plug.Router: /v1/messages, /v1/chat/completions, /v1/models
│   ├── RouteLoader          # Registers Relayixir upstreams from provider configs
│   ├── RateLimiter          # Per-provider ETS sliding window
│   ├── HealthChecker        # Periodic provider health probes
│   ├── UsageLog             # Ecto schema (insert-only)
│   ├── UsageCollector       # Telemetry handler → Oban job
│   ├── UsageQuery           # Aggregation queries
│   └── ApiRouter            # Admin REST API for provider CRUD
│
├── Clients                  # Access control
│   └── Client               # Ecto schema (name, token_hash, scopes)
│
├── Audit                    # Tool call logging, retention
├── Cache                    # Response cache (ETS)
├── Metrics                  # Prometheus export
├── PubSubBroadcaster        # Topic constants + broadcast helpers
├── Telemetry                # Telemetry event definitions
└── Jobs                     # Oban workers
    ├── UsageWriter          # Async LLM usage log insert
    └── UsageRetention       # Cron: prune old usage logs
```

**Removed modules (no longer part of Backplane):**
- `Backplane.Git.*` — all git provider/resolver/github/gitlab modules
- `Backplane.Docs.Ingestion`, `Docs.Parser`, `Docs.Parsers.*`, `Docs.Chunker`, `Docs.Indexer`, `Docs.Search`, `Docs.DocChunk`, `Docs.ReindexState` — future managed service
- `Backplane.Docs.Project` — retained only if docs managed service is in scope
- `Backplane.Skills.Sources.Git`, `Skills.Sources.Local` — skills are DB-stored and uploaded, not synced from git
- `Backplane.Skills.Sync` — no external sync
- `Backplane.Skills.Deps`, `Skills.Versions`, `Skills.SkillVersion` — defer to future
- `Backplane.Embeddings.*` — defer to future managed docs service
- `Backplane.Jobs.Reindex`, `Jobs.WebhookHandler`, `Jobs.EmbedChunks`, `Jobs.EmbedSkills` — tied to removed modules
- `Backplane.Tools.Git`, `Tools.Docs` — native tool modules for removed engines
- `Backplane.Config.Watcher` — no TOML hot-reload needed (DB is the config source)
- `Backplane.Notifications` — evaluate if still needed

**Moved/renamed:**
- `Backplane.LLM.Encryption` → `Backplane.Settings.Encryption` (shared)
- `Backplane.Skills.*` → `Backplane.Services.Skills.*`
- `Backplane.Tools.Skill` → `Backplane.Services.Skills` (tool registration within the service)
- `Backplane.Tools.Hub` → `Backplane.Hub.Discover` / `Backplane.Hub.Inspect` (already correct)
- `Backplane.Tools.Admin` — evaluate: may become Settings API tools

---

## 3. Settings System

### 3.1 Overview

`Backplane.Settings` is the runtime configuration layer. All operational settings are stored in a `system_settings` table, cached in ETS, and broadcast via PubSub on change.

### 3.2 Settings Data Model

**Table: `system_settings`**

| Column | Type | Description |
|---|---|---|
| key | text, PK | Dot-namespaced key (e.g., `mcp.default_timeout`) |
| value | jsonb | Typed value (string, integer, boolean, map) |
| value_type | text | Type hint for UI rendering: string, integer, boolean, json |
| description | text | Human-readable description |
| updated_at | utc_datetime_usec | Last modified |

**Behavior:** On boot, seed defaults for all known keys. `get/1` reads from ETS (populated on boot and on every `set/2`). `set/2` writes to DB, updates ETS, broadcasts `{:setting_changed, key, value}` on PubSub.

### 3.3 Settings Catalog

**General**
- `instance.name` (string) — Display name in UI and MCP server info
- `admin.auth_enabled` (boolean) — Require auth for admin UI
- `admin.username` (string) — Admin UI username
- `admin.password_hash` (string) — Bcrypt hash of admin password

**MCP Hub**
- `mcp.auth_required` (boolean) — Require bearer token for MCP endpoint
- `mcp.default_timeout_ms` (integer) — Default upstream tool call timeout
- `mcp.tool_discovery_interval_ms` (integer) — How often to refresh upstream tool lists

**LLM Proxy**
- `llm.default_rpm_limit` (integer, nullable) — Fallback RPM limit when provider has none
- `llm.usage_retention_days` (integer) — How long to keep usage logs
- `llm.health_check_interval_s` (integer) — Seconds between health probes
- `llm.streaming_enabled` (boolean) — Allow streaming responses

**Managed Services**
- `services.skills.enabled` (boolean) — Enable skills managed service
- `services.skills.max_upload_bytes` (integer) — Max skill package upload size
- `services.day.enabled` (boolean) — Enable day_ex datetime service
- `services.docs.enabled` (boolean) — Enable docs service (planned, default false)

**Observability**
- `audit.enabled` (boolean) — Enable tool call audit logging
- `audit.retention_days` (integer) — Audit log retention
- `metrics.enabled` (boolean) — Enable Prometheus metrics endpoint

### 3.4 Credentials Store

`Backplane.Settings.Credentials` is the single source of truth for all secrets in the system. No other module stores secrets.

**Table: `credentials`**

| Column | Type | Description |
|---|---|---|
| id | uuid, PK | |
| name | text, unique | Reference key (e.g., `anthropic-prod-key`, `github-token`) |
| kind | text | Category: `llm`, `upstream`, `service`, `admin`, `custom` |
| encrypted_value | bytea | AES-256-GCM encrypted secret |
| metadata | jsonb | Optional notes, associated entity hints |
| inserted_at | utc_datetime_usec | |
| updated_at | utc_datetime_usec | |

**Interface:**
- `store(name, plaintext, kind, metadata)` — Encrypt and upsert
- `fetch(name)` → `{:ok, plaintext}` | `{:error, :not_found}`
- `delete(name)` — Remove credential
- `list()` → List of `%{name, kind, metadata, updated_at}` — never returns plaintext
- `exists?(name)` → boolean

**Integration:** LLM providers and MCP upstreams reference credentials by name. At proxy time, the system calls `Credentials.fetch(entity.credential)` to obtain the actual secret for header injection.

**Encryption:** Uses `Backplane.Settings.Encryption` (AES-256-GCM), derived from `secret_key_base` in TOML. This module is shared — LLM.Provider no longer has its own encryption; `api_key_encrypted` column is replaced by a `credential` text column referencing a credential name.

---

## 4. MCP Hub

### 4.1 Upstream MCP Servers

Upstream servers are external MCP services that Backplane proxies. Previously defined in TOML; now DB-managed.

**Table: `mcp_upstreams`**

| Column | Type | Description |
|---|---|---|
| id | uuid, PK | |
| name | text, unique | Human identifier |
| prefix | text, unique | Namespace prefix (tools registered as `prefix::tool_name`) |
| transport | text | `http` or `stdio` |
| url | text, nullable | For http transport |
| command | text, nullable | For stdio transport |
| args | text[], nullable | For stdio transport |
| credential | text, nullable | References `credentials.name` for auth header injection |
| timeout_ms | integer | Tool call timeout (default from settings) |
| refresh_interval_ms | integer | Tool discovery refresh interval |
| enabled | boolean | Soft toggle |
| inserted_at | utc_datetime_usec | |
| updated_at | utc_datetime_usec | |

**Lifecycle:** On create/update/delete via admin UI, PubSub broadcast triggers `Proxy.Pool` to start/stop/reconfigure the corresponding `Proxy.Upstream` GenServer. No restart required.

**Credential injection for upstreams:** When an upstream requires authentication (e.g., GitHub MCP SSE needs a bearer token), the `Proxy.Upstream` GenServer fetches the credential on connect and includes it in the transport handshake headers.

### 4.2 Managed Services

Managed services are Backplane-native tool providers. They register tools into the same `ToolRegistry` as upstream servers, using the same `prefix::tool_name` namespacing. From the MCP client's perspective, there is no difference between an upstream tool and a managed tool.

**Managed services currently planned:**

| Service | Prefix | Tools | Status |
|---|---|---|---|
| Skills | `skills` | `skills::list`, `skills::get`, `skills::search` | Active |
| Day | `day` | `day::now`, `day::format`, `day::parse`, `day::diff`, etc. | Active |
| Docs | `docs` | `docs::search`, `docs::get` | Planned |

**Registration:** Each managed service module implements a `register/0` callback that inserts its tools into `ToolRegistry` with `origin: {:managed, prefix}`. This happens at application boot and is idempotent.

**Configuration:** Managed services respect `services.<name>.enabled` from Settings. When disabled, their tools are deregistered from `ToolRegistry`.

### 4.3 Skills as Managed Service

The skills system is a managed MCP service, not a separate engine. Skills are stored in PostgreSQL, uploaded through the admin UI, and served as MCP tools.

**Table: `skills`**

| Column | Type | Description |
|---|---|---|
| id | text, PK | Skill identifier (slug) |
| name | text | Display name |
| description | text | Short description |
| content | text | Full SKILL.md content |
| tags | text[] | Searchable tags |
| enabled | boolean | |
| inserted_at | utc_datetime_usec | |
| updated_at | utc_datetime_usec | |

**Upload flow:** Admin UI provides a form to either paste SKILL.md content directly or upload a `.tar.gz` package containing a SKILL.md. The loader parses frontmatter (name, description, tags) and body content, then inserts into the `skills` table.

**Removed:** Git sources, local filesystem sources, sync workers, dependency resolution, version tracking. Skills are simple DB records managed through the admin UI.

### 4.4 Hub Meta

Hub meta tools provide cross-service discovery. They query the `ToolRegistry` (which contains both upstream and managed tools) and return unified results.

- `hub::discover` — Search across all registered tools by name, description, or prefix
- `hub::inspect` — Return full tool schema and metadata for a named tool

These are always-on tools that cannot be disabled.

### 4.5 Tool Registry

The `ToolRegistry` is an ETS-backed registry that serves as the authoritative catalog of all available tools. It is unified — upstream tools, managed service tools, and hub meta tools all register here.

Each tool entry records: name (with prefix), description, input_schema, origin (`:native`, `{:upstream, name}`, `{:managed, prefix}`).

The MCP `tools/list` response is built directly from `ToolRegistry.list_all()`. The MCP `tools/call` dispatcher looks up the tool in the registry and routes to the appropriate handler based on origin.

---

## 5. LLM Proxy

### 5.1 Provider Data Model

LLM providers are DB-managed. The key change from v1: providers no longer store encrypted API keys directly. They reference a credential by name.

**Table: `llm_providers`** (modified)

| Column | Type | Description |
|---|---|---|
| id | uuid, PK | |
| name | text, unique (among active) | Lowercase hyphenated identifier |
| api_type | text | `anthropic` or `openai` |
| api_url | text | Base URL |
| credential | text | References `credentials.name` |
| models | text[] | Supported model identifiers |
| default_headers | jsonb | Extra headers to inject |
| rpm_limit | integer, nullable | Per-provider rate limit (falls back to settings) |
| enabled | boolean | |
| deleted_at | utc_datetime_usec, nullable | Soft delete |
| inserted_at | utc_datetime_usec | |
| updated_at | utc_datetime_usec | |

**Removed column:** `api_key_encrypted` — replaced by `credential` text reference.

**Model aliases, usage logs, rate limiting, health checking, model resolution** — all unchanged from the LLM proxy implementation plan. The only difference is the credential lookup path.

### 5.2 Credential Injection Flow

When a request arrives at the LLM proxy:

1. Model resolver identifies the target provider
2. `CredentialPlug.inject/2` calls `Settings.Credentials.fetch(provider.credential)`
3. If credential exists, inject appropriate auth header (x-api-key for Anthropic, Authorization Bearer for OpenAI)
4. If credential not found, return 503 with "provider credential not configured" error

This replaces the previous `Provider.decrypt_api_key/1` path.

---

## 6. Client Access Control

### 6.1 Data Model

Unchanged from current implementation. Clients have a name, hashed bearer token, scopes (list of `prefix::*` or `prefix::tool_name` patterns), and active flag.

### 6.2 Scope Evaluation

When an MCP `tools/call` arrives with a client bearer token:

1. `AuthPlug` validates the token against `clients.token_hash`
2. Dispatcher checks if the resolved tool name matches any of the client's scopes
3. `*` matches everything. `skills::*` matches all skills tools. `day::now` matches exactly one tool.

This applies uniformly to upstream tools, managed service tools, and hub meta tools.

---

## 7. Admin UI

### 7.1 Design Principles

The admin UI is an operator control plane. It uses Phoenix LiveView with DuskMoon UI components exclusively. No raw Tailwind card/form patterns — all UI elements use `.dm_*` components for visual consistency.

The navigation reflects the two-feature architecture plus supporting concerns.

### 7.2 Navigation

```
Dashboard  |  MCP Hub  |  LLM Providers  |  Clients  |  Logs  |  Settings
```

Six top-level modules. Each module may contain multiple pages and sub-routes.

### 7.3 Module Specifications

#### Dashboard (`/admin`)

The landing page. Answers "is everything working?" at a glance.

**Sections:**
- **MCP Hub Health** — Card per upstream: name, prefix, status badge (connected/degraded/disconnected), tool count. Card per managed service: name, enabled/disabled, tool count.
- **LLM Proxy Health** — Card per provider: name, api_type badge, health dot, model count.
- **Aggregate Stats** — Total tools, total requests (MCP + LLM), active clients.
- **Quick Actions** — Reconnect degraded upstreams, refresh tool discovery.

**Live updates:** PubSub subscriptions to upstream status changes, provider health changes, config reloads.

#### MCP Hub (`/admin/hub`)

The core MCP management page. Two sections.

**Upstream Servers section:**
- Table: name, prefix, transport, url/command, status badge, tool count, credential reference, enabled toggle
- CRUD: add/edit/delete upstream definitions
- Per-upstream: expand to see registered tools, reconnect action
- Credential field is a dropdown of available credentials from Settings.Credentials

**Managed Services section:**
- Card per service (skills, day, docs)
- Enable/disable toggle (writes to Settings)
- Skills-specific: skill browser with search, upload form, inline edit/delete
- Day-specific: read-only display of registered tools
- Docs-specific: "Planned" badge, no configuration yet

**Tool Browser:**
- Unified list of all tools (upstream + managed + hub)
- Filter by origin (upstream, managed, hub), prefix, search by name/description
- Click tool → detail drawer: name, description, input schema, origin, test call form
- Tool test call: interactive form to call any tool and see the result

#### LLM Providers (`/admin/providers`)

Existing ProvidersLive, adapted for credential references.

**Changes from current:**
- Remove API key password field
- Add credential dropdown (populated from Settings.Credentials)
- "No credential selected" warning state
- Everything else (aliases, usage panel, health dot, enable/disable) stays

#### Clients (`/admin/clients`)

Existing ClientsLive. No structural changes needed.

#### Logs (`/admin/logs`)

Unified activity stream across both features.

**Tabs:**
- **Tool Calls** — MCP tool call events: tool name, client, duration, success/error. Real-time via PubSub.
- **LLM Requests** — LLM proxy requests: provider, model, status, latency, tokens. From usage_logs table.
- **Jobs** — Oban job history: worker, queue, state, attempt, timing.

#### Settings (`/admin/settings`)

Grouped settings editor with a credentials management section.

**Sections (rendered as collapsible groups):**

**General** — Instance name, admin auth toggle, admin username, admin password (write-only field).

**Credentials** — The credential store management UI. Table: name, kind, last 4 chars hint, updated_at. Actions: add credential (name + kind + secret), rotate (new secret for existing name), delete. Secret input is write-only (password field). Stored values display `...xxxx` hint only.

**MCP Defaults** — Auth required toggle, default timeout, tool discovery interval.

**LLM Defaults** — Default RPM limit, usage retention days, health check interval, streaming toggle.

**Managed Services** — Per-service enable/disable toggles, skills max upload size.

**Observability** — Audit toggle, audit retention days, metrics toggle.

### 7.4 Shared Components

Extract a `BackplaneWeb.Components.Admin` module providing:

- Form field component (label, input, error, description) wrapping DuskMoon inputs
- Data table component with sortable columns
- Detail drawer (slide-out panel for tool/skill inspection)
- Stat card wrapping `.dm_stat`
- Status badge wrapping `.dm_badge`
- Action button wrapping `.dm_btn`
- Credential selector (dropdown populated from Credentials.list)
- Empty state component ("No X configured. Click Y to add one.")

All LiveView pages use these shared components. No page hand-rolls raw Tailwind form patterns.

### 7.5 Removed Pages

- `DocsLive` — removed (docs engine removed)
- `ProjectsLive` — removed (docs engine removed)
- `GitProvidersLive` — removed (git is an upstream, not native)
- `SkillsLive` — merged into MCP Hub page as managed services section

---

## 8. Supervision Tree

```
Backplane.Application
├── Backplane.Repo
├── Oban
├── Backplane.Settings                    # ETS cache for system_settings
├── Backplane.Registry.ToolRegistry       # ETS tool registry
├── Backplane.Services.Skills.Registry    # In-memory skill catalog
├── Backplane.Proxy.Pool                  # DynamicSupervisor for upstream connections
│   ├── Backplane.Proxy.Upstream (upstream_1)
│   ├── Backplane.Proxy.Upstream (upstream_2)
│   └── ...
├── Backplane.LLM.ModelResolver           # ETS-cached model resolution
├── Backplane.LLM.RouteLoader             # Registers Relayixir upstreams from providers
├── Backplane.LLM.RateLimiter             # ETS sliding window counters
├── Backplane.LLM.HealthChecker           # Periodic provider health probes
└── BackplaneWeb.Endpoint                 # Phoenix (Bandit adapter)
    ├── POST /mcp      → Backplane.Transport.McpPlug
    ├── POST /llm/*    → Backplane.LLM.Router
    ├── GET  /health   → Backplane.Transport.HealthPlug
    ├── GET  /metrics  → Backplane.Transport.MetricsPlug
    └── /admin/*       → BackplaneWeb.Router (Phoenix LiveView)
```

**Boot sequence for DB-managed upstreams:** On application start, after Repo is ready, `Proxy.Pool` queries `mcp_upstreams` table for all enabled upstreams and starts a `Proxy.Upstream` GenServer for each. On PubSub notification of upstream config change, Pool adjusts accordingly.

---

## 9. Resolved Decisions

### 9.1 TOML vs DB for Upstream Config

**Decision:** DB-only. TOML contains only host, port, database URL.

**Rationale:** The admin UI is the single management interface. TOML-configured upstreams create a split-brain configuration model where some things are editable and some aren't. DB-backed config with PubSub-driven reloads gives runtime mutability without restart.

**Trade-off:** First boot requires either seed data or manual admin UI setup. Acceptable for a self-hosted operator tool.

### 9.2 Centralized Credential Store

**Decision:** All secrets in one encrypted table, referenced by name everywhere else.

**Rationale:** Distributing encrypted secrets across tables (LLM providers, upstreams, git config) means multiple encryption/decryption paths, scattered key rotation, and no unified audit of stored secrets. A single credential store with name-based references is simpler to secure, rotate, and audit.

### 9.3 Skills as Managed Service, Not Engine

**Decision:** Skills are a managed MCP service inside the Hub, not a standalone engine with sync workers and git sources.

**Rationale:** The original design treated skills as a first-class engine with git sync, local filesystem watchers, and dependency resolution. In practice, skills are uploaded packages served via MCP tools. The complexity of sync infrastructure doesn't justify itself when the upload-and-serve model covers the use case. Git-sourced skills can be handled by an upstream MCP server dedicated to that purpose.

### 9.4 Git Removed Entirely

**Decision:** No native git provider, resolver, or platform client code in Backplane.

**Rationale:** GitHub MCP SSE, GitLab MCP SSE, and gitmcp.io are mature upstream MCP servers. Backplane proxies them like any other upstream. Building a parallel git client inside Backplane duplicates existing infrastructure and creates a maintenance burden for credential management, rate limiting, and API version tracking that's already handled by dedicated servers.

### 9.5 Docs as Future Managed Service

**Decision:** Keep docs in the architecture as a planned managed service. Do not implement now. Do not retain existing ingestion/parser/chunker code.

**Rationale:** Context7 and similar MCP servers handle documentation search well as upstreams. A managed docs service may be valuable for private/internal documentation, but the implementation (ingestion pipeline, parsers, chunking, indexing, search) is substantial. Better to start clean when needed rather than carry forward code designed for a different architecture.

### 9.6 DuskMoon Components Exclusively

**Decision:** All admin UI pages use DuskMoon component library exclusively. No raw Tailwind patterns for cards, forms, buttons, badges, or tables.

**Rationale:** The PRD mandates this. Current implementation violates it on 8 of 10 pages. Shared components wrapping DuskMoon primitives eliminate per-page style duplication and ensure visual consistency.
