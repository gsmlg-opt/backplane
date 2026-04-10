# SP-1: Clean Slate — Remove Dead Code

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete all modules, tests, and migrations for subsystems removed in v2 (git, docs, embeddings, webhooks, config watcher, dead skills modules), then fix all surviving files that referenced them so the app compiles and tests pass.

**Architecture:** Bulk-delete dead code in categories, then surgically edit surviving files that imported/aliased/called removed modules. Each task targets one category of deletions plus the edits needed for the app to remain compilable after that deletion.

**Tech Stack:** Elixir 1.18+ / OTP 28+, Phoenix 1.8, Ecto, Oban

---

## File Structure

**Files to DELETE** (92 files across 11 categories — see tasks for exact lists)

**Files to MODIFY** (surviving files that reference deleted modules):

| File | Why |
|------|-----|
| `apps/backplane/lib/backplane.ex` | Remove `search_docs` delegate, docs alias |
| `apps/backplane/lib/backplane/application.ex` | Remove Watcher, Notifications, Sync, Docs, Git from supervision/boot |
| `apps/backplane/lib/backplane/transport/router.ex` | Remove webhook routes and handler code |
| `apps/backplane/lib/backplane/transport/health_check.ex` | Remove docs/git/notifications from health |
| `apps/backplane/lib/backplane/transport/mcp_handler.ex` | Remove DocChunk/Project aliases and resource handlers |
| `apps/backplane/lib/backplane/registry/tool_registry.ex` | Replace `Notifications.tools_changed()` with `PubSubBroadcaster` |
| `apps/backplane/lib/backplane/skills/registry.ex` | Replace `Notifications.prompts_changed()` with `PubSubBroadcaster` |
| `apps/backplane/lib/backplane/skills/search.ex` | Remove embeddings reranking path |
| `apps/backplane/lib/backplane/tools/hub.ex` | Remove docs/git/notifications references |
| `apps/backplane/lib/backplane/hub/discover.ex` | Remove docs scope from discovery |
| `apps/backplane/lib/backplane/pub_sub.ex` | Remove `docs_reindex_topic` |
| `apps/backplane/lib/backplane/config.ex` | Strip to boot-only: `[backplane]`, `[database]`, `[cache]`, `[audit]`, `[clients]` |
| `apps/backplane/lib/backplane/config/validator.ex` | Remove project/skills validation |
| `apps/backplane_web/lib/backplane_web/router.ex` | Remove webhook forward, remove docs/projects/git routes |
| `apps/backplane_web/lib/backplane_web/live/dashboard_live.ex` | Remove docs/skills-sync references |
| `config/runtime.exs` | Remove git_providers, projects, skill_sources, embeddings config |
| `config/backplane.toml.example` | Strip to boot-only sections |

---

## Task 1: Delete Git Modules

**Files:**
- Delete: `apps/backplane/lib/backplane/git/provider.ex`
- Delete: `apps/backplane/lib/backplane/git/resolver.ex`
- Delete: `apps/backplane/lib/backplane/git/rate_limit_cache.ex`
- Delete: `apps/backplane/lib/backplane/git/cached_provider.ex`
- Delete: `apps/backplane/lib/backplane/git/providers/github.ex`
- Delete: `apps/backplane/lib/backplane/git/providers/gitlab.ex`
- Delete: `apps/backplane/test/backplane/git/resolver_test.exs`
- Delete: `apps/backplane/test/backplane/git/rate_limit_cache_test.exs`
- Delete: `apps/backplane/test/backplane/git/cached_provider_test.exs`
- Delete: `apps/backplane/test/backplane/git/providers/github_test.exs`
- Delete: `apps/backplane/test/backplane/git/providers/gitlab_test.exs`
- Delete: `apps/backplane/lib/backplane/tools/git.ex`
- Delete: `apps/backplane/test/backplane/tools/git_test.exs`

- [ ] **Step 1: Delete all git module files**

```bash
rm -rf apps/backplane/lib/backplane/git/
rm -rf apps/backplane/test/backplane/git/
rm apps/backplane/lib/backplane/tools/git.ex
rm apps/backplane/test/backplane/tools/git_test.exs
```

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "refactor(sp1): remove git modules and tools"
```

---

## Task 2: Delete Docs Modules

**Files:**
- Delete: `apps/backplane/lib/backplane/docs/` (all 12 files)
- Delete: `apps/backplane/test/backplane/docs/` (all 13 files)
- Delete: `apps/backplane/lib/backplane/tools/docs.ex`
- Delete: `apps/backplane/test/backplane/tools/docs_test.exs`

- [ ] **Step 1: Delete all docs module files**

```bash
rm -rf apps/backplane/lib/backplane/docs/
rm -rf apps/backplane/test/backplane/docs/
rm apps/backplane/lib/backplane/tools/docs.ex
rm apps/backplane/test/backplane/tools/docs_test.exs
```

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "refactor(sp1): remove docs modules and tools"
```

---

## Task 3: Delete Embeddings, Notifications, Analytics

**Files:**
- Delete: `apps/backplane/lib/backplane/embeddings.ex`
- Delete: `apps/backplane/lib/backplane/embeddings/` (4 files)
- Delete: `apps/backplane/test/backplane/embeddings/` (2 files)
- Delete: `apps/backplane/lib/backplane/notifications.ex`
- Delete: `apps/backplane/test/backplane/notifications_test.exs`
- Delete: `apps/backplane/lib/backplane/analytics.ex`
- Delete: `apps/backplane/test/backplane/analytics_test.exs`
- Delete: `apps/backplane/test/backplane/embeddings_test.exs` (if exists)

- [ ] **Step 1: Delete embeddings, notifications, and analytics**

```bash
rm apps/backplane/lib/backplane/embeddings.ex
rm -rf apps/backplane/lib/backplane/embeddings/
rm -rf apps/backplane/test/backplane/embeddings/
rm -f apps/backplane/test/backplane/embeddings_test.exs
rm apps/backplane/lib/backplane/notifications.ex
rm apps/backplane/test/backplane/notifications_test.exs
rm apps/backplane/lib/backplane/analytics.ex
rm apps/backplane/test/backplane/analytics_test.exs
```

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "refactor(sp1): remove embeddings, notifications, and analytics modules"
```

---

## Task 4: Delete Dead Jobs, Skills Modules, Config Watcher, Webhook

**Files:**
- Delete: `apps/backplane/lib/backplane/jobs/reindex.ex`
- Delete: `apps/backplane/lib/backplane/jobs/webhook_handler.ex`
- Delete: `apps/backplane/lib/backplane/jobs/embed_chunks.ex`
- Delete: `apps/backplane/lib/backplane/jobs/embed_skills.ex`
- Delete: `apps/backplane/test/backplane/jobs/reindex_test.exs`
- Delete: `apps/backplane/test/backplane/jobs/webhook_handler_test.exs`
- Delete: `apps/backplane/test/backplane/jobs/embed_chunks_test.exs`
- Delete: `apps/backplane/test/backplane/jobs/embed_skills_test.exs`
- Delete: `apps/backplane/lib/backplane/skills/deps.ex`
- Delete: `apps/backplane/lib/backplane/skills/skill_version.ex`
- Delete: `apps/backplane/lib/backplane/skills/versions.ex`
- Delete: `apps/backplane/lib/backplane/skills/sync.ex`
- Delete: `apps/backplane/lib/backplane/skills/sources/git.ex`
- Delete: `apps/backplane/lib/backplane/skills/sources/local.ex`
- Delete: `apps/backplane/test/backplane/skills/deps_test.exs`
- Delete: `apps/backplane/test/backplane/skills/skill_version_test.exs`
- Delete: `apps/backplane/test/backplane/skills/versions_test.exs`
- Delete: `apps/backplane/test/backplane/skills/sync_test.exs`
- Delete: `apps/backplane/test/backplane/skills/sources/git_test.exs`
- Delete: `apps/backplane/test/backplane/skills/sources/local_test.exs`
- Delete: `apps/backplane/lib/backplane/config/watcher.ex`
- Delete: `apps/backplane/test/backplane/config/watcher_test.exs`
- Delete: `apps/backplane/lib/backplane/transport/webhook_plug.ex`

- [ ] **Step 1: Delete dead jobs**

```bash
rm apps/backplane/lib/backplane/jobs/reindex.ex
rm apps/backplane/lib/backplane/jobs/webhook_handler.ex
rm apps/backplane/lib/backplane/jobs/embed_chunks.ex
rm apps/backplane/lib/backplane/jobs/embed_skills.ex
rm apps/backplane/test/backplane/jobs/reindex_test.exs
rm apps/backplane/test/backplane/jobs/webhook_handler_test.exs
rm apps/backplane/test/backplane/jobs/embed_chunks_test.exs
rm apps/backplane/test/backplane/jobs/embed_skills_test.exs
```

- [ ] **Step 2: Delete dead skills modules**

```bash
rm apps/backplane/lib/backplane/skills/deps.ex
rm apps/backplane/lib/backplane/skills/skill_version.ex
rm apps/backplane/lib/backplane/skills/versions.ex
rm apps/backplane/lib/backplane/skills/sync.ex
rm apps/backplane/lib/backplane/skills/sources/git.ex
rm apps/backplane/lib/backplane/skills/sources/local.ex
rm apps/backplane/test/backplane/skills/deps_test.exs
rm apps/backplane/test/backplane/skills/skill_version_test.exs
rm apps/backplane/test/backplane/skills/versions_test.exs
rm apps/backplane/test/backplane/skills/sync_test.exs
rm apps/backplane/test/backplane/skills/sources/git_test.exs
rm apps/backplane/test/backplane/skills/sources/local_test.exs
```

- [ ] **Step 3: Delete config watcher and webhook plug**

```bash
rm apps/backplane/lib/backplane/config/watcher.ex
rm apps/backplane/test/backplane/config/watcher_test.exs
rm apps/backplane/lib/backplane/transport/webhook_plug.ex
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(sp1): remove dead jobs, skills modules, config watcher, webhook plug"
```

---

## Task 5: Delete LiveViews and Migrations

**Files:**
- Delete: `apps/backplane_web/lib/backplane_web/live/docs_live.ex`
- Delete: `apps/backplane_web/lib/backplane_web/live/projects_live.ex`
- Delete: `apps/backplane_web/lib/backplane_web/live/git_providers_live.ex`
- Delete: `apps/backplane_web/test/backplane_web/live/docs_live_test.exs`
- Delete: `apps/backplane_web/test/backplane_web/live/projects_live_test.exs`
- Delete: `apps/backplane_web/test/backplane_web/live/git_providers_live_test.exs`
- Delete: all files in `apps/backplane/priv/repo/migrations/`

- [ ] **Step 1: Delete removed LiveViews and their tests**

```bash
rm apps/backplane_web/lib/backplane_web/live/docs_live.ex
rm apps/backplane_web/lib/backplane_web/live/projects_live.ex
rm apps/backplane_web/lib/backplane_web/live/git_providers_live.ex
rm apps/backplane_web/test/backplane_web/live/docs_live_test.exs
rm apps/backplane_web/test/backplane_web/live/projects_live_test.exs
rm apps/backplane_web/test/backplane_web/live/git_providers_live_test.exs
```

- [ ] **Step 2: Delete all existing migrations**

```bash
rm -rf apps/backplane/priv/repo/migrations/
mkdir -p apps/backplane/priv/repo/migrations
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor(sp1): remove dead LiveViews and delete all old migrations"
```

---

## Task 6: Fix Application Supervision Tree

**Files:**
- Modify: `apps/backplane/lib/backplane/application.ex`

- [ ] **Step 1: Rewrite application.ex**

Remove `Watcher`, `Notifications`, `Sync`, `Docs`, `Git` references. Remove `enqueue_skill_syncs/0`. Simplify `validate_config_at_boot/0`. Remove `Docs` and `Git` from `register_native_tools/0`.

```elixir
defmodule Backplane.Application do
  @moduledoc false

  use Application
  require Logger

  alias Backplane.Config.Validator
  alias Backplane.Metrics
  alias Backplane.Proxy.Pool
  alias Backplane.Registry.{Tool, ToolRegistry}
  alias Backplane.Skills.Registry, as: SkillsRegistry
  alias Backplane.Tools.{Admin, Hub, Skill}

  @drain_timeout 15_000

  @impl true
  def start(_type, _args) do
    validate_config_at_boot()

    cache_opts = [
      max_entries: Application.get_env(:backplane, :cache_max_entries, 10_000)
    ]

    children = [
      Backplane.Repo,
      {Oban, Application.fetch_env!(:backplane, Oban)},
      {Phoenix.PubSub, name: Backplane.PubSub},
      ToolRegistry,
      SkillsRegistry,
      Pool,
      {Backplane.Cache, cache_opts},
      Metrics,
      Relayixir,
      Backplane.LLM.ModelResolver,
      Backplane.LLM.RouteLoader,
      Backplane.LLM.RateLimiter,
      {Backplane.LLM.HealthChecker, []}
    ]

    opts = [strategy: :one_for_one, name: Backplane.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      register_native_tools()
      start_configured_upstreams()

      Backplane.LLM.UsageCollector.attach()

      Backplane.Clients.init_cache()
      upsert_config_clients()

      {:ok, pid}
    end
  end

  @impl true
  def prep_stop(state) do
    Logger.info("Shutting down — draining connections (#{@drain_timeout}ms timeout)")
    Oban.pause_all_queues(Oban)
    state
  rescue
    e ->
      Logger.warning("Error during prep_stop: #{Exception.message(e)}")
      state
  end

  defp register_native_tools do
    tool_modules = [Skill, Hub, Admin]

    for module <- tool_modules, tool_def <- module.tools() do
      tool = %Tool{
        name: tool_def.name,
        description: tool_def.description,
        input_schema: tool_def.input_schema,
        origin: :native,
        module: tool_def.module,
        handler: tool_def.handler
      }

      ToolRegistry.register_native(tool)
    end
  end

  defp start_configured_upstreams do
    upstreams = Application.get_env(:backplane, :upstreams, [])

    for upstream <- upstreams do
      Pool.start_upstream(upstream)
    end
  end

  defp upsert_config_clients do
    seeds = Application.get_env(:backplane, :client_seeds, [])

    for %{name: name} = seed when is_binary(name) <- seeds do
      case Backplane.Clients.upsert_from_config(seed) do
        {:ok, _client} ->
          Logger.info("Upserted client from config: #{name}")

        {:error, reason} ->
          Logger.warning("Failed to upsert client #{name}: #{inspect(reason)}")
      end
    end
  end

  defp validate_config_at_boot do
    config = [
      backplane: %{
        port: Application.get_env(:backplane, :port, 4100)
      },
      upstream: Application.get_env(:backplane, :upstreams, [])
    ]

    Validator.validate!(config)
  end
end
```

- [ ] **Step 2: Verify it compiles**

```bash
cd apps/backplane && mix compile --warnings-as-errors 2>&1 | head -30
```

Expected: May still fail due to other files referencing deleted modules — that's fine, we fix those in subsequent tasks.

- [ ] **Step 3: Commit**

```bash
git add apps/backplane/lib/backplane/application.ex
git commit -m "refactor(sp1): clean application.ex — remove dead module references"
```

---

## Task 7: Fix Transport Layer

**Files:**
- Modify: `apps/backplane/lib/backplane/transport/router.ex`
- Modify: `apps/backplane/lib/backplane/transport/health_check.ex`
- Modify: `apps/backplane/lib/backplane/transport/mcp_handler.ex` (remove DocChunk/Project aliases)

- [ ] **Step 1: Rewrite transport/router.ex — remove webhook routes and notification references**

Remove the webhook routes (`/webhook/github`, `/webhook/gitlab`), the `handle_webhook/2` function, all helper functions for webhook validation, and the `Notifications` import. The SSE notification loop needs to use `PubSubBroadcaster` instead of `Notifications`. Replace `Notifications.subscribe/unsubscribe` with PubSub-based approach.

```elixir
defmodule Backplane.Transport.Router do
  @moduledoc """
  Plug.Router handling the MCP endpoint.
  """

  use Plug.Router

  require Logger

  alias Backplane.Metrics
  alias Backplane.Transport.{HealthCheck, McpHandler}

  plug(Plug.RequestId)
  plug(Backplane.Transport.VersionHeader)
  plug(Backplane.Transport.CORS)
  plug(:match)
  plug(Backplane.Transport.Compression)
  plug(Backplane.Transport.RequestLogger)
  plug(Backplane.Transport.RateLimiter)
  plug(Backplane.Transport.AuthPlug)
  plug(Backplane.Transport.Idempotency)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 1_000_000,
    body_reader: {Backplane.Transport.CacheBodyReader, :read_body, []}
  )

  plug(:dispatch)

  post "/mcp" do
    McpHandler.handle(conn)
  end

  delete "/mcp" do
    send_resp(conn, 200, "")
  end

  get "/mcp" do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
    |> sse_notification_loop()
  end

  get "/health" do
    health = HealthCheck.check()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(health))
  end

  get "/metrics" do
    metrics = Metrics.snapshot()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(metrics))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end

  @sse_keepalive_ms 30_000

  defp sse_notification_loop(conn) do
    Phoenix.PubSub.subscribe(Backplane.PubSub, "mcp:notifications")
    sse_loop(conn)
  after
    Phoenix.PubSub.unsubscribe(Backplane.PubSub, "mcp:notifications")
  end

  defp sse_loop(conn) do
    receive do
      {:mcp_notification, notification} ->
        data = Jason.encode!(notification)
        chunk_data = "event: message\ndata: #{data}\n\n"

        case Plug.Conn.chunk(conn, chunk_data) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    after
      @sse_keepalive_ms ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  @doc false
  def call(conn, opts) do
    super(conn, opts)
  rescue
    e in Plug.Parsers.ParseError ->
      Logger.warning("Malformed request body: #{Exception.message(e)}")
      send_resp(conn, 400, Jason.encode!(%{error: "Malformed request body"}))

    e in Plug.Parsers.RequestTooLargeError ->
      Logger.warning("Request body too large: #{Exception.message(e)}")
      send_resp(conn, 413, Jason.encode!(%{error: "Request body too large"}))
  end
end
```

- [ ] **Step 2: Rewrite transport/health_check.ex — remove docs/git/notifications**

```elixir
defmodule Backplane.Transport.HealthCheck do
  @moduledoc """
  Health check endpoint logic. Returns status of proxy and skills engines.
  """

  require Logger

  alias Backplane.Proxy.Pool
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Skills.Registry, as: SkillsRegistry

  @spec check() :: map()
  def check do
    upstreams = get_upstreams()
    upstream_degraded = Enum.any?(upstreams, fn u -> u.status != :connected end)

    status = if upstream_degraded, do: "degraded", else: "ok"

    %{
      status: status,
      version: Backplane.version(),
      engines: %{
        proxy: %{
          upstreams: upstreams,
          total_tools: ToolRegistry.count()
        },
        skills: %{
          total: SkillsRegistry.count()
        }
      }
    }
  end

  defp get_upstreams do
    Pool.list_upstreams()
    |> Enum.map(fn u ->
      %{
        name: u.name,
        status: u.status,
        tool_count: u.tool_count,
        last_ping_at: u[:last_ping_at],
        last_pong_at: u[:last_pong_at],
        consecutive_ping_failures: u[:consecutive_ping_failures] || 0
      }
    end)
  rescue
    e ->
      Logger.warning("Failed to get upstreams: #{Exception.message(e)}")
      []
  end
end
```

- [ ] **Step 3: Fix mcp_handler.ex — remove DocChunk/Project aliases**

Remove lines referencing `Backplane.Docs.{DocChunk, Project}` from the alias block at the top of the file. Remove any resource handler functions that query DocChunk or Project. The file is large, so only remove the alias line and any functions that directly use those schemas. Leave the rest intact — the handler will be refactored further in SP-3.

Remove this alias line:
```elixir
alias Backplane.Docs.{DocChunk, Project}
```

And remove or stub any `resources/list` or `resources/read` handler clauses that query DocChunk or Project to return empty results.

- [ ] **Step 4: Commit**

```bash
git add apps/backplane/lib/backplane/transport/
git commit -m "refactor(sp1): clean transport layer — remove webhooks, docs, git from health"
```

---

## Task 8: Fix Registry, Skills, Hub, and Root Module

**Files:**
- Modify: `apps/backplane/lib/backplane/registry/tool_registry.ex`
- Modify: `apps/backplane/lib/backplane/skills/registry.ex`
- Modify: `apps/backplane/lib/backplane/skills/search.ex`
- Modify: `apps/backplane/lib/backplane/tools/hub.ex`
- Modify: `apps/backplane/lib/backplane/hub/discover.ex`
- Modify: `apps/backplane/lib/backplane/pub_sub.ex`
- Modify: `apps/backplane/lib/backplane.ex`

- [ ] **Step 1: Fix tool_registry.ex — replace Notifications with PubSubBroadcaster**

Replace all occurrences of `Backplane.Notifications.tools_changed()` with:
```elixir
Phoenix.PubSub.broadcast(Backplane.PubSub, "mcp:notifications", {:mcp_notification, %{jsonrpc: "2.0", method: "notifications/tools/list_changed"}})
```

Or better — add a helper to `PubSubBroadcaster`:
```elixir
Backplane.PubSubBroadcaster.broadcast_mcp_notification("notifications/tools/list_changed")
```

This requires adding the function to `PubSubBroadcaster` first.

- [ ] **Step 2: Add `broadcast_mcp_notification/1` to PubSubBroadcaster**

Add to `apps/backplane/lib/backplane/pub_sub.ex`:
```elixir
def mcp_notifications_topic, do: "mcp:notifications"

def broadcast_mcp_notification(method) do
  Phoenix.PubSub.broadcast(
    @pubsub,
    mcp_notifications_topic(),
    {:mcp_notification, %{jsonrpc: "2.0", method: method}}
  )
end
```

Also remove `docs_reindex_topic/0` and `broadcast_docs_reindex/2` since docs are removed.

- [ ] **Step 3: Fix skills/registry.ex — replace Notifications.prompts_changed()**

Replace `Backplane.Notifications.prompts_changed()` with:
```elixir
Backplane.PubSubBroadcaster.broadcast_mcp_notification("notifications/prompts/list_changed")
```

- [ ] **Step 4: Fix skills/search.ex — remove embeddings reranking**

Remove the `Backplane.Embeddings.configured?()` check and the reranking code path. The search should use only tsvector full-text search. Remove the `rerank` option handling and the `Similarity` alias.

In the `query/2` function, remove the `rerank?` variable and the `db_limit` over-fetch logic. Use `limit` directly.

- [ ] **Step 5: Fix tools/hub.ex — remove docs/git/notifications references**

Remove these aliases:
```elixir
alias Backplane.Docs.{DocChunk, Project}
alias Backplane.Git.RateLimitCache
alias Backplane.Notifications
```

Remove any tool definitions and handler functions that reference docs or git (like `hub::status` sections that report on git providers or doc projects). Keep the `hub::discover` and `hub::inspect` tool definitions, but remove docs/git from the discovery results.

- [ ] **Step 6: Fix hub/discover.ex — remove docs scope**

Remove:
```elixir
alias Backplane.Docs.{DocChunk, Project}
```

Remove `"docs"` and `"repos"` from `@all_scopes`. Update the `search/2` function to only search `["tools", "skills"]`. Remove the functions that query DocChunk or Project.

- [ ] **Step 7: Fix backplane.ex — remove search_docs delegate**

Rewrite `apps/backplane/lib/backplane.ex`:

```elixir
defmodule Backplane do
  @moduledoc """
  Backplane - A self-hosted MCP gateway.

  Two features:
  - MCP Hub (upstream MCP servers + managed services)
  - LLM Proxy (credential-injecting reverse proxy)
  """

  alias Backplane.Hub.Discover
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Skills.Registry, as: SkillsRegistry

  @doc "Unified discovery across tools and skills."
  defdelegate discover(query, opts \\ []), to: Discover, as: :search

  @doc "List all registered tools."
  def list_tools, do: ToolRegistry.list_all()

  @doc "Count registered tools."
  def tool_count, do: ToolRegistry.count()

  @doc "Search skills by query."
  def search_skills(query, opts \\ []), do: SkillsRegistry.search(query, opts)

  @doc "Count registered skills."
  def skill_count, do: SkillsRegistry.count()

  @doc "Get the current version from mix.exs."
  def version do
    Application.spec(:backplane, :vsn) |> to_string()
  end

  @doc "MCP protocol version supported by this server."
  def protocol_version, do: "2025-03-26"
end
```

- [ ] **Step 8: Commit**

```bash
git add apps/backplane/lib/backplane.ex apps/backplane/lib/backplane/registry/ apps/backplane/lib/backplane/skills/ apps/backplane/lib/backplane/tools/hub.ex apps/backplane/lib/backplane/hub/ apps/backplane/lib/backplane/pub_sub.ex
git commit -m "refactor(sp1): clean registry, skills, hub, root module — remove dead references"
```

---

## Task 9: Fix Config and Web Router

**Files:**
- Modify: `apps/backplane/lib/backplane/config.ex`
- Modify: `apps/backplane/lib/backplane/config/validator.ex`
- Modify: `apps/backplane_web/lib/backplane_web/router.ex`
- Modify: `apps/backplane_web/lib/backplane_web/live/dashboard_live.ex`
- Modify: `config/runtime.exs`
- Modify: `config/backplane.toml.example`

- [ ] **Step 1: Simplify config.ex — remove git/projects/skills/embeddings parsing**

```elixir
defmodule Backplane.Config do
  @moduledoc """
  Loads and parses the backplane.toml configuration file.
  Boot-only: [backplane], [database], [cache], [audit], [[clients]], [[upstream]].
  """

  @default_port 4100
  @default_host "0.0.0.0"

  @spec load!(String.t()) :: keyword()
  def load!(path) do
    unless File.exists?(path) do
      raise "Config file not found: #{path}"
    end

    case Toml.decode_file(path) do
      {:ok, raw} -> parse(raw)
      {:error, reason} -> raise "Failed to parse config file #{path}: #{inspect(reason)}"
    end
  end

  defp parse(raw) do
    [
      backplane: parse_backplane(raw["backplane"] || %{}),
      database: parse_database(raw["database"] || %{}),
      upstream: parse_upstreams(raw["upstream"] || []),
      clients: parse_clients(raw["clients"] || []),
      cache: parse_cache(raw["cache"] || %{}),
      audit: parse_audit(raw["audit"] || %{})
    ]
  end

  defp parse_backplane(section) do
    %{
      host: section["host"] || @default_host,
      port: section["port"] || @default_port,
      auth_token: section["auth_token"],
      auth_tokens: section["auth_tokens"],
      admin_username: section["admin_username"],
      admin_password: section["admin_password"]
    }
  end

  defp parse_database(section) do
    %{url: section["url"]}
  end

  defp parse_upstreams(upstreams) when is_list(upstreams) do
    Enum.map(upstreams, fn up ->
      base = %{
        name: up["name"],
        transport: up["transport"],
        prefix: up["prefix"],
        timeout: up["timeout"],
        refresh_interval: up["refresh_interval"],
        cache_ttl: up["cache_ttl"],
        cache_tools: up["cache_tools"]
      }

      case up["transport"] do
        "stdio" ->
          Map.merge(base, %{
            command: up["command"],
            args: up["args"] || [],
            env: parse_env(up["env"])
          })

        "http" ->
          Map.merge(base, %{
            url: up["url"],
            headers: up["headers"] || %{}
          })

        _ ->
          base
      end
    end)
  end

  defp parse_upstreams(_), do: []

  defp parse_audit(section) do
    %{
      enabled: section["enabled"] != false,
      retention_days: section["retention_days"] || 30
    }
  end

  defp parse_cache(section) do
    %{
      enabled: section["enabled"] != false,
      max_entries: section["max_entries"] || 10_000,
      default_ttl: section["default_ttl"] || "5m"
    }
  end

  defp parse_clients(clients) when is_list(clients) do
    Enum.map(clients, fn client ->
      %{
        name: client["name"],
        token: client["token"],
        scopes: client["scopes"] || []
      }
    end)
  end

  defp parse_clients(_), do: []

  defp parse_env(nil), do: %{}
  defp parse_env(env) when is_map(env), do: env
  defp parse_env(_), do: %{}
end
```

- [ ] **Step 2: Simplify config/validator.ex — remove projects/skills validation**

```elixir
defmodule Backplane.Config.Validator do
  @moduledoc """
  Validates parsed configuration at startup.
  """

  require Logger

  @spec validate(keyword()) :: [String.t()]
  def validate(config) do
    []
    |> validate_upstreams(config[:upstream] || [])
    |> validate_port(config[:backplane])
  end

  @spec validate!(keyword()) :: :ok
  def validate!(config) do
    for warning <- validate(config) do
      Logger.warning("Config: #{warning}")
    end

    :ok
  end

  defp validate_upstreams(warnings, upstreams) do
    warnings
    |> check_duplicates(upstreams, :prefix, "upstream prefix")
    |> check_duplicates(upstreams, :name, "upstream name")
    |> then(fn w ->
      Enum.reduce(upstreams, w, fn upstream, acc ->
        acc
        |> check_required(upstream, :name, "upstream")
        |> check_required(upstream, :prefix, "upstream #{upstream[:name]}")
        |> check_required(upstream, :transport, "upstream #{upstream[:name]}")
        |> check_upstream_transport(upstream)
      end)
    end)
  end

  defp check_upstream_transport(warnings, %{transport: "http"} = upstream) do
    warnings
    |> check_required(upstream, :url, "upstream #{upstream[:name]} (http)")
    |> check_positive_integer(upstream, :timeout, "upstream #{upstream[:name]}")
    |> check_positive_integer(upstream, :refresh_interval, "upstream #{upstream[:name]}")
  end

  defp check_upstream_transport(warnings, %{transport: "stdio"} = upstream) do
    warnings
    |> check_required(upstream, :command, "upstream #{upstream[:name]} (stdio)")
    |> check_positive_integer(upstream, :timeout, "upstream #{upstream[:name]}")
    |> check_positive_integer(upstream, :refresh_interval, "upstream #{upstream[:name]}")
  end

  defp check_upstream_transport(warnings, %{transport: transport, name: name})
       when is_binary(transport) do
    ["upstream #{name}: unknown transport '#{transport}' (expected 'http' or 'stdio')" | warnings]
  end

  defp check_upstream_transport(warnings, _upstream), do: warnings

  defp validate_port(warnings, %{port: port})
       when is_integer(port) and port > 0 and port < 65_536 do
    warnings
  end

  defp validate_port(warnings, %{port: port}) do
    ["invalid port #{inspect(port)}, must be 1-65535" | warnings]
  end

  defp validate_port(warnings, _), do: warnings

  defp check_required(warnings, map, key, context) do
    case Map.get(map, key) do
      nil -> ["#{context}: missing required field '#{key}'" | warnings]
      "" -> ["#{context}: '#{key}' cannot be empty" | warnings]
      _ -> warnings
    end
  end

  defp check_positive_integer(warnings, map, key, context) do
    case Map.get(map, key) do
      nil -> warnings
      val when is_integer(val) and val > 0 -> warnings
      val -> ["#{context}: '#{key}' must be a positive integer, got #{inspect(val)}" | warnings]
    end
  end

  defp check_duplicates(warnings, items, key, label) do
    items
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_val, count} -> count > 1 end)
    |> Enum.reduce(warnings, fn {val, count}, acc ->
      ["duplicate #{label} '#{val}' appears #{count} times" | acc]
    end)
  end
end
```

- [ ] **Step 3: Fix router.ex — remove dead routes**

```elixir
defmodule BackplaneWeb.Router do
  use BackplaneWeb, :router

  forward("/mcp", Backplane.Transport.McpPlug)
  forward("/health", Backplane.Transport.HealthPlug)
  forward("/metrics", Backplane.Transport.MetricsPlug)
  forward("/api/llm", Backplane.LLM.ApiRouter)

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BackplaneWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(Backplane.Web.AdminAuthPlug)
  end

  scope "/admin", BackplaneWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/upstreams", UpstreamsLive, :index)
    live("/skills", SkillsLive, :index)
    live("/tools", ToolsLive, :index)
    live("/logs", LogsLive, :index)
    live("/clients", ClientsLive, :index)
    live("/providers", ProvidersLive, :index)
  end

  if Application.compile_env(:backplane_web, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)
      live_dashboard("/dashboard", metrics: Backplane.Telemetry)
    end
  end
end
```

- [ ] **Step 4: Fix dashboard_live.ex — remove docs/skills-sync references**

Remove the `sync_skills` and `reindex_all` event handlers. Remove docs project/chunk count from assigns. Remove docs-related PubSub subscriptions. Remove the "Sync Skills", "Reindex All" buttons from the render function. Keep upstream status and tool/skill counts.

Key changes:
- Remove `PubSubBroadcaster.subscribe(PubSubBroadcaster.docs_reindex_topic())` from mount
- Remove `handle_event("sync_skills", ...)` handler
- Remove `handle_event("reindex_all", ...)` handler
- Remove `project_count` and `chunk_count` from `load_dashboard_data/1`
- Remove "Sync Skills" and "Reindex All" buttons from render
- Remove "Doc Projects" and "Doc Chunks" stat cards from render

- [ ] **Step 5: Fix runtime.exs — remove dead config sections**

```elixir
import Config

if bun_path = System.get_env("MIX_BUN_PATH") do
  config :bun, path: bun_path
end

if tailwind_path = System.get_env("MIX_TAILWIND_PATH") do
  config :tailwind, path: tailwind_path
end

if config_env() == :prod do
  config_path = System.get_env("BACKPLANE_CONFIG", "backplane.toml")

  if File.exists?(config_path) do
    backplane_config = Backplane.Config.load!(config_path)

    # Database
    if db_url = get_in(backplane_config, [:database, :url]) do
      config :backplane, Backplane.Repo, url: db_url
    end

    # Backplane server settings
    bp = backplane_config[:backplane]

    if bp do
      config :backplane,
        host: bp.host,
        port: bp.port,
        auth_token: bp.auth_token,
        config_path: config_path
    end

    # Upstream MCP servers to proxy
    config :backplane, upstreams: backplane_config[:upstream] || []

    # Pre-seeded clients (upserted on boot)
    config :backplane, client_seeds: backplane_config[:clients] || []

    # Audit settings
    if audit = backplane_config[:audit] do
      config :backplane,
        audit_enabled: audit.enabled,
        audit_retention_days: audit.retention_days
    end

    # Cache settings
    if cache = backplane_config[:cache] do
      config :backplane,
        cache_enabled: cache.enabled,
        cache_max_entries: cache.max_entries
    end
  end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST", "localhost")

  port =
    case System.get_env("BACKPLANE_PORT") || System.get_env("PORT") do
      nil -> 4100
      port_str -> String.to_integer(port_str)
    end

  config :backplane_web, BackplaneWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base
end
```

- [ ] **Step 6: Update backplane.toml.example — boot-only**

```toml
# Backplane Configuration (boot-only)
# Operational config (upstreams, providers, credentials, skills) is managed
# through the admin UI at /admin and stored in PostgreSQL.

[backplane]
host = "0.0.0.0"
port = 4100
# admin_username = "admin"
# admin_password = "changeme"

[database]
url = "postgres://localhost/backplane_dev"

# --- Upstream MCP Servers (temporary — will move to DB in SP-3) ---
# [[upstream]]
# name = "filesystem"
# transport = "stdio"
# command = "npx"
# args = ["-y", "@anthropic/mcp-filesystem"]
# prefix = "fs"
# timeout = 30000
# refresh_interval = 300000
```

- [ ] **Step 7: Commit**

```bash
git add apps/backplane/lib/backplane/config.ex apps/backplane/lib/backplane/config/validator.ex apps/backplane_web/lib/backplane_web/router.ex apps/backplane_web/lib/backplane_web/live/dashboard_live.ex config/runtime.exs config/backplane.toml.example
git commit -m "refactor(sp1): simplify config, router, dashboard — boot-only TOML"
```

---

## Task 10: Write Fresh v2 Migrations

**Files:**
- Create: `apps/backplane/priv/repo/migrations/20260410000001_create_oban_tables.exs`
- Create: `apps/backplane/priv/repo/migrations/20260410000002_create_skills.exs`
- Create: `apps/backplane/priv/repo/migrations/20260410000003_create_clients.exs`
- Create: `apps/backplane/priv/repo/migrations/20260410000004_create_tool_call_log.exs`
- Create: `apps/backplane/priv/repo/migrations/20260410000005_create_skill_load_log.exs`
- Create: `apps/backplane/priv/repo/migrations/20260410000006_create_llm_providers.exs`
- Create: `apps/backplane/priv/repo/migrations/20260410000007_create_llm_model_aliases.exs`
- Create: `apps/backplane/priv/repo/migrations/20260410000008_create_llm_usage_logs.exs`

- [ ] **Step 1: Create Oban migration**

```elixir
# apps/backplane/priv/repo/migrations/20260410000001_create_oban_tables.exs
defmodule Backplane.Repo.Migrations.CreateObanTables do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 12)
  def down, do: Oban.Migration.down(version: 1)
end
```

- [ ] **Step 2: Create skills table migration**

```elixir
# apps/backplane/priv/repo/migrations/20260410000002_create_skills.exs
defmodule Backplane.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add :id, :text, primary_key: true
      add :name, :text, null: false
      add :description, :text, default: ""
      add :tags, {:array, :text}, default: []
      add :content, :text, null: false
      add :content_hash, :text
      add :enabled, :boolean, default: true

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "ALTER TABLE skills ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(name, '') || ' ' || coalesce(description, '') || ' ' || coalesce(content, ''))) STORED",
      "ALTER TABLE skills DROP COLUMN search_vector"
    )

    create index(:skills, [:tags], using: :gin)
    create index(:skills, [:search_vector], using: :gin)
  end
end
```

- [ ] **Step 3: Create clients table migration**

```elixir
# apps/backplane/priv/repo/migrations/20260410000003_create_clients.exs
defmodule Backplane.Repo.Migrations.CreateClients do
  use Ecto.Migration

  def change do
    create table(:clients, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :token_hash, :text, null: false
      add :scopes, {:array, :text}, default: []
      add :active, :boolean, default: true
      add :last_seen_at, :utc_datetime_usec
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:clients, [:name])
  end
end
```

- [ ] **Step 4: Create audit log migrations**

```elixir
# apps/backplane/priv/repo/migrations/20260410000004_create_tool_call_log.exs
defmodule Backplane.Repo.Migrations.CreateToolCallLog do
  use Ecto.Migration

  def change do
    create table(:tool_call_log) do
      add :tool_name, :text, null: false
      add :client_id, references(:clients, type: :binary_id, on_delete: :nilify_all)
      add :client_name, :text
      add :duration_us, :integer
      add :status, :text, null: false
      add :error_message, :text
      add :arguments_hash, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")
    end

    create index(:tool_call_log, [:tool_name])
    create index(:tool_call_log, [:client_id])
    create index(:tool_call_log, [:inserted_at])
  end
end
```

```elixir
# apps/backplane/priv/repo/migrations/20260410000005_create_skill_load_log.exs
defmodule Backplane.Repo.Migrations.CreateSkillLoadLog do
  use Ecto.Migration

  def change do
    create table(:skill_load_log) do
      add :skill_name, :text, null: false
      add :client_id, references(:clients, type: :binary_id, on_delete: :nilify_all)
      add :client_name, :text
      add :loaded_deps, {:array, :text}, default: []

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")
    end

    create index(:skill_load_log, [:skill_name])
    create index(:skill_load_log, [:inserted_at])
  end
end
```

- [ ] **Step 5: Create LLM provider migrations**

```elixir
# apps/backplane/priv/repo/migrations/20260410000006_create_llm_providers.exs
defmodule Backplane.Repo.Migrations.CreateLlmProviders do
  use Ecto.Migration

  def change do
    create table(:llm_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :api_type, :text, null: false
      add :api_url, :text, null: false
      add :api_key_encrypted, :bytea
      add :models, {:array, :text}, default: []
      add :default_headers, :map, default: %{}
      add :rpm_limit, :integer
      add :enabled, :boolean, default: true
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_providers, [:name], where: "deleted_at IS NULL")
    create index(:llm_providers, [:api_type, :enabled])
    create index(:llm_providers, [:models], using: :gin)
  end
end
```

```elixir
# apps/backplane/priv/repo/migrations/20260410000007_create_llm_model_aliases.exs
defmodule Backplane.Repo.Migrations.CreateLlmModelAliases do
  use Ecto.Migration

  def change do
    create table(:llm_model_aliases, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :alias, :text, null: false
      add :model, :text, null: false
      add :provider_id, references(:llm_providers, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_model_aliases, [:alias])
    create index(:llm_model_aliases, [:provider_id])
  end
end
```

```elixir
# apps/backplane/priv/repo/migrations/20260410000008_create_llm_usage_logs.exs
defmodule Backplane.Repo.Migrations.CreateLlmUsageLogs do
  use Ecto.Migration

  def change do
    create table(:llm_usage_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :provider_id, references(:llm_providers, type: :binary_id, on_delete: :nilify_all)
      add :model, :text
      add :status, :integer
      add :latency_ms, :integer
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :stream, :boolean, default: false
      add :client_ip, :text
      add :error_reason, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")
    end

    create index(:llm_usage_logs, [:provider_id, :inserted_at])
    create index(:llm_usage_logs, [:model, :inserted_at])
    create index(:llm_usage_logs, [:inserted_at])
  end
end
```

- [ ] **Step 6: Commit**

```bash
git add apps/backplane/priv/repo/migrations/
git commit -m "refactor(sp1): write fresh v2 migrations — skills, clients, LLM, audit"
```

---

## Task 11: Compile, Reset DB, Run Tests

- [ ] **Step 1: Compile the entire project**

```bash
mix compile --warnings-as-errors 2>&1
```

Expected: Clean compilation with no warnings. If there are remaining references to deleted modules, fix them before proceeding.

- [ ] **Step 2: Reset the database**

```bash
mix ecto.reset
```

Expected: Database drops, creates, migrates successfully with the fresh migrations.

- [ ] **Step 3: Run the test suite**

```bash
mix test 2>&1
```

Expected: All tests pass. Tests for deleted modules are gone. Tests for modified modules may need updates — fix any failures.

- [ ] **Step 4: Fix any test failures**

Read each failing test, determine if it references a deleted module or removed behavior, and fix accordingly. Tests for surviving modules (LLM, proxy, transport, etc.) should still pass.

- [ ] **Step 5: Run credo**

```bash
mix credo --strict 2>&1
```

Expected: No new issues. Fix any unused alias/variable warnings from the cleanup.

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "refactor(sp1): clean slate complete — app compiles, tests pass, DB reset"
```
