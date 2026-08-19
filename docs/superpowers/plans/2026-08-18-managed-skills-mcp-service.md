# Managed Skills MCP Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing `skill::*` MCP tools a persistently enableable, disableable, and debuggable service in `/mcp/managed`.

**Architecture:** Add `Backplane.Services.Skills` as a managed-service adapter over `Backplane.Tools.Skill`, keeping tool definitions and execution logic single-sourced. Register Skills only through `ToolRegistry.register_managed/2`, guard direct admin calls with the persisted `services.skill.enabled` setting, and extend the three existing Managed MCP LiveViews without redesigning them.

**Tech Stack:** Elixir 1.18, OTP 28, Phoenix LiveView, Ecto/PostgreSQL, ExUnit, Backplane's ETS-backed `ToolRegistry`, DuskMoon Phoenix components.

---

## Final Review Addendum

Execution followed this plan test-first. Final production review then superseded
the plan's read-time registry refresh and added these completed hardening steps:

- fail managed-service startup closed when the authoritative Settings load fails,
  retrying a prior load error on application-level restart;
- clear stale managed rows on readiness failure while preserving unrelated tools;
- serialize Skills writes and toggles, plus Day/Web/Math UI read-modify-write
  toggles;
- make Managed MCP page loads read-only and report toggle errors truthfully;
- reserve normalized prefix `skill` in upstream config, persistence, and runtime;
- log rejected legacy upstreams during both configured and database boot paths.

The final implementation and verification evidence therefore take precedence over
individual steps below that mention page-load reconciliation.

## Working Directory and Verification Contract

Run every command from:

```text
/home/gao/Workspace/gsmlg-opt/backplane/.trees/codex/managed-skills
```

Use the repository-managed PostgreSQL socket for database-backed tests:

```bash
devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test <paths>
```

Before editing any existing function, run the required upstream GitNexus impact
check named in that task. Before every commit, run
`gitnexus_detect_changes({repo: "backplane", scope: "all"})`. The index is attached
to the primary worktree and may report `No changes detected` for this isolated
worktree; in that case, use the isolated worktree's `git diff`, `git diff --check`,
and focused tests as the authoritative scope evidence.

## File Map

- Create `apps/backplane_mcp/lib/backplane/services/skills.ex` — managed lifecycle and guarded delegation for Skills tools.
- Create `apps/backplane_mcp/test/backplane/services/skills_test.exs` — adapter contract, delegation, and enable/disable registry coverage.
- Modify `apps/backplane_system/lib/backplane/settings.ex` — declare the default-enabled persisted service setting.
- Modify `apps/backplane/lib/backplane/application.ex` — remove native Skills registration and expose a testable managed reconciliation seam used at boot.
- Modify `apps/backplane/test/backplane/application_test.exs` — prove persisted startup state replaces stale native Skills entries.
- Modify `apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs` — make transport fixtures match production managed registration and verify disabled discovery.
- Modify `apps/backplane_admin/lib/backplane/admin/live/managed_live.ex` — list and toggle Skills in Managed MCP.
- Modify `apps/backplane_admin/test/backplane/admin/live/managed_live_test.exs` — index and lifecycle regression coverage.
- Modify `apps/backplane_admin/lib/backplane/admin/live/managed_service_settings_live.ex` — accept the Skills debug route.
- Modify `apps/backplane_admin/test/backplane/admin/live/managed_service_settings_live_test.exs` — enabled and disabled debug coverage.
- Modify `apps/backplane_admin/lib/backplane/admin/live/managed_tool_detail_live.ex` — accept Skills tool-detail routes.
- Create `apps/backplane_admin/test/backplane/admin/live/managed_tool_detail_live_test.exs` — Skills detail/test-runner coverage.

### Task 1: Add the Managed Skills Adapter

**Files:**
- Create: `apps/backplane_mcp/lib/backplane/services/skills.ex`
- Create: `apps/backplane_mcp/test/backplane/services/skills_test.exs`
- Modify: `apps/backplane_system/lib/backplane/settings.ex:63-74`

- [ ] **Step 1: Confirm the new module has no pre-existing symbol to impact**

Search for the exact module and setting before creating them:

```bash
rg -n 'defmodule Backplane.Services.Skills|services\.skill\.enabled' apps
```

Expected: no matches.

- [ ] **Step 2: Write the failing adapter tests**

Create `apps/backplane_mcp/test/backplane/services/skills_test.exs`:

```elixir
defmodule Backplane.Services.SkillsTest do
  use Backplane.DataCase, async: false

  alias Backplane.Registry.ToolRegistry
  alias Backplane.Services.Skills
  alias Backplane.Settings
  alias Backplane.Tools.Skill, as: SkillTool

  @setting_key "services.skill.enabled"

  setup do
    previous = Settings.get(@setting_key)
    :ets.insert(:backplane_settings, {@setting_key, true})

    on_exit(fn ->
      :ets.insert(:backplane_settings, {@setting_key, previous})
      Skills.sync_registry(previous == true)
    end)

    :ok
  end

  test "adapts the existing skill tool definitions without changing their contract" do
    source_tools = SkillTool.tools()
    managed_tools = Skills.tools()

    assert Skills.prefix() == "skill"
    assert Enum.map(managed_tools, & &1.name) == Enum.map(source_tools, & &1.name)

    for {managed, source} <- Enum.zip(managed_tools, source_tools) do
      assert managed.name == source.name
      assert managed.description == source.description
      assert managed.input_schema == source.input_schema
      assert is_function(managed.handler, 1)
      refute Map.has_key?(managed, :module)
    end
  end

  test "delegates an enabled managed handler to the existing skill tool module" do
    list_tool = Enum.find(Skills.tools(), &(&1.name == "skill::list"))

    assert list_tool.handler.(%{}) == SkillTool.call(%{"_handler" => "list"})
  end

  test "rejects direct handler calls while disabled" do
    :ets.insert(:backplane_settings, {@setting_key, false})
    list_tool = Enum.find(Skills.tools(), &(&1.name == "skill::list"))

    assert {:error, %{code: "service_disabled", message: "Skills service is disabled"}} =
             list_tool.handler.(%{})
  end

  test "set_enabled/1 persists and synchronizes managed registry entries" do
    assert :ok = Skills.set_enabled(false)
    refute Skills.enabled?()
    assert :not_found = ToolRegistry.resolve("skill::list")

    assert :ok = Skills.set_enabled(true)
    assert Skills.enabled?()
    assert {:managed, handler} = ToolRegistry.resolve("skill::list")
    assert is_function(handler, 1)
  end
end
```

- [ ] **Step 3: Run the adapter tests and verify the expected failure**

Run:

```bash
devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_mcp/test/backplane/services/skills_test.exs
```

Expected: compilation fails because `Backplane.Services.Skills` is undefined.

- [ ] **Step 4: Declare the default-enabled setting**

Add this entry under `# Managed Services` in
`apps/backplane_system/lib/backplane/settings.ex`:

```elixir
"services.skill.enabled" => %{
  value: true,
  type: "boolean",
  desc: "Enable the managed Skills MCP service"
},
```

- [ ] **Step 5: Implement the managed adapter**

Create `apps/backplane_mcp/lib/backplane/services/skills.ex`:

```elixir
defmodule Backplane.Services.Skills do
  @moduledoc "Managed MCP service for archive-backed Skills tools."

  @behaviour Backplane.Services.ManagedService

  alias Backplane.Registry.ToolRegistry
  alias Backplane.Settings
  alias Backplane.Tools.Skill

  @setting_key "services.skill.enabled"

  @impl true
  def prefix, do: "skill"

  @impl true
  def enabled?, do: Settings.get(@setting_key) == true

  @impl true
  def tools do
    Enum.map(Skill.tools(), fn %{handler: handler} = tool ->
      tool
      |> Map.delete(:module)
      |> Map.put(:handler, fn args -> dispatch(handler, args) end)
    end)
  end

  @spec set_enabled(boolean()) :: :ok | {:error, term()}
  def set_enabled(enabled) when is_boolean(enabled) do
    with :ok <- Settings.set(@setting_key, enabled) do
      sync_registry(enabled)
    end
  end

  @spec sync_registry(boolean()) :: :ok
  def sync_registry(true) do
    ToolRegistry.deregister_managed(prefix())
    ToolRegistry.register_managed(prefix(), tools())
  end

  def sync_registry(false), do: ToolRegistry.deregister_managed(prefix())

  defp dispatch(handler, args) when is_atom(handler) and is_map(args) do
    if enabled?() do
      Skill.call(Map.put(args, "_handler", Atom.to_string(handler)))
    else
      {:error, %{code: "service_disabled", message: "Skills service is disabled"}}
    end
  end
end
```

- [ ] **Step 6: Run adapter and existing Skills implementation tests**

Run:

```bash
devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_mcp/test/backplane/services/skills_test.exs apps/backplane_mcp/test/backplane/tools/skill_test.exs
```

Expected: both test files pass with zero failures.

- [ ] **Step 7: Review scope and commit Task 1**

Run the required GitNexus change detection, then:

```bash
git diff --check
git diff -- apps/backplane_system/lib/backplane/settings.ex apps/backplane_mcp/lib/backplane/services/skills.ex apps/backplane_mcp/test/backplane/services/skills_test.exs
git add apps/backplane_system/lib/backplane/settings.ex apps/backplane_mcp/lib/backplane/services/skills.ex apps/backplane_mcp/test/backplane/services/skills_test.exs
git commit -m "feat(mcp): add managed skills service"
```

Expected: one commit containing only the setting, adapter, and adapter tests.

### Task 2: Move Skills Registration to the Managed Path

**Files:**
- Modify: `apps/backplane/lib/backplane/application.ex:7-72`
- Modify: `apps/backplane/test/backplane/application_test.exs:1-11`
- Modify: `apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs:19-125`

- [ ] **Step 1: Run impact analysis before editing startup symbols**

Run:

```text
gitnexus_impact({target: "register_native_tools", direction: "upstream", repo: "backplane", file_path: "apps/backplane/lib/backplane/application.ex"})
gitnexus_impact({target: "register_managed_services", direction: "upstream", repo: "backplane", file_path: "apps/backplane/lib/backplane/application.ex"})
```

Expected: review direct application-start callers. If either result is HIGH or
CRITICAL, report the blast radius before editing.

- [ ] **Step 2: Write the failing startup reconciliation test**

Replace `apps/backplane/test/backplane/application_test.exs` with:

```elixir
defmodule Backplane.ApplicationTest do
  use Backplane.DataCase, async: false

  alias Backplane.Registry.{Tool, ToolRegistry}
  alias Backplane.Settings

  @setting_key "services.skill.enabled"

  setup do
    previous_setting = Settings.get(@setting_key)
    previous_tools = :ets.tab2list(:backplane_tools)

    on_exit(fn ->
      :ets.insert(:backplane_settings, {@setting_key, previous_setting})
      :ets.delete_all_objects(:backplane_tools)
      :ets.insert(:backplane_tools, previous_tools)
    end)

    :ok
  end

  test "prep_stop returns state and does not crash" do
    state = %{some: :state}
    assert Backplane.Application.prep_stop(state) == state
  end

  test "managed reconciliation honors persisted Skills state and removes stale native rows" do
    ToolRegistry.register_native(%Tool{
      name: "test::sentinel",
      description: "Unrelated tool",
      input_schema: %{},
      origin: :native,
      module: __MODULE__,
      handler: nil
    })

    ToolRegistry.register_native(%Tool{
      name: "skill::stale",
      description: "Stale native Skills tool",
      input_schema: %{},
      origin: :native,
      module: Backplane.Tools.Skill,
      handler: :list
    })

    assert :ok = Settings.set(@setting_key, false)
    :ets.insert(:backplane_settings, {@setting_key, true})
    send(Settings, :seed_and_load)

    assert :ok = Backplane.Application.reconcile_managed_services()
    assert ToolRegistry.lookup("test::sentinel")
    refute Enum.any?(ToolRegistry.list_all(), &String.starts_with?(&1.name, "skill::"))

    assert :ok = Settings.set(@setting_key, true)
    :ets.insert(:backplane_settings, {@setting_key, false})
    send(Settings, :seed_and_load)

    assert :ok = Backplane.Application.reconcile_managed_services()

    skill_tools =
      ToolRegistry.list_all()
      |> Enum.filter(&String.starts_with?(&1.name, "skill::"))

    assert length(skill_tools) == 5
    assert Enum.all?(skill_tools, &(&1.origin == {:managed, "skill"}))
    assert ToolRegistry.lookup("test::sentinel")
  end
end
```

- [ ] **Step 3: Make the transport fixture expect managed Skills registration**

In `apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs`, add:

```elixir
@service_setting "services.skill.enabled"
```

Replace the setup block with this production-shaped registration:

```elixir
setup %{tmp_dir: tmp_dir} do
  previous_blob_root = Backplane.Settings.get(@blob_setting)
  previous_service_enabled = Backplane.Settings.get(@service_setting)
  :ets.insert(:backplane_settings, {@blob_setting, Path.join(tmp_dir, "blobs")})
  :ets.insert(:backplane_settings, {@service_setting, true})
  Backplane.Skills.Registry.refresh()

  alias Backplane.Registry.{Tool, ToolRegistry}

  :ets.delete_all_objects(:backplane_tools)

  for module <- [Backplane.Tools.Hub, Backplane.Tools.Admin], tool_def <- module.tools() do
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

  ToolRegistry.register_managed("skill", Backplane.Services.Skills.tools())

  ToolRegistry.register_native(%Tool{
    name: "public::echo",
    description: "Visible test tool",
    input_schema: %{"type" => "object", "properties" => %{}},
    origin: :native,
    module: __MODULE__.PublicTool,
    handler: nil
  })

  on_exit(fn ->
    :ets.insert(:backplane_settings, {@blob_setting, previous_blob_root})
    :ets.insert(:backplane_settings, {@service_setting, previous_service_enabled})
  end)

  :ok
end
```

Add these assertions to the `tools/list` describe block:

```elixir
test "registers skill tools with managed origin" do
  assert %{origin: {:managed, "skill"}} =
           Backplane.Registry.ToolRegistry.lookup("skill::search")
end

test "removes skill tools from discovery when the managed service is disabled" do
  assert :ok = Backplane.Services.Skills.set_enabled(false)

  resp = mcp_request("tools/list")
  names = Enum.map(resp["result"]["tools"], & &1["name"])

  refute Enum.any?(names, &String.starts_with?(&1, "skill::"))
  assert :not_found = Backplane.Registry.ToolRegistry.resolve("skill::list")
end
```

- [ ] **Step 4: Run startup and transport tests and verify the expected failure**

Run:

```bash
devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane/test/backplane/application_test.exs apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs
```

Expected: compilation fails because
`Backplane.Application.reconcile_managed_services/0` is undefined.

- [ ] **Step 5: Convert application startup to managed-only Skills registration**

In `apps/backplane/lib/backplane/application.ex`, change the aliases to:

```elixir
alias Backplane.Config.Validator
alias Backplane.Registry.{Tool, ToolRegistry}
alias Backplane.Tools.{Admin, Hub}
```

Change the native list to:

```elixir
tool_modules = [Hub, Admin]
```

In `start/2`, replace the private registration call with:

```elixir
register_native_tools()
reconcile_managed_services()
```

Replace `register_managed_services/0` with the public, internal reconciliation seam:

```elixir
@doc false
def reconcile_managed_services do
  Backplane.Settings.get_many([
    "services.day.enabled",
    "services.web.enabled",
    "services.skill.enabled"
  ])

  services = [
    Backplane.Services.Day,
    Backplane.Services.Web,
    Backplane.Services.Math,
    Backplane.Services.Skills
  ]

  Enum.each(services, fn service ->
    ToolRegistry.deregister_managed(service.prefix())

    if service.enabled?() do
      ToolRegistry.register_managed(service.prefix(), service.tools())
    end
  end)
end
```

The synchronous `get_many/1` call is the settings-load barrier. Deregistering each
prefix first removes stale native or managed rows, while conditional registration
ensures a persisted disabled state remains disabled after restart.

- [ ] **Step 6: Run startup-adjacent and transport tests**

Run:

```bash
devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane/test/backplane/application_test.exs apps/backplane_mcp/test/backplane/services/skills_test.exs apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs
```

Expected: all selected tests pass with zero failures; existing `skill::load` audit
tests remain green because the public name is unchanged.

- [ ] **Step 7: Review scope and commit Task 2**

Run the required GitNexus change detection, then:

```bash
git diff --check
git diff -- apps/backplane/lib/backplane/application.ex apps/backplane/test/backplane/application_test.exs apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs
git add apps/backplane/lib/backplane/application.ex apps/backplane/test/backplane/application_test.exs apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs
git commit -m "refactor(mcp): register skills as managed service"
```

Expected: one commit containing only startup and transport-fixture changes.

### Task 3: List and Toggle Skills in Managed MCP

**Files:**
- Modify: `apps/backplane_admin/lib/backplane/admin/live/managed_live.ex:8-105`
- Modify: `apps/backplane_admin/test/backplane/admin/live/managed_live_test.exs:1-90`

- [ ] **Step 1: Run impact analysis before editing the Managed MCP index**

Run:

```text
gitnexus_impact({target: "handle_event", direction: "upstream", repo: "backplane", file_path: "apps/backplane_admin/lib/backplane/admin/live/managed_live.ex"})
gitnexus_impact({target: "load_services", direction: "upstream", repo: "backplane", file_path: "apps/backplane_admin/lib/backplane/admin/live/managed_live.ex"})
```

Expected: impact is confined to the Managed MCP LiveView. Report before editing if
GitNexus returns HIGH or CRITICAL.

- [ ] **Step 2: Write failing index and lifecycle tests**

Add these aliases and setup to
`apps/backplane_admin/test/backplane/admin/live/managed_live_test.exs`:

```elixir
alias Backplane.Math.Config
alias Backplane.Registry.ToolRegistry
alias Backplane.Services.Skills
alias Backplane.Settings

@skills_setting "services.skill.enabled"

setup do
  previous = Settings.get(@skills_setting)

  on_exit(fn ->
    :ets.insert(:backplane_settings, {@skills_setting, previous})
    Skills.sync_registry(previous == true)
  end)

  :ok
end
```

Add the tests:

```elixir
test "renders the managed Skills service and its tools", %{conn: conn} do
  assert :ok = Skills.set_enabled(true)

  {:ok, _view, html} = live(conn, "/mcp/managed")

  assert html =~ "Skills"
  assert html =~ "skill::"
  assert html =~ "skill::search"
  assert html =~ "skill::load"
  assert html =~ "skill::list"
  assert html =~ "skill::download"
  assert html =~ "skill::publish"
  assert html =~ ~s(href="/mcp/managed/skill")
  assert html =~ ~s(href="/mcp/managed/skill/tool/list")
end

test "toggles the Skills setting and registry entries", %{conn: conn} do
  assert :ok = Skills.set_enabled(true)
  {:ok, view, _html} = live(conn, "/mcp/managed")

  view
  |> element("[phx-value-prefix='skill']")
  |> render_click()

  refute Skills.enabled?()
  assert :not_found = ToolRegistry.resolve("skill::list")

  view
  |> element("[phx-value-prefix='skill']")
  |> render_click()

  assert Skills.enabled?()
  assert {:managed, _handler} = ToolRegistry.resolve("skill::list")
end
```

Extend `"links managed services to settings pages"` with:

```elixir
assert html =~ ~s(href="/mcp/managed/skill")
```

- [ ] **Step 3: Run the index test and verify it fails**

Run:

```bash
devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/live/managed_live_test.exs
```

Expected: failures show that Skills is missing from the service catalog and toggle.

- [ ] **Step 4: Add Skills to the Managed MCP index and toggle**

Add this descriptor to `@managed_services` in
`apps/backplane_admin/lib/backplane/admin/live/managed_live.ex`:

```elixir
%{
  module: Backplane.Services.Skills,
  name: "Skills",
  description: "Search, load, download, and publish archive-backed agent skills",
  setting_key: "services.skill.enabled"
},
```

Add the setter clause before the Math clause:

```elixir
defp set_enabled(Backplane.Services.Skills = mod, enabled), do: mod.set_enabled(enabled)
```

The existing `refresh_managed_registry/0`, `sync_registry/2`, and template then
handle Skills without additional rendering branches.

- [ ] **Step 5: Run the index tests**

Run:

```bash
devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/live/managed_live_test.exs
```

Expected: all index tests pass with zero failures.

- [ ] **Step 6: Review scope and commit Task 3**

Run the required GitNexus change detection, then:

```bash
git diff --check
git diff -- apps/backplane_admin/lib/backplane/admin/live/managed_live.ex apps/backplane_admin/test/backplane/admin/live/managed_live_test.exs
git add apps/backplane_admin/lib/backplane/admin/live/managed_live.ex apps/backplane_admin/test/backplane/admin/live/managed_live_test.exs
git commit -m "feat(admin): manage skills MCP service"
```

Expected: one commit containing only the Managed MCP index and its tests.

### Task 4: Add Skills Debug and Tool Detail Routes

**Files:**
- Modify: `apps/backplane_admin/lib/backplane/admin/live/managed_service_settings_live.ex:9-28`
- Modify: `apps/backplane_admin/test/backplane/admin/live/managed_service_settings_live_test.exs`
- Modify: `apps/backplane_admin/lib/backplane/admin/live/managed_tool_detail_live.ex:11-30`
- Create: `apps/backplane_admin/test/backplane/admin/live/managed_tool_detail_live_test.exs`

- [ ] **Step 1: Run impact analysis before editing route handlers**

Run:

```text
gitnexus_impact({target: "handle_params", direction: "upstream", repo: "backplane", file_path: "apps/backplane_admin/lib/backplane/admin/live/managed_service_settings_live.ex"})
gitnexus_impact({target: "handle_params", direction: "upstream", repo: "backplane", file_path: "apps/backplane_admin/lib/backplane/admin/live/managed_tool_detail_live.ex"})
```

Expected: impact is limited to the two existing `/mcp/managed/:prefix` routes.
Report before editing if either result is HIGH or CRITICAL.

- [ ] **Step 2: Write failing Skills debug tests**

Append to
`apps/backplane_admin/test/backplane/admin/live/managed_service_settings_live_test.exs`:

```elixir
test "Skills debug tab calls an enabled tool", %{conn: conn} do
  previous = Settings.get("services.skill.enabled")
  :ets.insert(:backplane_settings, {"services.skill.enabled", true})
  on_exit(fn -> :ets.insert(:backplane_settings, {"services.skill.enabled", previous}) end)

  {:ok, view, html} = live(conn, "/mcp/managed/skill?tab=debug")

  assert html =~ "Skills Debug"
  assert html =~ "skill::search"
  assert html =~ "skill::list"
  assert html =~ "JSON Argument Schema"

  html =
    view
    |> form("#managed-tool-debug-form", %{
      "debug" => %{"tool_name" => "skill::list", "arguments" => "{}"}
    })
    |> render_submit()

  assert html =~ "Tool Result"
end

test "Skills debug tab rejects calls while disabled", %{conn: conn} do
  previous = Settings.get("services.skill.enabled")
  :ets.insert(:backplane_settings, {"services.skill.enabled", false})
  on_exit(fn -> :ets.insert(:backplane_settings, {"services.skill.enabled", previous}) end)

  {:ok, view, _html} = live(conn, "/mcp/managed/skill?tab=debug")

  html =
    view
    |> form("#managed-tool-debug-form", %{
      "debug" => %{"tool_name" => "skill::list", "arguments" => "{}"}
    })
    |> render_submit()

  assert html =~ "Tool Error"
  assert html =~ "Skills service is disabled"
end
```

Create
`apps/backplane_admin/test/backplane/admin/live/managed_tool_detail_live_test.exs`:

```elixir
defmodule Backplane.Admin.ManagedToolDetailLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Services.Skills
  alias Backplane.Settings

  @setting_key "services.skill.enabled"

  setup do
    previous = Settings.get(@setting_key)
    :ets.insert(:backplane_settings, {@setting_key, true})

    on_exit(fn ->
      :ets.insert(:backplane_settings, {@setting_key, previous})
      Skills.sync_registry(previous == true)
    end)

    :ok
  end

  test "renders and invokes a managed Skills tool", %{conn: conn} do
    {:ok, view, html} = live(conn, "/mcp/managed/skill/tool/list")

    assert html =~ "skill::list"
    assert html =~ "List all available skills"
    assert html =~ "Input Schema"
    assert html =~ "Test Tool"

    html =
      view
      |> form("#tool-test-form", %{"test" => %{"arguments" => "{}"}})
      |> render_submit()

    assert html =~ "Result"
  end

  test "rejects a detail-page call after Skills is disabled", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mcp/managed/skill/tool/list")
    :ets.insert(:backplane_settings, {@setting_key, false})

    html =
      view
      |> form("#tool-test-form", %{"test" => %{"arguments" => "{}"}})
      |> render_submit()

    assert html =~ "Error"
    assert html =~ "Skills service is disabled"
  end
end
```

- [ ] **Step 3: Run the debug/detail tests and verify they fail on unknown service**

Run:

```bash
devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/live/managed_service_settings_live_test.exs apps/backplane_admin/test/backplane/admin/live/managed_tool_detail_live_test.exs
```

Expected: the new cases fail because prefix `skill` is absent from both service lists.

- [ ] **Step 4: Add Skills to both debug/detail service catalogs**

Add this map to `@services` in both
`managed_service_settings_live.ex` and `managed_tool_detail_live.ex`:

```elixir
%{
  module: Backplane.Services.Skills,
  name: "Skills",
  prefix: "skill",
  description: "Search, load, download, and publish archive-backed agent skills"
},
```

No new HEEX branch or handler clause is needed: the adapter returns one-argument
function handlers compatible with both existing debug runners.

- [ ] **Step 5: Run all admin Managed MCP tests**

Run:

```bash
devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/live/managed_live_test.exs apps/backplane_admin/test/backplane/admin/live/managed_service_settings_live_test.exs apps/backplane_admin/test/backplane/admin/live/managed_tool_detail_live_test.exs
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 6: Review scope and commit Task 4**

Run the required GitNexus change detection, then:

```bash
git diff --check
git diff -- apps/backplane_admin/lib/backplane/admin/live/managed_service_settings_live.ex apps/backplane_admin/lib/backplane/admin/live/managed_tool_detail_live.ex apps/backplane_admin/test/backplane/admin/live/managed_service_settings_live_test.exs apps/backplane_admin/test/backplane/admin/live/managed_tool_detail_live_test.exs
git add apps/backplane_admin/lib/backplane/admin/live/managed_service_settings_live.ex apps/backplane_admin/lib/backplane/admin/live/managed_tool_detail_live.ex apps/backplane_admin/test/backplane/admin/live/managed_service_settings_live_test.exs apps/backplane_admin/test/backplane/admin/live/managed_tool_detail_live_test.exs
git commit -m "feat(admin): debug managed skills tools"
```

Expected: one commit containing only Skills debug/detail routing and tests.

### Task 5: Final Scoped Verification

**Files:**
- Verify all files changed in Tasks 1-4; make no unrelated edits.

- [ ] **Step 1: Format only the affected files**

Run:

```bash
devenv shell -- mix format \
  apps/backplane_system/lib/backplane/settings.ex \
  apps/backplane/lib/backplane/application.ex \
  apps/backplane/test/backplane/application_test.exs \
  apps/backplane_mcp/lib/backplane/services/skills.ex \
  apps/backplane_mcp/test/backplane/services/skills_test.exs \
  apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs \
  apps/backplane_admin/lib/backplane/admin/live/managed_live.ex \
  apps/backplane_admin/lib/backplane/admin/live/managed_service_settings_live.ex \
  apps/backplane_admin/lib/backplane/admin/live/managed_tool_detail_live.ex \
  apps/backplane_admin/test/backplane/admin/live/managed_live_test.exs \
  apps/backplane_admin/test/backplane/admin/live/managed_service_settings_live_test.exs \
  apps/backplane_admin/test/backplane/admin/live/managed_tool_detail_live_test.exs
```

Expected: the formatter exits successfully and touches no out-of-scope file.

- [ ] **Step 2: Run the complete focused regression set serially**

Run:

```bash
devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test \
  apps/backplane/test/backplane/application_test.exs \
  apps/backplane_mcp/test/backplane/services/skills_test.exs \
  apps/backplane_mcp/test/backplane/tools/skill_test.exs \
  apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs \
  apps/backplane_admin/test/backplane/admin/live/managed_live_test.exs \
  apps/backplane_admin/test/backplane/admin/live/managed_service_settings_live_test.exs \
  apps/backplane_admin/test/backplane/admin/live/managed_tool_detail_live_test.exs
```

Expected: all focused tests pass with zero failures. Module-redefinition warnings
from umbrella test support are pre-existing and do not change the success criterion.

- [ ] **Step 3: Verify formatting, scope, and graph impact**

Run:

```bash
devenv shell -- mix format --check-formatted \
  apps/backplane_system/lib/backplane/settings.ex \
  apps/backplane/lib/backplane/application.ex \
  apps/backplane/test/backplane/application_test.exs \
  apps/backplane_mcp/lib/backplane/services/skills.ex \
  apps/backplane_mcp/test/backplane/services/skills_test.exs \
  apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs \
  apps/backplane_admin/lib/backplane/admin/live/managed_live.ex \
  apps/backplane_admin/lib/backplane/admin/live/managed_service_settings_live.ex \
  apps/backplane_admin/lib/backplane/admin/live/managed_tool_detail_live.ex \
  apps/backplane_admin/test/backplane/admin/live/managed_live_test.exs \
  apps/backplane_admin/test/backplane/admin/live/managed_service_settings_live_test.exs \
  apps/backplane_admin/test/backplane/admin/live/managed_tool_detail_live_test.exs
git diff --check main...HEAD
git status --short --branch
git diff --stat main...HEAD
```

Run `gitnexus_detect_changes({repo: "backplane", scope: "compare", base_ref: "main"})`
and compare its result with the direct diff. Expected: only managed Skills service,
startup registration, transport fixtures, admin Managed MCP views/tests, and the
approved design/plan documents are present.

- [ ] **Step 4: Commit any formatter-only corrections**

If Step 1 changed tracked files after the four feature commits, run:

```bash
git add apps/backplane_system/lib/backplane/settings.ex apps/backplane/lib/backplane/application.ex apps/backplane/test/backplane/application_test.exs apps/backplane_mcp/lib/backplane/services/skills.ex apps/backplane_mcp/test/backplane/services/skills_test.exs apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs apps/backplane_admin/lib/backplane/admin/live/managed_live.ex apps/backplane_admin/lib/backplane/admin/live/managed_service_settings_live.ex apps/backplane_admin/lib/backplane/admin/live/managed_tool_detail_live.ex apps/backplane_admin/test/backplane/admin/live/managed_live_test.exs apps/backplane_admin/test/backplane/admin/live/managed_service_settings_live_test.exs apps/backplane_admin/test/backplane/admin/live/managed_tool_detail_live_test.exs
git commit -m "style(mcp): format managed skills service"
```

Expected: either no additional commit is needed or one formatter-only commit is
created. Do not push, merge, or modify the primary worktree without a separate user
request.
