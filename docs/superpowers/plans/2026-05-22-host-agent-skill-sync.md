# Backplane Host Agent Skill Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Host Agent v1 skill sync: Backplane assigns archive-backed skills to authenticated hosts, and an independently releasable Host Agent installs those skills into local runtime directories.

**Architecture:** Finish the archive-backed Skills Hub foundation first, then add host assignment/state APIs in `apps/backplane`, Phoenix Channel transport in `apps/backplane_web`, and the independent `apps/backplane_host_agent` daemon. The WebSocket/Phoenix Channel is the control plane; archive downloads stay on authenticated HTTPS routes keyed by skill slug while payloads retain text skill IDs for identity.

**Tech Stack:** Elixir 1.18, OTP supervisors/GenServer, Ecto/PostgreSQL, Phoenix Channels, Phoenix LiveView, `phoenix_socket_client`, Req, TOML, Jason or Elixir `JSON`, DuskMoon UI, `:erl_tar`, filesystem temp dirs.

---

## Source And Scope

Source spec: `docs/superpowers/specs/2026-05-22-host-agent-skill-sync-design.md`

Prerequisite plan: `docs/superpowers/plans/2026-05-20-skills-hub.md`

In scope:

- Archive-backed Skills Hub must exist before Host Agent sync work starts.
- Host Agent connects to Backplane with Phoenix Channels over WebSocket.
- Host Agent downloads archive bytes over authenticated HTTPS.
- Host tokens are admin-created and bcrypt-hashed.
- Host Agent v1 reconciles skills only.

Out of scope:

- Local MCP server.
- Local tool execution.
- Remote shell execution.
- Secret sync.
- NixOS/module deployment.
- Skill version history beyond the current archive checksum/version label.

Current preparation findings:

- `AGENTS.md`, `CLAUDE.md`, `.claude/`, and `docs/host-agent-design.md` were already dirty or untracked before this plan; do not stage or edit them unless explicitly asked.
- Use `devenv shell -- <command>` for Mix commands if bare `mix` is unavailable.
- Run GitNexus impact checks before editing existing symbols, as required by repo instructions.

## File Map

Prerequisite Skills Hub files are covered by `docs/superpowers/plans/2026-05-20-skills-hub.md`.

Create in `apps/backplane`:

- `apps/backplane/priv/repo/migrations/20260522000001_create_skill_host_sync_tables.exs`
- `apps/backplane/lib/backplane/skills/host.ex`
- `apps/backplane/lib/backplane/skills/host_assignment.ex`
- `apps/backplane/lib/backplane/skills/host_status.ex`
- `apps/backplane/lib/backplane/skills/hosts.ex`
- `apps/backplane/lib/backplane/skills/assignments.ex`
- `apps/backplane/lib/backplane/skills/desired_state.ex`
- `apps/backplane/lib/backplane/skills/host_agent_api_router.ex`
- `apps/backplane/test/backplane/skills/hosts_test.exs`
- `apps/backplane/test/backplane/skills/assignments_test.exs`
- `apps/backplane/test/backplane/skills/desired_state_test.exs`
- `apps/backplane/test/backplane/skills/host_agent_api_router_test.exs`

Modify in `apps/backplane_web`:

- `apps/backplane_web/lib/backplane_web/endpoint.ex`
- `apps/backplane_web/lib/backplane_web/router.ex`
- `apps/backplane_web/lib/backplane_web/live/skill_live.ex`
- `apps/backplane_web/test/backplane_web/live/skill_live_test.exs`

Create in `apps/backplane_web`:

- `apps/backplane_web/lib/backplane_web/channels/host_agent_socket.ex`
- `apps/backplane_web/lib/backplane_web/channels/host_agent_channel.ex`
- `apps/backplane_web/test/support/channel_case.ex`
- `apps/backplane_web/test/backplane_web/channels/host_agent_socket_test.exs`
- `apps/backplane_web/test/backplane_web/channels/host_agent_channel_test.exs`

Create `apps/backplane_host_agent`:

- `apps/backplane_host_agent/mix.exs`
- `apps/backplane_host_agent/lib/backplane/host_agent.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/application.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/config.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/channel.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/worker.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/reconciler.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/installer.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/manifest.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/local_store.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/reporter.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/checksum.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/skill_bundle.ex`
- `apps/backplane_host_agent/test/test_helper.exs`
- `apps/backplane_host_agent/test/backplane/host_agent/config_test.exs`
- `apps/backplane_host_agent/test/backplane/host_agent/manifest_test.exs`
- `apps/backplane_host_agent/test/backplane/host_agent/reconciler_test.exs`
- `apps/backplane_host_agent/test/backplane/host_agent/checksum_test.exs`
- `apps/backplane_host_agent/test/backplane/host_agent/skill_bundle_test.exs`
- `apps/backplane_host_agent/test/backplane/host_agent/installer_test.exs`
- `apps/backplane_host_agent/test/backplane/host_agent/reporter_test.exs`
- `apps/backplane_host_agent/test/backplane/host_agent/worker_test.exs`

## Shared Decisions

- Use slug in archive download URLs because existing skill IDs can contain `/`.
- Desired-state entries still include `id`, `slug`, `name`, `version`, `checksum`, `targets`, `enabled`, and `download_url`.
- Model `skill_hosts.targets` as a JSON map keyed by target name. Heartbeat payloads can send a list; the context normalizes it.
- Store host tokens as bcrypt hashes using the same `Bcrypt.hash_pwd_salt/1` and `Bcrypt.verify_pass/2` convention as `Backplane.Clients`.
- Use `X-Backplane-Host-Token` for WebSocket and HTTPS download auth.
- Keep the Host Agent app independent from `:backplane`.
- Target roots must already exist. Missing target roots return `target_missing`.
- Manifest writes are atomic: write temp file, rename into place.

## Task 0: Complete The Skills Hub Archive Foundation

**Files:**

- Use existing plan: `docs/superpowers/plans/2026-05-20-skills-hub.md`
- Verify: `apps/backplane/lib/backplane/skills/skill.ex`
- Verify: `apps/backplane/lib/backplane/skills.ex`
- Verify: `apps/backplane/lib/backplane/skills/archive.ex`
- Verify: `apps/backplane/lib/backplane/skills/blob/local_fs.ex`
- Verify: `apps/backplane/lib/backplane/skills/api_router.ex`

- [ ] **Step 1: Confirm the prerequisite plan exists**

Run:

```bash
test -f docs/superpowers/plans/2026-05-20-skills-hub.md && sed -n '1,120p' docs/superpowers/plans/2026-05-20-skills-hub.md
```

Expected: the plan header says "Backplane Skills Hub Implementation Plan" and describes archive-backed `.tar.gz` skills.

- [ ] **Step 2: Execute the Skills Hub plan before Host Agent work**

Run the tasks in `docs/superpowers/plans/2026-05-20-skills-hub.md` through its archive download/API acceptance criteria.

Expected final capabilities:

```elixir
Backplane.Skills.get_by_slug("repo-review")
Backplane.Skills.archive_stream("repo-review")
Backplane.Skills.ingest_archive(%Plug.Upload{}, %{})
```

Expected schema fields on `Backplane.Skills.Skill`:

```elixir
field(:slug, :string)
field(:version, :string)
field(:meta, :map, default: %{})
field(:archive_ref, :string)
field(:content_hash, :string)
field(:size_bytes, :integer)
field(:file_count, :integer)
```

- [ ] **Step 3: Run prerequisite scoped tests**

Run:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills apps/backplane/test/backplane/tools/skill_test.exs apps/backplane/test/backplane/transport/mcp_handler_test.exs apps/backplane_web/test/backplane_web/live/skill_live_test.exs
```

Expected: all Skills Hub archive tests pass. If database setup fails before tests run, stop and report the environment blocker.

- [ ] **Step 4: Commit the prerequisite work**

Run:

```bash
git status --short
npx gitnexus analyze
```

Then run GitNexus `detect_changes` for all uncommitted changes. Review any non-document affected symbols.

Commit message:

```bash
git add apps/backplane apps/backplane_web docs/superpowers/plans/2026-05-20-skills-hub.md
git commit -m "feat(skills): add archive-backed hub"
```

Expected: prerequisite work is committed separately from Host Agent work.

## Task 1: Host Sync Schemas And Contexts

**Files:**

- Create: `apps/backplane/priv/repo/migrations/20260522000001_create_skill_host_sync_tables.exs`
- Create: `apps/backplane/lib/backplane/skills/host.ex`
- Create: `apps/backplane/lib/backplane/skills/host_assignment.ex`
- Create: `apps/backplane/lib/backplane/skills/host_status.ex`
- Create: `apps/backplane/lib/backplane/skills/hosts.ex`
- Create: `apps/backplane/lib/backplane/skills/assignments.ex`
- Test: `apps/backplane/test/backplane/skills/hosts_test.exs`
- Test: `apps/backplane/test/backplane/skills/assignments_test.exs`

- [ ] **Step 1: Run impact checks**

Run:

```bash
npx gitnexus analyze
```

Then run GitNexus impact for:

- `Backplane.Skills.Skill`
- `Backplane.Skills`

Expected: risk is LOW or MEDIUM. If GitNexus cannot resolve Elixir symbols, record the miss in task notes and use `rg -n "Backplane.Skills"` to inspect callers before editing.

- [ ] **Step 2: Write failing host context tests**

Create `apps/backplane/test/backplane/skills/hosts_test.exs`:

```elixir
defmodule Backplane.Skills.HostsTest do
  use Backplane.DataCase, async: true

  alias Backplane.Skills.Hosts

  describe "hosts" do
    test "creates a host with a hashed token and verifies the token" do
      assert {:ok, host, token} =
               Hosts.create_host(%{
                 "name" => "t430",
                 "hostname" => "t430.local",
                 "targets" => [
                   %{"name" => "agents", "runtime" => "agent-skills", "path" => "/tmp/skills", "enabled" => true}
                 ],
                 "metadata" => %{"os" => "nixos"}
               })

      assert is_binary(token)
      refute token == host.token_hash
      assert Bcrypt.verify_pass(token, host.token_hash)
      assert {:ok, verified} = Hosts.verify_token(token)
      assert verified.id == host.id
      assert verified.targets["agents"]["runtime"] == "agent-skills"
    end

    test "rejects an invalid token" do
      assert :error = Hosts.verify_token("missing-token")
    end

    test "heartbeat updates last_seen_at, status, targets, and metadata" do
      assert {:ok, host, _token} = Hosts.create_host(%{"name" => "t430"})

      assert {:ok, updated} =
               Hosts.heartbeat(host, %{
                 "hostname" => "t430",
                 "agent_version" => "0.1.0",
                 "targets" => [%{"name" => "agents", "runtime" => "agent-skills", "path" => "/tmp/skills", "enabled" => true}],
                 "metadata" => %{"arch" => "x86_64"}
               })

      assert updated.status == "online"
      assert updated.agent_version == "0.1.0"
      assert updated.targets["agents"]["enabled"] == true
      assert updated.metadata["arch"] == "x86_64"
      assert %DateTime{} = updated.last_seen_at
    end
  end
end
```

Run:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/hosts_test.exs
```

Expected: fails because `Backplane.Skills.Hosts` does not exist.

- [ ] **Step 3: Write failing assignment tests**

Create `apps/backplane/test/backplane/skills/assignments_test.exs`:

```elixir
defmodule Backplane.Skills.AssignmentsTest do
  use Backplane.DataCase, async: true

  alias Backplane.Repo
  alias Backplane.Skills.{Assignments, Hosts, Skill}

  setup do
    {:ok, host, _token} = Hosts.create_host(%{"name" => "t430"})

    skill =
      Repo.insert!(%Skill{
        id: "db/host-agent-test",
        slug: "host-agent-test",
        name: "Host Agent Test",
        content: "# Host Agent Test",
        content_hash: "sha256:" <> String.duplicate("a", 64),
        archive_ref: "sha256/#{String.duplicate("a", 64)}.tar.gz",
        enabled: true
      })

    %{host: host, skill: skill}
  end

  test "assigns a skill to a host", %{host: host, skill: skill} do
    assert {:ok, assignment} =
             Assignments.assign_skill(host, skill, %{
               "targets" => ["agents"],
               "metadata" => %{"reason" => "test"}
             })

    assert assignment.host_id == host.id
    assert assignment.skill_id == skill.id
    assert assignment.targets == ["agents"]
    assert assignment.enabled == true
  end

  test "list_enabled_for_host excludes disabled assignments", %{host: host, skill: skill} do
    assert {:ok, assignment} = Assignments.assign_skill(host, skill, %{"targets" => ["agents"]})
    assert [%{id: id}] = Assignments.list_enabled_for_host(host)
    assert id == assignment.id

    assert {:ok, _disabled} = Assignments.update_assignment(assignment, %{"enabled" => false})
    assert [] = Assignments.list_enabled_for_host(host)
  end
end
```

Run:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/assignments_test.exs
```

Expected: fails because assignment modules do not exist.

- [ ] **Step 4: Add migration**

Create `apps/backplane/priv/repo/migrations/20260522000001_create_skill_host_sync_tables.exs`:

```elixir
defmodule Backplane.Repo.Migrations.CreateSkillHostSyncTables do
  use Ecto.Migration

  def change do
    create table(:skill_hosts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :hostname, :text
      add :token_hash, :text, null: false
      add :agent_version, :text
      add :last_seen_at, :utc_datetime_usec
      add :status, :text, null: false, default: "unknown"
      add :targets, :map, null: false, default: %{}
      add :active, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:skill_hosts, [:name])

    create table(:skill_host_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :host_id, references(:skill_hosts, type: :binary_id, on_delete: :delete_all), null: false
      add :skill_id, references(:skills, type: :text, column: :id, on_delete: :delete_all), null: false
      add :targets, {:array, :text}, null: false, default: []
      add :enabled, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skill_host_assignments, [:host_id])
    create unique_index(:skill_host_assignments, [:host_id, :skill_id])

    create table(:skill_host_statuses, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :host_id, references(:skill_hosts, type: :binary_id, on_delete: :delete_all), null: false
      add :skill_id, references(:skills, type: :text, column: :id, on_delete: :nilify_all)
      add :skill_slug, :text
      add :skill_name, :text, null: false
      add :desired_version, :text
      add :installed_version, :text
      add :desired_checksum, :text
      add :installed_checksum, :text
      add :targets, {:array, :text}, null: false, default: []
      add :status, :text, null: false
      add :error, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skill_host_statuses, [:host_id])
    create unique_index(:skill_host_statuses, [:host_id, :skill_name])
  end
end
```

- [ ] **Step 5: Add schemas**

Create `apps/backplane/lib/backplane/skills/host.ex`:

```elixir
defmodule Backplane.Skills.Host do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "skill_hosts" do
    field :name, :string
    field :hostname, :string
    field :token_hash, :string
    field :agent_version, :string
    field :last_seen_at, :utc_datetime_usec
    field :status, :string, default: "unknown"
    field :targets, :map, default: %{}
    field :active, :boolean, default: true
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(host, attrs) do
    host
    |> cast(attrs, [:name, :hostname, :token_hash, :agent_version, :last_seen_at, :status, :targets, :active, :metadata])
    |> validate_required([:name, :token_hash])
    |> unique_constraint(:name)
  end
end
```

Create `apps/backplane/lib/backplane/skills/host_assignment.ex`:

```elixir
defmodule Backplane.Skills.HostAssignment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "skill_host_assignments" do
    field :host_id, :binary_id
    field :skill_id, :string
    field :targets, {:array, :string}, default: []
    field :enabled, :boolean, default: true
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:host_id, :skill_id, :targets, :enabled, :metadata])
    |> validate_required([:host_id, :skill_id])
    |> unique_constraint([:host_id, :skill_id])
  end
end
```

Create `apps/backplane/lib/backplane/skills/host_status.ex` with the same field names as the migration and a changeset requiring `:host_id`, `:skill_name`, and `:status`.

- [ ] **Step 6: Add host and assignment contexts**

Create `apps/backplane/lib/backplane/skills/hosts.ex`:

```elixir
defmodule Backplane.Skills.Hosts do
  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.Host

  def list_hosts do
    Host |> order_by(:name) |> Repo.all()
  end

  def get_host(id), do: Repo.get(Host, id)

  def create_host(attrs) when is_map(attrs) do
    token = "bha_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    params =
      attrs
      |> stringify_keys()
      |> Map.put("token_hash", Bcrypt.hash_pwd_salt(token))
      |> normalize_targets()

    case %Host{} |> Host.changeset(params) |> Repo.insert() do
      {:ok, host} -> {:ok, host, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def verify_token(token) when is_binary(token) do
    hosts = Host |> where(active: true) |> Repo.all()

    case Enum.find(hosts, &Bcrypt.verify_pass(token, &1.token_hash)) do
      nil ->
        Bcrypt.no_user_verify()
        :error

      host ->
        {:ok, touch_last_seen(host)}
    end
  end

  def verify_token(_), do: :error

  def heartbeat(%Host{} = host, attrs) do
    params =
      attrs
      |> stringify_keys()
      |> normalize_targets()
      |> Map.put("status", "online")
      |> Map.put("last_seen_at", DateTime.utc_now())

    host
    |> Host.changeset(params)
    |> Repo.update()
  end

  defp touch_last_seen(host) do
    {:ok, host} = heartbeat(host, %{})
    host
  end

  defp normalize_targets(%{"targets" => targets} = attrs) when is_list(targets) do
    Map.put(attrs, "targets", Map.new(targets, fn target -> {target["name"], target} end))
  end

  defp normalize_targets(attrs), do: attrs

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
```

Create `apps/backplane/lib/backplane/skills/assignments.ex` with:

```elixir
defmodule Backplane.Skills.Assignments do
  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.{Host, HostAssignment, Skill}

  def assign_skill(%Host{} = host, %Skill{} = skill, attrs \\ %{}) do
    params =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.merge(%{"host_id" => host.id, "skill_id" => skill.id})

    %HostAssignment{}
    |> HostAssignment.changeset(params)
    |> Repo.insert()
  end

  def update_assignment(%HostAssignment{} = assignment, attrs) do
    assignment
    |> HostAssignment.changeset(attrs)
    |> Repo.update()
  end

  def list_enabled_for_host(%Host{id: host_id}) do
    HostAssignment
    |> where([a], a.host_id == ^host_id and a.enabled == true)
    |> Repo.all()
  end
end
```

- [ ] **Step 7: Run scoped tests**

Run:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/hosts_test.exs apps/backplane/test/backplane/skills/assignments_test.exs
```

Expected: both test files pass.

- [ ] **Step 8: Commit**

Run GitNexus `detect_changes` for all changes, then:

```bash
git add apps/backplane/priv/repo/migrations/20260522000001_create_skill_host_sync_tables.exs apps/backplane/lib/backplane/skills/host*.ex apps/backplane/lib/backplane/skills/hosts.ex apps/backplane/lib/backplane/skills/assignments.ex apps/backplane/test/backplane/skills/hosts_test.exs apps/backplane/test/backplane/skills/assignments_test.exs
git commit -m "feat(skills): add host sync data model"
```

## Task 2: Desired State And Authenticated Archive Download

**Files:**

- Create: `apps/backplane/lib/backplane/skills/desired_state.ex`
- Create: `apps/backplane/lib/backplane/skills/host_agent_api_router.ex`
- Modify: `apps/backplane_web/lib/backplane_web/router.ex`
- Test: `apps/backplane/test/backplane/skills/desired_state_test.exs`
- Test: `apps/backplane/test/backplane/skills/host_agent_api_router_test.exs`

- [ ] **Step 1: Run impact checks**

Run GitNexus impact for `BackplaneWeb.Router` and `Backplane.Skills`.

Expected: route impact is limited to web routing and Skills callers.

- [ ] **Step 2: Write desired-state tests**

Create `apps/backplane/test/backplane/skills/desired_state_test.exs`:

```elixir
defmodule Backplane.Skills.DesiredStateTest do
  use Backplane.DataCase, async: true

  alias Backplane.Repo
  alias Backplane.Skills.{Assignments, DesiredState, Hosts, Skill}

  test "returns enabled assignments with slug download URLs" do
    {:ok, host, _token} = Hosts.create_host(%{"name" => "t430"})

    skill =
      Repo.insert!(%Skill{
        id: "db/repo-review",
        slug: "repo-review",
        name: "Repo Review",
        version: "0.1.0",
        content: "# Repo Review",
        content_hash: "sha256:" <> String.duplicate("b", 64),
        archive_ref: "sha256/#{String.duplicate("b", 64)}.tar.gz",
        enabled: true
      })

    {:ok, _assignment} = Assignments.assign_skill(host, skill, %{"targets" => ["agents"]})

    assert {:ok, desired} = DesiredState.for_host(host)
    assert %{host: %{id: host_id}, skills: [entry], schema_version: 1} = desired
    assert host_id == host.id
    assert entry.id == skill.id
    assert entry.slug == "repo-review"
    assert entry.checksum == skill.content_hash
    assert entry.targets == ["agents"]
    assert entry.download_url == "/api/host-agent/skills/repo-review/download"
  end
end
```

Run:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/desired_state_test.exs
```

Expected: fails because `DesiredState` does not exist.

- [ ] **Step 3: Add desired-state module**

Create `apps/backplane/lib/backplane/skills/desired_state.ex`:

```elixir
defmodule Backplane.Skills.DesiredState do
  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.{Host, HostAssignment, Skill}

  def for_host(%Host{} = host) do
    rows =
      HostAssignment
      |> where([a], a.host_id == ^host.id and a.enabled == true)
      |> join(:inner, [a], s in Skill, on: s.id == a.skill_id)
      |> where([_a, s], s.enabled == true)
      |> select([a, s], {a, s})
      |> Repo.all()

    skills = Enum.map(rows, fn {assignment, skill} -> desired_skill(assignment, skill) end)

    {:ok, %{schema_version: 1, host: %{id: host.id, name: host.name}, skills: skills}}
  end

  defp desired_skill(assignment, skill) do
    %{
      id: skill.id,
      slug: skill.slug,
      name: skill.name,
      version: skill.version,
      checksum: skill.content_hash,
      targets: assignment.targets,
      enabled: assignment.enabled,
      download_url: "/api/host-agent/skills/#{URI.encode_www_form(skill.slug)}/download"
    }
  end
end
```

- [ ] **Step 4: Write download router tests**

Create `apps/backplane/test/backplane/skills/host_agent_api_router_test.exs`:

```elixir
defmodule Backplane.Skills.HostAgentApiRouterTest do
  use Backplane.DataCase, async: true

  import Plug.Conn
  import Plug.Test

  alias Backplane.Skills.{HostAgentApiRouter, Hosts}

  test "rejects missing host token" do
    conn = conn(:get, "/skills/repo-review/download")
    conn = HostAgentApiRouter.call(conn, HostAgentApiRouter.init([]))

    assert conn.status == 401
  end

  @tag :tmp_dir
  test "streams an assigned archive with a valid host token", %{tmp_dir: tmp_dir} do
    archive_path =
      Backplane.SkillArchiveCase.write_archive!(tmp_dir, "repo-review", %{
        "SKILL.md" => "# Repo Review"
      })

    assert {:ok, skill} =
             Backplane.Skills.ingest_archive(
               %Plug.Upload{path: archive_path, filename: "repo-review.tar.gz"},
               %{}
             )

    {:ok, _host, token} = Hosts.create_host(%{"name" => "t430"})

    assert skill.slug == "repo-review"

    conn =
      conn(:get, "/skills/repo-review/download")
      |> put_req_header("x-backplane-host-token", token)

    conn = HostAgentApiRouter.call(conn, HostAgentApiRouter.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") != []
  end
end
```

Run:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/host_agent_api_router_test.exs
```

Expected: fails because router does not exist.

- [ ] **Step 5: Add Host Agent API router**

Create `apps/backplane/lib/backplane/skills/host_agent_api_router.ex`:

```elixir
defmodule Backplane.Skills.HostAgentApiRouter do
  use Plug.Router

  alias Backplane.Skills
  alias Backplane.Skills.Hosts

  plug :match
  plug :fetch_query_params
  plug :auth_host
  plug :dispatch

  get "/skills/:slug/download" do
    case Skills.archive_stream(slug) do
      {:ok, stream} ->
        conn
        |> put_resp_content_type("application/gzip")
        |> send_chunked(200)
        |> stream_chunks(stream)

      {:error, :not_found} ->
        send_resp(conn, 404, "not found")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp auth_host(conn, _opts) do
    token =
      conn
      |> get_req_header("x-backplane-host-token")
      |> List.first()

    case Hosts.verify_token(token) do
      {:ok, host} -> assign(conn, :host, host)
      :error -> conn |> send_resp(401, "unauthorized") |> halt()
    end
  end

  defp stream_chunks(conn, stream) do
    Enum.reduce_while(stream, conn, fn bytes, acc ->
      case chunk(acc, bytes) do
        {:ok, acc} -> {:cont, acc}
        {:error, _reason} -> {:halt, acc}
      end
    end)
  end
end
```

- [ ] **Step 6: Mount API router through a non-browser API pipeline**

Modify `apps/backplane_web/lib/backplane_web/router.ex`:

```elixir
pipeline :api do
  plug(:accepts, ["json"])
end

scope "/api" do
  pipe_through(:api)
  forward("/host-agent", Backplane.Skills.HostAgentApiRouter)
end
```

Keep the existing LLM route behavior intact. If existing `/api/llm` depends on `:browser`, leave it in its current scope and add a separate `/api/host-agent` scope.

- [ ] **Step 7: Run scoped tests**

Run:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/desired_state_test.exs apps/backplane/test/backplane/skills/host_agent_api_router_test.exs
```

Expected: desired-state and download tests pass with a real archive blob created by the Skills Hub archive test helper from Task 0.

- [ ] **Step 8: Commit**

Run GitNexus `detect_changes`, then:

```bash
git add apps/backplane/lib/backplane/skills/desired_state.ex apps/backplane/lib/backplane/skills/host_agent_api_router.ex apps/backplane_web/lib/backplane_web/router.ex apps/backplane/test/backplane/skills/desired_state_test.exs apps/backplane/test/backplane/skills/host_agent_api_router_test.exs
git commit -m "feat(skills): expose host agent desired downloads"
```

## Task 3: Phoenix Socket And Channel Control Plane

**Files:**

- Modify: `apps/backplane_web/lib/backplane_web/endpoint.ex`
- Create: `apps/backplane_web/lib/backplane_web/channels/host_agent_socket.ex`
- Create: `apps/backplane_web/lib/backplane_web/channels/host_agent_channel.ex`
- Create: `apps/backplane_web/test/support/channel_case.ex`
- Create: `apps/backplane_web/test/backplane_web/channels/host_agent_socket_test.exs`
- Create: `apps/backplane_web/test/backplane_web/channels/host_agent_channel_test.exs`

- [ ] **Step 1: Run impact check**

Run GitNexus impact for `BackplaneWeb.Endpoint`.

Expected: risk is limited to endpoint socket routing.

- [ ] **Step 2: Add channel test support**

Create `apps/backplane_web/test/support/channel_case.ex`:

```elixir
defmodule Backplane.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint BackplaneWeb.Endpoint

      import Phoenix.ChannelTest
      import Backplane.ChannelCase
    end
  end

  setup tags do
    Backplane.DataCase.setup_sandbox(tags)
    :ok
  end
end
```

- [ ] **Step 3: Write socket auth tests**

Create `apps/backplane_web/test/backplane_web/channels/host_agent_socket_test.exs`:

```elixir
defmodule BackplaneWeb.HostAgentSocketTest do
  use Backplane.ChannelCase, async: true

  alias Backplane.Skills.Hosts
  alias BackplaneWeb.HostAgentSocket

  test "connects with x-backplane-host-token" do
    {:ok, host, token} = Hosts.create_host(%{"name" => "t430"})

    assert {:ok, socket} =
             connect(HostAgentSocket, %{},
               connect_info: %{x_headers: [{"x-backplane-host-token", token}]}
             )

    assert socket.assigns.host.id == host.id
  end

  test "rejects invalid host token" do
    assert :error =
             connect(HostAgentSocket, %{},
               connect_info: %{x_headers: [{"x-backplane-host-token", "wrong"}]}
             )
  end
end
```

Run:

```bash
devenv shell -- mix test apps/backplane_web/test/backplane_web/channels/host_agent_socket_test.exs
```

Expected: fails because socket module does not exist.

- [ ] **Step 4: Add HostAgentSocket**

Create `apps/backplane_web/lib/backplane_web/channels/host_agent_socket.ex`:

```elixir
defmodule BackplaneWeb.HostAgentSocket do
  use Phoenix.Socket

  alias Backplane.Skills.Hosts

  channel "host_agent:*", BackplaneWeb.HostAgentChannel

  @impl true
  def connect(_params, socket, connect_info) do
    token = host_token(connect_info)

    case Hosts.verify_token(token) do
      {:ok, host} -> {:ok, assign(socket, :host, host)}
      :error -> :error
    end
  end

  @impl true
  def id(socket), do: "host_agent:#{socket.assigns.host.id}"

  defp host_token(%{x_headers: headers}) do
    headers
    |> Enum.find_value(fn
      {"x-backplane-host-token", token} -> token
      {"X-Backplane-Host-Token", token} -> token
      _ -> nil
    end)
  end

  defp host_token(_), do: nil
end
```

- [ ] **Step 5: Mount socket in endpoint**

Modify `apps/backplane_web/lib/backplane_web/endpoint.ex` near the existing LiveView socket:

```elixir
socket("/host-agent/socket", BackplaneWeb.HostAgentSocket,
  websocket: [connect_info: [x_headers: ["x-backplane-host-token"]]],
  longpoll: false
)
```

- [ ] **Step 6: Write channel behavior tests**

Create `apps/backplane_web/test/backplane_web/channels/host_agent_channel_test.exs`:

```elixir
defmodule BackplaneWeb.HostAgentChannelTest do
  use Backplane.ChannelCase, async: true

  alias Backplane.Skills.Hosts
  alias BackplaneWeb.HostAgentSocket

  setup do
    {:ok, host, token} = Hosts.create_host(%{"name" => "t430"})

    {:ok, socket} =
      connect(HostAgentSocket, %{},
        connect_info: %{x_headers: [{"x-backplane-host-token", token}]}
      )

    %{host: host, socket: socket}
  end

  test "joins only its own topic", %{host: host, socket: socket} do
    assert {:ok, _reply, _socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})
    assert {:error, %{reason: "unauthorized"}} = subscribe_and_join(socket, "host_agent:not-this-host", %{})
  end

  test "heartbeat updates host state", %{host: host, socket: socket} do
    {:ok, _reply, channel} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref = push(channel, "heartbeat", %{"agent_version" => "0.1.0", "targets" => []})
    assert_reply ref, :ok, %{"ok" => true}

    assert Backplane.Skills.Hosts.get_host(host.id).agent_version == "0.1.0"
  end

  test "get_desired replies with desired snapshot", %{host: host, socket: socket} do
    {:ok, _reply, channel} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    ref = push(channel, "get_desired", %{})
    assert_reply ref, :ok, %{"schema_version" => 1, "skills" => []}
  end
end
```

- [ ] **Step 7: Add HostAgentChannel**

Create `apps/backplane_web/lib/backplane_web/channels/host_agent_channel.ex`:

```elixir
defmodule BackplaneWeb.HostAgentChannel do
  use Phoenix.Channel

  alias Backplane.Skills.{DesiredState, Hosts}

  @impl true
  def join("host_agent:" <> host_id, _payload, socket) do
    if socket.assigns.host.id == host_id do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("heartbeat", payload, socket) do
    {:ok, _host} = Hosts.heartbeat(socket.assigns.host, payload)
    {:reply, {:ok, %{"ok" => true}}, socket}
  end

  def handle_in("get_desired", _payload, socket) do
    {:ok, desired} = DesiredState.for_host(socket.assigns.host)
    {:reply, {:ok, Jason.decode!(Jason.encode!(desired))}, socket}
  end

  def handle_in("sync_started", _payload, socket) do
    {:reply, {:ok, %{"ok" => true}}, socket}
  end

  def handle_in("sync_result", payload, socket) do
    # Task 4 persists status rows. Keep this acknowledgement until then.
    {:reply, {:ok, Map.put(payload, "ok", true)}, socket}
  end

  def handle_in("sync_error", payload, socket) do
    {:reply, {:ok, Map.put(payload, "ok", true)}, socket}
  end
end
```

- [ ] **Step 8: Run scoped tests**

Run:

```bash
devenv shell -- mix test apps/backplane_web/test/backplane_web/channels
```

Expected: socket and channel tests pass.

- [ ] **Step 9: Commit**

Run GitNexus `detect_changes`, then:

```bash
git add apps/backplane_web/lib/backplane_web/endpoint.ex apps/backplane_web/lib/backplane_web/channels apps/backplane_web/test/support/channel_case.ex apps/backplane_web/test/backplane_web/channels
git commit -m "feat(host-agent): add phoenix channel control plane"
```

## Task 4: Persist Sync Results

**Files:**

- Create: `apps/backplane/lib/backplane/skills/sync_statuses.ex`
- Modify: `apps/backplane_web/lib/backplane_web/channels/host_agent_channel.ex`
- Test: `apps/backplane/test/backplane/skills/sync_statuses_test.exs`
- Test: `apps/backplane_web/test/backplane_web/channels/host_agent_channel_test.exs`

- [ ] **Step 1: Write sync status tests**

Create `apps/backplane/test/backplane/skills/sync_statuses_test.exs`:

```elixir
defmodule Backplane.Skills.SyncStatusesTest do
  use Backplane.DataCase, async: true

  alias Backplane.Skills.{Hosts, SyncStatuses}

  test "upserts per-skill sync results for a host" do
    {:ok, host, _token} = Hosts.create_host(%{"name" => "t430"})

    payload = %{
      "status" => "synced",
      "results" => [
        %{
          "skill_name" => "Repo Review",
          "skill_slug" => "repo-review",
          "desired_version" => "0.1.0",
          "installed_version" => "0.1.0",
          "desired_checksum" => "sha256:" <> String.duplicate("d", 64),
          "installed_checksum" => "sha256:" <> String.duplicate("d", 64),
          "targets" => ["agents"],
          "status" => "synced",
          "error" => nil
        }
      ]
    }

    assert {:ok, statuses} = SyncStatuses.record_sync_result(host, payload)
    assert [%{skill_name: "Repo Review", status: "synced"}] = statuses
  end
end
```

- [ ] **Step 2: Add SyncStatuses context**

Create `apps/backplane/lib/backplane/skills/sync_statuses.ex`:

```elixir
defmodule Backplane.Skills.SyncStatuses do
  alias Backplane.Repo
  alias Backplane.Skills.{Host, HostStatus}

  def record_sync_result(%Host{} = host, %{"results" => results}) when is_list(results) do
    statuses =
      Enum.map(results, fn result ->
        attrs = %{
          host_id: host.id,
          skill_id: result["skill_id"],
          skill_slug: result["skill_slug"],
          skill_name: result["skill_name"],
          desired_version: result["desired_version"],
          installed_version: result["installed_version"],
          desired_checksum: result["desired_checksum"] || result["checksum"],
          installed_checksum: result["installed_checksum"] || result["checksum"],
          targets: result["targets"] || [],
          status: result["status"],
          error: result["error"],
          metadata: result["metadata"] || %{}
        }

        %HostStatus{}
        |> HostStatus.changeset(attrs)
        |> Repo.insert!(
          on_conflict: {:replace, [:skill_id, :skill_slug, :desired_version, :installed_version, :desired_checksum, :installed_checksum, :targets, :status, :error, :metadata, :updated_at]},
          conflict_target: [:host_id, :skill_name]
        )
      end)

    {:ok, statuses}
  end
end
```

- [ ] **Step 3: Persist channel sync_result**

Modify `apps/backplane_web/lib/backplane_web/channels/host_agent_channel.ex`:

```elixir
alias Backplane.Skills.{DesiredState, Hosts, SyncStatuses}

def handle_in("sync_result", payload, socket) do
  case SyncStatuses.record_sync_result(socket.assigns.host, payload) do
    {:ok, _statuses} -> {:reply, {:ok, %{"ok" => true}}, socket}
    {:error, reason} -> {:reply, {:error, %{"error" => inspect(reason)}}, socket}
  end
end
```

- [ ] **Step 4: Run scoped tests**

Run:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills/sync_statuses_test.exs apps/backplane_web/test/backplane_web/channels/host_agent_channel_test.exs
```

Expected: sync status and channel tests pass.

- [ ] **Step 5: Commit**

Run GitNexus `detect_changes`, then:

```bash
git add apps/backplane/lib/backplane/skills/sync_statuses.ex apps/backplane/test/backplane/skills/sync_statuses_test.exs apps/backplane_web/lib/backplane_web/channels/host_agent_channel.ex apps/backplane_web/test/backplane_web/channels/host_agent_channel_test.exs
git commit -m "feat(host-agent): persist sync results"
```

## Task 5: Minimal Admin UI For Hosts And Assignments

**Files:**

- Modify: `apps/backplane_web/lib/backplane_web/live/skill_live.ex`
- Modify: `apps/backplane_web/test/backplane_web/live/skill_live_test.exs`

- [ ] **Step 1: Run impact check**

Run GitNexus impact for `BackplaneWeb.SkillLive`.

Expected: impact is limited to Skill admin UI tests/routes.

- [ ] **Step 2: Write LiveView test for host visibility**

Extend `apps/backplane_web/test/backplane_web/live/skill_live_test.exs`:

```elixir
test "renders host sync section", %{conn: conn} do
  {:ok, _host, _token} = Backplane.Skills.Hosts.create_host(%{"name" => "t430", "agent_version" => "0.1.0"})

  {:ok, _view, html} = live(conn, "/admin/skill")

  assert html =~ "Host Agents"
  assert html =~ "t430"
  assert html =~ "0.1.0"
end
```

Run:

```bash
devenv shell -- mix test apps/backplane_web/test/backplane_web/live/skill_live_test.exs
```

Expected: fails until `SkillLive` renders host data.

- [ ] **Step 3: Load host data outside mount**

Modify `apps/backplane_web/lib/backplane_web/live/skill_live.ex` so `mount/3` assigns only defaults and `handle_params/3` loads data:

```elixir
def mount(_params, _session, socket) do
  {:ok, assign(socket, current_path: "/admin/skill", hosts: [])}
end

def handle_params(_params, _uri, socket) do
  {:noreply, assign(socket, hosts: Backplane.Skills.Hosts.list_hosts())}
end
```

Keep database reads out of `mount/3`.

- [ ] **Step 4: Render a minimal host table**

Update the `render/1` body to include:

```heex
<section aria-label="Host Agents">
  <h2>Host Agents</h2>
  <table>
    <thead>
      <tr>
        <th>Name</th>
        <th>Status</th>
        <th>Agent</th>
        <th>Targets</th>
      </tr>
    </thead>
    <tbody>
      <tr :for={host <- @hosts}>
        <td><%= host.name %></td>
        <td><%= host.status %></td>
        <td><%= host.agent_version || "-" %></td>
        <td><%= map_size(host.targets || %{}) %></td>
      </tr>
    </tbody>
  </table>
</section>
```

Use DuskMoon components if the Skills Hub UI from Task 0 already introduced them into this LiveView.

- [ ] **Step 5: Run scoped tests**

Run:

```bash
devenv shell -- mix test apps/backplane_web/test/backplane_web/live/skill_live_test.exs
```

Expected: Skill LiveView tests pass.

- [ ] **Step 6: Commit**

Run GitNexus `detect_changes`, then:

```bash
git add apps/backplane_web/lib/backplane_web/live/skill_live.ex apps/backplane_web/test/backplane_web/live/skill_live_test.exs
git commit -m "feat(host-agent): show host sync status in admin"
```

## Task 6: Host Agent App Skeleton, Config, Manifest

**Files:**

- Create: `apps/backplane_host_agent/mix.exs`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/application.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/config.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/manifest.ex`
- Create: `apps/backplane_host_agent/test/test_helper.exs`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/config_test.exs`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/manifest_test.exs`

- [ ] **Step 1: Create app tests first**

Create `apps/backplane_host_agent/test/test_helper.exs`:

```elixir
ExUnit.start()
```

Create `apps/backplane_host_agent/test/backplane/host_agent/config_test.exs`:

```elixir
defmodule Backplane.HostAgent.ConfigTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Config

  @tag :tmp_dir
  test "loads TOML config", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "host_agent.toml")

    File.write!(path, """
    [agent]
    machine_name = "t430"
    hub_url = "http://localhost:4220"
    token = "secret"
    interval_ms = 60000
    manifest_path = "#{tmp_dir}/manifest.json"
    work_dir = "#{tmp_dir}/work"

    [[targets]]
    name = "agents"
    runtime = "agent-skills"
    path = "#{tmp_dir}/skills"
    enabled = true
    """)

    assert {:ok, config} = Config.load(path)
    assert config.machine_name == "t430"
    assert config.socket_url == "ws://localhost:4220/host-agent/socket/websocket"
    assert [%{name: "agents", enabled: true}] = config.targets
  end
end
```

Create `apps/backplane_host_agent/test/backplane/host_agent/manifest_test.exs`:

```elixir
defmodule Backplane.HostAgent.ManifestTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Manifest

  @tag :tmp_dir
  test "reads missing manifest as empty and writes atomically", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "manifest.json")

    assert {:ok, manifest} = Manifest.read(path, "t430")
    assert manifest.schema_version == 1
    assert manifest.skills == []

    updated = %{manifest | skills: [%{name: "repo-review", slug: "repo-review", checksum: "sha256:abc", targets: ["agents"], owned: true}]}
    assert :ok = Manifest.write(path, updated)
    assert {:ok, read_back} = Manifest.read(path, "t430")
    assert [%{slug: "repo-review", owned: true}] = read_back.skills
  end
end
```

Run:

```bash
devenv shell -- mix test apps/backplane_host_agent/test/backplane/host_agent/config_test.exs apps/backplane_host_agent/test/backplane/host_agent/manifest_test.exs
```

Expected: fails because the app does not exist.

- [ ] **Step 2: Add mix project**

Create `apps/backplane_host_agent/mix.exs`:

```elixir
defmodule Backplane.HostAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_host_agent,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {Backplane.HostAgent.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix_socket_client, "~> 0.7.0"},
      {:req, "~> 0.5", override: true},
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"}
    ]
  end
end
```

- [ ] **Step 3: Add facade and application**

Create `apps/backplane_host_agent/lib/backplane/host_agent.ex`:

```elixir
defmodule Backplane.HostAgent do
  def sync_now, do: Backplane.HostAgent.Worker.sync_now()
  def status, do: Backplane.HostAgent.Worker.status()
end
```

Create `apps/backplane_host_agent/lib/backplane/host_agent/application.ex`:

```elixir
defmodule Backplane.HostAgent.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Backplane.HostAgent.Worker
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Backplane.HostAgent.Supervisor)
  end
end
```

- [ ] **Step 4: Add Config module**

Create `apps/backplane_host_agent/lib/backplane/host_agent/config.ex`:

```elixir
defmodule Backplane.HostAgent.Config do
  defstruct machine_name: nil,
            hub_url: nil,
            socket_url: nil,
            token: nil,
            interval_ms: 60_000,
            manifest_path: nil,
            work_dir: nil,
            targets: []

  def load(path) when is_binary(path) do
    with {:ok, raw} <- Toml.decode_file(path) do
      agent = raw["agent"] || %{}

      config = %__MODULE__{
        machine_name: agent["machine_name"],
        hub_url: trim_trailing_slash(agent["hub_url"]),
        token: agent["token"],
        interval_ms: agent["interval_ms"] || 60_000,
        manifest_path: agent["manifest_path"],
        work_dir: agent["work_dir"],
        targets: Enum.map(raw["targets"] || [], &target/1)
      }

      {:ok, %{config | socket_url: socket_url(config.hub_url)}}
    end
  end

  defp target(raw) do
    %{
      name: raw["name"],
      runtime: raw["runtime"],
      path: raw["path"],
      enabled: Map.get(raw, "enabled", true)
    }
  end

  defp socket_url("https://" <> rest), do: "wss://" <> rest <> "/host-agent/socket/websocket"
  defp socket_url("http://" <> rest), do: "ws://" <> rest <> "/host-agent/socket/websocket"

  defp trim_trailing_slash(nil), do: nil
  defp trim_trailing_slash(url), do: String.trim_trailing(url, "/")
end
```

- [ ] **Step 5: Add Manifest module**

Create `apps/backplane_host_agent/lib/backplane/host_agent/manifest.ex`:

```elixir
defmodule Backplane.HostAgent.Manifest do
  defstruct schema_version: 1, machine_name: nil, updated_at: nil, skills: []

  def read(path, machine_name) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
      |> from_json()
    else
      {:ok, %__MODULE__{machine_name: machine_name, skills: []}}
    end
  end

  def write(path, %__MODULE__{} = manifest) do
    File.mkdir_p!(Path.dirname(path))

    json =
      manifest
      |> Map.from_struct()
      |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Jason.encode!(pretty: true)

    tmp = path <> ".tmp"
    File.write!(tmp, json)
    File.rename!(tmp, path)
    :ok
  end

  defp from_json(map) do
    skills = Enum.map(map["skills"] || [], &atomize_skill/1)

    {:ok,
     %__MODULE__{
       schema_version: map["schema_version"] || 1,
       machine_name: map["machine_name"],
       updated_at: map["updated_at"],
       skills: skills
     }}
  end

  defp atomize_skill(map) do
    %{
      name: map["name"],
      slug: map["slug"],
      version: map["version"],
      checksum: map["checksum"],
      targets: map["targets"] || [],
      owned: Map.get(map, "owned", true),
      installed_at: map["installed_at"]
    }
  end
end
```

- [ ] **Step 6: Add temporary Worker skeleton so the app compiles**

Create `apps/backplane_host_agent/lib/backplane/host_agent/worker.ex`:

```elixir
defmodule Backplane.HostAgent.Worker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def sync_now, do: GenServer.call(__MODULE__, :sync_now)
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts), do: {:ok, %{last_sync: nil, last_error: nil}}

  @impl true
  def handle_call(:sync_now, _from, state), do: {:reply, {:error, :not_configured}, state}

  def handle_call(:status, _from, state), do: {:reply, state, state}
end
```

- [ ] **Step 7: Run scoped tests**

Run:

```bash
devenv shell -- mix test apps/backplane_host_agent/test/backplane/host_agent/config_test.exs apps/backplane_host_agent/test/backplane/host_agent/manifest_test.exs
```

Expected: config and manifest tests pass.

- [ ] **Step 8: Commit**

Run GitNexus `detect_changes`, then:

```bash
git add apps/backplane_host_agent
git commit -m "feat(host-agent): add app skeleton and local config"
```

## Task 7: Reconciler, Checksum, Bundle Validation, Installer

**Files:**

- Create: `apps/backplane_host_agent/lib/backplane/host_agent/reconciler.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/checksum.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/skill_bundle.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/installer.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/local_store.ex`
- Test: `apps/backplane_host_agent/test/backplane/host_agent/reconciler_test.exs`
- Test: `apps/backplane_host_agent/test/backplane/host_agent/checksum_test.exs`
- Test: `apps/backplane_host_agent/test/backplane/host_agent/skill_bundle_test.exs`
- Test: `apps/backplane_host_agent/test/backplane/host_agent/installer_test.exs`

- [ ] **Step 1: Write reconciler tests**

Create `apps/backplane_host_agent/test/backplane/host_agent/reconciler_test.exs`:

```elixir
defmodule Backplane.HostAgent.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.{Manifest, Reconciler}

  test "installs missing desired skills" do
    manifest = %Manifest{skills: []}
    desired = [%{"slug" => "repo-review", "checksum" => "sha256:a", "targets" => ["agents"]}]

    assert [%{action: :install, slug: "repo-review"}] = Reconciler.plan(desired, manifest)
  end

  test "noops matching owned skills" do
    manifest = %Manifest{skills: [%{slug: "repo-review", checksum: "sha256:a", targets: ["agents"], owned: true}]}
    desired = [%{"slug" => "repo-review", "checksum" => "sha256:a", "targets" => ["agents"]}]

    assert [%{action: :noop}] = Reconciler.plan(desired, manifest)
  end

  test "updates checksum changes and removes only owned undesired skills" do
    manifest = %Manifest{
      skills: [
        %{slug: "repo-review", checksum: "sha256:a", targets: ["agents"], owned: true},
        %{slug: "manual", checksum: "sha256:m", targets: ["agents"], owned: false}
      ]
    }

    desired = [%{"slug" => "repo-review", "checksum" => "sha256:b", "targets" => ["agents"]}]

    assert [
             %{action: :update, slug: "repo-review"},
             %{action: :noop, slug: "manual"}
           ] = Reconciler.plan(desired, manifest)
  end
end
```

- [ ] **Step 2: Add Reconciler**

Create `apps/backplane_host_agent/lib/backplane/host_agent/reconciler.ex`:

```elixir
defmodule Backplane.HostAgent.Reconciler do
  def plan(desired, manifest) do
    desired_by_slug = Map.new(desired, fn skill -> {skill["slug"], skill} end)
    local_by_slug = Map.new(manifest.skills, fn skill -> {skill.slug || skill[:slug], skill} end)

    desired_actions =
      Enum.map(desired, fn skill ->
        slug = skill["slug"]

        case Map.get(local_by_slug, slug) do
          nil -> action(:install, skill)
          local -> compare(skill, local)
        end
      end)

    removal_actions =
      manifest.skills
      |> Enum.reject(fn skill -> Map.has_key?(desired_by_slug, skill.slug || skill[:slug]) end)
      |> Enum.map(fn skill ->
        if Map.get(skill, :owned, true), do: action(:remove, skill), else: action(:noop, skill)
      end)

    desired_actions ++ removal_actions
  end

  defp compare(desired, local) do
    local_checksum = local.checksum || local[:checksum]
    local_targets = local.targets || local[:targets] || []

    cond do
      desired["checksum"] != local_checksum -> action(:update, desired)
      Enum.sort(desired["targets"] || []) != Enum.sort(local_targets) -> action(:update, desired)
      true -> action(:noop, desired)
    end
  end

  defp action(kind, skill), do: %{action: kind, slug: skill["slug"] || skill[:slug], skill: skill}
end
```

- [ ] **Step 3: Write checksum and bundle tests**

Create `apps/backplane_host_agent/test/backplane/host_agent/checksum_test.exs`:

```elixir
defmodule Backplane.HostAgent.ChecksumTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Checksum

  @tag :tmp_dir
  test "verifies sha256-prefixed checksum", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "file.bin")
    File.write!(path, "abc")

    assert :ok = Checksum.verify_file(path, "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    assert {:error, :checksum_mismatch} = Checksum.verify_file(path, "sha256:" <> String.duplicate("0", 64))
  end
end
```

Create `apps/backplane_host_agent/test/backplane/host_agent/skill_bundle_test.exs`:

```elixir
defmodule Backplane.HostAgent.SkillBundleTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.SkillBundle

  @tag :tmp_dir
  test "validates extracted bundle shape", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "repo-review")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "SKILL.md"), "# Repo Review")

    assert {:ok, ^root} = SkillBundle.validate(root)
  end

  @tag :tmp_dir
  test "rejects missing SKILL.md", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "bad")
    File.mkdir_p!(root)

    assert {:error, :missing_skill_md} = SkillBundle.validate(root)
  end
end
```

- [ ] **Step 4: Add checksum and bundle modules**

Create `apps/backplane_host_agent/lib/backplane/host_agent/checksum.ex`:

```elixir
defmodule Backplane.HostAgent.Checksum do
  def verify_file(path, "sha256:" <> expected) do
    actual =
      path
      |> File.stream!([], 2048)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == expected, do: :ok, else: {:error, :checksum_mismatch}
  end

  def verify_file(_path, _checksum), do: {:error, :unsupported_checksum}
end
```

Create `apps/backplane_host_agent/lib/backplane/host_agent/skill_bundle.ex`:

```elixir
defmodule Backplane.HostAgent.SkillBundle do
  def validate(root) do
    skill_md = Path.join(root, "SKILL.md")

    cond do
      not File.dir?(root) -> {:error, :missing_bundle_root}
      not File.regular?(skill_md) -> {:error, :missing_skill_md}
      true -> {:ok, root}
    end
  end
end
```

- [ ] **Step 5: Write installer tests**

Create `apps/backplane_host_agent/test/backplane/host_agent/installer_test.exs`:

```elixir
defmodule Backplane.HostAgent.InstallerTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Installer

  @tag :tmp_dir
  test "installs extracted skill into existing target root", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source/repo-review")
    target = Path.join(tmp_dir, "target")
    File.mkdir_p!(source)
    File.mkdir_p!(target)
    File.write!(Path.join(source, "SKILL.md"), "# Repo Review")

    skill = %{"slug" => "repo-review", "targets" => ["agents"]}
    targets = [%{name: "agents", path: target, enabled: true}]

    assert {:ok, installed} = Installer.install_extracted(source, skill, targets)
    assert installed == ["agents"]
    assert File.exists?(Path.join([target, "repo-review", "SKILL.md"]))
  end

  @tag :tmp_dir
  test "reports missing target root", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source/repo-review")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "SKILL.md"), "# Repo Review")

    skill = %{"slug" => "repo-review", "targets" => ["agents"]}
    targets = [%{name: "agents", path: Path.join(tmp_dir, "missing"), enabled: true}]

    assert {:error, {:target_missing, "agents"}} = Installer.install_extracted(source, skill, targets)
  end
end
```

- [ ] **Step 6: Add LocalStore and Installer**

Create `apps/backplane_host_agent/lib/backplane/host_agent/local_store.ex`:

```elixir
defmodule Backplane.HostAgent.LocalStore do
  def enabled_targets(targets), do: Enum.filter(targets, &Map.get(&1, :enabled, true))
  def target_by_name(targets, name), do: Enum.find(targets, &(&1.name == name || &1[:name] == name))
end
```

Create `apps/backplane_host_agent/lib/backplane/host_agent/installer.ex`:

```elixir
defmodule Backplane.HostAgent.Installer do
  alias Backplane.HostAgent.SkillBundle

  def install_extracted(source_root, skill, targets) do
    with {:ok, _root} <- SkillBundle.validate(source_root) do
      install_targets(source_root, skill, targets)
    end
  end

  defp install_targets(source_root, skill, targets) do
    Enum.reduce_while(skill["targets"] || [], {:ok, []}, fn target_name, {:ok, installed} ->
      case Enum.find(targets, &(Map.get(&1, :name) == target_name)) do
        nil ->
          {:halt, {:error, {:target_missing, target_name}}}

        %{enabled: false} ->
          {:cont, {:ok, installed}}

        target ->
          case install_one(source_root, skill["slug"], target) do
            :ok -> {:cont, {:ok, installed ++ [target_name]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp install_one(source_root, slug, target) do
    target_root = target.path || target[:path]

    if File.dir?(target_root) do
      tmp_root = Path.join([target_root, ".backplane-tmp"])
      tmp_path = Path.join(tmp_root, slug <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false))
      final_path = Path.join(target_root, slug)
      backup_path = final_path <> ".backplane-backup"

      File.mkdir_p!(tmp_root)
      File.cp_r!(source_root, tmp_path)
      if File.exists?(backup_path), do: File.rm_rf!(backup_path)
      if File.exists?(final_path), do: File.rename!(final_path, backup_path)
      File.rename!(tmp_path, final_path)
      if File.exists?(backup_path), do: File.rm_rf!(backup_path)
      :ok
    else
      {:error, {:target_missing, target.name || target[:name]}}
    end
  rescue
    error -> {:error, error}
  end
end
```

- [ ] **Step 7: Run scoped tests**

Run:

```bash
devenv shell -- mix test apps/backplane_host_agent/test/backplane/host_agent/reconciler_test.exs apps/backplane_host_agent/test/backplane/host_agent/checksum_test.exs apps/backplane_host_agent/test/backplane/host_agent/skill_bundle_test.exs apps/backplane_host_agent/test/backplane/host_agent/installer_test.exs
```

Expected: all local runtime tests pass.

- [ ] **Step 8: Commit**

Run GitNexus `detect_changes`, then:

```bash
git add apps/backplane_host_agent/lib/backplane/host_agent/reconciler.ex apps/backplane_host_agent/lib/backplane/host_agent/checksum.ex apps/backplane_host_agent/lib/backplane/host_agent/skill_bundle.ex apps/backplane_host_agent/lib/backplane/host_agent/installer.ex apps/backplane_host_agent/lib/backplane/host_agent/local_store.ex apps/backplane_host_agent/test/backplane/host_agent/reconciler_test.exs apps/backplane_host_agent/test/backplane/host_agent/checksum_test.exs apps/backplane_host_agent/test/backplane/host_agent/skill_bundle_test.exs apps/backplane_host_agent/test/backplane/host_agent/installer_test.exs
git commit -m "feat(host-agent): add local reconciliation and install logic"
```

## Task 8: Channel Wrapper, Reporter, Worker Sync Loop

**Files:**

- Create: `apps/backplane_host_agent/lib/backplane/host_agent/channel.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/reporter.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/worker.ex`
- Test: `apps/backplane_host_agent/test/backplane/host_agent/reporter_test.exs`
- Test: `apps/backplane_host_agent/test/backplane/host_agent/worker_test.exs`

- [ ] **Step 1: Write reporter tests**

Create `apps/backplane_host_agent/test/backplane/host_agent/reporter_test.exs`:

```elixir
defmodule Backplane.HostAgent.ReporterTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Reporter

  test "formats heartbeat payload" do
    config = %{
      machine_name: "t430",
      targets: [%{name: "agents", runtime: "agent-skills", path: "/tmp/skills", enabled: true}]
    }

    payload = Reporter.heartbeat(config)

    assert payload["machine_name"] == "t430"
    assert [%{"name" => "agents"}] = payload["targets"]
  end

  test "formats sync result payload" do
    result = Reporter.sync_result(:synced, [%{skill_name: "Repo Review", status: "synced"}])

    assert result["status"] == "synced"
    assert [%{"skill_name" => "Repo Review"}] = result["results"]
  end
end
```

- [ ] **Step 2: Add Reporter**

Create `apps/backplane_host_agent/lib/backplane/host_agent/reporter.ex`:

```elixir
defmodule Backplane.HostAgent.Reporter do
  def heartbeat(config) do
    %{
      "machine_name" => config.machine_name,
      "hostname" => List.to_string(:inet.gethostname() |> elem(1)),
      "agent_version" => "0.1.0",
      "targets" => Enum.map(config.targets, &stringify_target/1),
      "metadata" => %{"otp_release" => System.otp_release()}
    }
  end

  def sync_result(status, results) do
    %{
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "status" => to_string(status),
      "results" => Enum.map(results, &stringify_map/1)
    }
  end

  defp stringify_target(target), do: stringify_map(target)

  defp stringify_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
```

- [ ] **Step 3: Add Channel wrapper**

Create `apps/backplane_host_agent/lib/backplane/host_agent/channel.ex`:

```elixir
defmodule Backplane.HostAgent.Channel do
  def start_socket(config) do
    Phoenix.SocketClient.start_link(
      url: config.socket_url,
      headers: [{"X-Backplane-Host-Token", config.token}],
      reconnect?: true,
      reconnect_interval: min(config.interval_ms, 60_000)
    )
  end

  def join(socket, host_id) do
    Phoenix.SocketClient.Channel.join(socket, "host_agent:#{host_id}", %{})
  end

  def push(channel, event, payload, timeout \\ 5_000) do
    Phoenix.SocketClient.Channel.push(channel, event, payload, timeout)
  end
end
```

- [ ] **Step 4: Write worker tests with injected channel module**

Create `apps/backplane_host_agent/test/backplane/host_agent/worker_test.exs`:

```elixir
defmodule Backplane.HostAgent.WorkerTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Worker

  test "status returns last sync state" do
    {:ok, pid} = Worker.start_link(name: nil)
    assert %{last_sync: nil, last_error: nil} = GenServer.call(pid, :status)
  end
end
```

- [ ] **Step 5: Update Worker**

Modify `apps/backplane_host_agent/lib/backplane/host_agent/worker.ex` so `start_link/1` accepts a `:name` option:

```elixir
def start_link(opts) do
  name = Keyword.get(opts, :name, __MODULE__)
  GenServer.start_link(__MODULE__, opts, name: name)
end
```

Keep the worker small in this task. Full download/install execution can be added after end-to-end fixtures exist.

- [ ] **Step 6: Run scoped tests**

Run:

```bash
devenv shell -- mix test apps/backplane_host_agent/test/backplane/host_agent/reporter_test.exs apps/backplane_host_agent/test/backplane/host_agent/worker_test.exs
```

Expected: reporter and worker tests pass.

- [ ] **Step 7: Commit**

Run GitNexus `detect_changes`, then:

```bash
git add apps/backplane_host_agent/lib/backplane/host_agent/channel.ex apps/backplane_host_agent/lib/backplane/host_agent/reporter.ex apps/backplane_host_agent/lib/backplane/host_agent/worker.ex apps/backplane_host_agent/test/backplane/host_agent/reporter_test.exs apps/backplane_host_agent/test/backplane/host_agent/worker_test.exs
git commit -m "feat(host-agent): add channel wrapper and sync reporting"
```

## Task 9: End-To-End Sync Test And Full Verification

**Files:**

- Create: `apps/backplane_web/test/backplane_web/host_agent_sync_e2e_test.exs`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/worker.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/installer.ex`

- [ ] **Step 1: Write end-to-end test**

Create `apps/backplane_web/test/backplane_web/host_agent_sync_e2e_test.exs`:

```elixir
defmodule BackplaneWeb.HostAgentSyncE2ETest do
  use Backplane.ChannelCase, async: false

  alias Backplane.Repo
  alias Backplane.Skills.{Assignments, DesiredState, Hosts, Skill}

  @tag :tmp_dir
  test "host can receive desired skill and report synced", %{tmp_dir: tmp_dir} do
    {:ok, host, _token} =
      Hosts.create_host(%{
        "name" => "t430",
        "targets" => [%{"name" => "agents", "runtime" => "agent-skills", "path" => tmp_dir, "enabled" => true}]
      })

    skill =
      Repo.insert!(%Skill{
        id: "db/e2e-skill",
        slug: "e2e-skill",
        name: "E2E Skill",
        version: "0.1.0",
        content: "# E2E Skill",
        content_hash: "sha256:" <> String.duplicate("e", 64),
        archive_ref: "sha256/#{String.duplicate("e", 64)}.tar.gz",
        enabled: true
      })

    {:ok, _assignment} = Assignments.assign_skill(host, skill, %{"targets" => ["agents"]})

    assert {:ok, %{skills: [desired]}} = DesiredState.for_host(host)
    assert desired.slug == "e2e-skill"
    assert desired.targets == ["agents"]
  end
end
```

Expected: this test proves the server-side desired-state path before the worker-level sync assertion below.

- [ ] **Step 2: Add worker-level sync assertion**

Extend `apps/backplane_host_agent/test/backplane/host_agent/worker_test.exs` with a deterministic sync test that injects desired state and installer callbacks instead of opening a real network socket:

```elixir
defmodule Backplane.HostAgent.WorkerTest.FakeChannel do
  def push(_channel, "heartbeat", _payload, _timeout), do: {:ok, %{"ok" => true}}
  def push(_channel, "get_desired", _payload, _timeout), do: {:ok, %{"skills" => []}}
  def push(_channel, "sync_result", _payload, _timeout), do: {:ok, %{"ok" => true}}
end

defmodule Backplane.HostAgent.WorkerTest.FakeInstaller do
  def install(_skill, _config), do: {:ok, ["agents"]}
end

test "run_once reconciles desired state and reports synced" do
  desired = %{
    "skills" => [
      %{
        "id" => "db/repo-review",
        "slug" => "repo-review",
        "name" => "Repo Review",
        "checksum" => "sha256:abc",
        "targets" => ["agents"],
        "download_url" => "/api/host-agent/skills/repo-review/download"
      }
    ]
  }

  state = %{
    config: %{machine_name: "t430", targets: [%{name: "agents", path: "/tmp/skills", enabled: true}]},
    manifest: %Backplane.HostAgent.Manifest{machine_name: "t430", skills: []},
    channel: :fake_channel,
    channel_module: Backplane.HostAgent.WorkerTest.FakeChannel,
    installer_module: Backplane.HostAgent.WorkerTest.FakeInstaller,
    last_sync: nil,
    last_error: nil,
    desired: desired
  }

  assert {:ok, next_state} = Worker.run_once(state)
  assert %DateTime{} = next_state.last_sync
  assert next_state.last_error == nil
end
```

Modify `apps/backplane_host_agent/lib/backplane/host_agent/worker.ex` to expose `run_once/1` for this test and for `handle_info(:sync)`:

```elixir
def run_once(state) do
  channel_module = Map.fetch!(state, :channel_module)
  installer_module = Map.fetch!(state, :installer_module)

  with {:ok, _} <- channel_module.push(state.channel, "heartbeat", Reporter.heartbeat(state.config), 5_000),
       {:ok, desired} <- desired_state(state, channel_module),
       actions <- Reconciler.plan(desired["skills"] || [], state.manifest),
       {:ok, results} <- execute_actions(actions, state.config, installer_module),
       {:ok, _} <- channel_module.push(state.channel, "sync_result", Reporter.sync_result(:synced, results), 5_000) do
    {:ok, %{state | last_sync: DateTime.utc_now(), last_error: nil}}
  else
    {:error, reason} -> {:error, %{state | last_error: reason}}
  end
end
```

`desired_state/2` must return `state.desired` when that key is present; otherwise it pushes `"get_desired"` over the channel. `execute_actions/3` must call the installer for `:install`, `:update`, and `:repair`, return `:noop` results for `:noop`, and return `:removed` results for `:remove` after removing manifest-owned skill directories.

- [ ] **Step 3: Run all scoped test groups**

Run:

```bash
devenv shell -- mix test apps/backplane/test/backplane/skills apps/backplane_web/test/backplane_web/channels apps/backplane_web/test/backplane_web/live/skill_live_test.exs apps/backplane_host_agent/test
```

Expected: all Host Agent and Skills scoped tests pass.

- [ ] **Step 4: Run compile**

Run:

```bash
devenv shell -- mix compile
```

Expected: umbrella compiles, including `apps/backplane_host_agent`.

- [ ] **Step 5: Run GitNexus change detection**

Run:

```bash
npx gitnexus analyze
```

Then run GitNexus `detect_changes` with scope `all`.

Expected: changes affect Skills, Host Agent socket/channel, Skill admin UI, and the new Host Agent app only.

- [ ] **Step 6: Final commit**

Run:

```bash
git add apps/backplane apps/backplane_web apps/backplane_host_agent
git commit -m "feat(host-agent): sync assigned skill archives"
```

Expected: final Host Agent implementation commit is separate from the prerequisite Skills Hub and intermediate Host Agent commits.

## Final Verification Checklist

- [ ] `devenv shell -- mix compile`
- [ ] `devenv shell -- mix test apps/backplane/test/backplane/skills`
- [ ] `devenv shell -- mix test apps/backplane_web/test/backplane_web/channels`
- [ ] `devenv shell -- mix test apps/backplane_web/test/backplane_web/live/skill_live_test.exs`
- [ ] `devenv shell -- mix test apps/backplane_host_agent/test`
- [ ] GitNexus `detect_changes` reviewed
- [ ] No unrelated dirty files staged
