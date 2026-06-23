# Backplane Admin/API Phoenix Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the current `apps/backplane_web` Phoenix surface into two Phoenix OTP apps: `apps/backplane_admin` using the `Backplane.Admin` namespace and `apps/backplane_api` using the `Backplane.Api` namespace.

**Architecture:** `Backplane.Api.Endpoint` owns `/`, `/api/*`, `/health`, `/metrics`, and `/host-agent/socket` on the public/API port. `Backplane.Admin.Endpoint` owns `/admin/*`, admin LiveViews, admin OAuth callback, and admin assets on the admin port. Shared non-Phoenix concerns remain in existing core apps, with a small `Backplane.WebOrigins` helper in `backplane_system` for cross-endpoint URLs.

**Tech Stack:** Elixir 1.18, Phoenix 1.8, Phoenix LiveView, Bandit, DuskMoon UI, Bun, Tailwind CSS 4, PostgreSQL/Ecto, Oban.

---

## Source Spec

Read before starting:

- `docs/superpowers/specs/2026-06-23-backplane-admin-api-split-design.md`
- `AGENTS.md`

## File Structure

Create:

- `apps/backplane_api/mix.exs` - Phoenix OTP app definition for public/API endpoint.
- `apps/backplane_api/package.json` - DuskMoon asset dependencies for public page.
- `apps/backplane_api/lib/backplane/api.ex` - macro host for API controllers/channels/components.
- `apps/backplane_api/lib/backplane/api/application.ex` - supervises `Backplane.Api.Endpoint`.
- `apps/backplane_api/lib/backplane/api/endpoint.ex` - public/API endpoint.
- `apps/backplane_api/lib/backplane/api/router.ex` - public/API routes.
- `apps/backplane_api/lib/backplane/api/controllers/*` - public page and error modules.
- `apps/backplane_api/lib/backplane/api/channels/*` - host-agent socket/channel.
- `apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex` - host-agent memory sync adapter.
- `apps/backplane_api/assets/*` and `apps/backplane_api/priv/static/*` - public/API static files.
- `apps/backplane_api/test/support/*` - API endpoint test cases.
- `apps/backplane_api/test/backplane/api/*` - API route, page, and channel tests.
- `apps/backplane_admin/mix.exs` - Phoenix OTP app definition for admin endpoint.
- `apps/backplane_admin/package.json` - DuskMoon asset dependencies for admin UI.
- `apps/backplane_admin/lib/backplane/admin.ex` - macro host for admin LiveViews/controllers/components.
- `apps/backplane_admin/lib/backplane/admin/application.ex` - supervises `Backplane.Admin.Endpoint`.
- `apps/backplane_admin/lib/backplane/admin/endpoint.ex` - admin endpoint.
- `apps/backplane_admin/lib/backplane/admin/router.ex` - admin routes.
- `apps/backplane_admin/lib/backplane/admin/controllers/*` - admin redirect, OAuth callback, and error modules.
- `apps/backplane_admin/lib/backplane/admin/live/*` - admin LiveViews.
- `apps/backplane_admin/lib/backplane/admin/components/*` - admin layouts and components.
- `apps/backplane_admin/assets/*` and `apps/backplane_admin/priv/static/*` - admin static files.
- `apps/backplane_admin/test/support/*` - admin endpoint test cases.
- `apps/backplane_admin/test/backplane/admin/*` - admin LiveView and controller tests.
- `apps/backplane_system/lib/backplane/web_origins.ex` - public/admin external URL helper.
- `apps/backplane_system/test/backplane/web_origins_test.exs` - URL helper tests.
- `apps/backplane_system/test/backplane/settings/encryption_config_test.exs` - secret config regression test.

Modify:

- `apps/backplane_system/lib/backplane/settings/encryption.ex` - read `:backplane, :secret_key_base`.
- `config/config.exs` - configure both endpoints and both asset builds.
- `config/dev.exs` - dev ports, watchers, live reload, URLs.
- `config/test.exs` - test ports, endpoint server flags, URLs.
- `config/prod.exs` - cache manifests for both endpoints.
- `config/runtime.exs` - runtime secret, URL, and port config for both endpoints.
- `mix.exs` - release apps and top-level asset aliases.
- `Dockerfile` - copy/build both Phoenix apps and expose both ports.
- `.github/workflows/build.yml` - build assets for both apps.
- `.github/workflows/release.yml` - build assets for both apps.
- `README.md` - update app list and port docs.
- `AGENTS.md` - update umbrella structure and route/port overview.

Remove after replacement compiles:

- `apps/backplane_web/mix.exs`
- `apps/backplane_web/package.json`
- `apps/backplane_web/lib/backplane_web.ex`
- `apps/backplane_web/lib/backplane_web/**`
- `apps/backplane_web/assets/**`
- `apps/backplane_web/priv/static/**`
- `apps/backplane_web/test/**`

## Task 0: Create Worktree And Baseline

**Files:**

- No repository files changed.

- [ ] **Step 1: Create an isolated worktree**

Run:

```bash
git worktree add .trees/codex/admin-api-split -b codex/admin-api-split
cd .trees/codex/admin-api-split
```

Expected: new worktree at `.trees/codex/admin-api-split` on branch `codex/admin-api-split`.

- [ ] **Step 2: Confirm baseline status**

Run:

```bash
git status --short
```

Expected: only files intentionally carried into the worktree are listed. If unrelated dirty files appear, do not stage them in later commits.

- [ ] **Step 3: Run baseline compile**

Run:

```bash
devenv shell -- mix compile
```

Expected: compile succeeds before refactor work begins. If it fails, capture the error and stop before editing.

## Task 1: Core Secret And Endpoint Origin Helpers

**Files:**

- Create: `apps/backplane_system/lib/backplane/web_origins.ex`
- Create: `apps/backplane_system/test/backplane/web_origins_test.exs`
- Create: `apps/backplane_system/test/backplane/settings/encryption_config_test.exs`
- Modify: `apps/backplane_system/lib/backplane/settings/encryption.ex`
- Modify: `config/config.exs`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`

- [ ] **Step 1: Write failing tests for core secret config**

Create `apps/backplane_system/test/backplane/settings/encryption_config_test.exs`:

```elixir
defmodule Backplane.Settings.EncryptionConfigTest do
  use ExUnit.Case, async: false

  alias Backplane.Settings.Encryption

  setup do
    old_secret = Application.get_env(:backplane, :secret_key_base)

    on_exit(fn ->
      restore_env(:backplane, :secret_key_base, old_secret)
    end)

    :ok
  end

  test "encrypts and decrypts using the core backplane secret" do
    Application.put_env(:backplane, :secret_key_base, String.duplicate("core-secret", 8))

    encrypted = Encryption.encrypt("secret-value")

    assert {:ok, "secret-value"} = Encryption.decrypt(encrypted)
  end

  test "raises when the core secret is missing" do
    Application.delete_env(:backplane, :secret_key_base)

    assert_raise RuntimeError, "secret_key_base not configured", fn ->
      Encryption.encrypt("secret-value")
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
```

- [ ] **Step 2: Write failing tests for public/admin origins**

Create `apps/backplane_system/test/backplane/web_origins_test.exs`:

```elixir
defmodule Backplane.WebOriginsTest do
  use ExUnit.Case, async: false

  alias Backplane.WebOrigins

  setup do
    old_api_url = Application.get_env(:backplane, :api_url)
    old_admin_url = Application.get_env(:backplane, :admin_url)

    on_exit(fn ->
      restore_env(:api_url, old_api_url)
      restore_env(:admin_url, old_admin_url)
    end)

    :ok
  end

  test "returns configured base URLs without trailing slashes" do
    Application.put_env(:backplane, :api_url, "http://api.example.test/")
    Application.put_env(:backplane, :admin_url, "http://admin.example.test/")

    assert WebOrigins.api_base_url() == "http://api.example.test"
    assert WebOrigins.admin_base_url() == "http://admin.example.test"
  end

  test "joins paths onto configured origins" do
    Application.put_env(:backplane, :api_url, "http://api.example.test")
    Application.put_env(:backplane, :admin_url, "http://admin.example.test")

    assert WebOrigins.api_url("/api/mcp") == "http://api.example.test/api/mcp"
    assert WebOrigins.api_url("api/mcp") == "http://api.example.test/api/mcp"
    assert WebOrigins.admin_url("/admin/dashboard/overview") ==
             "http://admin.example.test/admin/dashboard/overview"
  end

  test "uses development defaults when origins are not configured" do
    Application.delete_env(:backplane, :api_url)
    Application.delete_env(:backplane, :admin_url)

    assert WebOrigins.api_base_url() == "http://localhost:4220"
    assert WebOrigins.admin_base_url() == "http://localhost:4221"
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/settings/encryption_config_test.exs apps/backplane_system/test/backplane/web_origins_test.exs
```

Expected: failures mention `Backplane.WebOrigins` is undefined or encryption still depends on non-core config.

- [ ] **Step 4: Implement `Backplane.WebOrigins`**

Create `apps/backplane_system/lib/backplane/web_origins.ex`:

```elixir
defmodule Backplane.WebOrigins do
  @moduledoc """
  Runtime origins for links crossing the API/admin endpoint boundary.
  """

  @default_api_url "http://localhost:4220"
  @default_admin_url "http://localhost:4221"

  @spec api_base_url() :: String.t()
  def api_base_url, do: base_url(:api_url, @default_api_url)

  @spec admin_base_url() :: String.t()
  def admin_base_url, do: base_url(:admin_url, @default_admin_url)

  @spec api_url(String.t()) :: String.t()
  def api_url(path \\ "/"), do: join(api_base_url(), path)

  @spec admin_url(String.t()) :: String.t()
  def admin_url(path \\ "/admin"), do: join(admin_base_url(), path)

  defp base_url(key, default) do
    :backplane
    |> Application.get_env(key, default)
    |> String.trim_trailing("/")
  end

  defp join(base_url, path) when is_binary(path) do
    normalized_path = "/" <> String.trim_leading(path, "/")
    base_url <> normalized_path
  end
end
```

- [ ] **Step 5: Update encryption to read the core secret**

In `apps/backplane_system/lib/backplane/settings/encryption.ex`, replace `fetch_secret_key_base/0` with:

```elixir
  defp fetch_secret_key_base do
    Application.get_env(:backplane, :secret_key_base) ||
      raise "secret_key_base not configured"
  end
```

- [ ] **Step 6: Configure core secret and origins for existing endpoint**

In `config/dev.exs`, define the secret once before endpoint config:

```elixir
secret_key_base =
  "dev_secret_key_base_that_is_at_least_64_bytes_long_for_development_only_do_not_use"

config :backplane,
  secret_key_base: secret_key_base,
  api_url: "http://localhost:4220",
  admin_url: "http://localhost:4221"
```

Then change the existing `:backplane_web, BackplaneWeb.Endpoint` config to use:

```elixir
  secret_key_base: secret_key_base,
```

In `config/test.exs`, add before endpoint config:

```elixir
secret_key_base =
  "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_only_please"

config :backplane,
  secret_key_base: secret_key_base,
  api_url: "http://localhost:4002",
  admin_url: "http://localhost:4003"
```

Then change the existing test endpoint config to use:

```elixir
  secret_key_base: secret_key_base,
```

In `config/runtime.exs`, after `secret_key_base` is loaded in the `:prod` block, add:

```elixir
  api_port =
    case System.get_env("BACKPLANE_API_PORT") || System.get_env("BACKPLANE_PORT") || System.get_env("PORT") do
      nil -> 4100
      port_str -> String.to_integer(port_str)
    end

  admin_port =
    case System.get_env("BACKPLANE_ADMIN_PORT") do
      nil -> 4101
      port_str -> String.to_integer(port_str)
    end

  config :backplane,
    secret_key_base: secret_key_base,
    api_url: System.get_env("BACKPLANE_API_URL", "http://#{host}:#{api_port}"),
    admin_url: System.get_env("BACKPLANE_ADMIN_URL", "http://#{host}:#{admin_port}")
```

Keep the existing `port` variable until both new endpoints are introduced; it is removed in Task 6.

- [ ] **Step 7: Run focused tests**

Run:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/settings/encryption_config_test.exs apps/backplane_system/test/backplane/web_origins_test.exs
```

Expected: tests pass.

- [ ] **Step 8: Run compile**

Run:

```bash
devenv shell -- mix compile
```

Expected: compile succeeds.

- [ ] **Step 9: Commit**

Run:

```bash
git add apps/backplane_system/lib/backplane/settings/encryption.ex apps/backplane_system/lib/backplane/web_origins.ex apps/backplane_system/test/backplane/settings/encryption_config_test.exs apps/backplane_system/test/backplane/web_origins_test.exs config/dev.exs config/test.exs config/runtime.exs
git commit -m "refactor(system): decouple web secrets and origins"
```

## Task 2: Create `backplane_api` Phoenix App

**Files:**

- Create: `apps/backplane_api/mix.exs`
- Create: `apps/backplane_api/package.json`
- Create: `apps/backplane_api/lib/backplane/api.ex`
- Create: `apps/backplane_api/lib/backplane/api/application.ex`
- Create: `apps/backplane_api/lib/backplane/api/endpoint.ex`
- Create: `apps/backplane_api/lib/backplane/api/router.ex`
- Create: `apps/backplane_api/test/support/conn_case.ex`
- Create: `apps/backplane_api/test/test_helper.exs`
- Create: `apps/backplane_api/test/backplane/api/route_boundary_test.exs`

- [ ] **Step 1: Write failing API boundary tests**

Create `apps/backplane_api/test/test_helper.exs`:

```elixir
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Backplane.Repo, :manual)
```

Create `apps/backplane_api/test/support/conn_case.ex`:

```elixir
defmodule Backplane.Api.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Backplane.Api.Endpoint

      import Phoenix.ConnTest
      import Plug.Conn
      import Backplane.Api.ConnCase
    end
  end

  setup tags do
    Backplane.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
```

Create `apps/backplane_api/test/backplane/api/route_boundary_test.exs`:

```elixir
defmodule Backplane.Api.RouteBoundaryTest do
  use Backplane.Api.ConnCase, async: false

  test "serves public home page", %{conn: conn} do
    conn = get(conn, "/")

    assert html_response(conn, 200) =~ "Private gateway for MCP tools and LLM APIs"
  end

  test "does not serve admin routes", %{conn: conn} do
    conn = get(conn, "/admin/dashboard/overview")

    assert response(conn, 404)
  end

  test "routes health through API endpoint", %{conn: conn} do
    conn = get(conn, "/health")

    assert json_response(conn, 200)["status"] in ["ok", "healthy"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
devenv shell -- mix test apps/backplane_api/test/backplane/api/route_boundary_test.exs
```

Expected: fails because `:backplane_api` or `Backplane.Api.Endpoint` does not exist.

- [ ] **Step 3: Create `apps/backplane_api/mix.exs`**

Create `apps/backplane_api/mix.exs`:

```elixir
defmodule BackplaneApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_api,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :phoenix_ecto],
      mod: {Backplane.Api.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:backplane, in_umbrella: true},
      {:backplane_system, in_umbrella: true},
      {:backplane_mcp, in_umbrella: true},
      {:backplane_llama, in_umbrella: true},
      {:backplane_skills, in_umbrella: true},
      {:backplane_memory, in_umbrella: true},
      {:relayixir, in_umbrella: true},
      {:backplane_data_case, in_umbrella: true, only: :test},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_duskmoon, "~> 9.0"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:bun, "~> 2.0", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.4", runtime: Mix.env() == :dev},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["bun.install --if-missing", "tailwind.install --if-missing"],
      "assets.build": [
        "cmd mkdir -p priv/static/assets",
        "bun backplane_api",
        "tailwind backplane_api"
      ],
      "assets.deploy": [
        "phx.digest.clean",
        "cmd mkdir -p priv/static/assets",
        "bun backplane_api --minify",
        "tailwind backplane_api --minify",
        "phx.digest"
      ],
      test: ["test"]
    ]
  end
end
```

- [ ] **Step 4: Create API package file**

Create `apps/backplane_api/package.json`:

```json
{
  "name": "backplane_api",
  "private": true,
  "dependencies": {
    "@duskmoon-dev/core": "1.17.0",
    "@duskmoon-dev/css-art": "1.17.0",
    "@duskmoon-dev/elements": "1.5.4",
    "@duskmoon-dev/art-elements": "1.5.4"
  }
}
```

- [ ] **Step 5: Create API macro host**

Create `apps/backplane_api/lib/backplane/api.ex`:

```elixir
defmodule Backplane.Api do
  @moduledoc """
  Macro host for the public/API Phoenix endpoint.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: Backplane.Api.Layouts]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      import Phoenix.HTML
      use PhoenixDuskmoon.Component
      use PhoenixDuskmoon.ArtComponent

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: Backplane.Api.Endpoint,
        router: Backplane.Api.Router,
        statics: Backplane.Api.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
```

- [ ] **Step 6: Create API application and endpoint**

Create `apps/backplane_api/lib/backplane/api/application.ex`:

```elixir
defmodule Backplane.Api.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Backplane.Api.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Backplane.Api.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Backplane.Api.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

Create `apps/backplane_api/lib/backplane/api/endpoint.ex`:

```elixir
defmodule Backplane.Api.Endpoint do
  use Phoenix.Endpoint, otp_app: :backplane_api

  @session_options [
    store: :cookie,
    key: "_backplane_api_key",
    signing_salt: "bkpln_api_salt",
    same_site: "Lax"
  ]

  socket("/host-agent/socket", Backplane.Api.HostAgentSocket,
    websocket: [connect_info: [:x_headers, :peer_data]],
    longpoll: false
  )

  plug(Plug.Static,
    at: "/",
    from: :backplane_api,
    gzip: false,
    only: Backplane.Api.static_paths()
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Backplane.LLM.ProxyPlug)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(Backplane.Api.Router)
end
```

- [ ] **Step 7: Create temporary API router**

Create `apps/backplane_api/lib/backplane/api/router.ex`:

```elixir
defmodule Backplane.Api.Router do
  use Backplane.Api, :router

  forward("/api/mcp", Backplane.Transport.McpPlug)
  forward("/health", Backplane.Transport.HealthPlug)
  forward("/metrics", Backplane.Transport.MetricsPlug)

  pipeline :public_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :skills_api do
    plug(:accepts, ["json", "gz"])
  end

  scope "/", Backplane.Api do
    pipe_through(:public_browser)

    get("/", PageController, :home)
  end

  scope "/api" do
    pipe_through(:api)
    forward("/llm", Backplane.LLM.ApiRouter)
  end

  scope "/api" do
    pipe_through(:skills_api)
    forward("/host-agent", Backplane.Skills.HostAgentApiRouter)
    forward("/skills", Backplane.Skills.ApiRouter)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
```

This router will not compile until `Backplane.Api.PageController` and host-agent modules are moved in Task 3.

- [ ] **Step 8: Add API endpoint config**

In `config/config.exs`, add:

```elixir
config :backplane_api, Backplane.Api.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Backplane.Api.ErrorHTML, json: Backplane.Api.ErrorJSON],
    layout: false
  ],
  pubsub_server: Backplane.PubSub,
  live_view: [signing_salt: "bkpln_api_lv_salt"]
```

In `config/dev.exs`, add:

```elixir
config :backplane_api, dev_routes: true

config :backplane_api, Backplane.Api.Endpoint,
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 4220],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: secret_key_base,
  watchers: [
    tailwind_api: {Tailwind, :install_and_run, [:backplane_api, ~w(--watch)]},
    bun_api: {Bun, :install_and_run, [:backplane_api, ~w(--sourcemap=inline --watch)]}
  ]
```

In `config/test.exs`, add:

```elixir
config :backplane_api, Backplane.Api.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: secret_key_base,
  server: false
```

- [ ] **Step 9: Run compile to expose missing moved modules**

Run:

```bash
devenv shell -- mix compile
```

Expected: compile fails on missing `Backplane.Api.PageController`, `Backplane.Api.ErrorHTML`, `Backplane.Api.ErrorJSON`, or `Backplane.Api.HostAgentSocket`. Task 3 moves those modules.

Do not commit this task until Task 3 compiles.

## Task 3: Move Public/API Modules, Assets, And Tests

**Files:**

- Create: `apps/backplane_api/lib/backplane/api/components/layouts.ex`
- Create: `apps/backplane_api/lib/backplane/api/components/layouts/root.html.heex`
- Copy: `apps/backplane_web/lib/backplane_web/controllers/page_controller.ex` to `apps/backplane_api/lib/backplane/api/controllers/page_controller.ex`
- Copy: `apps/backplane_web/lib/backplane_web/controllers/page_html.ex` to `apps/backplane_api/lib/backplane/api/controllers/page_html.ex`
- Copy: `apps/backplane_web/lib/backplane_web/controllers/page_html/home.html.heex` to `apps/backplane_api/lib/backplane/api/controllers/page_html/home.html.heex`
- Copy: `apps/backplane_web/lib/backplane_web/controllers/error_html.ex` to `apps/backplane_api/lib/backplane/api/controllers/error_html.ex`
- Copy: `apps/backplane_web/lib/backplane_web/controllers/error_json.ex` to `apps/backplane_api/lib/backplane/api/controllers/error_json.ex`
- Copy: `apps/backplane_web/lib/backplane_web/channels/host_agent_socket.ex` to `apps/backplane_api/lib/backplane/api/channels/host_agent_socket.ex`
- Copy: `apps/backplane_web/lib/backplane_web/channels/host_agent_channel.ex` to `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex`
- Copy: `apps/backplane_web/lib/backplane_web/host_agent_memory_sync.ex` to `apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex`
- Create: `apps/backplane_api/assets/js/app.js`
- Create: `apps/backplane_api/assets/css/app.css`
- Copy: public static image/icon files into `apps/backplane_api/priv/static/`
- Move API-specific tests into `apps/backplane_api/test`

- [ ] **Step 1: Copy public/API source files**

Run:

```bash
mkdir -p apps/backplane_api/lib/backplane/api/controllers/page_html
mkdir -p apps/backplane_api/lib/backplane/api/channels
mkdir -p apps/backplane_api/lib/backplane/api/components/layouts
mkdir -p apps/backplane_api/assets/js apps/backplane_api/assets/css apps/backplane_api/priv/static/images

cp apps/backplane_web/lib/backplane_web/controllers/page_html/home.html.heex apps/backplane_api/lib/backplane/api/controllers/page_html/home.html.heex
cp apps/backplane_web/lib/backplane_web/controllers/page_html.ex apps/backplane_api/lib/backplane/api/controllers/page_html.ex
cp apps/backplane_web/lib/backplane_web/controllers/page_controller.ex apps/backplane_api/lib/backplane/api/controllers/page_controller.ex
cp apps/backplane_web/lib/backplane_web/controllers/error_html.ex apps/backplane_api/lib/backplane/api/controllers/error_html.ex
cp apps/backplane_web/lib/backplane_web/controllers/error_json.ex apps/backplane_api/lib/backplane/api/controllers/error_json.ex
cp apps/backplane_web/lib/backplane_web/channels/host_agent_socket.ex apps/backplane_api/lib/backplane/api/channels/host_agent_socket.ex
cp apps/backplane_web/lib/backplane_web/channels/host_agent_channel.ex apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex
cp apps/backplane_web/lib/backplane_web/host_agent_memory_sync.ex apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex
cp -R apps/backplane_web/priv/static/images apps/backplane_api/priv/static/
cp apps/backplane_web/priv/static/favicon.ico apps/backplane_api/priv/static/favicon.ico
```

- [ ] **Step 2: Rename module namespace in moved API files**

Run:

```bash
find apps/backplane_api/lib/backplane/api -type f \( -name '*.ex' -o -name '*.heex' \) -print0 \
  | xargs -0 perl -0pi -e 's/BackplaneWeb/Backplane.Api/g'
```

- [ ] **Step 3: Split `PageController` into public-only controller**

Edit `apps/backplane_api/lib/backplane/api/controllers/page_controller.ex` so it contains:

```elixir
defmodule Backplane.Api.PageController do
  use Backplane.Api, :controller

  alias Backplane.WebOrigins

  def home(conn, _params) do
    conn
    |> assign(:page_title, "Backplane")
    |> assign(:base_url, WebOrigins.api_base_url())
    |> assign(:admin_base_url, WebOrigins.admin_base_url())
    |> put_layout(html: false)
    |> render(:home)
  end
end
```

- [ ] **Step 4: Rewrite cross-app admin links in public home template**

In `apps/backplane_api/lib/backplane/api/controllers/page_html/home.html.heex`, replace each same-origin admin verified route with `@admin_base_url` links.

Use these replacements:

```heex
<:menu to={@admin_base_url <> "/admin/dashboard/overview"}>Admin</:menu>
```

```heex
<a href={@admin_base_url <> "/admin/dashboard/overview"} class="no-underline">
```

```heex
<a href={@admin_base_url <> "/admin/system/credentials"} class="font-medium text-primary">/admin/system/credentials</a>
```

```heex
<a href={@admin_base_url <> "/admin/llama/providers"} class="font-medium text-primary">/admin/llama/providers</a>
```

```heex
<a href={@admin_base_url <> "/admin/mcp/upstreams"} class="font-medium text-primary">
```

```heex
<a href={@admin_base_url <> "/admin/system/clients"} class="font-medium text-primary">/admin/system/clients</a>
```

Search to confirm no admin verified routes remain in the API app:

```bash
rg '~p"/admin|href=\\{~p"/admin|to=\\{~p"/admin' apps/backplane_api
```

Expected: no matches.

- [ ] **Step 5: Create API layouts**

Create `apps/backplane_api/lib/backplane/api/components/layouts.ex`:

```elixir
defmodule Backplane.Api.Layouts do
  @moduledoc """
  Layouts for the public/API endpoint.
  """

  use Backplane.Api, :html

  embed_templates("layouts/*")
end
```

Create `apps/backplane_api/lib/backplane/api/components/layouts/root.html.heex`:

```heex
<!DOCTYPE html>
<html lang="en" data-theme="moonlight" class="h-full">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="csrf-token" content={get_csrf_token()} />
    <meta name="theme-color" content="#d6d6d6" />
    <title>{assigns[:page_title] || "Backplane"}</title>
    <link rel="icon" href={~p"/favicon.ico"} sizes="any" />
    <link rel="icon" type="image/png" sizes="32x32" href={~p"/images/favicon-32.png"} />
    <link rel="apple-touch-icon" sizes="180x180" href={~p"/images/apple-touch-icon.png"} />
    <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
    <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
    </script>
  </head>
  <body class="h-full antialiased bg-surface text-on-surface">
    {@inner_content}
  </body>
</html>
```

In `Backplane.Api.Router`, add this line inside `pipeline :public_browser` after `fetch_live_flash`:

```elixir
    plug(:put_root_layout, html: {Backplane.Api.Layouts, :root})
```

- [ ] **Step 6: Create API assets**

Create `apps/backplane_api/assets/js/app.js`:

```javascript
import "phoenix_html"

import {register as registerButton} from "@duskmoon-dev/el-button"
import {register as registerCard} from "@duskmoon-dev/el-card"
import {register as registerBadge} from "@duskmoon-dev/el-badge"
import {register as registerAlert} from "@duskmoon-dev/el-alert"

registerButton()
registerCard()
registerBadge()
registerAlert()

const themeColors = {
  moonlight: "#d6d6d6",
  sunshine: "#d1a644"
}

function applyTheme(theme) {
  if (theme && theme !== "default") {
    document.documentElement.setAttribute("data-theme", theme)
  } else {
    document.documentElement.removeAttribute("data-theme")
  }

  const meta = document.querySelector('meta[name="theme-color"]')
  if (meta) {
    const resolvedTheme = theme === "default" ? "moonlight" : theme
    meta.setAttribute("content", themeColors[resolvedTheme] || "#d6d6d6")
  }
}

function initThemeSwitchers(root = document) {
  root.querySelectorAll(".theme-controller-dropdown").forEach((switcher) => {
    if (switcher.dataset.themeSwitcherBound === "true") return

    switcher.dataset.themeSwitcherBound = "true"

    let theme = switcher.dataset.theme || localStorage.getItem("theme") || "default"
    applyTheme(theme)

    switcher.querySelectorAll(".theme-controller-item").forEach((input) => {
      input.checked = theme === input.value

      input.addEventListener("change", (event) => {
        theme = event.target.value
        applyTheme(theme)
        localStorage.setItem("theme", theme)
        switcher.removeAttribute("open")
      })
    })
  })
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => initThemeSwitchers())
} else {
  initThemeSwitchers()
}
```

Create `apps/backplane_api/assets/css/app.css`:

```css
@import "tailwindcss" source(none);
@source "../css";
@source "../js";
@source "../../lib/backplane/api";
@source "../../../deps/phoenix_duskmoon/lib";
@source "../../../deps/phoenix_duskmoon/assets/js";
@plugin "@duskmoon-dev/core/plugin";
@import "@duskmoon-dev/core/themes/sunshine";
@import "@duskmoon-dev/core/themes/moonlight";
@import "@duskmoon-dev/core/components";
```

- [ ] **Step 7: Update API channel references**

In `apps/backplane_api/lib/backplane/api/channels/host_agent_socket.ex`, ensure the channel line is:

```elixir
  channel("host_agent:*", Backplane.Api.HostAgentChannel)
```

In `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex`, ensure the module starts with:

```elixir
defmodule Backplane.Api.HostAgentChannel do
  use Backplane.Api, :channel
```

In that same file, replace adapter env keys:

```elixir
Application.get_env(:backplane_api, :memory_service, BackplaneMemory.Service)
Application.get_env(:backplane_api, :host_memory_sync_adapter, Backplane.Api.HostAgentMemorySync)
```

- [ ] **Step 8: Move API tests**

Run:

```bash
mkdir -p apps/backplane_api/test/backplane/api/channels
git mv apps/backplane_web/test/backplane_web/controllers/page_controller_test.exs apps/backplane_api/test/backplane/api/page_controller_test.exs
git mv apps/backplane_web/test/backplane_web/channels/host_agent_socket_test.exs apps/backplane_api/test/backplane/api/channels/host_agent_socket_test.exs
git mv apps/backplane_web/test/backplane_web/channels/host_agent_channel_test.exs apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs
git mv apps/backplane_web/test/backplane_web/host_agent_memory_sync_test.exs apps/backplane_api/test/backplane/api/host_agent_memory_sync_test.exs
git mv apps/backplane_web/test/backplane_web/host_agent_sync_e2e_test.exs apps/backplane_api/test/backplane/api/host_agent_sync_e2e_test.exs
```

Then replace namespaces and test cases:

```bash
find apps/backplane_api/test -type f -name '*.exs' -print0 \
  | xargs -0 perl -0pi -e 's/BackplaneWeb/Backplane.Api/g; s/Backplane\\.LiveCase/Backplane.Api.ConnCase/g; s/Backplane\\.ChannelCase/Backplane.Api.ChannelCase/g; s/:backplane_web/:backplane_api/g'
```

Create `apps/backplane_api/test/support/channel_case.ex`:

```elixir
defmodule Backplane.Api.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Backplane.Api.Endpoint

      import Phoenix.ChannelTest
      import Backplane.Api.ChannelCase
    end
  end

  setup tags do
    Backplane.DataCase.setup_sandbox(tags)
    :ok
  end
end
```

- [ ] **Step 9: Run focused API tests**

Run:

```bash
devenv shell -- mix test apps/backplane_api/test/backplane/api/route_boundary_test.exs apps/backplane_api/test/backplane/api/page_controller_test.exs apps/backplane_api/test/backplane/api/channels/host_agent_socket_test.exs
```

Expected: API route boundary, page, and socket tests pass.

- [ ] **Step 10: Run compile**

Run:

```bash
devenv shell -- mix compile
```

Expected: compile succeeds or fails only on missing admin app modules that are introduced in Task 4.

- [ ] **Step 11: Commit**

Run after compile and focused tests pass:

```bash
git add apps/backplane_api config/config.exs config/dev.exs config/test.exs
git commit -m "feat(api): add public phoenix endpoint"
```

## Task 4: Create `backplane_admin` Phoenix App

**Files:**

- Create: `apps/backplane_admin/mix.exs`
- Create: `apps/backplane_admin/package.json`
- Create: `apps/backplane_admin/lib/backplane/admin.ex`
- Create: `apps/backplane_admin/lib/backplane/admin/application.ex`
- Create: `apps/backplane_admin/lib/backplane/admin/endpoint.ex`
- Create: `apps/backplane_admin/lib/backplane/admin/router.ex`
- Create: `apps/backplane_admin/lib/backplane/admin/controllers/page_controller.ex`
- Create: `apps/backplane_admin/test/support/live_case.ex`
- Create: `apps/backplane_admin/test/backplane/admin/route_boundary_test.exs`

- [ ] **Step 1: Write failing admin boundary test**

Create `apps/backplane_admin/test/test_helper.exs`:

```elixir
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Backplane.Repo, :manual)
```

Create `apps/backplane_admin/test/support/live_case.ex`:

```elixir
defmodule Backplane.Admin.LiveCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Backplane.Admin.Endpoint

      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Backplane.Admin.LiveCase
    end
  end

  setup tags do
    Backplane.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
```

Create `apps/backplane_admin/test/backplane/admin/route_boundary_test.exs`:

```elixir
defmodule Backplane.Admin.RouteBoundaryTest do
  use Backplane.Admin.LiveCase, async: false

  test "redirects /admin to the dashboard", %{conn: conn} do
    conn = get(conn, "/admin")

    assert redirected_to(conn) == "/admin/dashboard/overview"
  end

  test "does not serve API routes", %{conn: conn} do
    conn = get(conn, "/api/mcp")

    assert response(conn, 404)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/route_boundary_test.exs
```

Expected: fails because `:backplane_admin` or `Backplane.Admin.Endpoint` does not exist.

- [ ] **Step 3: Create admin app files**

Create `apps/backplane_admin/mix.exs`:

```elixir
defmodule BackplaneAdmin.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_admin,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :phoenix_ecto],
      mod: {Backplane.Admin.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:backplane, in_umbrella: true},
      {:backplane_system, in_umbrella: true},
      {:backplane_mcp, in_umbrella: true},
      {:backplane_llama, in_umbrella: true},
      {:backplane_skills, in_umbrella: true},
      {:backplane_memory, in_umbrella: true},
      {:backplane_monitor, in_umbrella: true},
      {:relayixir, in_umbrella: true},
      {:backplane_data_case, in_umbrella: true, only: :test},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:phoenix_duskmoon, "~> 9.0"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:bun, "~> 2.0", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.4", runtime: Mix.env() == :dev},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["bun.install --if-missing", "tailwind.install --if-missing"],
      "assets.build": [
        "cmd mkdir -p priv/static/assets",
        "bun backplane_admin",
        "tailwind backplane_admin"
      ],
      "assets.deploy": [
        "phx.digest.clean",
        "cmd mkdir -p priv/static/assets",
        "bun backplane_admin --minify",
        "tailwind backplane_admin --minify",
        "phx.digest"
      ],
      test: ["test"]
    ]
  end
end
```

Create `apps/backplane_admin/package.json`:

```json
{
  "name": "backplane_admin",
  "private": true,
  "dependencies": {
    "@duskmoon-dev/core": "1.17.0",
    "@duskmoon-dev/css-art": "1.17.0",
    "@duskmoon-dev/elements": "1.5.4",
    "@duskmoon-dev/art-elements": "1.5.4"
  }
}
```

- [ ] **Step 4: Create admin macro host**

Create `apps/backplane_admin/lib/backplane/admin.ex`:

```elixir
defmodule Backplane.Admin do
  @moduledoc """
  Macro host for the Backplane admin Phoenix endpoint.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: Backplane.Admin.Layouts]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {Backplane.Admin.Layouts, :app}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML

      use PhoenixDuskmoon.Component
      use PhoenixDuskmoon.ArtComponent

      import Backplane.Admin.Components.LocalTime

      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: Backplane.Admin.Endpoint,
        router: Backplane.Admin.Router,
        statics: Backplane.Admin.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
```

- [ ] **Step 5: Create admin application and endpoint**

Create `apps/backplane_admin/lib/backplane/admin/application.ex`:

```elixir
defmodule Backplane.Admin.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Backplane.Admin.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Backplane.Admin.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Backplane.Admin.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

Create `apps/backplane_admin/lib/backplane/admin/endpoint.ex`:

```elixir
defmodule Backplane.Admin.Endpoint do
  use Phoenix.Endpoint, otp_app: :backplane_admin

  @session_options [
    store: :cookie,
    key: "_backplane_admin_key",
    signing_salt: "bkpln_admin_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.Static,
    at: "/",
    from: :backplane_admin,
    gzip: false,
    only: Backplane.Admin.static_paths()
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(Backplane.Admin.Router)
end
```

- [ ] **Step 6: Create admin route skeleton**

Create `apps/backplane_admin/lib/backplane/admin/controllers/page_controller.ex`:

```elixir
defmodule Backplane.Admin.PageController do
  use Backplane.Admin, :controller

  def admin(conn, _params) do
    redirect(conn, to: ~p"/admin/dashboard/overview")
  end
end
```

Create `apps/backplane_admin/lib/backplane/admin/router.ex` by copying the current `/admin` scope from `apps/backplane_web/lib/backplane_web/router.ex`, then applying these edits:

```elixir
defmodule Backplane.Admin.Router do
  use Backplane.Admin, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Backplane.Admin.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(Backplane.Web.AdminAuthPlug)
  end

  scope "/admin", Backplane.Admin do
    pipe_through(:browser)

    get("/", PageController, :admin)
  end

  if Application.compile_env(:backplane_admin, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)
      live_dashboard("/dashboard", metrics: Backplane.Telemetry)
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
```

Task 5 expands the admin scope with all current LiveView routes.

- [ ] **Step 7: Add admin endpoint config**

In `config/config.exs`, add:

```elixir
config :backplane_admin, Backplane.Admin.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Backplane.Admin.ErrorHTML, json: Backplane.Admin.ErrorJSON],
    layout: false
  ],
  pubsub_server: Backplane.PubSub,
  live_view: [signing_salt: "bkpln_admin_lv_salt"]
```

In `config/dev.exs`, add:

```elixir
config :backplane_admin, dev_routes: true

config :backplane_admin, Backplane.Admin.Endpoint,
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 4221],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: secret_key_base,
  watchers: [
    tailwind_admin: {Tailwind, :install_and_run, [:backplane_admin, ~w(--watch)]},
    bun_admin: {Bun, :install_and_run, [:backplane_admin, ~w(--sourcemap=inline --watch)]}
  ]
```

In `config/test.exs`, add:

```elixir
config :backplane_admin, Backplane.Admin.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: secret_key_base,
  server: false
```

- [ ] **Step 8: Run boundary test**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/route_boundary_test.exs
```

Expected: the `/admin` redirect test passes. The `/api/mcp` test passes with 404.

Do not commit this task until Task 5 moves admin modules and the app compiles.

## Task 5: Move Admin LiveViews, Layouts, Assets, And Tests

**Files:**

- Copy: `apps/backplane_web/lib/backplane_web/live/*.ex` to `apps/backplane_admin/lib/backplane/admin/live/*.ex`
- Copy: `apps/backplane_web/lib/backplane_web/components/*` to `apps/backplane_admin/lib/backplane/admin/components/*`
- Copy: `apps/backplane_web/lib/backplane_web/controllers/oauth_callback_controller.ex` to `apps/backplane_admin/lib/backplane/admin/controllers/oauth_callback_controller.ex`
- Copy: `apps/backplane_web/lib/backplane_web/controllers/error_html.ex` to `apps/backplane_admin/lib/backplane/admin/controllers/error_html.ex`
- Copy: `apps/backplane_web/lib/backplane_web/controllers/error_json.ex` to `apps/backplane_admin/lib/backplane/admin/controllers/error_json.ex`
- Copy: admin assets into `apps/backplane_admin/assets` and `apps/backplane_admin/priv/static`
- Move: admin tests from `apps/backplane_web/test/backplane_web/live` to `apps/backplane_admin/test/backplane/admin/live`

- [ ] **Step 1: Copy admin source files**

Run:

```bash
mkdir -p apps/backplane_admin/lib/backplane/admin/live
mkdir -p apps/backplane_admin/lib/backplane/admin/components
mkdir -p apps/backplane_admin/lib/backplane/admin/controllers
mkdir -p apps/backplane_admin/assets/js apps/backplane_admin/assets/css apps/backplane_admin/priv/static/images

cp apps/backplane_web/lib/backplane_web/live/*.ex apps/backplane_admin/lib/backplane/admin/live/
cp apps/backplane_web/lib/backplane_web/components/local_time.ex apps/backplane_admin/lib/backplane/admin/components/local_time.ex
cp apps/backplane_web/lib/backplane_web/components/layouts.ex apps/backplane_admin/lib/backplane/admin/components/layouts.ex
cp -R apps/backplane_web/lib/backplane_web/components/layouts apps/backplane_admin/lib/backplane/admin/components/layouts
cp apps/backplane_web/lib/backplane_web/controllers/oauth_callback_controller.ex apps/backplane_admin/lib/backplane/admin/controllers/oauth_callback_controller.ex
cp apps/backplane_web/lib/backplane_web/controllers/error_html.ex apps/backplane_admin/lib/backplane/admin/controllers/error_html.ex
cp apps/backplane_web/lib/backplane_web/controllers/error_json.ex apps/backplane_admin/lib/backplane/admin/controllers/error_json.ex
cp apps/backplane_web/assets/js/app.js apps/backplane_admin/assets/js/app.js
cp apps/backplane_web/assets/css/app.css apps/backplane_admin/assets/css/app.css
cp -R apps/backplane_web/priv/static/images apps/backplane_admin/priv/static/
cp apps/backplane_web/priv/static/favicon.ico apps/backplane_admin/priv/static/favicon.ico
```

- [ ] **Step 2: Rename admin module namespace**

Run:

```bash
find apps/backplane_admin/lib/backplane/admin -type f \( -name '*.ex' -o -name '*.heex' \) -print0 \
  | xargs -0 perl -0pi -e 's/BackplaneWeb/Backplane.Admin/g; s/use Backplane\\.Admin, :channel/use Backplane.Api, :channel/g'
```

The second replacement is harmless for admin files; it prevents accidental channel usage if a channel file was moved to the wrong app. Confirm no channel file exists in admin:

```bash
find apps/backplane_admin/lib/backplane/admin -path '*channels*' -type f -print
```

Expected: no output.

- [ ] **Step 3: Update admin asset source paths**

In `apps/backplane_admin/assets/css/app.css`, replace:

```css
@source "../../lib/backplane_web";
```

with:

```css
@source "../../lib/backplane/admin";
```

In `apps/backplane_admin/assets/js/app.js`, keep the existing LiveSocket setup for `"/live"` and update no endpoint path.

- [ ] **Step 4: Expand admin router with all LiveView routes**

Copy every route from the old `scope "/admin", BackplaneWeb do` block into `apps/backplane_admin/lib/backplane/admin/router.ex`, replacing `BackplaneWeb` with `Backplane.Admin`.

The final scope must contain these route groups:

```elixir
  scope "/admin", Backplane.Admin do
    pipe_through(:browser)

    get("/", PageController, :admin)
    live("/dashboard/overview", DashboardLive, :overview)
    live("/dashboard/usage/llm", DashboardUsageLive, :llm)
    live("/dashboard/usage/mcp", DashboardUsageLive, :mcp)
    live("/llama/providers", ProvidersLive, :index)
    live("/llama/providers/new", ProviderNewLive, :new)
    live("/llama/providers/:id", ProviderShowLive, :show)
    live("/llama/embedding", EmbeddingLive, :index)
    live("/llama/model-aliases", SettingsLive, :model_aliases)
    live("/mcp/upstreams", UpstreamsLive, :index)
    live("/mcp/upstreams/new", UpstreamsLive, :new)
    live("/mcp/upstreams/:id/edit", UpstreamsLive, :edit)
    live("/mcp/managed", ManagedLive, :index)
    live("/mcp/managed/:prefix", ManagedServiceSettingsLive, :show)
    live("/mcp/managed/:prefix/tool/:tool_name", ManagedToolDetailLive, :show)
    live("/mcp/agent", AgentMcpLive, :index)
    live("/mcp/agent/new", AgentMcpLive, :new)
    live("/mcp/agent/:id/edit", AgentMcpLive, :edit)
    live("/mcp/inspector", McpInspectorLive, :index)
    live("/mcp/inspector/internal", McpInspectorLive, :internal)
    live("/memory", MemoryOverviewLive, :index)
    live("/memory/observations", MemoryObservationsLive, :index)
    live("/memory/sessions", MemorySessionsLive, :index)
    live("/memory/graph", MemoryGraphLive, :index)
    live("/memory/actions", MemoryActionsLive, :index)
    live("/memory/audit", MemoryAuditLive, :index)
    live("/memory/config", MemoryConfigLive, :index)
    live("/memory/browse", MemoryLive, :index)
    live("/memory/stats", MemoryStatsLive, :index)
    live("/skills", SkillOverviewLive, :index)
    live("/skills/browse", SkillBrowseLive, :index)
    live("/skills/browse/:id", SkillBrowseLive, :show)
    live("/skills/metadata", SkillMetadataLive, :index)
    live("/skills/upstream", SkillUpstreamLive, :index)
    live("/skills/upstream/new", SkillUpstreamLive, :new)
    live("/skills/upstream/:id", SkillUpstreamLive, :show)
    live("/skills/upstream/:id/edit", SkillUpstreamLive, :edit)
    live("/skills/draft", SkillDraftLive, :index)
    live("/skills/draft/new", SkillDraftLive, :new)
    live("/skills/draft/:id/edit", SkillDraftLive, :edit)
    live("/skills/upload", SkillUploadLive, :index)
    live("/skills/upload/:id", SkillUploadLive, :show)
    live("/system/clients", ClientsLive, :index)
    live("/system/logs", LogsLive, :index)
    live("/system/monitor/plans", MonitorPlansLive, :index)
    live("/system/monitor/plans/new", MonitorPlansLive, :new)
    live("/system/monitor/plans/:id/edit", MonitorPlansLive, :edit)
    live("/system/credentials", SettingsLive, :credentials)
    live("/system/credentials/new", SettingsLive, :credentials_new)
    live("/system/credentials/new/:vendor", SettingsLive, :credentials_new_oauth)
    live("/system/credentials/:name/edit", SettingsLive, :credentials_edit)
    live("/system/host-agents", HostAgentsLive, :index)
    live("/system/host-agents/:id", HostAgentsLive, :show)
    live("/dashboard/usage/plans", DashboardPlanUsageLive, :index)
    get("/oauth/callback", OAuthCallbackController, :callback)
  end
```

- [ ] **Step 5: Fix admin cross-app URLs**

In `apps/backplane_admin/lib/backplane/admin/components/layouts/app.html.heex`, replace the logo link:

```heex
<.link navigate={~p"/"} class="appbar-brand no-underline">
```

with:

```heex
<a href={Backplane.WebOrigins.api_url("/")} class="appbar-brand no-underline">
```

and replace the closing `</.link>` for that brand link with:

```heex
</a>
```

In `apps/backplane_admin/lib/backplane/admin/live/settings_live.ex`, replace:

```elixir
redirect_uri = Backplane.Admin.Endpoint.url() <> "/admin/oauth/callback"
```

with:

```elixir
redirect_uri = Backplane.WebOrigins.admin_url("/admin/oauth/callback")
```

In `apps/backplane_admin/lib/backplane/admin/live/host_agents_live.ex`, replace `hub_url_hint/0` with:

```elixir
  defp hub_url_hint do
    Backplane.WebOrigins.api_base_url()
  end
```

- [ ] **Step 6: Move admin tests**

Run:

```bash
mkdir -p apps/backplane_admin/test/backplane/admin/live
git mv apps/backplane_web/test/backplane_web/live/*.exs apps/backplane_admin/test/backplane/admin/live/
```

Then rewrite namespaces:

```bash
find apps/backplane_admin/test -type f -name '*.exs' -print0 \
  | xargs -0 perl -0pi -e 's/BackplaneWeb/Backplane.Admin/g; s/Backplane\\.LiveCase/Backplane.Admin.LiveCase/g; s/:backplane_web/:backplane_admin/g'
```

- [ ] **Step 7: Run focused admin route tests**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/route_boundary_test.exs apps/backplane_admin/test/backplane/admin/live/dashboard_live_test.exs
```

Expected: tests pass.

- [ ] **Step 8: Run admin LiveView test suite**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test
```

Expected: tests pass. If failures are from namespace rewrites, fix only moved admin files and rerun this command.

- [ ] **Step 9: Run compile**

Run:

```bash
devenv shell -- mix compile
```

Expected: compile succeeds while `apps/backplane_web` still exists.

- [ ] **Step 10: Commit**

Run:

```bash
git add apps/backplane_admin apps/backplane_api config/config.exs config/dev.exs config/test.exs
git commit -m "feat(admin): add dedicated phoenix endpoint"
```

## Task 6: Runtime Config, Assets, Release, Docker, And CI

**Files:**

- Modify: `config/config.exs`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`
- Modify: `config/prod.exs`
- Modify: `config/runtime.exs`
- Modify: `mix.exs`
- Modify: `Dockerfile`
- Modify: `.github/workflows/build.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `README.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Update asset config**

In `config/config.exs`, replace the single `:bun, backplane:` config with:

```elixir
config :bun,
  version: "1.3.3",
  backplane_api: [
    args:
      ~w(build assets/js/app.js --outdir=priv/static/assets --external /fonts/* --external /images/*),
    cd: Path.expand("../apps/backplane_api", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ],
  backplane_admin: [
    args:
      ~w(build assets/js/app.js --outdir=priv/static/assets --external /fonts/* --external /images/*),
    cd: Path.expand("../apps/backplane_admin", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]
```

Replace the single `:tailwind, backplane:` config with:

```elixir
config :tailwind,
  version: "4.1.18",
  backplane_api: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/app.css),
    cd: Path.expand("../apps/backplane_api", __DIR__)
  ],
  backplane_admin: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/app.css),
    cd: Path.expand("../apps/backplane_admin", __DIR__)
  ]
```

- [ ] **Step 2: Update production endpoint config**

In `config/prod.exs`, replace the old endpoint manifest with:

```elixir
config :backplane_api, Backplane.Api.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :backplane_admin, Backplane.Admin.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"
```

- [ ] **Step 3: Update runtime endpoint config**

In `config/runtime.exs`, replace the old `:backplane_web, BackplaneWeb.Endpoint` production block with:

```elixir
  api_port =
    case System.get_env("BACKPLANE_API_PORT") || System.get_env("BACKPLANE_PORT") || System.get_env("PORT") do
      nil -> 4100
      port_str -> String.to_integer(port_str)
    end

  admin_port =
    case System.get_env("BACKPLANE_ADMIN_PORT") do
      nil -> 4101
      port_str -> String.to_integer(port_str)
    end

  config :backplane,
    secret_key_base: secret_key_base,
    api_url: System.get_env("BACKPLANE_API_URL", "http://#{host}:#{api_port}"),
    admin_url: System.get_env("BACKPLANE_ADMIN_URL", "http://#{host}:#{admin_port}")

  config :backplane_api, Backplane.Api.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: api_port],
    secret_key_base: secret_key_base,
    server: server?

  config :backplane_admin, Backplane.Admin.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: admin_port],
    secret_key_base: secret_key_base,
    server: server?
```

Ensure there is no remaining production config for `:backplane_web`.

- [ ] **Step 4: Update top-level Mix aliases and release**

In root `mix.exs`, replace:

```elixir
"assets.deploy": ["do --app backplane_web assets.deploy"],
```

with:

```elixir
"assets.deploy": [
  "do --app backplane_api assets.deploy",
  "do --app backplane_admin assets.deploy"
],
```

In the `backplane` release applications, replace:

```elixir
backplane_web: :permanent,
```

with:

```elixir
backplane_api: :permanent,
backplane_admin: :permanent,
```

- [ ] **Step 5: Update Dockerfile**

Replace the old web app copy line with:

```dockerfile
COPY apps/backplane_api/mix.exs apps/backplane_api/package.json ./apps/backplane_api/
COPY apps/backplane_admin/mix.exs apps/backplane_admin/package.json ./apps/backplane_admin/
```

Replace the old asset setup line with:

```dockerfile
RUN mix "do" --app backplane_api assets.setup \
  && mix "do" --app backplane_admin assets.setup \
  && ./_build/bun install --frozen-lockfile
```

Replace the old asset deploy line with:

```dockerfile
RUN mix "do" --app backplane_api assets.deploy \
  && mix "do" --app backplane_admin assets.deploy
```

Update runtime environment and exposed ports:

```dockerfile
ENV BACKPLANE_API_PORT=4100 \
  BACKPLANE_ADMIN_PORT=4101 \
  BACKPLANE_PORT=4100 \
  BACKPLANE_VERSION="${VERSION}" \
  HOME=/app \
  LANG=C.UTF-8 \
  PHX_SERVER=true \
  PORT=4100

EXPOSE 4100 4101
```

- [ ] **Step 6: Update GitHub workflows**

In `.github/workflows/build.yml` and `.github/workflows/release.yml`, replace:

```yaml
run: mix "do" --app backplane_web assets.setup
```

with:

```yaml
run: mix "do" --app backplane_api assets.setup && mix "do" --app backplane_admin assets.setup
```

Replace:

```yaml
run: mix "do" --app backplane_web assets.deploy
```

with:

```yaml
run: mix "do" --app backplane_api assets.deploy && mix "do" --app backplane_admin assets.deploy
```

- [ ] **Step 7: Update docs**

In `README.md`, update the app list and production port section to say:

```markdown
- `apps/backplane_api`: Phoenix public/API endpoint for `/`, `/api/*`, `/health`, `/metrics`, and host-agent sockets.
- `apps/backplane_admin`: Phoenix admin UI endpoint for `/admin/*`.

Production public/API HTTP binding is controlled by `BACKPLANE_API_PORT`, `BACKPLANE_PORT`, or `PORT`; if none is set, it defaults to `4100`.
Production admin HTTP binding is controlled by `BACKPLANE_ADMIN_PORT`; if it is not set, it defaults to `4101`.
```

In `AGENTS.md`, update the umbrella structure and route table to mention the two Phoenix apps and the two default ports.

- [ ] **Step 8: Run asset builds**

Run:

```bash
devenv shell -- mix do --app backplane_api assets.build
devenv shell -- mix do --app backplane_admin assets.build
```

Expected: both commands create `priv/static/assets/app.css` and `priv/static/assets/app.js` under their app directories.

- [ ] **Step 9: Run compile and endpoint tests**

Run:

```bash
devenv shell -- mix compile
devenv shell -- mix test apps/backplane_api/test apps/backplane_admin/test
```

Expected: compile and both Phoenix app test suites pass.

- [ ] **Step 10: Commit**

Run:

```bash
git add config mix.exs Dockerfile .github/workflows/build.yml .github/workflows/release.yml README.md AGENTS.md apps/backplane_api apps/backplane_admin
git commit -m "build: wire split phoenix endpoints"
```

## Task 7: Remove `backplane_web` And Verify Final Scope

**Files:**

- Delete: `apps/backplane_web/**`
- Modify: any remaining references found by `rg "backplane_web|BackplaneWeb"`

- [ ] **Step 1: Search for stale references**

Run:

```bash
rg -n "backplane_web|BackplaneWeb|Backplane\\.LiveCase|Backplane\\.ChannelCase" apps config mix.exs Dockerfile README.md AGENTS.md .github/workflows
```

Expected: matches only inside files still waiting to be moved. After Step 2, this command must return no matches.

- [ ] **Step 2: Delete old Phoenix app**

Run:

```bash
git rm -r apps/backplane_web
```

- [ ] **Step 3: Fix any stale references**

Run:

```bash
rg -n "backplane_web|BackplaneWeb|Backplane\\.LiveCase|Backplane\\.ChannelCase" apps config mix.exs Dockerfile README.md AGENTS.md .github/workflows
```

Expected: no matches.

If matches remain, edit the referenced files so:

- `BackplaneWeb.Endpoint` becomes `Backplane.Api.Endpoint` for public/API tests and `Backplane.Admin.Endpoint` for admin tests.
- `BackplaneWeb.Router` becomes `Backplane.Api.Router` or `Backplane.Admin.Router` by route ownership.
- `:backplane_web` config becomes `:backplane_api` or `:backplane_admin` by endpoint ownership.

- [ ] **Step 4: Run final focused test suites**

Run:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/settings/encryption_config_test.exs apps/backplane_system/test/backplane/web_origins_test.exs
devenv shell -- mix test apps/backplane_api/test
devenv shell -- mix test apps/backplane_admin/test
```

Expected: all pass.

- [ ] **Step 5: Run full compile**

Run:

```bash
devenv shell -- mix compile --warnings-as-errors
```

Expected: compile succeeds without warnings.

- [ ] **Step 6: Run route smoke checks with dev server**

Start the server:

```bash
devenv shell -- mix phx.server
```

In another shell, run:

```bash
curl -i http://localhost:4220/
curl -i http://localhost:4220/admin/dashboard/overview
curl -i http://localhost:4221/admin/dashboard/overview
curl -i http://localhost:4221/api/mcp
curl -i http://localhost:4220/health
```

Expected:

- `http://localhost:4220/` returns `200`.
- `http://localhost:4220/admin/dashboard/overview` returns `404`.
- `http://localhost:4221/admin/dashboard/overview` returns `200` or the configured admin auth response.
- `http://localhost:4221/api/mcp` returns `404`.
- `http://localhost:4220/health` returns `200`.

Stop the server after the smoke checks.

- [ ] **Step 7: Run GitNexus change detection**

Run the GitNexus `detect_changes` tool with `scope: "all"` for repository `backplane`.

Expected: changed symbols map to endpoint/router/config/test/documentation scope. If it reports high-risk affected flows outside endpoint routing, inspect those files before committing.

- [ ] **Step 8: Commit**

Run:

```bash
git add apps config mix.exs Dockerfile README.md AGENTS.md .github/workflows
git commit -m "refactor(web): remove legacy phoenix app"
```

## Final Verification

Run:

```bash
devenv shell -- mix test apps/backplane_system/test/backplane/settings/encryption_config_test.exs apps/backplane_system/test/backplane/web_origins_test.exs
devenv shell -- mix test apps/backplane_api/test
devenv shell -- mix test apps/backplane_admin/test
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix assets.deploy
```

Expected: all commands pass.

Then run:

```bash
rg -n "backplane_web|BackplaneWeb" apps config mix.exs Dockerfile README.md AGENTS.md .github/workflows
```

Expected: no matches.

## Self-Review Checklist

- [ ] `Backplane.Api.Endpoint` has `Backplane.LLM.ProxyPlug` before `Plug.Parsers`.
- [ ] `Backplane.Admin.Endpoint` does not mount API routes.
- [ ] `Backplane.Api.Router` does not mount admin routes.
- [ ] OAuth redirect URI uses `Backplane.WebOrigins.admin_url("/admin/oauth/callback")`.
- [ ] Admin host-agent hint uses `Backplane.WebOrigins.api_base_url()`.
- [ ] Public page admin links use the configured admin origin.
- [ ] `:backplane_web` is absent from the final release configuration.
- [ ] Docker exposes both `4100` and `4101`.
- [ ] CI builds assets for both Phoenix apps.
- [ ] No unrelated dirty files are staged.
