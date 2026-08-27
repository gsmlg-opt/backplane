# Honest Green PR Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore a reproducible pull-request gate in which all 17 Backplane umbrella applications test independently and Compile, Format, Credo, and Dialyzer report no unhandled findings.

**Architecture:** Keep `BackplaneDataCase` as the repository-agnostic sandbox primitive while each application owns its test case and fixtures. Repair analyzer findings at their source, retain only exact generated ignores for verified OTP 28 opaque false positives, and replace the partial Test workflow with an isolated application matrix.

**Tech Stack:** Elixir 1.18.4, Erlang/OTP 28.5.0.5 in GitHub Actions, Ecto SQL Sandbox, ExUnit, Credo, Dialyzer/Dialyxir 1.4.7, GitHub Actions, PostgreSQL 17, pgvector 0.8.0, Rust 1.95.0.

---

## Preflight Rules

- Work only in `/home/gao/Workspace/gsmlg-opt/backplane/.trees/green-pr-gate` on `codex/green-pr-gate`.
- Do not modify the original checkout's dirty `AGENTS.md`.
- Before editing a function or module, run GitNexus upstream impact with its exact `file_path`; report `HIGH` or `CRITICAL` results before editing. GitNexus may return `UNKNOWN` for Elixir, in which case direct source, focused tests, and diffs are authoritative.
- Before every commit, run `gitnexus_detect_changes({repo: "backplane", scope: "all"})`, `git diff --check`, and inspect `git status --short`.
- `unbuffer` is not installed in this devenv. Use `devenv shell -- mix ...` exactly as shown.
- Keep the worktree-local PostgreSQL process running with `devenv up -d postgres`; verify it with `devenv processes status postgres` and `devenv shell -- sh -c 'pg_isready -h "$PGHOST" -d backplane_test'`.

### Task 1: Migrate tests to application-owned DataCases

**Files:**
- Create: `apps/backplane_api/test/support/data_case.ex`
- Modify: `apps/backplane_admin/test/support/live_case.ex`
- Modify: `apps/backplane_api/test/support/channel_case.ex`
- Modify: `apps/backplane_api/test/support/conn_case.ex`
- Modify: `apps/backplane_api/test/backplane/api/host_agent_memory_sync_test.exs`
- Modify: `apps/backplane_mcp/test/support/conn_case.ex`
- Modify: the exact Llama, MCP, Memory, Skills, and System tests listed in Step 4

- [ ] **Step 1: Run impact analysis for the case modules**

Run these MCP calls before edits:

```text
gitnexus_impact({target: "Backplane.DataCase", file_path: "apps/backplane/test/support/data_case.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "BackplaneLlama.DataCase", file_path: "apps/backplane_llama/test/support/data_case.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "BackplaneMcp.DataCase", file_path: "apps/backplane_mcp/test/support/data_case.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "Backplane.Memory.DataCase", file_path: "apps/backplane_memory/test/support/data_case.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "BackplaneSkills.DataCase", file_path: "apps/backplane_skills/test/support/data_case.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "BackplaneSystem.DataCase", file_path: "apps/backplane_system/test/support/data_case.ex", direction: "upstream", includeTests: true})
```

Expected: direct impact is limited to test modules; if GitNexus returns `UNKNOWN`, continue with the already captured `rg` inventory.

- [ ] **Step 2: Reproduce the independent Memory failure**

Run:

```bash
devenv shell -- mix do --app backplane_memory cmd mix test test/backplane/memory/query_log_privacy_test.exs
```

Expected: FAIL compiling `Backplane.Memory.QueryLogPrivacyTest` because `Backplane.DataCase` is unavailable.

- [ ] **Step 3: Add the API-local DB case**

Create `apps/backplane_api/test/support/data_case.ex`:

```elixir
defmodule Backplane.Api.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Backplane.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Backplane.Api.DataCase
    end
  end

  setup tags do
    BackplaneDataCase.setup_sandbox(Backplane.Repo, tags)
    :ok
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
```

Change `apps/backplane_api/test/backplane/api/host_agent_memory_sync_test.exs` to:

```elixir
use Backplane.Api.DataCase, async: false
```

- [ ] **Step 4: Replace every cross-application DataCase use**

Make these exact replacements while preserving each file's `async:` value:

```text
BackplaneLlama.DataCase
  apps/backplane_llama/test/backplane/embedding_test.exs
  apps/backplane_llama/test/backplane/jobs/usage_retention_test.exs
  apps/backplane_llama/test/backplane/jobs/usage_writer_test.exs
  apps/backplane_llama/test/backplane/llm/api_router_test.exs
  apps/backplane_llama/test/backplane/llm/auto_model_resolver_test.exs
  apps/backplane_llama/test/backplane/llm/credential_plug_openai_codex_test.exs
  apps/backplane_llama/test/backplane/llm/credential_plug_test.exs
  apps/backplane_llama/test/backplane/llm/model_alias_test.exs
  apps/backplane_llama/test/backplane/llm/model_discovery_proxy_test.exs
  apps/backplane_llama/test/backplane/llm/model_resolver_test.exs
  apps/backplane_llama/test/backplane/llm/provider_test.exs
  apps/backplane_llama/test/backplane/llm/proxy_plug_test.exs
  apps/backplane_llama/test/backplane/llm/resource_authorization_test.exs
  apps/backplane_llama/test/backplane/llm/route_loader_test.exs
  apps/backplane_llama/test/backplane/llm/router_test.exs
  apps/backplane_llama/test/backplane/llm/streaming_integration_test.exs
  apps/backplane_llama/test/backplane/llm/usage_collector_test.exs
  apps/backplane_llama/test/backplane/llm/usage_query_test.exs

BackplaneMcp.DataCase
  apps/backplane_mcp/test/backplane/hub/discover_test.exs
  apps/backplane_mcp/test/backplane/math/config/record_test.exs
  apps/backplane_mcp/test/backplane/math/config_test.exs
  apps/backplane_mcp/test/backplane/math/registration_test.exs
  apps/backplane_mcp/test/backplane/math/router_test.exs
  apps/backplane_mcp/test/backplane/proxy/auth_injector_test.exs
  apps/backplane_mcp/test/backplane/proxy/protocol_client_test.exs
  apps/backplane_mcp/test/backplane/proxy/upstream_test.exs
  apps/backplane_mcp/test/backplane/services/math_test.exs
  apps/backplane_mcp/test/backplane/services/skills_test.exs
  apps/backplane_mcp/test/backplane/services/web_live_search_proxy_test.exs
  apps/backplane_mcp/test/backplane/services/web_live_search_test.exs
  apps/backplane_mcp/test/backplane/services/web_search_test.exs
  apps/backplane_mcp/test/backplane/services/web_x_search_test.exs
  apps/backplane_mcp/test/backplane/tools/admin_test.exs
  apps/backplane_mcp/test/backplane/tools/hub_test.exs
  apps/backplane_mcp/test/backplane/tools/skill_test.exs
  apps/backplane_mcp/test/backplane/transport/health_check_test.exs

Backplane.Memory.DataCase
  apps/backplane_memory/test/backplane/memory/lessons_admin_test.exs
  apps/backplane_memory/test/backplane/memory/query_log_privacy_test.exs
  apps/backplane_memory/test/backplane/memory/workers/pipeline_telemetry_test.exs

BackplaneSkills.DataCase
  apps/backplane_skills/test/backplane/skills/agent_manage_test.exs
  apps/backplane_skills/test/backplane/skills/api_router_test.exs
  apps/backplane_skills/test/backplane/skills/assignments_test.exs
  apps/backplane_skills/test/backplane/skills/desired_state_test.exs
  apps/backplane_skills/test/backplane/skills/export_test.exs
  apps/backplane_skills/test/backplane/skills/hosts_test.exs
  apps/backplane_skills/test/backplane/skills/ingest_test.exs
  apps/backplane_skills/test/backplane/skills/registry_test.exs
  apps/backplane_skills/test/backplane/skills/search_reranking_test.exs
  apps/backplane_skills/test/backplane/skills/search_test.exs
  apps/backplane_skills/test/backplane/skills/skill_test.exs
  apps/backplane_skills/test/backplane/skills/sources/database_test.exs
  apps/backplane_skills/test/backplane/skills/sync_statuses_test.exs

BackplaneSystem.DataCase
  apps/backplane_system/test/backplane/accounts/accounts_test.exs
  apps/backplane_system/test/backplane/accounts/auth_provider_test.exs
  apps/backplane_system/test/backplane/accounts/boruta_foundation_test.exs
  apps/backplane_system/test/backplane/accounts/federated_login_test.exs
  apps/backplane_system/test/backplane/accounts/resource_owners_test.exs
  apps/backplane_system/test/backplane/audit/pruner_test.exs
  apps/backplane_system/test/backplane/audit/tool_call_log_test.exs
  apps/backplane_system/test/backplane/audit_test.exs
  apps/backplane_system/test/backplane/clients/client_test.exs
  apps/backplane_system/test/backplane/clients_test.exs
```

- [ ] **Step 5: Remove support-case coupling to the core test module**

In the four support cases below, replace `Backplane.DataCase.setup_sandbox(tags)` with the shared primitive:

```elixir
BackplaneDataCase.setup_sandbox(Backplane.Repo, tags)
```

Files:

```text
apps/backplane_admin/test/support/live_case.ex
apps/backplane_api/test/support/channel_case.ex
apps/backplane_api/test/support/conn_case.ex
apps/backplane_mcp/test/support/conn_case.ex
```

- [ ] **Step 6: Prove the ownership migration**

Run:

```bash
devenv shell -- mix do --app backplane_memory cmd mix test test/backplane/memory/query_log_privacy_test.exs test/backplane/memory/lessons_admin_test.exs test/backplane/memory/workers/pipeline_telemetry_test.exs
devenv shell -- mix do --app backplane_api cmd mix test test/backplane/api/host_agent_memory_sync_test.exs
devenv shell -- mix do --app backplane_llama cmd mix test
devenv shell -- mix do --app backplane_mcp cmd mix test
devenv shell -- mix do --app backplane_skills cmd mix test
devenv shell -- mix do --app backplane_system cmd mix test
devenv shell -- mix do --app backplane_admin cmd mix test
rg -n 'Backplane\.DataCase' apps --glob '*.ex' --glob '*.exs'
```

Expected: all focused suites PASS. The final `rg` output contains only the core Backplane case/tests and the historical sentence in `apps/backplane_data_case/lib/backplane_data_case.ex`.

- [ ] **Step 7: Review and commit the DataCase migration**

Run GitNexus change detection and diff checks, then:

```bash
git add apps/backplane_admin/test apps/backplane_api/test apps/backplane_llama/test apps/backplane_mcp/test apps/backplane_memory/test apps/backplane_skills/test apps/backplane_system/test
git commit -m "test(umbrella): use app-owned data cases"
```

### Task 2: Isolate compiled fixture ownership

**Files:**
- Move: `apps/backplane/test/support/fixtures/` → `apps/backplane/test/fixtures/`
- Move: `apps/backplane_mcp/test/support/fixtures/` → `apps/backplane_mcp/test/fixtures/`
- Move: `apps/backplane_skills/test/support/fixtures/` → `apps/backplane_skills/test/fixtures/`
- Modify: `apps/backplane/test/support/fixtures.ex`
- Modify: `apps/backplane_mcp/test/support/fixtures.ex`
- Modify: `apps/backplane_skills/test/support/fixtures.ex`
- Create: `apps/backplane_admin/test/support/fixtures.ex`
- Create: `apps/backplane_api/test/support/fixtures.ex`
- Create: `apps/backplane_system/test/support/fixtures.ex`
- Modify: exact caller files listed in Step 5
- Modify: `AGENTS.md`

- [ ] **Step 1: Run fixture-module impact analysis**

```text
gitnexus_impact({target: "Backplane.Fixtures", file_path: "apps/backplane/test/support/fixtures.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "Backplane.Fixtures", file_path: "apps/backplane_mcp/test/support/fixtures.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "Backplane.Fixtures", file_path: "apps/backplane_skills/test/support/fixtures.ex", direction: "upstream", includeTests: true})
```

Expected: callers are test-only; direct source search remains authoritative if GitNexus cannot distinguish the duplicate module definitions.

- [ ] **Step 2: Reproduce compiled fixture collisions**

Run:

```bash
devenv shell -- env MIX_ENV=test mix compile --force --warnings-as-errors
```

Expected: FAIL with redefinition warnings for `Backplane.Fixtures`, `Example.Documented`, `Example.Undocumented`, `Example.Outer`, and its nested modules.

- [ ] **Step 3: Move parser samples out of compiled support paths**

Run these recoverable Git moves:

```bash
git mv apps/backplane/test/support/fixtures apps/backplane/test/fixtures
git mv apps/backplane_mcp/test/support/fixtures apps/backplane_mcp/test/fixtures
git mv apps/backplane_skills/test/support/fixtures apps/backplane_skills/test/fixtures
```

In all three `test/support/fixtures.ex` helpers, change:

```elixir
@fixtures_dir Path.expand("../fixtures", __DIR__)
```

- [ ] **Step 4: Give executable helper modules application-owned names**

Keep the core helper as `Backplane.Fixtures`. Change the other two module declarations:

```elixir
defmodule BackplaneMcp.Fixtures do
```

```elixir
defmodule BackplaneSkills.Fixtures do
```

- [ ] **Step 5: Update exact fixture callers and add minimal local helpers**

Use `BackplaneMcp.Fixtures` in:

```text
apps/backplane_mcp/test/backplane/tools/admin_test.exs
apps/backplane_mcp/test/backplane/tools/skill_test.exs
apps/backplane_mcp/test/backplane/transport/managed_prompt_test.exs
apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs
apps/backplane_mcp/test/backplane/transport/modern_mcp_test.exs
apps/backplane_mcp/test/backplane/transport/router_test.exs
```

Use `BackplaneSkills.Fixtures` in:

```text
apps/backplane_skills/test/backplane/skills/search_reranking_test.exs
apps/backplane_skills/test/backplane/skills/skill_test.exs
```

Create `apps/backplane_admin/test/support/fixtures.ex` and `apps/backplane_system/test/support/fixtures.ex`, changing only the module name between the two files:

```elixir
defmodule Backplane.Admin.Fixtures do
  alias Backplane.Repo

  def insert_client(overrides \\ []) do
    token = Keyword.get(overrides, :token, "bp_test_#{System.unique_integer([:positive])}")
    attrs = %{
      name: Keyword.get(overrides, :name, "test-client-#{System.unique_integer([:positive])}"),
      token_hash: Bcrypt.hash_pwd_salt(token),
      scopes: Keyword.get(overrides, :scopes, ["*"]),
      active: Keyword.get(overrides, :active, true),
      metadata: Keyword.get(overrides, :metadata, %{})
    }

    client =
      %Backplane.Clients.Client{}
      |> Backplane.Clients.Client.changeset(attrs)
      |> Repo.insert!()

    {client, token}
  end
end
```

For the System file, the first line is:

```elixir
defmodule BackplaneSystem.Fixtures do
```

Create `apps/backplane_api/test/support/fixtures.ex`:

```elixir
defmodule Backplane.Api.Fixtures do
  alias Backplane.Repo
  alias Backplane.Skills.Skill

  def insert_skill(overrides \\ []) do
    name = Keyword.get(overrides, :name, "test-skill-#{System.unique_integer([:positive])}")
    id = Keyword.get(overrides, :id, name)
    content = Keyword.get(overrides, :content, "# #{name}\n\nSkill content here.")

    attrs = %{
      id: id,
      slug: Keyword.get(overrides, :slug, name),
      name: name,
      description: Keyword.get(overrides, :description, "A test skill"),
      tags: Keyword.get(overrides, :tags, ["test"]),
      content: content,
      content_hash:
        Keyword.get(overrides, :content_hash, :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)),
      enabled: Keyword.get(overrides, :enabled, true),
      archive_ref: Keyword.get(overrides, :archive_ref),
      source_kind: Keyword.get(overrides, :source_kind)
    }

    Repo.insert!(Skill.changeset(%Skill{}, attrs))
  end
end
```

Update callers:

```text
apps/backplane_admin/test/backplane/admin/live/clients_live_test.exs
  import Backplane.Admin.Fixtures

apps/backplane_api/test/backplane/api/host_agent_sync_e2e_test.exs
  alias Backplane.Api.Fixtures

apps/backplane_system/test/backplane/clients_test.exs
  import BackplaneSystem.Fixtures
```

- [ ] **Step 6: Correct the repository testing convention**

Replace the stale DataCase bullet in `AGENTS.md` with:

```markdown
- `BackplaneDataCase` owns the repository-agnostic `setup_sandbox/2` primitive.
- Each umbrella app owns its DataCase/ConnCase/LiveCase wrapper and domain test helpers; tests must not depend on another app's `test/support` modules.
- `Backplane.DataCase` belongs only to the `backplane` app. Use the owning app's case when running child-app tests independently.
```

- [ ] **Step 7: Verify fixture isolation**

Run:

```bash
devenv shell -- env MIX_ENV=test mix compile --force --warnings-as-errors
devenv shell -- mix do --app backplane_admin cmd mix test test/backplane/admin/live/clients_live_test.exs
devenv shell -- mix do --app backplane_api cmd mix test test/backplane/api/host_agent_sync_e2e_test.exs
devenv shell -- mix do --app backplane_system cmd mix test test/backplane/clients_test.exs
devenv shell -- mix do --app backplane_mcp cmd mix test test/backplane/tools/admin_test.exs test/backplane/tools/skill_test.exs test/backplane/transport/managed_prompt_test.exs test/backplane/transport/mcp_handler_test.exs test/backplane/transport/modern_mcp_test.exs test/backplane/transport/router_test.exs
devenv shell -- mix do --app backplane_skills cmd mix test test/backplane/skills/search_reranking_test.exs test/backplane/skills/skill_test.exs
rg -n '^\s*defmodule Example\.' apps/*/test/support --glob '*.ex'
```

Expected: compile and tests PASS; the final `rg` returns no matches.

- [ ] **Step 8: Review and commit fixture ownership**

Run required GitNexus/diff checks, then:

```bash
git add AGENTS.md apps/backplane/test apps/backplane_admin/test apps/backplane_api/test apps/backplane_mcp/test apps/backplane_skills/test apps/backplane_system/test
git commit -m "test(umbrella): isolate test fixture ownership"
```

### Task 3: Centralize Memory numeric contracts

**Files:**
- Create: `apps/backplane_memory/lib/backplane/memory/numeric.ex`
- Create: `apps/backplane_memory/test/backplane/memory/numeric_test.exs`
- Modify: `apps/backplane_memory/lib/backplane/memory/memories/search.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/recall/candidate.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/recall/packer.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/recall/post_fusion.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/recall/query_plan.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/recall/reranker.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/recall/store.ex`
- Modify: `apps/backplane_memory/test/backplane/memory/recall/query_plan_test.exs`

- [ ] **Step 1: Run impact analysis for every numeric caller**

Use upstream impact with the exact file path for `apply_reranking`, `unit_float`, `valid_channel_score?`, `nonnegative_finite?`, `finite?`, `numeric`, and `finite_number?`. Report any high-risk result before edits.

- [ ] **Step 2: Write the failing numeric contract tests**

Create `apps/backplane_memory/test/backplane/memory/numeric_test.exs`:

```elixir
defmodule Backplane.Memory.NumericTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Numeric

  test "accepts only numbers in the inclusive unit interval" do
    assert Numeric.unit_interval?(0)
    assert Numeric.unit_interval?(0.5)
    assert Numeric.unit_interval?(1)
    refute Numeric.unit_interval?(-0.1)
    refute Numeric.unit_interval?(1.1)
    refute Numeric.unit_interval?("0.5")
  end

  test "preserves the bounded-float and unbounded-integer score contract" do
    assert Numeric.nonnegative_score?(0)
    assert Numeric.nonnegative_score?(Integer.pow(10, 400))
    assert Numeric.nonnegative_score?(1.0e308)
    refute Numeric.nonnegative_score?(-1)
    refute Numeric.nonnegative_score?(1.1e308)
    refute Numeric.nonnegative_score?(:invalid)
  end

  test "normalizes integers and floats without accepting other terms" do
    assert {:ok, 2.0} = Numeric.to_float(2)
    assert {:ok, 2.5} = Numeric.to_float(2.5)
    assert :error = Numeric.to_float("2")
  end
end
```

Add to `query_plan_test.exs`:

```elixir
test "rejects nonnumeric channel weights" do
  assert {:error, {:invalid, :channel_weights}} =
           QueryPlan.new(%{"channel_weights" => %{"fts" => "one"}}, @partition)
end
```

- [ ] **Step 3: Run the new tests red**

```bash
devenv shell -- mix test apps/backplane_memory/test/backplane/memory/numeric_test.exs apps/backplane_memory/test/backplane/memory/recall/query_plan_test.exs
```

Expected: FAIL because `Backplane.Memory.Numeric` does not exist.

- [ ] **Step 4: Implement the minimal numeric module**

Create `apps/backplane_memory/lib/backplane/memory/numeric.ex`:

```elixir
defmodule Backplane.Memory.Numeric do
  @moduledoc false

  @max_float_score 1.0e308

  @spec unit_interval?(term()) :: boolean()
  def unit_interval?(value) when is_number(value), do: value >= 0 and value <= 1
  def unit_interval?(_value), do: false

  @spec nonnegative_score?(term()) :: boolean()
  def nonnegative_score?(value) when is_integer(value), do: value >= 0

  def nonnegative_score?(value) when is_float(value),
    do: value >= 0 and value <= @max_float_score

  def nonnegative_score?(_value), do: false

  @spec to_float(term()) :: {:ok, float()} | :error
  def to_float(value) when is_integer(value), do: {:ok, value / 1}
  def to_float(value) when is_float(value), do: {:ok, value}
  def to_float(_value), do: :error
end
```

- [ ] **Step 5: Route callers through explicit domain predicates**

Apply these exact behaviors:

```text
Memories.Search: validate provider scores with Numeric.unit_interval?/1, then retain score / 1 normalization.
Recall.Reranker: unit scores use Numeric.unit_interval?/1; nonnegative result scores use Numeric.nonnegative_score?/1.
Recall.Packer: replace nonnegative_finite?/1 with Numeric.nonnegative_score?/1.
Recall.Candidate: unit_float/2 uses Numeric.to_float/1 followed by Numeric.unit_interval?/1; channel score values use is_number/1.
Recall.QueryPlan: numeric/1 delegates to Numeric.to_float/1 and raises ArgumentError on :error.
Recall.Store: validate stored channel scores with is_number/1 and delete finite_number?/1.
Recall.PostFusion: retain is_number(value) and value >= 0; delete finite?/1 without adding the 1.0e308 bound.
```

Delete all `value == value` and `score == score` checks from these files.

- [ ] **Step 6: Run focused Memory regressions and Credo**

```bash
devenv shell -- mix test apps/backplane_memory/test/backplane/memory/numeric_test.exs apps/backplane_memory/test/backplane/memory/recall/candidate_test.exs apps/backplane_memory/test/backplane/memory/recall/query_plan_test.exs apps/backplane_memory/test/backplane/memory/recall/selection_test.exs apps/backplane_memory/test/backplane/memory/recall/post_fusion_test.exs apps/backplane_memory/test/backplane/memory/recall/store_test.exs apps/backplane_memory/test/backplane/memory/memories/search_expansion_test.exs
devenv shell -- mix credo --strict
```

Expected: focused tests PASS; numeric tautology findings disappear while unrelated remaining Credo findings remain visible.

- [ ] **Step 7: Review and commit numeric validation**

Run required GitNexus/diff checks, then:

```bash
git add apps/backplane_memory/lib/backplane/memory/numeric.ex apps/backplane_memory/lib/backplane/memory/memories/search.ex apps/backplane_memory/lib/backplane/memory/recall apps/backplane_memory/test/backplane/memory/numeric_test.exs apps/backplane_memory/test/backplane/memory/recall/query_plan_test.exs
git commit -m "fix(memory): centralize score validation"
```

### Task 4: Enforce CrystalWorker sandbox authorization

**Files:**
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/crystal_worker.ex`
- Modify: `apps/backplane_memory/test/backplane/memory/crystals_test.exs`

- [ ] **Step 1: Run impact analysis**

```text
gitnexus_impact({target: "run", file_path: "apps/backplane_memory/lib/backplane/memory/workers/crystal_worker.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "allow_sandbox", file_path: "apps/backplane_memory/lib/backplane/memory/workers/crystal_worker.ex", direction: "upstream", includeTests: true})
```

- [ ] **Step 2: Add failing allowance and task-gating tests**

In `crystals_test.exs`, add a fake non-Sandbox repo and tests with these assertions:

```elixir
defmodule ProductionRepo do
  def config, do: [pool: DBConnection.ConnectionPool]
end

test "sandbox allowance is unnecessary for production pools" do
  assert :ok = CrystalWorker.allow_sandbox(self(), ProductionRepo)
end

test "returns an explicit error when no sandbox owner can authorize the task" do
  parent = self()

  spawn(fn ->
    send(parent, {:allowance, CrystalWorker.allow_sandbox(self(), repo())})
  end)

  assert_receive {:allowance, {:error, :sandbox_owner_not_found}}
end

test "does not execute the build after sandbox authorization fails" do
  parent = self()
  input = crystal_input!()

  assert {:error, :sandbox_owner_not_found} =
           CrystalWorker.run(worker_args(input), DateTime.utc_now(),
             sandbox_allow_fn: fn _pid -> {:error, :sandbox_owner_not_found} end,
             build_fn: fn -> send(parent, :build_ran) end
           )

  refute_receive :build_ran
end
```

Use the file's existing input/state helpers instead of duplicating fixtures. Add an assertion that a first allowance and an `{:already, _}` second allowance both normalize to `:ok`.

- [ ] **Step 3: Run the focused test red**

```bash
devenv shell -- mix test apps/backplane_memory/test/backplane/memory/crystals_test.exs
```

Expected: FAIL because `allow_sandbox/2` and `sandbox_allow_fn` do not exist and the current code always returns `:ok`.

- [ ] **Step 4: Implement explicit sandbox results**

Add the option in `execute_build/3`:

```elixir
sandbox_allow_fn = Keyword.get(opts, :sandbox_allow_fn, &allow_sandbox/1)
```

Gate task execution:

```elixir
outcome =
  case sandbox_allow_fn.(task.pid) do
    :ok ->
      send(task.pid, :crystal_task_run)
      yield_build_task(task, timeout)

    {:error, _reason} = error ->
      Task.shutdown(task, :brutal_kill)
      error
  end
```

Extract the existing `Task.yield/2` case into `yield_build_task/2` without changing timeout/exit results. Implement the internal test seam:

```elixir
@doc false
def allow_sandbox(task_pid, repo \\ repo()) do
  if repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
    [self() | Process.get(:"$callers", [])]
    |> Enum.uniq()
    |> Enum.reduce_while({:error, :sandbox_owner_not_found}, fn owner, _acc ->
      case Ecto.Adapters.SQL.Sandbox.allow(repo, owner, task_pid) do
        :ok -> {:halt, :ok}
        {:already, _status} -> {:halt, :ok}
        :not_found -> {:cont, {:error, :sandbox_owner_not_found}}
        other -> {:halt, {:error, {:sandbox_allow_failed, other}}}
      end
    end)
  else
    :ok
  end
end
```

- [ ] **Step 5: Run Crystal regressions and Credo**

```bash
devenv shell -- mix test apps/backplane_memory/test/backplane/memory/crystals_test.exs
devenv shell -- mix credo --strict
```

Expected: tests PASS and the discarded `Enum.find_value/2` finding disappears.

- [ ] **Step 6: Review and commit sandbox behavior**

Run required GitNexus/diff checks, then:

```bash
git add apps/backplane_memory/lib/backplane/memory/workers/crystal_worker.ex apps/backplane_memory/test/backplane/memory/crystals_test.exs
git commit -m "fix(memory): enforce crystal sandbox authorization"
```

### Task 5: Resolve remaining strict Credo findings and MCP types

**Files:**
- Modify: `apps/backplane_memory/lib/backplane/memory/context.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/coordination/lease.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/recall/adapters.ex`
- Modify: `apps/backplane_memory/test/backplane/memory/context_test.exs`
- Modify: `apps/backplane_mcp/lib/backplane/proxy/mcp_upstream.ex`
- Modify: `apps/backplane_mcp/lib/backplane/proxy/upstreams.ex`

- [ ] **Step 1: Run impact analysis for the four warned symbols**

Run upstream impact for `partition_from_opts`, `acquire`, `artifact_partition`, `validate_empty_partition`, `McpUpstream`, and `runtime_config` with their exact file paths.

- [ ] **Step 2: Capture the remaining Credo failures**

```bash
devenv shell -- mix credo --strict --format oneline
```

Expected: only the approved local refactors and MCP struct-in-spec warning remain after Tasks 3 and 4.

- [ ] **Step 3: Add the missing Context regression**

Add to `context_test.exs`:

```elixir
test "fails closed when one trusted partition field is empty" do
  stub_setting("true")
  assert Context.build("my-project", "session", Keyword.put(@partition, :namespace, "")) == nil
end
```

- [ ] **Step 4: Apply behavior-preserving refactors**

In `Lease.acquire/4`, change `if not action_owned do` to `if action_owned do`. Move the current transaction expression beginning `{:ok, result} = repo().transaction(fn ->` through its matching `end)`, plus the following `result` expression, into that true branch without altering any nested statement. Move the existing `{:error, :not_found}` expression into the `else` branch.

In `Context`, remove assignment from the condition:

```elixir
defp partition_from_opts(opts) do
  partition = Map.new(opts)
  keys = [:host_id, :client_id, :scope, :namespace]

  if Enum.all?(keys, &valid_partition_value?(partition[&1])) do
    {:ok, Map.take(partition, keys)}
  else
    {:error, :unauthorized}
  end
end

defp valid_partition_value?(value), do: is_binary(value) and value != ""
```

In `Recall.Adapters`, remove condition assignments:

```elixir
defp artifact_partition_matches?(artifact, partition, key) do
  expected = value(partition, key)
  actual = value(artifact, key)

  valid_partition_value?(expected) and (is_nil(actual) or actual == expected)
end

defp valid_partition_value?(value),
  do: is_binary(value) and String.trim(value) != ""
```

Use `Enum.all?(keys, &artifact_partition_matches?(artifact, partition, &1))` and `Enum.all?(keys, &valid_partition_value?(value(partition, &1)))` in the two warned functions.

- [ ] **Step 5: Correct the MCP typespec at its owner**

Add to `McpUpstream`:

```elixir
@type t :: %__MODULE__{}
```

Change `Upstreams.runtime_config/1` to:

```elixir
@spec runtime_config(McpUpstream.t()) :: map()
```

- [ ] **Step 6: Run focused tests and strict Credo**

```bash
devenv shell -- mix test apps/backplane_memory/test/backplane/memory/coordination/lease_test.exs apps/backplane_memory/test/backplane/memory/partitioned_models_test.exs apps/backplane_memory/test/backplane/memory/recall/candidate_test.exs apps/backplane_memory/test/backplane/memory/context_test.exs
devenv shell -- mix test apps/backplane_mcp/test/backplane/proxy/mcp_upstream_test.exs
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix credo --strict
```

Expected: all commands PASS with zero Credo findings.

- [ ] **Step 7: Review and commit the refactors**

Run required GitNexus/diff checks, then create two scope-correct commits:

```bash
git add apps/backplane_memory/lib/backplane/memory/context.ex apps/backplane_memory/lib/backplane/memory/coordination/lease.ex apps/backplane_memory/lib/backplane/memory/recall/adapters.ex apps/backplane_memory/test/backplane/memory/context_test.exs
git commit -m "refactor(memory): resolve strict credo findings"
```

```bash
git add apps/backplane_mcp/lib/backplane/proxy/mcp_upstream.ex apps/backplane_mcp/lib/backplane/proxy/upstreams.ex
git commit -m "fix(mcp): type upstream runtime config"
```

### Task 6: Repair genuine OTP 28 Dialyzer findings

**Files:**
- Modify: `mix.exs`
- Modify: `apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/import.ex`
- Modify: `apps/backplane_mcp/lib/backplane/mcp/dispatch.ex`
- Modify: `apps/backplane_mcp/lib/backplane/proxy/client_pool.ex`
- Modify: `apps/backplane_mcp/lib/backplane/proxy/tool_catalog.ex`
- Modify: `apps/backplane_mcp/lib/backplane/transport/idempotency.ex`
- Modify: `apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex`
- Modify: `apps/backplane_system/lib/backplane/registry/tool.ex`
- Modify: `apps/backplane_system/lib/backplane/registry/tool_registry.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/config.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/crystals.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/lessons.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/memories.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/projection_repair_worker.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/projections/observation_projector.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/prompts.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/recall/store.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/memories/verification.ex`
- Modify: focused tests named in Steps 4 and 5

- [ ] **Step 1: Run impact analysis for every warned production symbol**

Use upstream impact with exact file paths for the functions edited below. Treat `Backplane.Registry.Tool.t/0` and `ToolRegistry.resolve/1` as shared boundaries; report high-risk results before proceeding.

- [ ] **Step 2: Reproduce and inventory raw warnings**

```bash
devenv shell -- mix dialyzer --format raw
```

Expected baseline: exit 2 with 256 total warnings, 179 skipped, 10 unnecessary skips, including `:opaque_compare` at `memory/config.ex`.

- [ ] **Step 3: Complete the PLT and remove the formatter-crashing source comparison**

Add to root `mix.exs` Dialyzer options:

```elixir
plt_add_apps: [:mix, :ex_unit],
```

Replace `Config.bounded_channel_map/3` key comparison with:

```elixir
map_size(value) == 3 and
  Enum.all?(~w(fts vector graph), &Map.has_key?(value, &1)) and
  Enum.all?(value, fn {_key, item} -> validator.(item) end)
```

The existing `config_test.exs` missing/extra-key cases are the regression test.

- [ ] **Step 4: Correct shared tool handler types**

In `Backplane.Registry.Tool`:

```elixir
@type handler ::
        (map() -> {:ok, term()} | {:error, term()})
        | (map(), map() -> {:ok, term()} | {:error, term()})
```

Within the existing `%__MODULE__{}` type, replace the `handler:` field with:

```elixir
handler: atom() | handler() | nil,
```

In `ToolRegistry.resolve/1`:

```elixir
| {:managed, Tool.handler()}
```

Keep both arity-one and arity-two dispatch clauses. Add to `apps/backplane_mcp/test/backplane/mcp/dispatch_test.exs` a managed arity-two handler that sends its auth map to the test process and assert the exact map is received.

- [ ] **Step 5: Remove only Dialyzer-proven impossible branches**

Apply these exact changes:

```text
apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex
  Delete catch-all clauses after the is_binary(local_id) clauses at current lines 204 and 219.

apps/backplane_host_agent/lib/backplane/host_agent/memory/import.ex
  Replace the three else branches around current lines 193-195 with:
    {:error, reason} -> {:error, {:file_error, reason}}

apps/backplane_mcp/lib/backplane/proxy/client_pool.ex
  Change DynamicSupervisor.on_start() to Supervisor.on_start().

apps/backplane_mcp/lib/backplane/proxy/tool_catalog.ex
  Delete the unreachable valid_absolute_uri?(_value) fallback.

apps/backplane_mcp/lib/backplane/transport/idempotency.ex
  Delete the unreachable header_digest(_headers) fallback.

apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex
  Delete the unreachable outer catch-all after the body_params map branch.

apps/backplane_memory/lib/backplane/memory/crystals.ex
  Delete the final _ -> {:error, :invalid_arguments} branch at current line 36.

apps/backplane_memory/lib/backplane/memory/lessons.ex
  Delete the final _invalid -> {:error, :invalid_arguments} branch at current line 216.

apps/backplane_memory/lib/backplane/memory/memories.ex
  Keep apply_exact_partition(query, nil) only inside if Mix.env() == :test.

apps/backplane_memory/lib/backplane/memory/projections/observation_projector.ex
  Delete the unreachable content_value/2 fallback; source/1 guarantees a map.

apps/backplane_memory/lib/backplane/memory/prompts.ex
  Delete nil project clauses at current lines 350, 572, 1179, 1185, 1187;
  replace line 489 with memory_partition? or MapSet.member?(columns, "project");
  return the project tuple directly at line 509.

apps/backplane_memory/lib/backplane/memory/recall/store.ex
  Change do_put_candidates/4 to do_put_candidates/3, always use locked_run/2, and delete unused existing_run/2.

apps/backplane_memory/lib/backplane/memory/workers/projection_repair_worker.ex
  Delete only the outer catch-all at current line 69; retain inner unexpected-result rollback handling.
```

In `memories/verification.ex`, replace runtime `Mix.env/0` with compile-time definitions:

```elixir
if Mix.env() == :test do
  defp graph_query_fun,
    do: Application.get_env(:backplane_memory, :verification_graph_query, &repo().query/3)
else
  defp graph_query_fun, do: &repo().query/3
end
```

Then call `graph_query_fun().(sql, params, timeout: @graph_query_timeout)`.

- [ ] **Step 6: Run every affected public regression**

```bash
devenv shell -- mix do --app backplane_api cmd mix test test/backplane/api/host_agent_memory_sync_test.exs
devenv shell -- mix do --app backplane_host_agent cmd mix test test/backplane/host_agent/memory/import_test.exs
devenv shell -- mix do --app backplane_system cmd mix test test/backplane/registry/tool_registry_test.exs
devenv shell -- mix do --app backplane_mcp cmd mix test test/backplane/mcp/dispatch_test.exs test/backplane/proxy/pool_test.exs test/backplane/proxy/tool_catalog_test.exs test/backplane/transport/idempotency_test.exs test/backplane/transport/mcp_handler_test.exs
devenv shell -- mix test apps/backplane_memory/test/backplane/memory/config_test.exs apps/backplane_memory/test/backplane/memory/crystal_action_chain_test.exs apps/backplane_memory/test/backplane/memory/lesson_governance_test.exs apps/backplane_memory/test/backplane/memory/memory_test.exs apps/backplane_memory/test/backplane/memory/projections/projectors_test.exs apps/backplane_memory/test/backplane/memory/prompts_test.exs apps/backplane_memory/test/backplane/memory/memories/verification_test.exs apps/backplane_memory/test/backplane/memory/recall/store_test.exs apps/backplane_memory/test/backplane/memory/projections/projection_repair_worker_test.exs
devenv shell -- mix compile --warnings-as-errors
```

Expected: all tests and compile PASS.

- [ ] **Step 7: Rebuild the PLT and rerun raw Dialyzer**

```bash
devenv shell -- mix dialyzer --plt
devenv shell -- mix dialyzer --format raw
```

Expected: raw Dialyzer still exits nonzero, but remaining unignored findings are limited to the Task/MapSet OTP 28 opacity allowlist in Task 7. No `matching`, `pattern_match_cov`, `not_called`, `unknown_function`, `unknown_type`, `callback_info_missing`, or `opaque_compare` findings remain.

- [ ] **Step 8: Review and commit genuine source fixes**

Run required GitNexus/diff checks, then:

```bash
git add mix.exs apps/backplane_api apps/backplane_host_agent apps/backplane_mcp apps/backplane_system apps/backplane_memory
git commit -m "fix(types): resolve genuine OTP 28 findings"
```

### Task 7: Record only strict OTP 28 opacity exceptions

**Files:**
- Modify: `.dialyzer_ignore.exs`

- [ ] **Step 1: Generate exact warning descriptions**

```bash
devenv shell -- mix dialyzer --format ignore_file_strict
```

Expected: generated tuples for the remaining Task/MapSet opacity warnings.

- [ ] **Step 2: Admit only the approved file/function allowlist**

Copy the generator's emitted `{file, warning_description}` tuples verbatim only when the file and called function match this list:

```text
lib/backplane/host_agent/memory/import.ex
  MapSet.member?/2; walk/7

lib/backplane/memory/memories/relation_classifier.ex
  MapSet.disjoint?/2

lib/backplane/memory/memories/relations.ex
  MapSet.member?/2; supersession_reaches?/3

lib/backplane/memory/memories/verification.ex
  MapSet.member?/2 at the four generated strict entries corresponding to current lines 214, 215, 823, and 824

lib/backplane/memory/recall/reranker.ex
  await/4; Task.yield/2

lib/backplane/memory/workers/crystal_worker.ex
  Task.yield/2

lib/backplane/proxy/tool_catalog.ex
  MapSet.member?/2; fetch_pages/6

lib/backplane/skills/agent_manage.ex
  MapSet.member?/2

lib/backplane/transport/idempotency.ex
  MapSet.member?/2; MapSet.put/2; normalize_replay_headers/3
```

Do not add `{file, :warning_type}` entries. Keep the four existing exact Ecto descriptions. Do not broaden or rewrite legacy ignores outside this currently unignored set.

- [ ] **Step 3: Prove both authoritative and annotation formatters**

```bash
devenv shell -- mix dialyzer --format raw
devenv shell -- mix dialyzer --format github
```

Expected: both commands exit 0. GitHub formatting no longer crashes because the source-level `:opaque_compare` warning is gone.

- [ ] **Step 4: Review and commit narrow ignores**

Run required GitNexus/diff checks, then:

```bash
git add .dialyzer_ignore.exs
git commit -m "fix(types): document OTP 28 opaque warnings"
```

### Task 8: Convert CI to an exact 17-application PR gate

**Files:**
- Create: `test/ci_workflow_test.exs`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/test.yml`

- [ ] **Step 1: Write the failing workflow contract**

Create `test/ci_workflow_test.exs`:

```elixir
defmodule Backplane.CIWorkflowTest do
  use ExUnit.Case, async: true

  @apps ~w(
    backplane backplane_admin backplane_api backplane_auth backplane_data_case
    backplane_host_agent backplane_llama backplane_mcp backplane_mcp_protocol
    backplane_memory backplane_monitor backplane_skills backplane_system
    backplane_telemetry day_ex math_ex relayixir
  )

  test "static checks run on pull requests with exact toolchains" do
    workflow = File.read!(".github/workflows/ci.yml")

    assert workflow =~ "pull_request:"
    assert workflow =~ ~s(elixir-version: "1.18.4")
    assert workflow =~ ~s(otp-version: "28.5.0.5")
    assert workflow =~ ~s(toolchain: "1.95.0")
    assert workflow =~ "mix dialyzer --format raw"
  end

  test "test workflow runs every umbrella application independently" do
    workflow = File.read!(".github/workflows/test.yml")

    assert workflow =~ "fail-fast: false"
    assert workflow =~ ~s(mix do --app ${{ matrix.app }} cmd mix test)
    assert workflow =~ "postgresql-17"
    assert workflow =~ "pgvector/pgvector"
    refute workflow =~ "bun-version: latest"

    for app <- @apps do
      assert workflow =~ ~r/^\s+- #{Regex.escape(app)}$/m,
             "missing test matrix entry #{app}"
    end
  end
end
```

- [ ] **Step 2: Run the workflow contract red**

```bash
devenv shell -- mix test --no-start test/ci_workflow_test.exs
```

Expected: FAIL because CI is push-only, versions move, Dialyzer uses GitHub format, and the Test workflow has no matrix.

- [ ] **Step 3: Pin and harden static CI**

At the top of `ci.yml`, use:

```yaml
name: CI

on:
  push:
    branches: ["**"]
  pull_request:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

env:
  ELIXIR_VERSION: "1.18.4"
  OTP_VERSION: "28.5.0.5"
  RUST_VERSION: "1.95.0"
```

For every job:

```yaml
runs-on: ubuntu-24.04
```

For every BEAM setup:

```yaml
with:
  elixir-version: ${{ env.ELIXIR_VERSION }}
  otp-version: ${{ env.OTP_VERSION }}
```

For Compile and Dialyzer Rust setup:

```yaml
- name: Set up Rust
  uses: dtolnay/rust-toolchain@stable
  with:
    toolchain: ${{ env.RUST_VERSION }}
```

Include exact versions and `MIX_ENV` in Mix/PLT cache keys. Change the final Dialyzer command to:

```yaml
- name: Run Dialyzer
  run: mix dialyzer --format raw
```

Add to the Format job after its format check:

```yaml
- name: Verify workflow contracts
  run: mix test --no-start test/ci_workflow_test.exs
```

- [ ] **Step 4: Replace the partial Test job with the exact matrix**

Use this job header in `test.yml`:

```yaml
permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

env:
  ELIXIR_VERSION: "1.18.4"
  OTP_VERSION: "28.5.0.5"
  RUST_VERSION: "1.95.0"

jobs:
  test:
    name: Test (${{ matrix.app }})
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        app:
          - backplane
          - backplane_admin
          - backplane_api
          - backplane_auth
          - backplane_data_case
          - backplane_host_agent
          - backplane_llama
          - backplane_mcp
          - backplane_mcp_protocol
          - backplane_memory
          - backplane_monitor
          - backplane_skills
          - backplane_system
          - backplane_telemetry
          - day_ex
          - math_ex
          - relayixir
```

Pin BEAM and Rust using the same snippets as static CI. Before compilation, install `build-essential`, `pkg-config`, and `libssl-dev`. Remove the Bun setup because no test command invokes Bun.

Copy the PostgreSQL 17/pgvector 0.8.0 installation and extension setup from `.github/workflows/release.yml`, retaining `PGHOST: /var/run/postgresql`. Keep `mix ecto.setup`, then run:

```yaml
- name: Run ${{ matrix.app }} tests
  run: mix do --app ${{ matrix.app }} cmd mix test
```

- [ ] **Step 5: Run contract and workflow validation green**

```bash
devenv shell -- mix test --no-start test/ci_workflow_test.exs
yq '.' .github/workflows/ci.yml
yq '.' .github/workflows/test.yml
env GOSUMDB=sum.golang.org go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 .github/workflows/ci.yml .github/workflows/test.yml
```

Expected: all commands exit 0.

- [ ] **Step 6: Review and commit the gate**

Run required GitNexus/diff checks, then:

```bash
git add .github/workflows/ci.yml .github/workflows/test.yml test/ci_workflow_test.exs
git commit -m "ci(github): test every umbrella application"
```

### Task 9: Verify the complete milestone and save the Agent Note

**Files:**
- No source files should change during verification
- External artifact: one Agent Note labeled `project: backplane`

- [ ] **Step 1: Verify repository quality gates**

```bash
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix credo --strict
devenv shell -- mix dialyzer --format raw
devenv shell -- mix dialyzer --format github
git diff --check origin/main...HEAD
```

Expected: every command exits 0.

- [ ] **Step 2: Run every application suite independently**

Run these commands serially because the local jobs share one PostgreSQL test database:

```bash
devenv shell -- mix do --app backplane cmd mix test
devenv shell -- mix do --app backplane_admin cmd mix test
devenv shell -- mix do --app backplane_api cmd mix test
devenv shell -- mix do --app backplane_auth cmd mix test
devenv shell -- mix do --app backplane_data_case cmd mix test
devenv shell -- mix do --app backplane_host_agent cmd mix test
devenv shell -- mix do --app backplane_llama cmd mix test
devenv shell -- mix do --app backplane_mcp cmd mix test
devenv shell -- mix do --app backplane_mcp_protocol cmd mix test
devenv shell -- mix do --app backplane_memory cmd mix test
devenv shell -- mix do --app backplane_monitor cmd mix test
devenv shell -- mix do --app backplane_skills cmd mix test
devenv shell -- mix do --app backplane_system cmd mix test
devenv shell -- mix do --app backplane_telemetry cmd mix test
devenv shell -- mix do --app day_ex cmd mix test
devenv shell -- mix do --app math_ex cmd mix test
devenv shell -- mix do --app relayixir cmd mix test
```

Expected: all 17 commands exit 0. If an out-of-scope suite fails, record it and stop rather than changing unrelated code.

- [ ] **Step 3: Run final change-impact and branch checks**

```text
gitnexus_detect_changes({repo: "backplane", base_ref: "origin/main", scope: "compare"})
```

```bash
git status --short --branch
git log --oneline --decorate origin/main..HEAD
```

Expected: only approved test-support, Memory quality, type-analysis, and CI surfaces are reported; the worktree is clean and the branch is ahead of `origin/main` by the design plus implementation commits.

- [ ] **Step 4: Save the required Agent Note**

Call `mcp__agent_note__save_note` with:

```json
{
  "title": "Backplane honest green PR gate (2026-08-28)",
  "labels": [["project", "backplane"]],
  "content": "# Backplane honest green PR gate\n\nRecord branch codex/green-pr-gate, base 55835fbd799c81238e455446f8fa43701a5adda6, the exact output of git log --oneline origin/main..HEAD, all 17 application test counts, Compile/Format/Credo/Dialyzer results, workflow validation results, and any remaining external advisories. State explicitly that Admin security behavior was not changed and that the branch was not pushed or merged."
}
```

Expected: the tool returns a note ID and revision. Record the note ID in the final handoff.

## Completion Boundary

Stop when the approved checklist passes, the worktree is clean, and the Agent Note is saved. Do not push, merge, release, close issues, or start the supervised-bootstrap milestone without separate authorization.
