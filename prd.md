# Backplane — Product Requirements Document

## 1. Overview

**Project:** `backplane`
**Module namespace:** `Backplane`
**Repository:** `gsmlg-opt/backplane` (standalone)
**Target:** Elixir >= 1.18 / OTP 28+
**Transport:** MCP Streamable HTTP (SSE over POST)

Backplane is a private, self-hosted MCP gateway that presents a single endpoint to any MCP client. Behind that endpoint it aggregates five capabilities:

1. **MCP Proxy** — connect N upstream MCP servers (stdio or HTTP), namespace their tools, forward calls. The core hub function.
2. **Skills Hub** — curated prompt/instruction packages discoverable and loadable by any connected agent. Skills are the reusable "how to do X well" layer.
3. **Doc Server** — Context7-style documentation search over your own projects (indexed, chunked, ranked)
4. **Git Platform Proxy** — unified GitHub + GitLab API access with centralized token management
5. **Hub Meta** — cross-cutting discovery tools: search across all tools/skills/docs in one query

**One-line definition:** One MCP endpoint — all your tools, skills, docs, and repos. Connect once, access everything.

### Why Standalone

Backplane is infrastructure, not a feature of any single consumer. Synapsis, Samgita, Claude Code, Codex CLI, Cursor, Windsurf — any MCP client connects to it. Coupling it to a consumer project limits reuse and entangles deployment lifecycles.

---

## 2. Architecture

### 2.1 High-Level

```
MCP Clients                        Backplane                          Backends
─────────────────────────────────────────────────────────────────────────────
                              ┌──────────────────┐
 Synapsis ─────┐              │   Plug Router    │
               │   MCP/HTTP   │   /mcp           │
 Claude Code ──┼─────────────▶│                  │
               │              │   JSON-RPC       │
 Codex CLI ────┤              │   Dispatcher     │
               │              ├──────────────────┤
 Cursor ───────┘              │                  │
                              │  ┌────────────┐  │       ┌──────────────┐
                              │  │ Hub Meta   │  │       │ (cross-cut   │
                              │  │ (discovery)│──┼──────▶│  all engines) │
                              │  └────────────┘  │       └──────────────┘
                              │                  │
                              │  ┌────────────┐  │       ┌──────────────┐
                              │  │ MCP Proxy  │──┼──────▶│ Upstream MCP │
                              │  └────────────┘  │       │ servers (N)  │
                              │                  │       └──────────────┘
                              │  ┌────────────┐  │       ┌──────────────┐
                              │  │Skills Engine│──┼──────▶│ Git repos /  │
                              │  └────────────┘  │       │ local dirs   │
                              │                  │       └──────────────┘
                              │  ┌────────────┐  │       ┌──────────────┐
                              │  │ Doc Engine │──┼──────▶│  PostgreSQL   │
                              │  └────────────┘  │       └──────────────┘
                              │                  │
                              │  ┌────────────┐  │       ┌──────────────┐
                              │  │ Git Proxy  │──┼──────▶│ GitHub API   │
                              │  └────────────┘  │       │ GitLab API   │
                              │                  │       └──────────────┘
                              └──────────────────┘
```

### 2.2 Internal Modules

```
backplane/
├── lib/
│   ├── backplane/
│   │   ├── application.ex          # OTP application, supervision tree
│   │   ├── config.ex               # TOML config loader
│   │   │
│   │   ├── transport/
│   │   │   ├── router.ex           # Plug.Router — /mcp, /webhook/:provider
│   │   │   ├── mcp_handler.ex      # JSON-RPC dispatch (initialize, tools/list, tools/call)
│   │   │   └── sse.ex              # SSE streaming support
│   │   │
│   │   ├── registry/
│   │   │   ├── tool_registry.ex    # ETS-backed tool registry, namespacing
│   │   │   └── tool.ex             # Tool schema struct
│   │   │
│   │   ├── docs/
│   │   │   ├── ingestion.ex        # Git clone → parse → chunk → index pipeline
│   │   │   ├── parser.ex           # Behaviour for doc parsers
│   │   │   ├── parsers/
│   │   │   │   ├── elixir.ex       # @moduledoc/@doc extraction from AST
│   │   │   │   ├── markdown.ex     # Markdown section chunking
│   │   │   │   ├── hex_docs.ex     # ExDoc .build artifact parser
│   │   │   │   └── generic.ex      # Fallback: heading-based splitting
│   │   │   ├── chunker.ex          # Semantic boundary chunker
│   │   │   ├── indexer.ex          # PG tsvector + optional pgvector writes
│   │   │   └── search.ex           # Query interface over indexed docs
│   │   │
│   │   ├── git/
│   │   │   ├── provider.ex         # Behaviour: list_repos, fetch_tree, fetch_file, ...
│   │   │   ├── providers/
│   │   │   │   ├── github.ex       # GitHub REST v3 client
│   │   │   │   └── gitlab.ex       # GitLab REST v4 client
│   │   │   └── resolver.ex         # "github:org/repo" → provider + credentials
│   │   │
│   │   ├── proxy/
│   │   │   ├── upstream.ex         # Upstream MCP connection manager (GenServer per upstream)
│   │   │   ├── pool.ex             # Supervision of upstream connections
│   │   │   └── namespace.ex        # Tool name prefixing/deduplication
│   │   │
│   │   ├── skills/
│   │   │   ├── registry.ex         # ETS-backed skill catalog
│   │   │   ├── loader.ex           # SKILL.md parser (frontmatter + body)
│   │   │   ├── source.ex           # Behaviour for skill sources
│   │   │   ├── sources/
│   │   │   │   ├── git.ex          # Skills from git repos (clone + watch)
│   │   │   │   ├── local.ex        # Skills from local filesystem dirs
│   │   │   │   └── database.ex     # User-authored skills stored in PG
│   │   │   ├── search.ex           # tsvector search over skill metadata + content
│   │   │   └── sync.ex             # Oban worker: periodic sync from git sources
│   │   │
│   │   ├── hub/
│   │   │   ├── discover.ex         # Cross-engine unified search
│   │   │   └── inspect.ex          # Tool introspection (schema, origin, health)
│   │   │
│   │   └── jobs/
│   │       ├── reindex.ex          # Oban worker: periodic reindex per project
│   │       └── webhook_handler.ex  # Oban worker: webhook-triggered reindex
│   │
│   └── backplane.ex                  # Public API facade
│
├── config/
│   ├── config.exs
│   ├── runtime.exs                 # Reads backplane.toml at boot
│   └── backplane.toml.example            # Reference config
│
├── priv/
│   └── repo/migrations/
│       ├── 001_create_projects.exs
│       ├── 002_create_doc_chunks.exs
│       ├── 003_create_reindex_state.exs
│       └── 004_create_skills.exs
│
├── test/
├── mix.exs
├── CLAUDE.md
└── README.md
```

### 2.3 Supervision Tree

```
Backplane.Application
├── Backplane.Repo                        # Ecto
├── Oban                               # Job processing
├── Backplane.Registry.ToolRegistry       # ETS tool registry
├── Backplane.Skills.Registry             # ETS skill catalog
├── Backplane.Proxy.Pool                  # DynamicSupervisor for upstream MCP connections
│   ├── Backplane.Proxy.Upstream (server_1)
│   ├── Backplane.Proxy.Upstream (server_2)
│   └── ...
└── Bandit (Backplane.Transport.Router)   # HTTP server
```

---

## 3. Configuration

Single TOML file. Loaded at boot via `runtime.exs`. Hot-reloadable for token rotation (file watch + SIGHUP).

### 3.1 Reference Config

```toml
[backplane]
host = "0.0.0.0"
port = 4100
# Optional: require bearer token from MCP clients
auth_token = "your-backplane-secret"

[database]
url = "postgres://localhost/backplane_dev"

# ─── Git Platform Credentials ───

[github]
token = "ghp_..."
api_url = "https://api.github.com"            # or GitHub Enterprise URL

[github.secondary]                             # multiple GitHub instances
token = "ghp_..."
api_url = "https://github.corp.example.com/api/v3"

[gitlab]
token = "glpat-..."
api_url = "https://gitlab.com/api/v4"

[gitlab.self_hosted]
token = "glpat-..."
api_url = "https://git.internal.example.com/api/v4"

# ─── Projects to Index ───

[[projects]]
id = "synapsis"
repo = "github:gsmlg-opt/Synapsis"
ref = "main"
parsers = ["elixir", "markdown"]               # parser chain
reindex_interval = "1h"

[[projects]]
id = "samgita"
repo = "github:gsmlg-opt/Samgita"
ref = "main"
parsers = ["elixir", "markdown"]
reindex_interval = "2h"

[[projects]]
id = "internal-lib"
repo = "gitlab.self_hosted:mygroup/internal-lib"
ref = "develop"
parsers = ["elixir", "markdown"]
reindex_interval = "6h"

# ─── Upstream MCP Servers to Proxy ───

[[upstream]]
name = "filesystem"
transport = "stdio"
command = "npx"
args = ["-y", "@anthropic/mcp-filesystem"]
env = { HOME = "/home/user" }
prefix = "fs"                                   # tools become fs::<tool_name>

[[upstream]]
name = "postgres-mcp"
transport = "http"
url = "http://localhost:4200/mcp"
prefix = "pg"

[[upstream]]
name = "slack"
transport = "http"
url = "https://mcp.slack.com/mcp"
headers = { "Authorization" = "Bearer xoxb-..." }
prefix = "slack"

# ─── Skill Sources ───

[[skills]]
name = "elixir-patterns"
source = "git"
repo = "github:gsmlg-opt/skills"          # git repo containing SKILL.md files
path = "elixir/"                            # subdirectory within repo
ref = "main"
sync_interval = "1h"

[[skills]]
name = "company-workflows"
source = "git"
repo = "gitlab.self_hosted:mygroup/ai-skills"
path = "/"
ref = "main"
sync_interval = "2h"

[[skills]]
name = "local-experiments"
source = "local"
path = "/home/user/.config/backplane/skills" # local filesystem directory

# Database-sourced skills need no config — they are managed via hub tools
```

### 3.2 Config Schema

| Section | Key | Type | Required | Description |
|---|---|---|---|---|
| `backplane` | `host` | string | no | Bind address. Default `"0.0.0.0"` |
| `backplane` | `port` | integer | no | Listen port. Default `4100` |
| `backplane` | `auth_token` | string | no | Bearer token MCP clients must present. Omit to disable auth |
| `github.*` | `token` | string | yes | Personal access token or app token |
| `github.*` | `api_url` | string | no | Default `https://api.github.com` |
| `gitlab.*` | `token` | string | yes | Personal access token |
| `gitlab.*` | `api_url` | string | no | Default `https://gitlab.com/api/v4` |
| `projects[]` | `id` | string | yes | Stable identifier used in tool calls |
| `projects[]` | `repo` | string | yes | `provider:owner/repo` format |
| `projects[]` | `ref` | string | no | Git ref to index. Default `main` |
| `projects[]` | `parsers` | list | no | Parser chain. Default `["generic"]` |
| `projects[]` | `reindex_interval` | string | no | Cron-style or duration. Default `"1h"` |
| `upstream[]` | `name` | string | yes | Human label |
| `upstream[]` | `transport` | enum | yes | `"stdio"` or `"http"` |
| `upstream[]` | `command` | string | stdio only | Command to spawn |
| `upstream[]` | `args` | list | no | Command arguments |
| `upstream[]` | `url` | string | http only | Upstream MCP endpoint |
| `upstream[]` | `headers` | map | no | Extra HTTP headers (auth, etc.) |
| `upstream[]` | `prefix` | string | yes | Tool namespace prefix |
| `upstream[]` | `env` | map | no | Environment variables for stdio |
| `skills[]` | `name` | string | yes | Human label for this skill source |
| `skills[]` | `source` | enum | yes | `"git"`, `"local"` |
| `skills[]` | `repo` | string | git only | `provider:owner/repo` format |
| `skills[]` | `path` | string | yes | Subdirectory (git) or absolute path (local) |
| `skills[]` | `ref` | string | no | Git ref. Default `main` |
| `skills[]` | `sync_interval` | string | no | How often to re-sync. Default `"1h"` |

---

## 4. MCP Transport Layer

### 4.1 Protocol

Implements MCP Streamable HTTP transport:

- `POST /mcp` — receives JSON-RPC messages
- Response: either a single JSON-RPC response or SSE stream (for `tools/call` that stream results)
- Supports `initialize`, `tools/list`, `tools/call`, `ping`

### 4.2 Authentication

Optional bearer token check. When `backplane.auth_token` is set:

```
POST /mcp
Authorization: Bearer your-backplane-secret
```

Requests without valid token receive `401`. When `auth_token` is omitted, all requests are accepted (for local/VPN deployments).

### 4.3 Router

```elixir
defmodule Backplane.Transport.Router do
  use Plug.Router

  plug :match
  plug Backplane.Transport.AuthPlug         # optional bearer check
  plug Plug.Parsers, parsers: [:json]
  plug :dispatch

  post "/mcp" do
    Backplane.Transport.McpHandler.handle(conn)
  end

  post "/webhook/github" do
    Backplane.Jobs.WebhookHandler.enqueue(:github, conn.body_params)
    send_resp(conn, 200, "ok")
  end

  post "/webhook/gitlab" do
    Backplane.Jobs.WebhookHandler.enqueue(:gitlab, conn.body_params)
    send_resp(conn, 200, "ok")
  end
end
```

### 4.4 JSON-RPC Dispatcher

```elixir
defmodule Backplane.Transport.McpHandler do
  def handle(conn) do
    case conn.body_params do
      %{"method" => "initialize", "id" => id} ->
        reply(conn, id, server_info())

      %{"method" => "tools/list", "id" => id} ->
        tools = Backplane.Registry.ToolRegistry.list_all()
        reply(conn, id, %{tools: tools})

      %{"method" => "tools/call", "id" => id, "params" => params} ->
        result = dispatch_tool_call(params["name"], params["arguments"])
        reply(conn, id, result)

      %{"method" => "ping", "id" => id} ->
        reply(conn, id, %{})

      _ ->
        error(conn, -32601, "Method not found")
    end
  end

  defp dispatch_tool_call(name, args) do
    case Backplane.Registry.ToolRegistry.resolve(name) do
      {:native, module}           -> module.call(args)
      {:upstream, upstream, tool} -> Backplane.Proxy.Upstream.forward(upstream, tool, args)
      :not_found                  -> {:error, "Unknown tool: #{name}"}
    end
  end
end
```

---

## 5. Tool Registry & Namespacing

### 5.1 Tool Name Format

```
<prefix>::<tool_name>
```

- Native doc tools: `docs::resolve-project`, `docs::query-docs`
- Native git tools: `git::repo-tree`, `git::repo-file`, `git::repo-issues`, ...
- Upstream tools: `<configured_prefix>::<upstream_tool_name>`
  - e.g. `fs::read_file`, `slack::send_message`, `pg::query`

The `::` separator is chosen over `/` and `:` to avoid ambiguity with MCP server names and URL paths.

### 5.2 Registry Structure

ETS table keyed by full tool name. Each entry:

```elixir
%Backplane.Registry.Tool{
  name: "git::repo-tree",
  description: "List files and directories in a repository",
  input_schema: %{...},               # JSON Schema
  origin: :native | {:upstream, "filesystem"},
  module: Backplane.Tools.Git.RepoTree,  # nil for upstream tools
}
```

### 5.3 Registration Flow

1. **Boot**: native tools register statically
2. **Upstream connect**: each `Backplane.Proxy.Upstream` GenServer calls `tools/list` on its upstream, prefixes all tool names, registers them
3. **Upstream disconnect**: tools are deregistered
4. **Refresh**: upstream tools re-fetched periodically (configurable, default 5min) to pick up changes

---

## 6. Native Tools — Doc Engine

### 6.1 Tools

#### BP-1: `docs::resolve-project`

Resolves a project name to a project ID.

**Parameters:**
| Name | Type | Required | Description |
|---|---|---|---|
| `query` | string | yes | Project name or keyword to search for |

**Returns:** Array of `{id, name, repo, description, last_indexed_at}` sorted by relevance.

**Behaviour:** Fuzzy match against configured projects. If only one match, return it. If ambiguous, return top 5 candidates.

#### BP-2: `docs::query-docs`

Retrieves ranked documentation chunks for a project.

**Parameters:**
| Name | Type | Required | Description |
|---|---|---|---|
| `project_id` | string | yes | Project ID from `resolve-project` |
| `query` | string | yes | Search query |
| `max_tokens` | integer | no | Token budget for response. Default `8000` |
| `version` | string | no | Git ref. Default: configured `ref` for the project |

**Returns:** Array of `{content, source_path, module, function, chunk_type, score}` filling up to `max_tokens`.

**Ranking:** `ts_rank` from tsvector, weighted by chunk_type (moduledoc > function doc > guide section > code comment). Optional pgvector reranking when embeddings are enabled.

### 6.2 Data Model

```sql
-- BP-3
CREATE TABLE projects (
  id          TEXT PRIMARY KEY,        -- from config: "synapsis"
  repo        TEXT NOT NULL,           -- "github:gsmlg-opt/Synapsis"
  ref         TEXT NOT NULL DEFAULT 'main',
  description TEXT,
  last_indexed_at TIMESTAMPTZ,
  index_hash  TEXT,                    -- content-addressable: skip unchanged reindexes
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- BP-4
CREATE TABLE doc_chunks (
  id          BIGSERIAL PRIMARY KEY,
  project_id  TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  source_path TEXT NOT NULL,           -- "lib/synapsis_agent/context_builder.ex"
  module      TEXT,                    -- "SynapsisAgent.ContextBuilder"
  function    TEXT,                    -- "build_system_prompt/2"
  chunk_type  TEXT NOT NULL,           -- "moduledoc" | "function_doc" | "typespec" | "guide" | "code"
  content     TEXT NOT NULL,
  content_hash TEXT NOT NULL,          -- SHA256 — skip unchanged chunks on reindex
  tokens      INTEGER,                -- estimated token count
  search_vector TSVECTOR GENERATED ALWAYS AS (
    setweight(to_tsvector('english', coalesce(module, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(function, '')), 'A') ||
    setweight(to_tsvector('english', content), 'B')
  ) STORED,
  -- Optional: embedding VECTOR(1536) for pgvector semantic search
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_doc_chunks_project ON doc_chunks(project_id);
CREATE INDEX idx_doc_chunks_search ON doc_chunks USING GIN(search_vector);
CREATE INDEX idx_doc_chunks_hash ON doc_chunks(project_id, content_hash);

-- BP-5
CREATE TABLE reindex_state (
  project_id  TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
  commit_sha  TEXT,                    -- last indexed commit
  started_at  TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  chunk_count INTEGER,
  status      TEXT NOT NULL DEFAULT 'pending'  -- pending | running | completed | failed
);
```

### 6.3 Ingestion Pipeline

```
BP-6: Reindex Flow

  Oban trigger (periodic | webhook)
          │
          ▼
  ┌─ Clone/Pull ─────────────────────┐
  │  shallow clone --depth 1          │
  │  authenticated URL from GitProvider│
  │  into /tmp/backplane/<project_id>/  │
  └───────────┬───────────────────────┘
              │
              ▼
  ┌─ Diff Check ─────────────────────┐
  │  compare HEAD SHA with            │
  │  reindex_state.commit_sha         │
  │  skip if unchanged                │
  └───────────┬───────────────────────┘
              │
              ▼
  ┌─ Parse ──────────────────────────┐
  │  walk file tree                   │
  │  route each file to parser chain  │
  │  .ex/.exs → ElixirParser          │
  │  .md      → MarkdownParser        │
  │  other    → GenericParser          │
  └───────────┬───────────────────────┘
              │
              ▼
  ┌─ Chunk ──────────────────────────┐
  │  semantic boundaries:             │
  │  - 1 chunk = 1 moduledoc          │
  │  - 1 chunk = 1 function doc +     │
  │              typespec + signature  │
  │  - 1 chunk = 1 markdown section   │
  │  hash each chunk (SHA256)         │
  └───────────┬───────────────────────┘
              │
              ▼
  ┌─ Index ──────────────────────────┐
  │  diff against existing hashes     │
  │  INSERT new, DELETE removed       │
  │  skip unchanged (same hash)       │
  │  update reindex_state             │
  └──────────────────────────────────┘
```

### 6.4 Elixir Parser (BP-7)

```elixir
defmodule Backplane.Docs.Parsers.Elixir do
  @behaviour Backplane.Docs.Parser

  @impl true
  def parse(source_path, content) do
    {:ok, ast} = Code.string_to_quoted(content, columns: true)
    walk(ast, source_path, [])
  end

  # Extracts:
  # - @moduledoc string → chunk_type "moduledoc", module name from defmodule
  # - @doc string before def/defp → chunk_type "function_doc", includes:
  #   - function name + arity
  #   - preceding @spec if present
  #   - function head (signature line only)
  # - @typedoc + @type → chunk_type "typespec"
end
```

### 6.5 Markdown Parser (BP-8)

Splits on headings (`## `, `### `). Each section becomes a chunk. Frontmatter (YAML between `---`) is extracted as metadata but not indexed as a separate chunk.

---

## 7. Native Tools — Git Platform Proxy

### 7.1 Provider Behaviour

```elixir
defmodule Backplane.Git.Provider do
  @type repo_id :: String.t()     # "owner/repo" or numeric ID
  @type ref :: String.t()         # branch, tag, or SHA
  @type file_entry :: %{path: String.t(), type: :file | :dir, size: integer()}

  @callback list_repos(opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_tree(repo_id, ref, path :: String.t()) :: {:ok, [file_entry]} | {:error, term()}
  @callback fetch_file(repo_id, path :: String.t(), ref) :: {:ok, binary()} | {:error, term()}
  @callback fetch_issues(repo_id, opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_commits(repo_id, opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_merge_requests(repo_id, opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback search_code(query :: String.t(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback clone_url(repo_id) :: String.t()
end
```

### 7.2 API Normalization (BP-9)

| Concept | GitHub | GitLab | Normalized |
|---|---|---|---|
| Repo ID | `owner/repo` | numeric or `group%2Fproject` | `provider:owner/repo` |
| Code change | Pull Request | Merge Request | `merge_request` |
| CI | Actions / Checks | CI/CD Pipeline | `pipeline` |
| Tree endpoint | `/repos/:owner/:repo/git/trees/:sha` | `/projects/:id/repository/tree` | unified via behaviour |
| File endpoint | `/repos/:owner/:repo/contents/:path` | `/projects/:id/repository/files/:path` | unified via behaviour |
| Pagination | Link header (cursor) | `X-Next-Page` header (keyset) | abstracted in each provider |
| Rate limiting | `X-RateLimit-*` | `RateLimit-*` | shared backoff GenServer |

### 7.3 Tools

#### BP-10: `git::search-repos`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `query` | string | yes | Search term |
| `provider` | string | no | Filter to `"github"`, `"gitlab"`, or a named instance. Default: search all |

#### BP-11: `git::repo-tree`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `repo` | string | yes | `provider:owner/repo` format |
| `path` | string | no | Subdirectory. Default `"/"` |
| `ref` | string | no | Branch/tag. Default: repo's default branch |

#### BP-12: `git::repo-file`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `repo` | string | yes | `provider:owner/repo` |
| `path` | string | yes | File path |
| `ref` | string | no | Branch/tag |

Returns file content as text (with truncation at configurable max, default 100KB).

#### BP-13: `git::repo-issues`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `repo` | string | yes | `provider:owner/repo` |
| `state` | string | no | `"open"`, `"closed"`, `"all"`. Default `"open"` |
| `query` | string | no | Search within issues |
| `limit` | integer | no | Max results. Default `20` |

Returns normalized issue objects: `{number, title, state, author, labels, created_at, body_preview}`.

#### BP-14: `git::repo-commits`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `repo` | string | yes | `provider:owner/repo` |
| `ref` | string | no | Branch/tag |
| `path` | string | no | Filter to file path |
| `limit` | integer | no | Max results. Default `20` |

#### BP-15: `git::repo-merge-requests`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `repo` | string | yes | `provider:owner/repo` |
| `state` | string | no | `"open"`, `"closed"`, `"merged"`, `"all"`. Default `"open"` |
| `limit` | integer | no | Max results. Default `20` |

#### BP-16: `git::search-code`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `query` | string | yes | Code search query |
| `repo` | string | no | Limit to specific repo |
| `language` | string | no | Filter by language |

---

## 8. Upstream MCP Proxy

### 8.1 Connection Management (BP-17)

Each `[[upstream]]` entry in config spawns a `Backplane.Proxy.Upstream` GenServer under `Backplane.Proxy.Pool` (DynamicSupervisor).

**Stdio upstreams:** GenServer manages a Port. Sends JSON-RPC over stdin, reads from stdout. Lifecycle: start on boot, restart on crash (supervisor).

**HTTP upstreams:** GenServer holds a `Req` client with base URL and headers. Stateless — no persistent connection needed, but the GenServer manages tool caching and health checks.

### 8.2 Tool Discovery (BP-18)

On connection (or reconnect), each upstream GenServer:

1. Sends `initialize` → receives capabilities
2. Sends `tools/list` → receives tool definitions
3. Prefixes each tool name: `<prefix>::<original_name>`
4. Registers all tools in `Backplane.Registry.ToolRegistry`
5. Schedules periodic refresh (default 5min)

### 8.3 Tool Call Forwarding (BP-19)

When `dispatch_tool_call` resolves to `{:upstream, upstream_pid, original_tool_name}`:

1. Strip the namespace prefix to recover the original tool name
2. `GenServer.call(upstream_pid, {:tools_call, original_tool_name, arguments})`
3. The GenServer forwards via stdio or HTTP to the upstream
4. Return result (or error with timeout after configurable deadline, default 30s)

### 8.4 Failure Handling (BP-20)

- Upstream crash (stdio): supervisor restarts, tools temporarily deregistered, re-registered on reconnect
- Upstream timeout (http): return error to caller, mark upstream degraded, exponential backoff on retries
- Upstream gone: tools deregistered, periodic reconnect attempts

---

## 9. Skills Engine

### 9.1 What Is a Skill

A skill is a curated instruction package — a document that tells an agent **how** to do something well. Unlike tools (which execute actions), skills inject domain expertise, coding patterns, workflow guidance, and prompt strategies into an agent's context.

Skill format follows the convention established by Claude Code and adopted in Synapsis:

```markdown
---
name: elixir-genserver
description: Best practices for GenServer design in production Elixir
tags: [elixir, otp, genserver, patterns]
tools: [file_read, file_write, bash]
model: claude-sonnet-4                    # optional: recommended model
version: "1.2.0"
---

# GenServer Production Patterns

## When to Use a GenServer
...

## Supervision Strategy
...
```

**Frontmatter** (YAML between `---`): machine-readable metadata for discovery.
**Body** (markdown): the actual instructions injected into agent context when loaded.

### 9.2 Skill Sources

Skills can come from three places, with a unified interface:

```elixir
defmodule Backplane.Skills.Source do
  @type skill_entry :: %{
    id: String.t(),             # stable ID: "source_name/skill_name"
    name: String.t(),
    description: String.t(),
    tags: [String.t()],
    tools: [String.t()],
    model: String.t() | nil,
    version: String.t(),
    content: String.t(),        # full markdown body
    content_hash: String.t(),   # SHA256 for change detection
    source: String.t(),         # "git:elixir-patterns", "local:experiments", "db"
  }

  @callback list() :: {:ok, [skill_entry]} | {:error, term()}
  @callback fetch(skill_id :: String.t()) :: {:ok, skill_entry} | {:error, term()}
end
```

| Source | Discovery | Sync | Authoring |
|---|---|---|---|
| **Git** | Walk repo dir, find `*.md` with frontmatter | Oban periodic job, shallow clone + diff | Edit in repo, push, auto-syncs |
| **Local** | Watch filesystem dir | `FileSystem` watcher or periodic scan | Edit files directly |
| **Database** | Query `skills` table | Immediate (it's the source of truth) | Via `skill::create`/`skill::update` tools |

### 9.3 Data Model

```sql
-- BP-22
CREATE TABLE skills (
  id           TEXT PRIMARY KEY,          -- "source_name/skill_name" or ULID for DB-authored
  name         TEXT NOT NULL,
  description  TEXT NOT NULL DEFAULT '',
  tags         TEXT[] NOT NULL DEFAULT '{}',
  tools        TEXT[] NOT NULL DEFAULT '{}',
  model        TEXT,
  version      TEXT NOT NULL DEFAULT '1.0.0',
  content      TEXT NOT NULL,             -- full markdown body
  content_hash TEXT NOT NULL,             -- SHA256
  source       TEXT NOT NULL,             -- "git:elixir-patterns" | "local:experiments" | "db"
  enabled      BOOLEAN NOT NULL DEFAULT true,
  search_vector TSVECTOR GENERATED ALWAYS AS (
    setweight(to_tsvector('english', name), 'A') ||
    setweight(to_tsvector('english', description), 'A') ||
    setweight(to_tsvector('english', array_to_string(tags, ' ')), 'A') ||
    setweight(to_tsvector('english', content), 'B')
  ) STORED,
  inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_skills_search ON skills USING GIN(search_vector);
CREATE INDEX idx_skills_tags ON skills USING GIN(tags);
CREATE INDEX idx_skills_source ON skills(source);
```

Git-sourced and local-sourced skills are synced **into** this table. The table is the unified catalog. Source field tracks provenance. Content hash enables diff-aware sync (skip unchanged skills).

### 9.4 Skills Registry

ETS table mirroring the `skills` table for fast reads. Rebuilt on boot from PG. Updated on sync events via PubSub.

```elixir
defmodule Backplane.Skills.Registry do
  # ETS table: :backplane_skills
  # Key: skill ID
  # Value: %{name, description, tags, tools, model, version, content, source}

  def list(opts \\ [])                # filter by tags, source, enabled
  def search(query)                   # tsvector search
  def fetch(skill_id)                 # single skill with full content
  def refresh()                       # reload from PG
end
```

### 9.5 Tools

#### BP-23: `skill::search`

Search for available skills by keyword, tag, or tool requirement.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `query` | string | yes | Search keywords |
| `tags` | array | no | Filter by tags (AND match) |
| `tools` | array | no | Filter by required tools |
| `limit` | integer | no | Max results. Default `10` |

**Returns:** Array of `{id, name, description, tags, version, source}`. Does NOT return content — use `skill::load` for that.

#### BP-24: `skill::load`

Load a skill's full content for injection into agent context.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `skill_id` | string | yes | Skill ID from `skill::search` |

**Returns:** `{id, name, content, tools, model}`. The `content` field is the full markdown body, ready for system prompt injection.

#### BP-25: `skill::list`

List all available skills with metadata (no content).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `source` | string | no | Filter by source type: `"git"`, `"local"`, `"db"` |
| `tags` | array | no | Filter by tags |

**Returns:** Array of `{id, name, description, tags, version, source, enabled}`.

#### BP-26: `skill::create`

Create a new database-sourced skill.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Skill name |
| `description` | string | yes | Short description |
| `content` | string | yes | Full markdown body |
| `tags` | array | no | Tags for discovery |
| `tools` | array | no | Recommended tools |
| `model` | string | no | Recommended model |

**Returns:** Created skill entry. Only works for `source: "db"` skills. Git/local skills are managed at their source.

#### BP-27: `skill::update`

Update a database-sourced skill.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `skill_id` | string | yes | Skill ID (must be `db` sourced) |
| `content` | string | no | Updated markdown body |
| `description` | string | no | Updated description |
| `tags` | array | no | Updated tags |
| `enabled` | boolean | no | Enable/disable |

**Returns:** Updated skill entry. Rejects updates to git/local sourced skills.

### 9.6 Sync Pipeline (BP-28)

```
Oban trigger (periodic per skill source)
        │
        ▼
┌─ Resolve Source ──────────────────┐
│  git → shallow clone / pull       │
│  local → read directory           │
└───────────┬───────────────────────┘
            │
            ▼
┌─ Discover Skills ─────────────────┐
│  walk dir, find *.md files        │
│  parse frontmatter + body         │
│  compute content_hash             │
└───────────┬───────────────────────┘
            │
            ▼
┌─ Diff & Upsert ──────────────────┐
│  compare hashes with DB           │
│  INSERT new skills                │
│  UPDATE changed skills            │
│  mark removed skills disabled     │
│  (don't delete — preserve refs)   │
└───────────┬───────────────────────┘
            │
            ▼
┌─ Notify ─────────────────────────┐
│  PubSub broadcast                 │
│  Skills.Registry refreshes ETS    │
└──────────────────────────────────┘
```

---

## 10. Hub Meta Tools

Hub Meta tools provide cross-cutting discovery and introspection across all engines. They are the "glue" that makes the hub feel like one system rather than four separate things.

### 10.1 Tools

#### BP-29: `hub::discover`

Unified search across everything in the hub: tools, skills, docs, repos.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `query` | string | yes | Search keywords |
| `scope` | array | no | Filter to `["tools", "skills", "docs", "repos"]`. Default: all |
| `limit` | integer | no | Max results per scope. Default `5` |

**Returns:** Grouped results:
```json
{
  "tools": [{"name": "git::repo-tree", "description": "...", "origin": "native"}],
  "skills": [{"id": "elixir-patterns/genserver", "name": "...", "tags": [...]}],
  "docs": [{"project": "synapsis", "module": "SynapsisAgent.Loop", "snippet": "..."}],
  "repos": [{"repo": "github:gsmlg-opt/Synapsis", "description": "..."}]
}
```

This is the "I don't know what I'm looking for" tool. Agents use it when they need to figure out what's available before making specific tool calls.

#### BP-30: `hub::inspect`

Introspect a specific tool's full schema, origin, and health.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `tool_name` | string | yes | Full namespaced tool name (e.g. `git::repo-tree`) |

**Returns:** `{name, description, input_schema, origin, upstream_name, upstream_healthy, last_called_at}`.

Useful for agents that need to understand a tool's parameters before calling it, or for debugging upstream connectivity.

#### BP-31: `hub::status`

Health and status overview of the entire hub.

| Parameter | Type | Required | Description |
|---|---|---|---|
| (none) | | | |

**Returns:**
```json
{
  "upstreams": [{"name": "slack", "status": "connected", "tool_count": 12}],
  "skill_sources": [{"name": "elixir-patterns", "source": "git", "skill_count": 8, "last_synced": "..."}],
  "doc_projects": [{"id": "synapsis", "chunk_count": 1420, "last_indexed": "..."}],
  "git_providers": [{"name": "github", "status": "ok", "rate_remaining": 4800}],
  "total_tools": 47,
  "total_skills": 23
}
```

---

## 11. Webhooks (BP-21)

### 11.1 GitHub Webhook

`POST /webhook/github`

Validates `X-Hub-Signature-256` against a configured secret per project. On `push` events to the tracked `ref`, enqueues an Oban reindex job for the matching project.

### 11.2 GitLab Webhook

`POST /webhook/gitlab`

Validates `X-Gitlab-Token`. On `push` events to the tracked `ref`, enqueues reindex.

### 11.3 Webhook Config

```toml
[[projects]]
id = "synapsis"
repo = "github:gsmlg-opt/Synapsis"
ref = "main"
webhook_secret = "whsec_..."    # GitHub: HMAC secret, GitLab: token
```

---

## 12. Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:plug, "~> 1.16"},
    {:bandit, "~> 1.5"},
    {:jason, "~> 1.4"},
    {:req, "~> 0.5"},
    {:ecto_sql, "~> 3.12"},
    {:postgrex, "~> 0.19"},
    {:oban, "~> 2.18"},
    {:toml, "~> 0.7"},
    {:file_system, "~> 1.0"},      # local skill source watching

    # Optional
    {:pgvector, "~> 0.3"},         # semantic search (opt-in)

    # Dev/Test
    {:credo, "~> 1.7", only: [:dev, :test]},
    {:dialyxir, "~> 1.4", only: [:dev, :test]},
    {:ex_machina, "~> 2.8", only: :test},
    {:mox, "~> 1.1", only: :test},
  ]
end
```

---

## 13. Open Questions — Resolved

### OQ-1: Should `::` namespace be configurable per-client?

**Decision: No.** `::` is the canonical separator. MCP clients receive tool names as opaque strings — they don't parse separators. No known MCP client chokes on `::`. If a future client does, we add a gateway-level rewrite as a Plug (e.g., `::` → `__`), not a config option. Keeping it fixed avoids divergent namespaces across clients talking to the same hub.

### OQ-2: Embedding pipeline — Ollama local vs API?

**Decision: Defer entirely.** tsvector is the initial search strategy for both docs and skills. Embeddings are Phase 7+ (production hardening). When implemented, support both: a `[embeddings]` config section with `provider = "ollama" | "openai" | "anthropic"` and `model`, `api_url`, `api_key` fields. The indexer calls a `Backplane.Embeddings` behaviour that dispatches to the configured provider. Don't build any of this until tsvector proves insufficient.

### OQ-3: Auth model — single token or per-client scoped tokens?

**Decision: Single bearer token for initial phases.** Per-client scoped access (client A gets `docs::*` + `git::*`, client B gets everything) is a future consideration. The current model: one `backplane.auth_token` in config. All authenticated clients see all tools. Scoped access requires a `clients` table, token-to-scope mapping, and registry filtering per request — real work that isn't needed until multi-user deployment.

### OQ-4: Should the hub expose MCP `resources` and `prompts` capabilities?

**Decision: Yes, but not in initial phases.** MCP resources are a natural fit for doc chunks (a doc chunk *is* a resource — it has a URI, content, and MIME type). MCP prompts are a natural fit for skills (a skill *is* a prompt template). Mapping:

| MCP Capability | Hub Engine | When |
|---|---|---|
| `tools` | All engines | Phase 1+ (core) |
| `resources` | Doc Engine | Phase 4+ (doc chunks as resources with `backplane://docs/{project}/{path}` URIs) |
| `prompts` | Skills Engine | Phase 3+ (skills as prompts with parameter extraction from frontmatter `tools`/`model` fields) |

Implementation: add `resources/list`, `resources/read`, `prompts/list`, `prompts/get` to the JSON-RPC dispatcher. Resource URIs and prompt names follow the same `::` namespace convention. This is additive — tools work first, resources/prompts layer on top.

### OQ-5: Git provider credential rotation — how?

**Decision: Config hot-reload via SIGHUP.** When the hub process receives SIGHUP, it re-reads `backplane.toml` and updates the in-memory credential store. No restart needed. Git provider modules read credentials from the Config module on each request (not cached at init). This means token rotation is: edit `backplane.toml` → `kill -HUP <pid>`. Implemented in Phase 7.

---

## 14. Shared Test Support

```elixir
# test/support/data_case.ex
defmodule Backplane.DataCase do
  use ExUnit.CaseTemplate
  # Ecto sandbox checkout for DB-backed tests
end

# test/support/conn_case.ex
defmodule Backplane.ConnCase do
  use ExUnit.CaseTemplate
  # Helpers: mcp_request/3 (sends JSON-RPC to /mcp, returns parsed response)
  #          get_request/1 (sends GET, returns parsed response)
end

# test/support/fixtures.ex
defmodule Backplane.Fixtures do
  # Factory functions for: projects, doc_chunks, skills, upstream configs
  # Sample SKILL.md content, sample Elixir source with docs, sample markdown guides
end

# test/support/mocks.ex
# Mox definitions:
#   Backplane.Git.ProviderMock       — GitHub/GitLab API calls
#   Backplane.Proxy.TransportMock    — upstream MCP communication
#   Backplane.Docs.ParserMock        — doc parsing
#   Backplane.Skills.SourceMock      — skill source loading
```

Fixture files in `test/support/fixtures/`:

```
test/support/fixtures/
├── skills/
│   ├── valid_skill.md              # Complete SKILL.md with frontmatter + body
│   ├── minimal_skill.md            # Frontmatter with only required fields
│   ├── no_frontmatter.md           # Markdown without YAML frontmatter
│   └── invalid_frontmatter.md      # Malformed YAML
├── elixir_source/
│   ├── documented_module.ex        # Module with @moduledoc, @doc, @spec, @type
│   ├── undocumented_module.ex      # Module with no docs
│   └── nested_modules.ex           # Nested defmodule blocks
├── markdown/
│   ├── guide_with_headings.md      # Multi-section guide
│   ├── guide_with_frontmatter.md   # Guide with YAML frontmatter
│   └── flat_document.md            # No headings
└── config/
    ├── minimal.toml                # Hub section only
    ├── full.toml                   # All sections populated
    └── invalid.toml                # Malformed
```

---

## 15. Implementation Phases

### Phase 1: Skeleton + MCP Transport

**Goal:** Bare MCP server that responds to `initialize`, `tools/list`, `tools/call` with zero native tools. Any MCP client can connect. Config loader works.

**Modules:** `Application`, `Config`, `Transport.Router`, `Transport.McpHandler`, `Transport.AuthPlug`, `Registry.ToolRegistry`, `Tool` (behaviour)

**Migrations:** None.

**Tests (29 tests):**

```
test/backplane/config_test.exs
├── describe "load!/0"
│   ├── loads minimal config (hub section only)
│   ├── loads full config with all sections populated
│   ├── parses single github credential with token and api_url
│   ├── parses multiple github instances (github.secondary)
│   ├── parses single gitlab credential
│   ├── parses multiple gitlab instances
│   ├── parses projects list with all fields
│   ├── defaults ref to "main" when omitted
│   ├── defaults parsers to ["generic"] when omitted
│   ├── parses upstream servers with stdio transport
│   ├── parses upstream servers with http transport
│   ├── parses skill sources with git source
│   ├── parses skill sources with local source
│   ├── parses host string to inet tuple
│   ├── defaults port to 4100 when omitted
│   ├── reads auth_token from hub section
│   ├── raises on missing config file
│   └── raises on malformed TOML

test/backplane/transport/auth_plug_test.exs
├── describe "no auth configured"
│   ├── passes all requests through
│   └── does not check authorization header
├── describe "auth configured"
│   ├── passes request with valid bearer token
│   ├── rejects request with missing authorization header (401)
│   ├── rejects request with wrong token (401)
│   ├── rejects request with malformed authorization header (401)
│   └── always passes /health without auth

test/backplane/transport/mcp_handler_test.exs
├── describe "initialize"
│   ├── returns protocolVersion and serverInfo
│   └── returns tools capability with listChanged
├── describe "tools/list"
│   └── returns empty tools array when no tools registered
├── describe "tools/call"
│   └── returns error for unknown tool name
├── describe "ping"
│   └── returns empty result
├── describe "invalid request"
│   ├── returns -32600 for missing jsonrpc field
│   └── returns -32601 for unknown method

test/backplane/registry/tool_registry_test.exs
├── describe "register_native/1"
│   ├── registers a tool module and appears in list_all
│   └── tool is resolvable via resolve/1
├── describe "list_all/0"
│   ├── returns empty list when no tools registered
│   └── returns sorted list of all tools
├── describe "resolve/1"
│   ├── returns {:native, module} for native tool
│   └── returns :not_found for unregistered name
├── describe "count/0"
│   └── returns number of registered tools
```

### Phase 2: Upstream MCP Proxy

**Goal:** Connect to upstream MCP servers, namespace their tools, forward calls. This is the core hub function — usable day one.

**Modules:** `Proxy.Pool`, `Proxy.Upstream`, `Proxy.Namespace`

**Migrations:** None.

**Tests (34 tests):**

```
test/backplane/proxy/namespace_test.exs
├── describe "prefix/2"
│   ├── prefixes tool name with separator ("fs" + "read_file" → "fs::read_file")
│   ├── handles empty tool name
│   └── handles tool name already containing ::
├── describe "strip/2"
│   ├── removes prefix to recover original name
│   └── returns original if no prefix match

test/backplane/proxy/upstream_test.exs
├── describe "HTTP transport"
│   ├── connects and sends initialize
│   ├── discovers tools via tools/list
│   ├── registers discovered tools with prefix in registry
│   ├── forwards tool call and returns result
│   ├── returns error on upstream timeout
│   ├── returns error when upstream returns JSON-RPC error
│   ├── returns error when connection refused
│   ├── deregisters tools on disconnect
│   └── reconnects after connection failure with backoff
├── describe "stdio transport"
│   ├── spawns port process with configured command
│   ├── sends initialize over stdin
│   ├── discovers tools via tools/list over stdin
│   ├── registers discovered tools with prefix in registry
│   ├── forwards tool call over stdin and returns result
│   ├── deregisters tools when port process exits
│   └── restarts port process after crash
├── describe "tool refresh"
│   ├── re-fetches tools/list on refresh interval
│   ├── updates registry when upstream tools change
│   └── handles refresh failure gracefully (keeps existing tools)

test/backplane/proxy/pool_test.exs
├── describe "start_link/1"
│   ├── starts with empty upstream list
│   └── starts child for each configured upstream
├── describe "start_upstream/1"
│   └── dynamically adds new upstream connection
├── describe "list_upstreams/0"
│   ├── returns status for all upstreams
│   └── returns empty when no upstreams configured

test/backplane/registry/tool_registry_test.exs (additions to Phase 1)
├── describe "register_upstream/3"
│   ├── registers upstream tools with prefix
│   ├── stores upstream_pid for forwarding
│   └── stores original tool name for stripping
├── describe "deregister_upstream/1"
│   ├── removes all tools with given prefix
│   └── leaves other prefixes intact
├── describe "resolve/1" (upstream path)
│   └── returns {:upstream, pid, original_name} for upstream tool
├── describe "search/2"
│   ├── finds tools by name substring
│   ├── finds tools by description substring
│   └── respects limit option

test/integration/proxy_roundtrip_test.exs
├── describe "end-to-end proxy"
│   ├── client calls tools/list → sees namespaced upstream tools
│   ├── client calls tools/call with namespaced name → receives upstream result
│   └── upstream crash → tool disappears from list → reconnect → tool reappears
```

### Phase 3: Skills Engine

**Goal:** Skills discoverable and loadable from git, local, and database sources. Five skill tools functional.

**Modules:** `Skills.Registry`, `Skills.Loader`, `Skills.Source` (behaviour), `Skills.Sources.Git`, `Skills.Sources.Local`, `Skills.Sources.Database`, `Skills.Search`, `Skills.Sync`, `Tools.Skill.*`, Ecto migration

**Migrations:** `004_create_skills`

**Tests (52 tests):**

```
test/backplane/skills/loader_test.exs
├── describe "parse/1"
│   ├── extracts name from frontmatter
│   ├── extracts description from frontmatter
│   ├── extracts tags array from frontmatter
│   ├── extracts tools array from frontmatter
│   ├── extracts model from frontmatter (optional)
│   ├── extracts version from frontmatter
│   ├── extracts markdown body after frontmatter
│   ├── handles minimal frontmatter (only name)
│   ├── defaults missing fields (tags → [], version → "1.0.0")
│   ├── computes SHA256 content_hash
│   ├── returns error for missing frontmatter
│   └── returns error for malformed YAML in frontmatter

test/backplane/skills/sources/git_test.exs
├── describe "list/0"
│   ├── clones repo and discovers SKILL.md files
│   ├── scans only configured subdirectory path
│   ├── ignores non-.md files
│   ├── ignores .md files without valid frontmatter
│   └── returns skill entries with source set to "git:<name>"
├── describe "fetch/1"
│   ├── returns specific skill by ID
│   └── returns error for nonexistent skill

test/backplane/skills/sources/local_test.exs
├── describe "list/0"
│   ├── reads configured directory for SKILL.md files
│   ├── ignores subdirectories (non-recursive by default)
│   ├── ignores non-.md files
│   └── returns skill entries with source set to "local:<name>"
├── describe "fetch/1"
│   ├── returns specific skill by ID
│   └── returns error for nonexistent skill

test/backplane/skills/sources/database_test.exs
├── describe "list/0"
│   └── returns all enabled skills with source "db"
├── describe "fetch/1"
│   ├── returns skill by ID
│   └── returns error for nonexistent
├── describe "create/1"
│   ├── inserts skill with generated ID
│   ├── computes content_hash
│   └── validates required fields (name, content)
├── describe "update/2"
│   ├── updates content and recomputes hash
│   ├── updates tags and description
│   └── rejects update of non-db-sourced skill

test/backplane/skills/sync_test.exs
├── describe "perform/1" (Oban worker)
│   ├── inserts new skills from source
│   ├── updates changed skills (different content_hash)
│   ├── disables removed skills (not present in source)
│   ├── skips unchanged skills (same content_hash)
│   ├── refreshes ETS registry after sync
│   └── handles source fetch failure gracefully

test/backplane/skills/search_test.exs
├── describe "query/2"
│   ├── finds skills by name match (weighted highest)
│   ├── finds skills by tag match
│   ├── finds skills by description match
│   ├── finds skills by content match (weighted lower)
│   ├── filters by tags (AND match)
│   ├── filters by source type
│   ├── excludes disabled skills
│   ├── respects limit
│   └── returns empty for no matches

test/backplane/skills/registry_test.exs
├── describe "list/1"
│   ├── returns all skills from ETS
│   └── filters by source when option provided
├── describe "search/2"
│   ├── searches by keyword in name and description
│   └── respects limit option
├── describe "fetch/1"
│   ├── returns skill by ID from ETS
│   └── returns :not_found for missing
├── describe "count/0"
│   └── returns total skill count
├── describe "refresh/0"
│   └── reloads ETS from database

test/backplane/tools/skill_test.exs
├── describe "skill::search"
│   ├── returns matching skills without content
│   └── filters by tags when provided
├── describe "skill::load"
│   ├── returns full content for valid skill_id
│   └── returns error for nonexistent skill_id
├── describe "skill::list"
│   ├── returns all enabled skills
│   └── filters by source when provided
├── describe "skill::create"
│   ├── creates db-sourced skill and returns entry
│   └── validates required fields
├── describe "skill::update"
│   ├── updates db-sourced skill
│   └── rejects update of git-sourced skill
```

### Phase 4: Doc Engine

**Goal:** Index configured projects, serve `docs::resolve-project` and `docs::query-docs`. Webhooks trigger reindex.

**Modules:** `Docs.Ingestion`, `Docs.Parser` (behaviour), `Docs.Parsers.Elixir`, `Docs.Parsers.Markdown`, `Docs.Parsers.Generic`, `Docs.Chunker`, `Docs.Indexer`, `Docs.Search`, `Tools.Docs.*`, `Jobs.Reindex`, `Jobs.WebhookHandler`

**Migrations:** `001_create_projects`, `002_create_doc_chunks`, `003_create_reindex_state`

**Tests (56 tests):**

```
test/backplane/docs/parsers/elixir_test.exs
├── describe "parse/2"
│   ├── extracts @moduledoc as moduledoc chunk
│   ├── extracts module name from defmodule
│   ├── extracts @doc + function name + arity as function_doc chunk
│   ├── includes preceding @spec in function_doc chunk
│   ├── includes function head (signature) in function_doc chunk
│   ├── extracts @typedoc + @type as typespec chunk
│   ├── handles module with no docs (returns empty list)
│   ├── handles nested defmodule blocks
│   ├── handles heredoc @moduledoc
│   ├── handles @moduledoc false (skip, don't create chunk)
│   └── handles syntax errors gracefully (returns error, not crash)

test/backplane/docs/parsers/markdown_test.exs
├── describe "parse/2"
│   ├── splits on ## headings into chunks
│   ├── splits on ### headings within ## sections
│   ├── preserves heading text as chunk title
│   ├── extracts YAML frontmatter as metadata (not a separate chunk)
│   ├── handles document with no headings (single chunk)
│   ├── handles empty document
│   └── sets chunk_type to "guide"

test/backplane/docs/parsers/generic_test.exs
├── describe "parse/2"
│   ├── splits on blank-line-separated paragraphs for unknown file types
│   └── sets chunk_type to "code"

test/backplane/docs/chunker_test.exs
├── describe "chunk/1"
│   ├── computes SHA256 content_hash per chunk
│   ├── estimates token count per chunk
│   ├── preserves source_path, module, function metadata
│   └── does not split below minimum chunk size

test/backplane/docs/indexer_test.exs
├── describe "index/2"
│   ├── inserts new chunks into doc_chunks table
│   ├── skips chunks with unchanged content_hash
│   ├── deletes chunks no longer present in source
│   ├── updates reindex_state with commit_sha and status
│   └── handles empty chunk list (clears project)

test/backplane/docs/search_test.exs
├── describe "query/3"
│   ├── finds chunks by content match (tsvector)
│   ├── weights module/function name higher than content
│   ├── filters by project_id
│   ├── respects max_tokens budget (fills until budget exhausted)
│   ├── returns chunks sorted by ts_rank descending
│   ├── returns empty for no matches
│   └── filters by version (git ref) when provided

test/backplane/docs/ingestion_test.exs
├── describe "run/1"
│   ├── clones repo for new project (no prior index)
│   ├── pulls repo for existing project
│   ├── skips reindex when HEAD SHA unchanged
│   ├── routes .ex files to Elixir parser
│   ├── routes .md files to Markdown parser
│   ├── routes other files to Generic parser
│   ├── chains through chunker → indexer
│   ├── updates reindex_state on success
│   ├── sets reindex_state status to "failed" on error
│   └── cleans up temp directory after completion

test/backplane/jobs/reindex_test.exs
├── describe "perform/1" (Oban worker)
│   ├── runs ingestion for specified project_id
│   ├── is unique per project_id (Oban uniqueness)
│   └── handles ingestion failure (job retries)

test/backplane/jobs/webhook_handler_test.exs
├── describe "perform/1"
│   ├── enqueues reindex for matching project on github push event
│   ├── enqueues reindex for matching project on gitlab push event
│   ├── ignores push to non-tracked ref
│   ├── validates github webhook signature (X-Hub-Signature-256)
│   ├── validates gitlab webhook token (X-Gitlab-Token)
│   └── ignores non-push events

test/backplane/tools/docs_test.exs
├── describe "docs::resolve-project"
│   ├── returns matching project for exact name
│   ├── returns top candidates for fuzzy match
│   └── returns empty for no match
├── describe "docs::query-docs"
│   ├── returns ranked chunks for valid project_id
│   ├── respects max_tokens parameter
│   ├── returns error for nonexistent project_id
│   └── filters by version when provided

test/integration/doc_roundtrip_test.exs
├── describe "end-to-end"
│   ├── configure project → reindex → query returns Elixir doc chunks
│   ├── modify source → reindex → only changed chunks updated
│   └── webhook → reindex triggered → fresh results available
```

### Phase 5: Git Platform Proxy

**Goal:** GitHub + GitLab tools work with centralized auth. API responses normalized across platforms.

**Modules:** `Git.Provider` (behaviour), `Git.Providers.GitHub`, `Git.Providers.GitLab`, `Git.Resolver`, `Tools.Git.*`

**Migrations:** None.

**Tests (47 tests):**

```
test/backplane/git/resolver_test.exs
├── describe "resolve/1"
│   ├── resolves "github:owner/repo" to GitHub provider + credentials
│   ├── resolves "gitlab:group/project" to GitLab provider + credentials
│   ├── resolves named instance "github.enterprise:owner/repo"
│   ├── resolves named instance "gitlab.self_hosted:group/project"
│   └── returns error for unknown provider prefix

test/backplane/git/providers/github_test.exs
├── describe "fetch_tree/3"
│   ├── returns file listing at root
│   ├── returns file listing at subdirectory
│   ├── includes type (:file or :dir) and size
│   └── handles non-existent path (404)
├── describe "fetch_file/3"
│   ├── returns file content as text
│   ├── truncates at configured max size
│   └── handles non-existent file (404)
├── describe "fetch_issues/2"
│   ├── returns open issues by default
│   ├── filters by state
│   ├── searches within issues by query
│   └── returns normalized issue objects
├── describe "fetch_commits/2"
│   ├── returns commits on default branch
│   ├── filters by ref
│   ├── filters by path
│   └── respects limit
├── describe "fetch_merge_requests/2"
│   ├── returns open pull requests
│   └── filters by state
├── describe "search_code/2"
│   ├── returns code search results
│   └── filters by repo and language
├── describe "rate limiting"
│   ├── reads X-RateLimit-Remaining header
│   └── backs off when limit approaching

test/backplane/git/providers/gitlab_test.exs
├── describe "fetch_tree/3"
│   ├── returns file listing at root
│   ├── handles URL-encoded project path (group%2Fproject)
│   └── paginates via X-Next-Page header
├── describe "fetch_file/3"
│   ├── returns file content as text
│   └── handles non-existent file
├── describe "fetch_issues/2"
│   ├── returns open issues by default
│   └── returns normalized issue objects matching GitHub shape
├── describe "fetch_commits/2"
│   ├── returns commits on default branch
│   └── respects limit
├── describe "fetch_merge_requests/2"
│   ├── returns open merge requests
│   ├── maps "merged" state correctly
│   └── normalizes to same shape as GitHub PRs
├── describe "search_code/2"
│   └── returns code search results
├── describe "rate limiting"
│   ├── reads RateLimit-Remaining header
│   └── backs off when limit approaching

test/backplane/tools/git_test.exs
├── describe "git::search-repos"
│   ├── searches across all configured providers
│   └── filters by provider when specified
├── describe "git::repo-tree"
│   ├── returns file listing for github: repo
│   ├── returns file listing for gitlab: repo
│   └── returns error for unknown repo
├── describe "git::repo-file"
│   ├── returns file content
│   └── returns error for non-existent path
├── describe "git::repo-issues"
│   ├── returns normalized issues
│   └── filters by state
├── describe "git::repo-commits"
│   └── returns commits with optional path filter
├── describe "git::repo-merge-requests"
│   └── returns normalized MRs from both platforms
├── describe "git::search-code"
│   └── returns code results with repo and language filter
```

### Phase 6: Hub Meta Tools

**Goal:** Cross-cutting discovery and introspection across all engines.

**Modules:** `Hub.Discover`, `Hub.Inspect`, `Tools.Hub.Discover`, `Tools.Hub.Inspect`, `Tools.Hub.Status`

**Migrations:** None.

**Tests (19 tests):**

```
test/backplane/hub/discover_test.exs
├── describe "search/2"
│   ├── returns results across tools, skills, docs
│   ├── scopes to tools only when scope: ["tools"]
│   ├── scopes to skills only when scope: ["skills"]
│   ├── scopes to docs only when scope: ["docs"]
│   ├── scopes to repos only when scope: ["repos"]
│   ├── limits results per scope
│   ├── returns empty groups for no matches
│   └── handles missing engines gracefully (skills empty when none indexed)

test/backplane/tools/hub_test.exs
├── describe "hub::discover"
│   ├── returns grouped results matching query
│   ├── respects scope filter
│   └── respects limit
├── describe "hub::inspect"
│   ├── returns full schema for native tool
│   ├── returns full schema for upstream tool with origin info
│   └── returns error for unknown tool
├── describe "hub::status"
│   ├── returns upstream connection statuses
│   ├── returns skill source summaries
│   ├── returns doc project summaries
│   ├── returns total tool count
│   └── returns total skill count
```

### Phase 7: Production Hardening

**Goal:** Operationally ready for long-running deployment.

**Modules:** `Config.Watcher`, `Transport.HealthCheck`, telemetry event definitions

**Tests (12 tests):**

```
test/backplane/config/watcher_test.exs
├── describe "SIGHUP handling"
│   ├── reloads config on SIGHUP
│   ├── updates auth_token in application env
│   ├── updates git credentials in memory
│   └── does not restart existing upstream connections

test/backplane/transport/health_check_test.exs
├── describe "GET /health"
│   ├── returns 200 when all engines healthy
│   ├── returns 200 with degraded upstreams (hub still serves)
│   └── includes engine summaries in response

test/backplane/telemetry_test.exs
├── describe "tool_call events"
│   ├── emits [:backplane, :tool_call, :start] on dispatch
│   ├── emits [:backplane, :tool_call, :stop] on success
│   ├── emits [:backplane, :tool_call, :exception] on error
│   └── includes tool name and duration in metadata

test/backplane/transport/structured_logging_test.exs
├── describe "JSON log format"
│   └── logs request/response as structured JSON
```

### Test Summary

| Phase | Tests | Cumulative |
|---|---|---|
| Phase 1: Skeleton + MCP Transport | 29 | 29 |
| Phase 2: Upstream MCP Proxy | 34 | 63 |
| Phase 3: Skills Engine | 52 | 115 |
| Phase 4: Doc Engine | 56 | 171 |
| Phase 5: Git Platform Proxy | 47 | 218 |
| Phase 6: Hub Meta Tools | 19 | 237 |
| Phase 7: Production Hardening | 12 | 249 |
| **Total** | **249** | |

---

## 16. Resolved Decisions

1. **Standalone project** — not part of Synapsis or Samgita. It's infrastructure, not a feature.

2. **`::` namespace separator** — avoids ambiguity with `:` (Elixir atoms, MCP server names) and `/` (URL paths, file paths). Visually distinct.

3. **TOML config over environment variables** — structured config with arrays and tables doesn't fit in env vars. TOML is the convention for MCP config (Claude Code, Codex both use it).

4. **Plug + Bandit, not Phoenix** — no HTML, no sessions, no LiveView. Pure API. Phoenix is unnecessary overhead. Bandit gives HTTP/2 + WebSocket for future SSE needs.

5. **Oban for reindexing and skill sync** — needs: periodic scheduling, uniqueness (don't double-index), persistence across restarts, observability. Oban provides all of these. GenServer + `Process.send_after` does not.

6. **ETS tool registry, not GenServer state** — concurrent reads from multiple request processes. GenServer would serialize. ETS gives lock-free reads.

7. **AST-based Elixir parsing over ExDoc artifacts** — ExDoc artifacts require compilation. AST parsing works on source alone. More portable for projects you can't compile locally.

8. **Content-addressable chunks and skills** — SHA256 hash per chunk/skill enables diff-aware sync. Only changed entries are written. Critical for large projects and skill repos.

9. **One GenServer per upstream** — isolates failure. Slack MCP going down doesn't affect filesystem MCP. Each has independent reconnect logic.

10. **Webhook + periodic dual strategy** — webhooks for instant reindex on push. Periodic as fallback (webhooks can be lost, misconfigured, or unavailable for some repos).

11. **MCP Proxy before Doc Engine in phase order** — the proxy is the highest-leverage feature: it's useful day one with zero indexing. An agent connecting to the hub immediately gets access to all upstream tools. Docs and skills are additive value on top.

12. **Skills stored in PG regardless of source** — git and local sources sync *into* the database. The `skills` table is the unified catalog. ETS mirrors it for reads. This means search, filtering, and the tool API work identically regardless of where the skill was authored.

13. **Skills are immutable-from-hub for git/local sources** — `skill::create` and `skill::update` only work for `source: "db"` skills. Git-sourced skills are managed at their source (edit, commit, push → auto-sync). This prevents divergence between the repo and the hub's copy.

14. **Hub Meta as native tools, not a separate protocol** — `hub::discover` is just another MCP tool. No special protocol extensions needed. Any MCP client can call it. Keeps the hub compatible with every existing MCP client.

15. **Skills follow SKILL.md convention** — YAML frontmatter + markdown body, same format as Claude Code skills and Synapsis skills. No new format to learn. Skill repos are portable between systems.

16. **`::` namespace is not configurable** — (OQ-1) MCP clients treat tool names as opaque strings. No known client parses separators. If one does, a gateway-level rewrite Plug is the fix, not per-client config.

17. **Embeddings deferred until tsvector insufficient** — (OQ-2) No embedding pipeline in initial phases. When needed, a `Backplane.Embeddings` behaviour with Ollama/OpenAI/Anthropic backends behind a `[embeddings]` config section.

18. **Single bearer token auth initially** — (OQ-3) One `backplane.auth_token` in config. Per-client scoped access (client → tool whitelist) is future work requiring a `clients` table.

19. **MCP resources and prompts planned, not initial** — (OQ-4) Doc chunks map to MCP resources (`backplane://docs/{project}/{path}`). Skills map to MCP prompts. Both are additive after tools work. Added to JSON-RPC dispatcher as `resources/*` and `prompts/*` methods.

20. **SIGHUP-based config hot-reload** — (OQ-5) `kill -HUP <pid>` re-reads `backplane.toml`. Git credentials updated in memory. No restart needed. Provider modules read credentials on each request, not at init.

---

## 17. Future Considerations

- **Embedding pipeline**: Optional Oban job that computes embeddings per doc chunk and skill via local model (Ollama) or API. Stored in pgvector column. Enables semantic reranking for both `docs::query-docs` and `skill::search`.
- **Project auto-discovery**: Scan GitHub org / GitLab group and auto-register all repos matching a pattern.
- **Access control**: Per-client tool scoping — client A can access `docs::*` and `git::*` but not `slack::*`. Token-based or IP-based.
- **Cache layer**: Cache git platform API responses (tree, file content) with TTL. Avoid redundant API calls for popular repos.
- **MCP notification support**: When a reindex or skill sync completes, notify connected clients via MCP notification mechanism. Clients can refresh their tool/skill state.
- **Multi-tenant mode**: Single hub serving multiple users with isolated project configs, skill sets, and token stores.
- **Skill composition**: Skills that reference other skills (`depends_on: [other-skill]`). Loading a skill auto-loads its dependencies. Enables building complex instruction chains from composable pieces.
- **Skill versioning and rollback**: Maintain version history for DB-sourced skills. Git-sourced skills get this for free via git history. Allow agents to load a specific skill version.
- **Skill analytics**: Track which skills are loaded most, by which agents, with what outcomes. Feed back into skill curation.
- **Upstream MCP health dashboard**: Simple web UI (or a separate status page) showing upstream connectivity, tool counts, error rates. Optional — could be a static HTML page served from Plug.
- **Skill marketplace**: Publish skills to a shared registry that other hub instances can subscribe to. Opt-in, curated, pull-based.
- **Prompt template engine**: Skills that contain `{{variable}}` placeholders, filled at load time with agent context. Turns skills into parameterized prompt templates.
