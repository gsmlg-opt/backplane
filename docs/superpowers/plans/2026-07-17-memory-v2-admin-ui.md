# Memory V2 Admin Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the legacy Memory admin pages with a fail-closed, four-page V2 operations console over authoritative event streams, committed-event notifications, and guarded rollout controls.

**Architecture:** Keep V1 projections and public contracts intact, correct the public V2 append boundary, and add a transactional PostgreSQL notification path plus a `Backplane.Memory.Operations` facade. Four Phoenix LiveViews consume that facade only, share DuskMoon presentation components, keep filters and selections in the URL, and run in a dedicated required-auth LiveView session.

**Tech Stack:** Elixir 1.18, OTP 28, Phoenix 1.8 LiveView, Ecto/PostgreSQL, Postgrex notifications, Phoenix PubSub, ExUnit, DuskMoon 9.7, Tailwind CSS 4, Chrome DevTools.

---

## Execution rules

- Work only in `/home/gao/Workspace/gsmlg-opt/backplane/.trees/memory-v2-ui` on branch `codex/memory-v2-ui`.
- Preserve the V1 Memory schemas, contexts, workers, MCP tools, migrations, projection writes, and response contracts.
- Use only `phoenix_duskmoon` and existing Tailwind/DuskMoon utilities in the admin UI. Do not add DaisyUI, `core_components.ex`, or a new JavaScript component.
- Streams and events are inspect-only. The only mutations in this plan are the three rollout gates.
- Keep `Events.Query`'s public limit cap of 500 for compatibility; impose the admin cap of 100 in `Operations`.
- Use persisted `inserted_at` for the 24-hour count and 60-minute ingestion-volume buckets. Use `occurred_at DESC, id DESC` for the event timeline.
- Every database-backed command below includes `PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres`; preserve that exact socket.
- Before changing an existing function or module, call `gitnexus_impact` with the exact symbol named by that task and `direction: "upstream"`. If GitNexus cannot resolve the Elixir symbol, record that result and use the direct caller/test map in this plan. If it reports HIGH or CRITICAL risk, stop and report the blast radius before editing.
- Before every commit, run `gitnexus_detect_changes()` and compare it with `git status --short` and the staged diff. GitNexus is advisory here because its current Elixir index does not resolve several Memory symbols; direct Git output is authoritative.
- Follow red-green-refactor within every task. Do not combine task commits.

## File map

### Create

- `apps/backplane_memory/lib/backplane/memory/events/preparation.ex` — pure normalization and privacy-filtering seam.
- `apps/backplane_memory/lib/backplane/memory/event_notifier.ex` — transactional notification helper and supervised PostgreSQL listener.
- `apps/backplane_memory/lib/backplane/memory/operations.ex` — admin-facing V2 facade, overview orchestration, subscriptions, and notification matching.
- `apps/backplane_memory/lib/backplane/memory/operations/params.ex` — whitelist-based web parameter normalization.
- `apps/backplane_memory/lib/backplane/memory/operations/query.ex` — typed stream/event aggregate queries and keyset pagination.
- `apps/backplane_memory/lib/backplane/memory/operations/rollout.ex` — configured/effective gate state and dependency-safe writes.
- `apps/backplane_system/priv/repo/migrations/20260717000001_add_memory_v2_admin_indexes.exs` — concurrent stream/event keyset indexes.
- `apps/backplane_system/test/backplane/runtime_config_test.exs` — production TOML and environment credential wiring.
- `apps/backplane_admin/lib/backplane/admin/plugs/memory_detail_plug.ex` — disconnected-request 404/503 guard for detail IDs.
- `apps/backplane_admin/lib/backplane/admin/components/memory_components.ex` — safe, query-free Memory presentation helpers.
- `apps/backplane_admin/lib/backplane/admin/live/memory_streams_live.ex` — stream inventory and bounded sequence detail.
- `apps/backplane_admin/lib/backplane/admin/live/memory_events_live.ex` — global event explorer and event detail.
- `apps/backplane_admin/lib/backplane/admin/live/memory_pipeline_live.ex` — implemented gates and unavailable-stage rail.
- `apps/backplane_admin/test/support/memory_fixtures.ex` — authenticated connection, gate cleanup, and persisted event fixtures.
- `apps/backplane_admin/test/backplane/admin/live/memory_overview_live_test.exs`
- `apps/backplane_admin/test/backplane/admin/live/memory_streams_live_test.exs`
- `apps/backplane_admin/test/backplane/admin/live/memory_events_live_test.exs`
- `apps/backplane_admin/test/backplane/admin/live/memory_pipeline_live_test.exs`
- `apps/backplane_memory/test/backplane/memory/events/preparation_test.exs`
- `apps/backplane_memory/test/backplane/memory/events/event_notifier_test.exs`
- `apps/backplane_memory/test/backplane/memory/operations/params_test.exs`
- `apps/backplane_memory/test/backplane/memory/operations/events_test.exs`
- `apps/backplane_memory/test/backplane/memory/operations/streams_test.exs`
- `apps/backplane_memory/test/backplane/memory/operations/rollout_test.exs`
- `apps/backplane_memory/test/backplane/memory/operations/overview_test.exs`

### Modify

- `apps/backplane/lib/backplane/web/admin_auth_plug.ex`
- `apps/backplane/test/backplane/web/admin_auth_plug_test.exs`
- `apps/backplane_memory/mix.exs`
- `apps/backplane_memory/lib/backplane/memory/application.ex`
- `apps/backplane_memory/lib/backplane/memory/events.ex`
- `apps/backplane_memory/lib/backplane/memory/events/store.ex`
- `apps/backplane_memory/lib/backplane/memory/events/query.ex`
- `apps/backplane_system/lib/backplane/settings.ex`
- `apps/backplane_system/test/backplane/settings_test.exs`
- `apps/backplane_memory/test/backplane/memory/events/events_test.exs`
- `apps/backplane_memory/test/backplane/memory/events/query_test.exs`
- `apps/backplane_memory/test/backplane/memory/events/migration_test.exs`
- `apps/backplane_admin/lib/backplane/admin/router.ex`
- `apps/backplane_admin/lib/backplane/admin/components/layouts.ex`
- `apps/backplane_admin/lib/backplane/admin/live/memory_overview_live.ex`
- `apps/backplane_admin/test/backplane/admin/route_boundary_test.exs`
- `apps/backplane_admin/test/backplane/admin/endpoint_test.exs`
- `config/dev.exs`
- `config/runtime.exs`
- `README.md`

### Delete after replacement tests are green

- `apps/backplane_admin/lib/backplane/admin/live/memory_live.ex`
- `apps/backplane_admin/lib/backplane/admin/live/memory_stats_live.ex`
- `apps/backplane_admin/lib/backplane/admin/live/memory_observations_live.ex`
- `apps/backplane_admin/lib/backplane/admin/live/memory_sessions_live.ex`
- `apps/backplane_admin/lib/backplane/admin/live/memory_graph_live.ex`
- `apps/backplane_admin/lib/backplane/admin/live/memory_actions_live.ex`
- `apps/backplane_admin/lib/backplane/admin/live/memory_audit_live.ex`
- `apps/backplane_admin/lib/backplane/admin/live/memory_config_live.ex`
- `apps/backplane_admin/test/backplane/admin/live/memory_live_test.exs`

## Result contracts

The implementation must keep these shapes stable between the core and LiveView tasks:

```elixir
%{
  streams: [Backplane.Memory.Events.Stream.t()],
  next_cursor: String.t() | nil,
  filters: map()
}

%{
  events: [Backplane.Memory.Events.Event.t()],
  next_cursor: String.t() | nil,
  filters: map()
}

%{
  events: [Backplane.Memory.Events.Event.t()],
  older_before: pos_integer() | nil,
  newer_after: pos_integer() | nil,
  window: :latest | :before | :after,
  params: map()
}

%{
  pipeline: gate_state(),
  events: gate_state(),
  dual_write: gate_state(),
  later: [future_stage()]
}

%{
  pipeline: {:ok, term()} | {:error, term()},
  persisted_counts: {:ok, term()} | {:error, term()},
  event_volume: {:ok, term()} | {:error, term()},
  runtime_metrics: {:ok, term()} | {:error, term()},
  recent_events: {:ok, term()} | {:error, term()},
  active_streams: {:ok, term()} | {:error, term()}
}
```

For the rollout result, use these concrete map shapes:

```elixir
gate_state = %{
  key: String.t(),
  label: String.t(),
  configured: boolean(),
  effective: boolean(),
  blocked: boolean()
}

future_stage = %{
  key: String.t(),
  label: String.t(),
  available: false
}
```

Invalid web input returns:

```elixir
{:error, {:invalid_param, key, canonical_params}}
```

where `key` is the rejected atom or string and `canonical_params` retains every valid nonblank filter while dropping the invalid value. LiveViews use that map for a `replace: true` canonical patch and show one concise flash.

### Task 1: Make Memory authentication fail closed and wire remote credentials

**Files:**

- Modify: `apps/backplane/lib/backplane/web/admin_auth_plug.ex`
- Modify: `apps/backplane/test/backplane/web/admin_auth_plug_test.exs`
- Create: `apps/backplane_system/test/backplane/runtime_config_test.exs`
- Modify: `apps/backplane_admin/test/backplane/admin/endpoint_test.exs`
- Modify: `config/dev.exs`
- Modify: `config/runtime.exs`
- Modify: `README.md`

- [ ] **Step 1: Check the auth/config blast radius**

  Run impact analysis for `Backplane.Web.AdminAuthPlug.call/2`, `Backplane.Web.AdminAuthPlug.init/1`, and the admin endpoint configuration. The known direct callers are the admin `:browser` pipeline and the new Memory-only pipeline added later.

- [ ] **Step 2: Add required-mode RED tests**

  Change `Backplane.Web.AdminAuthPlugTest` to `async: false`, snapshot both application keys in setup, and restore their exact prior values in `on_exit/1`. Keep the existing optional-mode assertions and add:

  ```elixir
  test "required mode returns 503 when credentials are absent, partial, or blank" do
    for {username, password} <- [
          {nil, nil},
          {"admin", nil},
          {nil, "secret"},
          {"", "secret"},
          {"admin", ""}
        ] do
      restore_env(:admin_username, username)
      restore_env(:admin_password, password)

      conn =
        conn(:get, "/memory")
        |> AdminAuthPlug.call(AdminAuthPlug.init(required: true))

      assert conn.halted
      assert conn.status == 503
      assert conn.resp_body == "Admin authentication is not configured"
      assert get_resp_header(conn, "www-authenticate") == []
    end
  end

  test "required mode challenges a request only after credentials are configured" do
    Application.put_env(:backplane, :admin_username, "admin")
    Application.put_env(:backplane, :admin_password, "secret")

    conn =
      conn(:get, "/memory")
      |> AdminAuthPlug.call(AdminAuthPlug.init(required: true))

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [
             "Basic realm=\"Backplane Admin\""
           ]
  end
  ```

  Also call required mode with a correct header and assert the connection is not halted.

- [ ] **Step 3: Run the plug test to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane/test/backplane/web/admin_auth_plug_test.exs
  ```

  Expected: only the required-mode cases fail because missing credentials still pass through.

- [ ] **Step 4: Implement required mode without changing optional behavior**

  Replace the plug's option and credential branches with:

  ```elixir
  @impl true
  def init(opts) do
    opts = Keyword.validate!(opts, required: false)

    unless is_boolean(opts[:required]) do
      raise ArgumentError, ":required must be a boolean"
    end

    opts
  end

  @impl true
  def call(conn, opts) do
    case get_admin_credentials() do
      {:ok, {username, password}} ->
        verify_basic_auth(conn, username, password)

      :error when opts[:required] ->
        conn
        |> send_resp(503, "Admin authentication is not configured")
        |> halt()

      :error ->
        conn
    end
  end

  defp get_admin_credentials do
    username = Application.get_env(:backplane, :admin_username)
    password = Application.get_env(:backplane, :admin_password)

    if is_binary(username) and is_binary(password) and username != "" and password != "" do
      {:ok, {username, password}}
    else
      :error
    end
  end
  ```

  Update the module documentation to distinguish optional default mode from required Memory mode. Keep the existing constant-time comparison and 401 challenge.

- [ ] **Step 5: Add runtime/dev configuration RED tests**

  In `runtime_config_test.exs`, use `ExUnit.Case, async: false`. Snapshot and restore `BACKPLANE_CONFIG`, `SECRET_KEY_BASE`, `BACKPLANE_ADMIN_USERNAME`, and `BACKPLANE_ADMIN_PASSWORD`. Write a test-owned TOML under `tmp_dir`, evaluate `config/runtime.exs` with `Config.Reader.read!(path, env: :prod)`, and assert:

  ```elixir
  backplane_config = Keyword.fetch!(config, :backplane)
  assert Keyword.fetch!(backplane_config, :admin_username) == "env-admin"
  assert Keyword.fetch!(backplane_config, :admin_password) == "env-secret"
  ```

  Build the test directory with:

  ```elixir
  tmp_dir =
    Path.join(
      System.tmp_dir!(),
      "backplane-runtime-config-#{System.unique_integer([:positive, :monotonic])}"
    )

  File.mkdir_p!(tmp_dir)
  on_exit(fn -> File.rm_rf!(tmp_dir) end)

  config_path = Path.join(tmp_dir, "backplane.toml")

  File.write!(config_path, """
  [backplane]
  host = "0.0.0.0"
  port = 4100
  admin_username = "toml-admin"
  admin_password = "toml-secret"

  [database]
  url = "postgres://localhost/backplane_test"
  """)
  ```

  Set `BACKPLANE_CONFIG` to `config_path` and `SECRET_KEY_BASE` to a test string of at least 64 bytes before each read. Run a second read without the two environment overrides and assert the TOML values are used.

  Run a third read with `BACKPLANE_CONFIG` pointing to a nonexistent test path
  and both environment credentials set. Assert the environment-only values are
  still applied; production authentication must not require a TOML file when
  both credential variables are present.

  In `endpoint_test.exs`, make the module `async: false`, read `config/dev.exs`, and assert:

  ```elixir
  assert endpoint_config[:http][:ip] == {0, 0, 0, 0}
  assert endpoint_config[:http][:port] == 4221
  assert backplane_config[:admin_username] == "dev-admin"
  assert backplane_config[:admin_password] == "dev-secret"
  ```

  Set and restore the two environment variables around that `Config.Reader.read!/2` call.

- [ ] **Step 6: Run the config tests to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_system/test/backplane/runtime_config_test.exs apps/backplane_admin/test/backplane/admin/endpoint_test.exs
  ```

  Expected: the new credential and IPv4 assertions fail.

- [ ] **Step 7: Wire TOML, environment overrides, and IPv4-any**

  Add the two development keys to the existing `config :backplane` block:

  ```elixir
  config :backplane,
    admin_username: System.get_env("BACKPLANE_ADMIN_USERNAME"),
    admin_password: System.get_env("BACKPLANE_ADMIN_PASSWORD")
  ```

  Change only the admin endpoint IP tuple to:

  ```elixir
  config :backplane_admin, Backplane.Admin.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: 4221]
  ```

  Keep the public API endpoint unchanged.

  When `bp` is present in production, add its parsed values:

  ```elixir
  config :backplane,
    admin_username: bp.admin_username,
    admin_password: bp.admin_password
  ```

  Inside the outer `config_env() == :prod` block, but outside the
  `File.exists?(config_path)` block, apply non-`nil` environment overrides
  independently:

  ```elixir
  if username = System.get_env("BACKPLANE_ADMIN_USERNAME") do
    config :backplane, admin_username: username
  end

  if password = System.get_env("BACKPLANE_ADMIN_PASSWORD") do
    config :backplane, admin_password: password
  end
  ```

  This intentionally lets a partial or blank override make required Memory routes return 503.

- [ ] **Step 8: Correct the operator documentation**

  Replace the README statement that TOML credentials are not applied. Document that production reads `admin_username` and `admin_password` from `[backplane]`, environment variables override them, remote development reads the same variables, changes require a restart, and Memory V2 returns 503 until both are configured.

- [ ] **Step 9: Run GREEN verification**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane/test/backplane/web/admin_auth_plug_test.exs apps/backplane_system/test/backplane/runtime_config_test.exs apps/backplane_admin/test/backplane/admin/endpoint_test.exs
  ```

  Expected: all focused tests pass.

- [ ] **Step 10: Detect scope and commit**

  Run `gitnexus_detect_changes()`, inspect `git diff --check`, then:

  ```bash
  git add apps/backplane/lib/backplane/web/admin_auth_plug.ex \
    apps/backplane/test/backplane/web/admin_auth_plug_test.exs \
    apps/backplane_system/test/backplane/runtime_config_test.exs \
    apps/backplane_admin/test/backplane/admin/endpoint_test.exs \
    config/dev.exs config/runtime.exs README.md
  git diff --cached --check
  git commit -m "feat(memory): require v2 admin authentication"
  ```

### Task 2: Correct the persistent Events facade

**Files:**

- Create: `apps/backplane_memory/lib/backplane/memory/events/preparation.ex`
- Create: `apps/backplane_memory/test/backplane/memory/events/preparation_test.exs`
- Modify: `apps/backplane_memory/lib/backplane/memory/events.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/events/store.ex`
- Modify: `apps/backplane_memory/test/backplane/memory/events/events_test.exs`

- [ ] **Step 1: Check the append blast radius**

  Run impact analysis for `Backplane.Memory.Events.append/1`, `append_batch/1`, `Backplane.Memory.Events.Store.append_multi/3`, and `append_batch/2`. Direct inspection shows `Store.append_multi/3` is used by the observation/session dual-write paths, so recursion and rollback behavior are high-test-surface concerns even if GitNexus reports no indexed callers.

- [ ] **Step 2: Split pure tests from persistence tests**

  Move the current normalization, recursive redaction, invalid UTF-8, invalid attribute, and stop-at-first-invalid batch assertions from `events_test.exs` into `preparation_test.exs`. Rename the tested alias and calls to:

  ```elixir
  alias Backplane.Memory.Events.Preparation

  Preparation.prepare(attrs)
  Preparation.prepare_batch(attrs_list)
  ```

  Change `EventsTest` to `use Backplane.Memory.DataCase, async: false` and replace it with database assertions:

  ```elixir
  defp unique(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  test "append persists and allocates stream-local sequences" do
    stream_id = unique("facade")

    assert {:ok, first} =
             Events.append(%{stream_id: stream_id, event_type: "task.created"})

    assert {:ok, second} =
             Events.append(%{stream_id: stream_id, event_type: "task.updated"})

    assert [first.sequence, second.sequence] == [1, 2]
    assert repo().get!(Event, first.id).stream_id == stream_id
    assert repo().get!(Stream, stream_id).next_sequence == 3
  end

  test "append_batch persists in input order and rolls back preparation failure" do
    stream_id = unique("batch")

    assert {:ok, events} =
             Events.append_batch([
               %{stream_id: stream_id, event_type: "task.created"},
               %{stream_id: stream_id, event_type: "task.updated"}
             ])

    assert Enum.map(events, & &1.sequence) == [1, 2]

    invalid_stream = unique("invalid")

    assert {:error, :missing_identity} =
             Events.append_batch([
               %{stream_id: invalid_stream, event_type: "task.created"},
               %{event_type: "task.updated"}
             ])

    refute repo().get(Stream, invalid_stream)
  end
  ```

- [ ] **Step 3: Run the facade tests to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/events/preparation_test.exs apps/backplane_memory/test/backplane/memory/events/events_test.exs
  ```

  Expected: `Preparation` is missing and facade persistence assertions fail.

- [ ] **Step 4: Add the pure preparation seam**

  Create:

  ```elixir
  defmodule Backplane.Memory.Events.Preparation do
    @moduledoc false

    alias Backplane.Memory.Events.{Event, Types}

    def prepare(attrs) do
      with {:ok, normalized} <- Types.normalize(attrs),
           {:ok, filtered} <- Backplane.Memory.Privacy.Filter.apply_event(normalized) do
        allowed_fields = Event.__schema__(:fields) ++ [:id]

        allowed =
          for {key, value} <- filtered, key in allowed_fields, into: %{} do
            {key, value}
          end

        {:ok, struct(Event, allowed)}
      end
    end

    def prepare_batch(list) when is_list(list) do
      list
      |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, events} ->
        case prepare(attrs) do
          {:ok, event} -> {:cont, {:ok, [event | events]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, events} -> {:ok, Enum.reverse(events)}
        {:error, reason} -> {:error, reason}
      end
    end

    def prepare_batch(_value), do: {:error, :invalid_attributes}
  end
  ```

- [ ] **Step 5: Delegate the public facade to Store and remove the cycle**

  Make `Events.append/1` and `append_batch/1`:

  ```elixir
  def append(attrs), do: Store.append(attrs)
  def append_batch(attrs), do: Store.append_batch(attrs)
  ```

  In `Store`, alias `Preparation`, call `Preparation.prepare/1` from `append_multi/3`, and call `Preparation.prepare_batch/1` before `transact_batch/3`. Do not call the public `Events` facade from `Store`.

- [ ] **Step 6: Run facade and storage GREEN tests**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/events/preparation_test.exs apps/backplane_memory/test/backplane/memory/events/events_test.exs apps/backplane_memory/test/backplane/memory/events/store_test.exs apps/backplane_memory/test/backplane/memory/observations_test.exs
  ```

  Expected: public calls persist, pure preparation retains existing privacy behavior, and outer Multi behavior stays green.

- [ ] **Step 7: Detect scope and commit**

  Run `gitnexus_detect_changes()`, inspect the direct diff, then:

  ```bash
  git add apps/backplane_memory/lib/backplane/memory/events.ex \
    apps/backplane_memory/lib/backplane/memory/events/store.ex \
    apps/backplane_memory/lib/backplane/memory/events/preparation.ex \
    apps/backplane_memory/test/backplane/memory/events/events_test.exs \
    apps/backplane_memory/test/backplane/memory/events/preparation_test.exs
  git diff --cached --check
  git commit -m "fix(memory): persist public event appends"
  ```

### Task 3: Broadcast only committed, newly inserted events

**Files:**

- Create: `apps/backplane_memory/lib/backplane/memory/event_notifier.ex`
- Create: `apps/backplane_memory/test/backplane/memory/events/event_notifier_test.exs`
- Modify: `apps/backplane_memory/lib/backplane/memory/events/store.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/application.ex`
- Modify: `apps/backplane_memory/mix.exs`

- [ ] **Step 1: Check the insert/supervision blast radius**

  Run impact analysis for `Backplane.Memory.Events.Store.insert_new_event/3` and `Backplane.Memory.Application.start/2`. Direct inspection establishes that `insert_new_event/3` is shared by single appends, batches, outer Multis, and all observation/session dual-write paths. Do not modify `Observations`; notification coverage must come from this one insert seam.

- [ ] **Step 2: Add committed-notification RED tests**

  Create the test with `use ExUnit.Case, async: false`, not `DataCase`; these
  rows must commit outside the sandbox transaction. Import `Ecto.Query`, alias
  `Backplane.Memory.EventNotifier`,
  `Backplane.Memory.Events.{Event, Store, Stream}`, and
  `Ecto.Adapters.SQL.Sandbox`, then use:

  ```elixir
  defp unboxed(fun) do
    :ok = Sandbox.checkout(repo(), sandbox: false)

    try do
      fun.()
    after
      :ok = Sandbox.checkin(repo())
    end
  end

  defp cleanup_on_exit(prefix) do
    on_exit(fn ->
      unboxed(fn ->
        repo().delete_all(
          from(event in Event, where: like(event.stream_id, ^"#{prefix}%"))
        )

        repo().delete_all(
          from(stream in Stream, where: like(stream.stream_id, ^"#{prefix}%"))
        )
      end)
    end)
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  defp unique(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
  ```

  Cover each boundary:

  ```elixir
  test "broadcasts a safe summary only after commit"
  test "an outer transaction rollback emits no notification"
  test "an idempotent duplicate emits no second notification"
  test "a batch emits once per inserted event"
  test "the summary excludes content and payload"
  ```

  In the commit test, subscribe first, start an unboxed outer transaction in a
  task, call `Store.append/1` inside it, signal the test before returning from
  the transaction, and assert:

  ```elixir
  parent = self()

  transaction_task =
    Task.async(fn ->
      unboxed(fn ->
        repo().transaction(fn ->
          {:ok, event} =
            Store.append(%{
              stream_id: "#{prefix}:stream",
              event_type: "task.created"
            })

          send(parent, {:inserted_inside_transaction, self(), event})

          receive do
            :commit -> event
          end
        end)
      end)
    end)

  assert_receive {
    :inserted_inside_transaction,
    transaction_pid,
    event
  }

  refute_receive {:memory_event_inserted, _summary}, 100
  send(transaction_pid, :commit)

  assert {:ok, ^event} = Task.await(transaction_task, 5_000)

  assert_receive {:memory_event_inserted, summary}, 1_000
  assert Map.keys(summary) |> Enum.sort() ==
           [
             :agent_id,
             :event_type,
             :id,
             :occurred_at,
             :project,
             :run_id,
             :session_id,
             :status,
             :stream_id,
             :tool_name
           ]
  refute Map.has_key?(summary, :content)
  refute Map.has_key?(summary, :payload)
  ```

- [ ] **Step 3: Run notifier tests to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/events/event_notifier_test.exs
  ```

  Expected: the notifier module and broadcasts are missing.

- [ ] **Step 4: Add direct dependencies**

  Add these direct dependencies to `apps/backplane_memory/mix.exs`, matching the umbrella's existing constraints:

  ```elixir
  [
    {:postgrex, "~> 0.19"},
    {:phoenix_pubsub, "~> 2.1"}
  ]
  ```

  `mix.lock` already resolves Postgrex 0.22.2 and Phoenix PubSub 2.2.0, so this step must not produce a lockfile version change.

- [ ] **Step 5: Implement the notifier**

  Create `Backplane.Memory.EventNotifier` as a GenServer with:

  ```elixir
  @database_channel "backplane_memory_v2_events"
  @topic "memory:v2:events"
  @notification_server Backplane.Memory.EventNotifications
  @summary_fields [
    :id,
    :stream_id,
    :event_type,
    :project,
    :agent_id,
    :session_id,
    :run_id,
    :tool_name,
    :status,
    :occurred_at
  ]

  def database_channel, do: @database_channel
  def topic, do: @topic

  def subscribe do
    Phoenix.PubSub.subscribe(Backplane.PubSub, @topic)
  end

  def enqueue(repo, event_id) do
    case Ecto.Adapters.SQL.query(
           repo,
           "SELECT pg_notify($1, $2)",
           [@database_channel, event_id]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, ref} = Postgrex.Notifications.listen(@notification_server, @database_channel)
    {:ok, %{listen_ref: ref}}
  end

  @impl true
  def handle_info(
        {:notification, _pid, ref, @database_channel, event_id},
        %{listen_ref: ref} = state
      ) do
    event =
      Backplane.Memory.Events.Event
      |> Ecto.Query.where([event], event.id == ^event_id)
      |> Ecto.Query.select([event], map(event, ^@summary_fields))
      |> repo().one()

    if event do
      Phoenix.PubSub.broadcast(
        Backplane.PubSub,
        @topic,
        {:memory_event_inserted, event}
      )
    end

    {:noreply, state}
  end
  ```

  Add `connection_options/0` that takes only Postgrex connection keys from
  `repo().config()`:

  ```elixir
  @connection_keys [
    :url,
    :hostname,
    :port,
    :database,
    :username,
    :password,
    :socket_dir,
    :ssl,
    :ssl_opts,
    :parameters,
    :connect_timeout,
    :socket_options,
    :types
  ]

  def connection_options do
    repo().config()
    |> Keyword.take(@connection_keys)
    |> Keyword.merge(
      name: @notification_server,
      sync_connect: true,
      auto_reconnect: false
    )
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
  ```

  Do not pass Ecto pool metadata such as `:pool`, `:pool_size`,
  `:telemetry_prefix`, `:otp_app`, or the Repo `:name`.

- [ ] **Step 6: Enqueue inside the existing database transaction**

  Alias `EventNotifier` in `Store`. In the successful `repo.insert/2` branch, keep the stream cursor update and then return success only after:

  ```elixir
  case EventNotifier.enqueue(repo, inserted.id) do
    :ok -> {:inserted, inserted, updated_stream}
    {:error, reason} -> {:error, reason}
  end
  ```

  Do not broadcast or notify after `repo.transaction/1` returns. Duplicates never enter this branch. A query error must propagate and roll back the event and stream update.

- [ ] **Step 7: Supervise connection before listener**

  Change `Backplane.Memory.Application` to:

  ```elixir
  children = [
    Supervisor.child_spec(
      {Postgrex.Notifications, EventNotifier.connection_options()},
      id: Backplane.Memory.EventNotifications
    ),
    EventNotifier
  ]

  opts = [strategy: :rest_for_one, name: Backplane.Memory.Supervisor]
  ```

  `:rest_for_one` restarts and re-subscribes the listener when the connection exits. Keep subscribe-before-reload in every LiveView so a reconnect gap is repaired by the next authoritative load.

- [ ] **Step 8: Run committed-event GREEN tests and regressions**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/events/event_notifier_test.exs apps/backplane_memory/test/backplane/memory/events/store_test.exs apps/backplane_memory/test/backplane/memory/events/concurrency_test.exs apps/backplane_memory/test/backplane/memory/observations_test.exs
  ```

  Expected: no pre-commit, rollback, or duplicate broadcast; batch and dual-write storage remain green.

- [ ] **Step 9: Detect scope and commit**

  Run `gitnexus_detect_changes()`, verify `mix.lock` is unchanged, then:

  ```bash
  git add apps/backplane_memory/mix.exs \
    apps/backplane_memory/lib/backplane/memory/application.ex \
    apps/backplane_memory/lib/backplane/memory/event_notifier.ex \
    apps/backplane_memory/lib/backplane/memory/events/store.ex \
    apps/backplane_memory/test/backplane/memory/events/event_notifier_test.exs
  git diff --cached --check
  git commit -m "feat(memory): broadcast committed event inserts"
  ```

### Task 4: Add event operations and strict web parameter normalization

**Files:**

- Create: `apps/backplane_memory/lib/backplane/memory/operations.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/operations/params.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/operations/query.ex`
- Create: `apps/backplane_memory/test/backplane/memory/operations/params_test.exs`
- Create: `apps/backplane_memory/test/backplane/memory/operations/events_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/events/event_notifier_test.exs`
- Modify: `apps/backplane_memory/lib/backplane/memory/events/query.ex`
- Modify: `apps/backplane_memory/test/backplane/memory/events/query_test.exs`

- [ ] **Step 1: Check the timeline blast radius**

  Run impact analysis for `Backplane.Memory.Events.Query.timeline/1` and `Backplane.Memory.Events.timeline/1`. The existing public query contract and 500-row cap must remain compatible.

- [ ] **Step 2: Add status-filter RED coverage to the existing query**

  Extend the existing all-filter test with two events that share every identity field but use distinct statuses. Assert atom and string keys each select only the matching row:

  ```elixir
  assert {:ok, %{events: [%Event{id: id}]}} =
           Events.timeline(status: "failed", project: project)

  assert id == failed.id

  assert {:ok, %{events: [%Event{id: string_id}]}} =
           Events.timeline(%{"status" => "failed", "project" => project})

  assert string_id == failed.id
  ```

  Add `:status` to the non-string equality rejection loop.

- [ ] **Step 3: Add parameter normalization RED tests**

  `ParamsTest` must cover:

  - atom and string keys;
  - whitespace trimming and blank removal;
  - unknown nonblank keys;
  - numeric-string limits with default 50 and cap 100;
  - full ISO-8601 plus `datetime-local` minute, second, and
    fractional-second precision interpreted as UTC and returned as full
    canonical UTC ISO-8601;
  - invalid timestamps;
  - stream state restricted to `"open"` or `"closed"`;
  - sequence `before`/`after` restricted to positive integers and mutually exclusive;
  - canonical string-key query maps that omit default limit and blank values.

  Use these exact public functions:

  ```elixir
  Params.timeline(raw)
  Params.streams(raw)
  Params.sequence(raw)
  ```

  Successful results have:

  ```elixir
  {:ok, %{values: atom_keyed_values, query: string_keyed_query}}
  ```

  Invalid results have:

  ```elixir
  {:error, {:invalid_param, key, canonical_query}}
  ```

- [ ] **Step 4: Add event facade RED tests**

  In `events_test.exs` under `operations`, persist events and assert:

  ```elixir
  assert {:ok, %{events: events, next_cursor: nil, filters: filters}} =
           Operations.timeline(%{
             "project" => project,
             "status" => "failed",
             "limit" => "100"
           })

  assert Enum.map(events, & &1.id) == [failed.id]
  assert filters == %{
           "limit" => "100",
           "project" => project,
           "status" => "failed"
         }

  assert {:ok, ^failed} = Operations.get_event(failed.id)
  assert {:error, :not_found} = Operations.get_event(Ecto.UUID.generate())
  assert {:error, :not_found} = Operations.get_event("not-a-uuid")
  ```

  Also assert a malformed cursor returns:

  ```elixir
  {:error, {:invalid_param, :cursor, canonical_without_cursor}}
  ```

  Define this nested test module:

  ```elixir
  defmodule EventsFailingRepo do
    def all(_query), do: raise("forced events read failure")
    def get(_schema, _id), do: raise("forced events read failure")
  end
  ```

  In a synchronous test, preserve
  `Application.fetch_env(:backplane_memory, :repo)`, restore it in `on_exit/1`,
  install `EventsFailingRepo`, and assert both `Operations.timeline(%{})` and
  `Operations.get_event(Ecto.UUID.generate())` return
  `{:error, %RuntimeError{}}` rather than raising.

  Add notification-matching assertions for stream, project, agent, session,
  run, type, tool, status, inclusive from/to bounds, and a nonmatching value
  for every field. Assert that `cursor` and `limit` never change the result.
  Assert `false` for a non-map, missing required key, wrong timestamp type,
  string-keyed summary, extra key, and summaries containing `:content` or
  `:payload`.

  Extend `event_notifier_test.exs` with the subscribe-before-reload protocol test:

  ```elixir
  test "a commit between subscription and authoritative reload cannot be missed" do
    project = unique("subscribe-reload")
    :ok = EventNotifier.subscribe()

    event =
      unboxed(fn ->
        assert {:ok, event} =
                 Events.append(%{
                   stream_id: unique("subscribe-reload-stream"),
                   event_type: "task.created",
                   project: project
                 })

        event
      end)

    assert {:ok, %{events: events}} = Operations.timeline(%{"project" => project})
    assert Enum.any?(events, &(&1.id == event.id))
    assert_receive {:memory_event_inserted, %{id: id}}, 1_000
    assert id == event.id
  end
  ```

  Register committed-row cleanup with the same `unboxed/1` helper used by the notifier tests. The commit happens after subscription and before the authoritative reload; the row is present in the reload and the PubSub message is merely an acceleration signal.

- [ ] **Step 5: Run all new event tests to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/events/event_notifier_test.exs apps/backplane_memory/test/backplane/memory/events/query_test.exs apps/backplane_memory/test/backplane/memory/operations/params_test.exs apps/backplane_memory/test/backplane/memory/operations/events_test.exs
  ```

  Expected: status is rejected and the Operations modules are missing.

- [ ] **Step 6: Extend the existing query with status**

  Add `:status` to `@equality_filters`, add atom/string entries to
  `@filter_aliases`, and add this reducer clause before its fallback:

  ```elixir
  fn
    {:status, value}, query ->
      where(query, [event], event.status == ^value)
  end
  ```

  to `apply_equality_filters/2`. Do not change ordering, cursor encoding, or the 500-row cap.

- [ ] **Step 7: Implement strict Params normalization**

  Create `Backplane.Memory.Operations.Params` with these complete normalization rules:

  ```elixir
  defmodule Backplane.Memory.Operations.Params do
    @moduledoc false

    @timeline_fields %{
      "stream" => {:stream, :string},
      "project" => {:project, :string},
      "agent" => {:agent, :string},
      "session" => {:session, :string},
      "run" => {:run, :string},
      "type" => {:type, :string},
      "tool" => {:tool, :string},
      "status" => {:status, :string},
      "from" => {:from, :time},
      "to" => {:to, :time},
      "cursor" => {:cursor, :cursor},
      "limit" => {:limit, :limit}
    }

    @stream_fields %{
      "state" => {:state, :state},
      "project" => {:project, :string},
      "agent" => {:agent, :string},
      "host" => {:host, :string},
      "session" => {:session, :string},
      "run" => {:run, :string},
      "cursor" => {:cursor, :cursor},
      "limit" => {:limit, :limit}
    }

    @sequence_fields %{
      "before" => {:before, :anchor},
      "after" => {:after, :anchor},
      "limit" => {:limit, :limit}
    }

    def timeline(raw), do: normalize(raw, @timeline_fields, 50, :standard)
    def streams(raw), do: normalize(raw, @stream_fields, 50, :standard)
    def sequence(raw), do: normalize(raw, @sequence_fields, 100, :sequence)

    defp normalize(raw, fields, default_limit, mode) do
      with {:ok, pairs} <- pairs(raw) do
        {values, query, invalid_key} =
          Enum.reduce(pairs, {%{}, %{}, nil}, fn {raw_key, raw_value},
                                                 {values, query, invalid_key} ->
            case normalize_key(fields, raw_key) do
              {:ok, key, parser, query_key} ->
                case normalize_value(parser, raw_value) do
                  :omit ->
                    {values, query, invalid_key}

                  {:ok, value, canonical} ->
                    {
                      Map.put(values, key, value),
                      Map.put(query, query_key, canonical),
                      invalid_key
                    }

                  :error ->
                    {values, query, invalid_key || key}
                end

              :error ->
                {values, query, invalid_key || raw_key}
            end
          end)

        {values, query, invalid_key} =
          enforce_mode(mode, values, query, invalid_key)

        values = Map.put_new(values, :limit, default_limit)
        query =
          if values.limit == default_limit,
            do: Map.delete(query, "limit"),
            else: query

        if invalid_key do
          {:error, {:invalid_param, invalid_key, query}}
        else
          {:ok, %{values: values, query: query}}
        end
      else
        :error -> {:error, {:invalid_param, :filters, %{}}}
      end
    end

    defp pairs(raw) when is_map(raw), do: {:ok, Map.to_list(raw)}

    defp pairs(raw) when is_list(raw) do
      if Keyword.keyword?(raw), do: {:ok, raw}, else: :error
    end

    defp pairs(_raw), do: :error

    defp normalize_key(fields, raw_key) when is_atom(raw_key) do
      normalize_key(fields, Atom.to_string(raw_key))
    end

    defp normalize_key(fields, raw_key) when is_binary(raw_key) do
      case Map.fetch(fields, raw_key) do
        {:ok, {key, parser}} -> {:ok, key, parser, raw_key}
        :error -> :error
      end
    end

    defp normalize_key(_fields, _raw_key), do: :error

    defp normalize_value(_parser, nil), do: :omit

    defp normalize_value(:limit, value) when is_integer(value) and value > 0 do
      capped = min(value, 100)
      {:ok, capped, Integer.to_string(capped)}
    end

    defp normalize_value(:anchor, value) when is_integer(value) and value > 0 do
      {:ok, value, Integer.to_string(value)}
    end

    defp normalize_value(parser, value) when is_binary(value) do
      if String.valid?(value) do
        value
        |> String.trim()
        |> normalize_trimmed(parser)
      else
        :error
      end
    end

    defp normalize_value(_parser, _value), do: :error

    defp normalize_trimmed("", _parser), do: :omit
    defp normalize_trimmed(value, :string), do: {:ok, value, value}
    defp normalize_trimmed(value, :cursor), do: {:ok, value, value}

    defp normalize_trimmed(value, :state) when value in ["open", "closed"] do
      {:ok, value, value}
    end

    defp normalize_trimmed(_value, :state), do: :error

    defp normalize_trimmed(value, parser) when parser in [:limit, :anchor] do
      case Integer.parse(value) do
        {integer, ""} when integer > 0 -> normalize_value(parser, integer)
        _error -> :error
      end
    end

    defp normalize_trimmed(value, :time) do
      case DateTime.from_iso8601(value) do
        {:ok, datetime, _offset} ->
          {:ok, datetime, DateTime.to_iso8601(datetime)}

        {:error, _reason} ->
          local_value =
            if Regex.match?(
                 ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/,
                 value
               ),
              do: value <> ":00",
              else: value

          with {:ok, naive} <- NaiveDateTime.from_iso8601(local_value),
               {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
            {:ok, datetime, DateTime.to_iso8601(datetime)}
          else
            _error -> :error
          end
      end
    end

    defp enforce_mode(:standard, values, query, invalid_key) do
      {values, query, invalid_key}
    end

    defp enforce_mode(:sequence, values, query, invalid_key) do
      if Map.has_key?(values, :before) and Map.has_key?(values, :after) do
        {
          Map.delete(values, :after),
          Map.delete(query, "after"),
          invalid_key || :after
        }
      else
        {values, query, invalid_key}
      end
    end
  end
  ```

  The fixed field maps prevent atom creation from input. The reducer continues after an invalid pair so the returned canonical query retains every other valid value.

- [ ] **Step 8: Implement the initial typed query layer**

  In `Operations.Query`, add:

  ```elixir
  def get_event(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case repo().get(Event, uuid) do
          nil -> {:error, :not_found}
          event -> {:ok, event}
        end

      :error ->
        {:error, :not_found}
    end
  end
  ```

  Keep the repo behind a private `repo/0` that reads `:backplane_memory, :repo`. LiveViews must never call this module directly.

- [ ] **Step 9: Implement the public event facade and subscriptions**

  In `Operations`, add:

  ```elixir
  def timeline(raw_filters) do
    with {:ok, normalized} <- Params.timeline(raw_filters),
         {:ok, page} <- safe_read(fn -> Events.timeline(normalized.values) end) do
      {:ok, Map.merge(page, %{filters: normalized.query})}
    else
      {:error, :invalid_cursor} ->
        canonical = raw_filters |> canonical_timeline_query() |> Map.delete("cursor")
        {:error, {:invalid_param, :cursor, canonical}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_event(id), do: safe_read(fn -> Query.get_event(id) end)
  def subscribe_events, do: EventNotifier.subscribe()
  def normalize_timeline_params(raw), do: Params.timeline(raw)
  ```

  `subscribe_rollout/0` is added with the Rollout adapter in Task 6, so Task 4
  does not introduce a temporary direct Settings dependency.

  Add this private boundary and use it around every Operations database read:

  ```elixir
  defp safe_read(loader) do
    try do
      loader.()
    rescue
      error -> {:error, error}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end
  ```

  `get_event/1`, and the stream reads added in Task 5, must also use this boundary so the detail plug can return 503 on a repository failure rather than crashing the endpoint.

  Use this internal helper rather than a permissive input copy:

  ```elixir
  defp canonical_timeline_query(raw_filters) do
    case Params.timeline(raw_filters) do
      {:ok, %{query: query}} -> query
      {:error, {:invalid_param, _key, canonical_query}} -> canonical_query
    end
  end
  ```

  Add the complete notification matcher:

  ```elixir
  @notification_fields %{
    stream: :stream_id,
    project: :project,
    agent: :agent_id,
    session: :session_id,
    run: :run_id,
    type: :event_type,
    tool: :tool_name,
    status: :status
  }

  @notification_summary_fields [
    :agent_id,
    :event_type,
    :id,
    :occurred_at,
    :project,
    :run_id,
    :session_id,
    :status,
    :stream_id,
    :tool_name
  ]

  def notification_matches?(summary, raw_filters) when is_map(summary) do
    with true <- valid_notification_summary?(summary),
         {:ok, normalized} <- Params.timeline(raw_filters) do
      normalized.values
      |> Map.drop([:cursor, :limit])
      |> Enum.all?(fn
        {:from, from} ->
          DateTime.compare(summary.occurred_at, from) in [:eq, :gt]

        {:to, to} ->
          DateTime.compare(summary.occurred_at, to) in [:eq, :lt]

        {filter, value} ->
          case Map.fetch(@notification_fields, filter) do
            {:ok, summary_field} -> Map.get(summary, summary_field) == value
            :error -> false
          end
      end)
    else
      _error -> false
    end
  end

  def notification_matches?(_summary, _raw_filters), do: false

  defp valid_notification_summary?(summary) do
    Enum.sort(Map.keys(summary)) == Enum.sort(@notification_summary_fields) and
      is_binary(summary.id) and summary.id != "" and
      is_binary(summary.stream_id) and summary.stream_id != "" and
      is_binary(summary.event_type) and summary.event_type != "" and
      match?(%DateTime{}, summary.occurred_at) and
      Enum.all?(
        [:project, :agent_id, :session_id, :run_id, :tool_name, :status],
        fn field ->
          value = Map.get(summary, field)
          is_nil(value) or (is_binary(value) and String.valid?(value))
        end
      )
  end
  ```

  The exact-key check rejects summaries containing content, payload, or any
  other unexpected field. `cursor` and `limit` are deliberately removed before
  comparison. Time bounds are inclusive.

- [ ] **Step 10: Run event operations GREEN tests**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/events/event_notifier_test.exs apps/backplane_memory/test/backplane/memory/events/query_test.exs apps/backplane_memory/test/backplane/memory/operations/params_test.exs apps/backplane_memory/test/backplane/memory/operations/events_test.exs
  ```

  Expected: status filtering, canonical maps, not-found behavior, the 100-row admin cap, and notification matching pass.

- [ ] **Step 11: Detect scope and commit**

  Run `gitnexus_detect_changes()`, inspect the direct diff, then:

  ```bash
  git add apps/backplane_memory/lib/backplane/memory/events/query.ex \
    apps/backplane_memory/lib/backplane/memory/operations.ex \
    apps/backplane_memory/lib/backplane/memory/operations/params.ex \
    apps/backplane_memory/lib/backplane/memory/operations/query.ex \
    apps/backplane_memory/test/backplane/memory/events/event_notifier_test.exs \
    apps/backplane_memory/test/backplane/memory/events/query_test.exs \
    apps/backplane_memory/test/backplane/memory/operations/params_test.exs \
    apps/backplane_memory/test/backplane/memory/operations/events_test.exs
  git diff --cached --check
  git commit -m "feat(memory): add v2 event operations"
  ```

### Task 5: Add stream inventory and bounded sequence windows

**Files:**

- Modify: `apps/backplane_memory/lib/backplane/memory/operations.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/operations/query.ex`
- Create: `apps/backplane_memory/test/backplane/memory/operations/streams_test.exs`

- [ ] **Step 1: Check stream/query blast radius**

  Run impact analysis for the `Backplane.Memory.Events.Stream` schema and `Backplane.Memory.Events.Query.range/2`. This task only reads streams/events and must not change stream lifecycle behavior.

- [ ] **Step 2: Add stream keyset RED tests**

  Persist streams with:

  - tied non-null `last_event_at` values;
  - descending distinct timestamps;
  - at least three `nil` timestamps inserted directly as stream rows;
  - open and closed states;
  - distinct project, agent, host, session, and run values.

  Assert every filter independently, a maximum of 100 rows, and the complete traversal order:

  ```elixir
  [
    {newest_time, "stream-z"},
    {tied_time, "stream-b"},
    {tied_time, "stream-a"},
    {nil, "undated-c"},
    {nil, "undated-b"},
    {nil, "undated-a"}
  ]
  ```

  Traverse with a small limit until `next_cursor` is nil and assert the concatenated stream IDs contain no duplicates or gaps. Add malformed Base64, malformed JSON, invalid branch, missing tuple field, invalid timestamp, and non-string cursor cases.

- [ ] **Step 3: Add sequence-window RED tests**

  Append 250 events to one stream and assert:

  ```elixir
  assert {:ok, latest} = Operations.stream_events(stream_id, %{})
  assert Enum.map(latest.events, & &1.sequence) == Enum.to_list(151..250)
  assert latest.older_before == 151
  assert latest.newer_after == nil
  assert latest.window == :latest
  assert latest.params == %{}

  assert {:ok, older} =
           Operations.stream_events(stream_id, %{"before" => "151"})

  assert Enum.map(older.events, & &1.sequence) == Enum.to_list(51..150)
  assert older.older_before == 51
  assert older.newer_after == 150

  assert {:ok, round_trip} =
           Operations.stream_events(stream_id, %{"after" => "150"})

  assert Enum.map(round_trip.events, & &1.sequence) == Enum.to_list(151..250)
  ```

  Add tests for the oldest page, a stream with fewer than 100 events, an empty stream, unknown stream, non-positive/malformed anchors, simultaneous anchors, and a caller limit above 100.

  Define this nested test module:

  ```elixir
  defmodule StreamsFailingRepo do
    def all(_query), do: raise("forced streams read failure")
    def get(_schema, _id), do: raise("forced streams read failure")
  end
  ```

  Preserve and restore the `:backplane_memory, :repo` application value around
  a synchronous failure test. Install `StreamsFailingRepo` and assert
  `Operations.list_streams(%{})`, `Operations.get_stream("stream-id")`, and
  `Operations.stream_events("stream-id", %{})` return tagged errors without
  raising.

- [ ] **Step 4: Run stream tests to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/operations/streams_test.exs
  ```

  Expected: stream operations are missing.

- [ ] **Step 5: Implement stream keyset pagination**

  Add these functions to `Operations.Query`:

  ```elixir
  def list_streams(filters) do
    with {:ok, cursor} <- decode_stream_cursor(Map.get(filters, :cursor)) do
      limit = Map.fetch!(filters, :limit)

      query =
        Stream
        |> apply_stream_filters(filters)
        |> apply_stream_cursor(cursor)
        |> order_by([stream],
          desc_nulls_last: stream.last_event_at,
          desc: stream.stream_id
        )
        |> limit(^(limit + 1))

      rows = repo().all(query)
      {streams, remaining} = Enum.split(rows, limit)

      next_cursor =
        if remaining == [] do
          nil
        else
          streams |> List.last() |> encode_stream_cursor()
        end

      {:ok, %{streams: streams, next_cursor: next_cursor}}
    end
  end

  def get_stream(stream_id) do
    case repo().get(Stream, stream_id) do
      nil -> {:error, :not_found}
      stream -> {:ok, stream}
    end
  end

  defp apply_stream_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:state, "open"}, query -> where(query, [stream], is_nil(stream.closed_at))
      {:state, "closed"}, query -> where(query, [stream], not is_nil(stream.closed_at))
      {:project, value}, query -> where(query, [stream], stream.project == ^value)
      {:agent, value}, query -> where(query, [stream], stream.agent_id == ^value)
      {:host, value}, query -> where(query, [stream], stream.host_id == ^value)
      {:session, value}, query -> where(query, [stream], stream.session_id == ^value)
      {:run, value}, query -> where(query, [stream], stream.run_id == ^value)
      {_option, _value}, query -> query
    end)
  end

  defp apply_stream_cursor(query, nil), do: query

  defp apply_stream_cursor(query, {:dated, last_event_at, stream_id}) do
    where(
      query,
      [stream],
      stream.last_event_at < ^last_event_at or
        (stream.last_event_at == ^last_event_at and stream.stream_id < ^stream_id) or
        is_nil(stream.last_event_at)
    )
  end

  defp apply_stream_cursor(query, {:undated, stream_id}) do
    where(
      query,
      [stream],
      is_nil(stream.last_event_at) and stream.stream_id < ^stream_id
    )
  end

  defp decode_stream_cursor(nil), do: {:ok, nil}

  defp decode_stream_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, decoded} <- Jason.decode(json) do
      decode_stream_cursor_map(decoded)
    else
      _error -> {:error, :invalid_cursor}
    end
  end

  defp decode_stream_cursor(_cursor), do: {:error, :invalid_cursor}

  defp decode_stream_cursor_map(
         cursor = %{
           "branch" => "dated",
           "last_event_at" => last_event_at,
           "stream_id" => stream_id
         }
       )
       when map_size(cursor) == 3 and is_binary(last_event_at) and
              is_binary(stream_id) and byte_size(stream_id) > 0 do
    case DateTime.from_iso8601(last_event_at) do
      {:ok, datetime, _offset} -> {:ok, {:dated, datetime, stream_id}}
      _error -> {:error, :invalid_cursor}
    end
  end

  defp decode_stream_cursor_map(
         cursor = %{"branch" => "undated", "stream_id" => stream_id}
       )
       when map_size(cursor) == 2 and is_binary(stream_id) and byte_size(stream_id) > 0 do
    {:ok, {:undated, stream_id}}
  end

  defp decode_stream_cursor_map(_cursor), do: {:error, :invalid_cursor}

  defp encode_stream_cursor(%Stream{last_event_at: nil, stream_id: stream_id}) do
    %{"branch" => "undated", "stream_id" => stream_id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp encode_stream_cursor(%Stream{} = stream) do
    %{
      "branch" => "dated",
      "last_event_at" => DateTime.to_iso8601(stream.last_event_at),
      "stream_id" => stream.stream_id
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end
  ```

- [ ] **Step 6: Implement bounded sequence windows**

  Add:

  ```elixir
  def stream_events(%Stream{} = stream, options) do
    max_sequence = max(stream.next_sequence - 1, 0)
    {window, bounds} = sequence_bounds(max_sequence, options)

    case bounds do
      nil ->
        {:ok,
         %{
           events: [],
           older_before: nil,
           newer_after: nil,
           window: window
         }}

      {first_sequence, last_sequence} ->
        with {:ok, events} <-
               Events.range(stream.stream_id, first_sequence..last_sequence) do
          first = List.first(events)
          last = List.last(events)

          {:ok,
           %{
             events: events,
             older_before:
               if(first && first.sequence > 1, do: first.sequence, else: nil),
             newer_after:
               if(last && last.sequence < max_sequence, do: last.sequence, else: nil),
             window: window
           }}
        end
    end
  end

  defp sequence_bounds(0, options), do: {sequence_window(options), nil}

  defp sequence_bounds(max_sequence, %{before: before_sequence, limit: limit}) do
    last_sequence = min(max_sequence, before_sequence - 1)

    if last_sequence < 1 do
      {:before, nil}
    else
      {:before, {max(1, last_sequence - limit + 1), last_sequence}}
    end
  end

  defp sequence_bounds(max_sequence, %{after: after_sequence, limit: limit}) do
    first_sequence = after_sequence + 1

    if first_sequence > max_sequence do
      {:after, nil}
    else
      {:after, {first_sequence, min(max_sequence, first_sequence + limit - 1)}}
    end
  end

  defp sequence_bounds(max_sequence, %{limit: limit}) do
    {:latest, {max(1, max_sequence - limit + 1), max_sequence}}
  end

  defp sequence_window(%{before: _sequence}), do: :before
  defp sequence_window(%{after: _sequence}), do: :after
  defp sequence_window(_options), do: :latest
  ```

  Alias `Backplane.Memory.Events` and its `Stream` schema in `Operations.Query`. The facade adds canonical `params`; this query function never loads more than the normalized 100-row limit.

- [ ] **Step 7: Wire the stream facade**

  Add:

  ```elixir
  def normalize_stream_params(raw), do: Params.streams(raw)
  def normalize_sequence_params(raw), do: Params.sequence(raw)

  def list_streams(raw_filters) do
    with {:ok, normalized} <- Params.streams(raw_filters),
         {:ok, page} <- safe_read(fn -> Query.list_streams(normalized.values) end) do
      {:ok, Map.put(page, :filters, normalized.query)}
    else
      {:error, :invalid_cursor} ->
        canonical = raw_filters |> canonical_stream_query() |> Map.delete("cursor")
        {:error, {:invalid_param, :cursor, canonical}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_stream(stream_id) when is_binary(stream_id) do
    if String.trim(stream_id) == "" do
      {:error, :not_found}
    else
      safe_read(fn -> Query.get_stream(stream_id) end)
    end
  end

  def get_stream(_stream_id), do: {:error, :not_found}

  def stream_events(stream_id, raw_options) do
    with {:ok, normalized} <- Params.sequence(raw_options),
         {:ok, stream} <- get_stream(stream_id),
         {:ok, page} <-
           safe_read(fn -> Query.stream_events(stream, normalized.values) end) do
      {:ok, Map.put(page, :params, normalized.query)}
    end
  end

  defp canonical_stream_query(raw_filters) do
    case Params.streams(raw_filters) do
      {:ok, %{query: query}} -> query
      {:error, {:invalid_param, _key, canonical_query}} -> canonical_query
    end
  end
  ```

  Each function normalizes through `Params`, delegates typed reads to `Operations.Query`, and returns the stable result contracts at the top of this plan. A malformed stream cursor becomes `{:error, {:invalid_param, :cursor, query_without_cursor}}`.

- [ ] **Step 8: Run stream GREEN tests**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/operations/params_test.exs apps/backplane_memory/test/backplane/memory/operations/streams_test.exs apps/backplane_memory/test/backplane/memory/events/query_test.exs
  ```

  Expected: filters, dated-to-null traversal, null cursors, and sequence round trips pass.

- [ ] **Step 9: Detect scope and commit**

  Run `gitnexus_detect_changes()`, inspect the direct diff, then:

  ```bash
  git add apps/backplane_memory/lib/backplane/memory/operations.ex \
    apps/backplane_memory/lib/backplane/memory/operations/query.ex \
    apps/backplane_memory/test/backplane/memory/operations/streams_test.exs
  git diff --cached --check
  git commit -m "feat(memory): add stream inspection operations"
  ```

### Task 6: Add guarded rollout operations

**Files:**

- Create: `apps/backplane_memory/lib/backplane/memory/operations/rollout.ex`
- Create: `apps/backplane_memory/test/backplane/memory/operations/rollout_test.exs`
- Modify: `apps/backplane_memory/lib/backplane/memory/operations.ex`
- Modify: `apps/backplane_system/lib/backplane/settings.ex`
- Modify: `apps/backplane_system/test/backplane/settings_test.exs`

- [ ] **Step 1: Check Settings/Config blast radius**

  Run impact analysis for `Backplane.Settings.get/1`,
  `Backplane.Settings.set/2`, `Backplane.Settings.handle_call/3`, and
  `Backplane.Memory.Config.events_enabled?/0`.

  Extend the existing `Backplane.Settings` GenServer with a serialized
  multi-key snapshot and conditional write. Preserve `get/1` and `set/2`
  contracts. Do not add another process: all normal and conditional setting
  writes must share the existing Settings mailbox.

- [ ] **Step 2: Add rollout RED tests**

  Snapshot and restore the three setting values around every test. Cover:

  - all three disabled;
  - configured and effective values for each valid hierarchy;
  - a configured child blocked by a disabled parent;
  - every allowed transition;
  - every refused transition in both directions;
  - nonboolean values;
  - unknown gate atoms/strings;
  - recovery from `pipeline=false, events=true, dual_write=true` only by disabling Dual Write, then Events;
  - exactly five later stages with `available: false`.

  Assert structured errors:

  ```elixir
  {:error, {:dependency, :pipeline, true}}
  {:error, {:dependency, :events, true}}
  {:error, {:dependency, :dual_write, false}}
  {:error, {:blocked_descendant, :events}}
  {:error, {:blocked_descendant, :dual_write}}
  {:error, :invalid_gate}
  {:error, :invalid_boolean}
  ```

  Subscribe through `Operations.subscribe_rollout/0`, perform a successful mutation, and assert the existing message:

  ```elixir
  assert_receive {:setting_changed, "memory.pipeline.enabled", true}
  ```

  Define a test-only adapter in the same test file:

  ```elixir
  defmodule FailingSettings do
    def get_many(keys), do: Backplane.Settings.get_many(keys)
    def subscribe, do: Backplane.Settings.subscribe()

    def set_if(_key, _value, _expectations),
      do: {:error, :forced_setting_failure}
  end
  ```

  Preserve and restore `Application.fetch_env(:backplane_memory,
  :settings_adapter)`, install `FailingSettings` for one test, and assert a
  valid transition returns `{:error, :forced_setting_failure}` without changing
  the configured value.

  Add this deterministic concurrent-invariant test:

  ```elixir
  test "concurrent valid transitions cannot commit an invalid hierarchy" do
    assert :ok = Settings.set("memory.pipeline.enabled", true)
    assert :ok = Settings.set("memory.events.enabled", true)
    assert :ok = Settings.set("memory.events.dual_write", false)

    settings_pid = Process.whereis(Settings)
    :ok = :sys.suspend(settings_pid)

    tasks =
      try do
        tasks = [
          Task.async(fn -> Operations.set_gate(:events, false) end),
          Task.async(fn -> Operations.set_gate(:dual_write, true) end)
        ]

        assert eventually(fn -> queued_set_if_calls(settings_pid) == 2 end)
        tasks
      after
        :sys.resume(settings_pid)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &(&1 == :ok)) == 1

    assert Enum.count(results, fn
             {:error, {:dependency, _, _}} -> true
             _other -> false
           end) == 1

    rollout = Operations.rollout_state()

    refute rollout.events.configured and not rollout.pipeline.configured
    refute rollout.dual_write.configured and not rollout.events.configured

    assert {rollout.events.configured, rollout.dual_write.configured} in [
             {false, false},
             {true, true}
           ]
  end

  defp queued_set_if_calls(pid) do
    {:messages, messages} = Process.info(pid, :messages)

    Enum.count(messages, fn
      {:"$gen_call", _from, {:set_if, _key, _value, _expectations}} -> true
      _other -> false
    end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
  ```

  Suspending Settings ensures both conflicting requests are queued before
  either is evaluated, so the test does not depend on scheduler timing.

  Extend `apps/backplane_system/test/backplane/settings_test.exs` to assert
  `get_many/1` returns one mailbox-serialized snapshot, a successful
  `set_if/3` persists and broadcasts once, a failed expectation neither writes
  nor broadcasts, and a target-value no-op returns `:ok` without broadcasting.

- [ ] **Step 3: Run rollout tests to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/operations/rollout_test.exs
  ```

  Expected: rollout operations are missing.

- [ ] **Step 4: Add serialized Settings snapshot and conditional write**

  Add these public APIs to `Backplane.Settings`:

  ```elixir
  @type expectation :: {String.t(), term()}

  @spec get_many([String.t()]) :: %{String.t() => term()}
  def get_many(keys) when is_list(keys) do
    GenServer.call(__MODULE__, {:get_many, keys})
  end

  @spec set_if(String.t(), term(), [expectation()]) ::
          :ok | {:error, {:condition_failed, String.t()}} | {:error, term()}
  def set_if(key, value, expectations)
      when is_binary(key) and is_list(expectations) do
    GenServer.call(__MODULE__, {:set_if, key, value, expectations})
  end
  ```

  Handle both operations inside the existing GenServer:

  ```elixir
  def handle_call({:get_many, keys}, _from, state) do
    values = Map.new(keys, fn key -> {key, get(key)} end)
    {:reply, values, state}
  end

  def handle_call({:set, key, value}, _from, state) do
    persist_setting(key, value, state)
  end

  def handle_call({:set_if, key, value, expectations}, _from, state) do
    case get(key) do
      current when current === value ->
        {:reply, :ok, state}

      _current ->
        case Enum.find(expectations, fn {expected_key, expected_value} ->
               get(expected_key) !== expected_value
             end) do
          nil ->
            persist_setting(key, value, state)

          {failed_key, _expected_value} ->
            {:reply, {:error, {:condition_failed, failed_key}}, state}
        end
    end
  end
  ```

  Extract the existing `handle_call({:set, key, value}, from, state)`
  persistence body unchanged
  into `persist_setting/3`. It must still write PostgreSQL, update ETS, and
  broadcast before replying. `set_if/3` checks the target no-op, all
  expectations, and the write in one mailbox turn. Because ordinary `set/2`
  also uses this mailbox, it cannot interleave between validation and write.

- [ ] **Step 5: Implement one-snapshot rollout state**

  Create `Backplane.Memory.Operations.Rollout` with the metadata and complete
  one-snapshot state calculation:

  ```elixir
  @gates %{
    pipeline: %{key: "memory.pipeline.enabled", label: "Pipeline"},
    events: %{key: "memory.events.enabled", label: "Events"},
    dual_write: %{key: "memory.events.dual_write", label: "Dual Write"}
  }

  @later [
    %{key: "memory.window_summaries.enabled", label: "Window Summaries", available: false},
    %{key: "memory.session_summary_v2.enabled", label: "Session Summary V2", available: false},
    %{key: "memory.fact_extraction_v2.enabled", label: "Fact Extraction V2", available: false},
    %{
      key: "memory.procedure_extraction_v2.enabled",
      label: "Procedure Extraction V2",
      available: false
    },
    %{key: "memory.recall_v2.enabled", label: "Recall V2", available: false}
  ]

  def state do
    gate_keys =
      Map.new(@gates, fn {gate, metadata} ->
        {gate, metadata.key}
      end)

    values = settings().get_many(Map.values(gate_keys))

    configured =
      Map.new(gate_keys, fn {gate, key} ->
        {gate, Map.fetch!(values, key) == true}
      end)

    pipeline_effective = configured.pipeline
    events_effective = pipeline_effective and configured.events
    dual_write_effective = events_effective and configured.dual_write

    %{
      pipeline:
        gate_state(
          :pipeline,
          configured.pipeline,
          pipeline_effective
        ),
      events:
        gate_state(
          :events,
          configured.events,
          events_effective
        ),
      dual_write:
        gate_state(
          :dual_write,
          configured.dual_write,
          dual_write_effective
        ),
      later: @later
    }
  end

  def subscribe, do: settings().subscribe()

  defp gate_state(gate, configured, effective) do
    @gates
    |> Map.fetch!(gate)
    |> Map.merge(%{
      configured: configured,
      effective: effective,
      blocked: configured and not effective
    })
  end

  defp settings do
    Application.get_env(
      :backplane_memory,
      :settings_adapter,
      Backplane.Settings
    )
  end
  ```

- [ ] **Step 6: Enforce dependency-safe transitions atomically**

  Add the complete mutation boundary:

  ```elixir
  def set_gate(gate, _value) when not is_map_key(@gates, gate),
    do: {:error, :invalid_gate}

  def set_gate(_gate, value) when not is_boolean(value),
    do: {:error, :invalid_boolean}

  def set_gate(gate, value) do
    requirements = transition_requirements(gate, value)

    expectations =
      Enum.map(requirements, fn {required_gate, expected, _error} ->
        {gate_key(required_gate), expected}
      end)

    case settings().set_if(gate_key(gate), value, expectations) do
      {:error, {:condition_failed, failed_key}} ->
        {_gate, _expected, error} =
          Enum.find(requirements, fn {required_gate, _expected, _error} ->
            gate_key(required_gate) == failed_key
          end)

        {:error, error}

      result ->
        result
    end
  end

  defp transition_requirements(:pipeline, true) do
    [
      {:events, false, {:blocked_descendant, :events}},
      {:dual_write, false, {:blocked_descendant, :dual_write}}
    ]
  end

  defp transition_requirements(:events, true) do
    [
      {:pipeline, true, {:dependency, :pipeline, true}},
      {:dual_write, false, {:dependency, :dual_write, false}}
    ]
  end

  defp transition_requirements(:dual_write, true) do
    [
      {:pipeline, true, {:dependency, :events, true}},
      {:events, true, {:dependency, :events, true}}
    ]
  end

  defp transition_requirements(:dual_write, false), do: []

  defp transition_requirements(:events, false) do
    [{:dual_write, false, {:dependency, :dual_write, false}}]
  end

  defp transition_requirements(:pipeline, false) do
    [
      {:events, false, {:blocked_descendant, :events}},
      {:dual_write, false, {:blocked_descendant, :dual_write}}
    ]
  end

  defp gate_key(gate) do
    @gates
    |> Map.fetch!(gate)
    |> Map.fetch!(:key)
  end
  ```

  This implements the exact transition table:

  | Mutation | Required state |
  |---|---|
  | Enable Pipeline | Events and Dual Write are both configured false |
  | Enable Events | Pipeline is configured true and Dual Write is configured false |
  | Enable Dual Write | Pipeline and Events are both configured true |
  | Disable Dual Write | Always allowed |
  | Disable Events | Dual Write is configured false |
  | Disable Pipeline | Events and Dual Write are both configured false |

  The Settings GenServer evaluates every expectation and persists the target
  in one mailbox turn, so concurrent transitions cannot both validate an old
  snapshot. A no-op is detected inside the serialized conditional write and
  returns `:ok` without broadcasting. Every real successful transition
  performs exactly one adapter `set_if/3`; condition failures are translated
  to the existing rollout errors, while persistence errors propagate
  unchanged.

- [ ] **Step 7: Expose rollout through Operations**

  Add:

  ```elixir
  def rollout_state, do: Rollout.state()
  def set_gate(gate, value), do: Rollout.set_gate(gate, value)
  def subscribe_rollout, do: Rollout.subscribe()
  ```

  The application setting `:settings_adapter` is an explicit test seam. It
  defaults to `Backplane.Settings`; production configuration does not set it.

- [ ] **Step 8: Run rollout GREEN tests**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/operations/rollout_test.exs apps/backplane_memory/test/backplane/memory/config_test.exs apps/backplane_system/test/backplane/settings_test.exs
  ```

  Expected: consistent transitions succeed, the deterministic concurrent
  test preserves the hierarchy, inconsistent state can only move toward
  safety, and PubSub messages pass.

- [ ] **Step 9: Detect scope and commit**

  Run `gitnexus_detect_changes()`, inspect the direct diff, then:

  ```bash
  git add apps/backplane_memory/lib/backplane/memory/operations.ex \
    apps/backplane_memory/lib/backplane/memory/operations/rollout.ex \
    apps/backplane_memory/test/backplane/memory/operations/rollout_test.exs \
    apps/backplane_system/lib/backplane/settings.ex \
    apps/backplane_system/test/backplane/settings_test.exs
  git diff --cached --check
  git commit -m "feat(memory): add guarded v2 rollout controls"
  ```

### Task 7: Add independently tagged overview regions

**Files:**

- Modify: `apps/backplane_memory/lib/backplane/memory/operations.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/operations/query.ex`
- Create: `apps/backplane_memory/test/backplane/memory/operations/overview_test.exs`

- [ ] **Step 1: Check metrics/query blast radius**

  Run impact analysis for `Backplane.Metrics.snapshot/0`. This task only reads its existing counters and must not change telemetry emission or Metrics state.

- [ ] **Step 2: Add overview RED tests**

  Persist events around fixed UTC boundaries, then set their `inserted_at` values with a test-only `repo().update_all/3` so the production append contract remains untouched. Assert:

  - open stream count excludes closed streams;
  - last-24-hours count uses `inserted_at`, not delayed `occurred_at`;
  - volume returns exactly 60 ascending one-minute buckets;
  - minutes without rows have count zero;
  - the first bucket is minute-floor(`now`) minus 59 minutes;
  - the final bucket is minute-floor(`now`);
  - recent events remain ordered by `occurred_at DESC, id DESC`;
  - active streams are open and ordered by `last_event_at DESC NULLS LAST, stream_id DESC`;
  - runtime counters use `"memory_events_appended"`, `"memory_events_duplicates"`, and `"memory_events_errors"`;
  - missing individual counters are legitimate zero;
  - runtime data is labeled `scope: :since_process_start`.

  Add a deterministic partial-failure test:

  ```elixir
  regions = %{
    pipeline: fn -> :healthy end,
    persisted_counts: fn -> raise "database unavailable" end,
    event_volume: fn -> :volume end,
    runtime_metrics: fn -> :metrics end,
    recent_events: fn -> :recent end,
    active_streams: fn -> :streams end
  }

  result = Operations.collect_regions(regions)

  assert result.pipeline == {:ok, :healthy}
  assert {:error, %RuntimeError{message: "database unavailable"}} =
           result.persisted_counts
  assert result.event_volume == {:ok, :volume}
  ```

- [ ] **Step 3: Run overview tests to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/operations/overview_test.exs
  ```

  Expected: overview functions are missing.

- [ ] **Step 4: Implement persisted aggregate queries**

  In `Operations.Query`, alias `Event` and `Stream`, then add these complete
  typed query functions:

  ```elixir
  def persisted_counts(%DateTime{} = now) do
    cutoff = DateTime.add(now, -24, :hour)

    open_streams =
      Stream
      |> where([stream], is_nil(stream.closed_at))
      |> repo().aggregate(:count, :stream_id)

    events_last_24h =
      Event
      |> where([event], event.inserted_at >= ^cutoff)
      |> repo().aggregate(:count, :id)

    %{
      open_streams: open_streams,
      events_last_24h: events_last_24h
    }
  end

  def event_volume(%DateTime{} = now) do
    final_bucket = minute_floor(now)
    first_bucket = DateTime.add(final_bucket, -59, :minute)
    exclusive_end = DateTime.add(final_bucket, 1, :minute)

    counts =
      Event
      |> where(
        [event],
        event.inserted_at >= ^first_bucket and
          event.inserted_at < ^exclusive_end
      )
      |> group_by(
        [event],
        type(
          fragment("date_trunc('minute', ?)", event.inserted_at),
          :utc_datetime_usec
        )
      )
      |> select(
        [event],
        {
          type(
            fragment("date_trunc('minute', ?)", event.inserted_at),
            :utc_datetime_usec
          ),
          count(event.id)
        }
      )
      |> repo().all()
      |> Map.new()

    for offset <- 0..59 do
      at = DateTime.add(first_bucket, offset, :minute)
      %{at: at, count: Map.get(counts, at, 0)}
    end
  end

  def recent_events(limit) when is_integer(limit) and limit > 0 do
    Event
    |> order_by([event], desc: event.occurred_at, desc: event.id)
    |> limit(^limit)
    |> repo().all()
  end

  def active_streams(limit) when is_integer(limit) and limit > 0 do
    Stream
    |> where([stream], is_nil(stream.closed_at))
    |> order_by(
      [stream],
      desc_nulls_last: stream.last_event_at,
      desc: stream.stream_id
    )
    |> limit(^limit)
    |> repo().all()
  end

  defp minute_floor(datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> Map.put(:second, 0)
  end
  ```

  The range is half-open and missing minutes are filled in Elixir. Persisted
  counts and volume use `inserted_at`; recent ordering continues to use
  `occurred_at DESC, id DESC`.

- [ ] **Step 5: Implement tagged overview orchestration**

  Add:

  ```elixir
  def overview do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    collect_regions(%{
      pipeline: &rollout_state/0,
      persisted_counts: fn -> Query.persisted_counts(now) end,
      event_volume: fn -> Query.event_volume(now) end,
      runtime_metrics: &runtime_metrics/0,
      recent_events: fn -> Query.recent_events(8) end,
      active_streams: fn -> Query.active_streams(8) end
    })
  end

  @doc false
  def collect_regions(region_functions) do
    Map.new(region_functions, fn {region, loader} ->
      result =
        try do
          {:ok, loader.()}
        rescue
          error -> {:error, error}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      {region, result}
    end)
  end
  ```

  Implement the runtime loader exactly once per region:

  ```elixir
  defp runtime_metrics do
    snapshot = Backplane.Metrics.snapshot()
    counters = Map.get(snapshot, :counters, %{})

    %{
      appended: Map.get(counters, "memory_events_appended", 0),
      duplicates: Map.get(counters, "memory_events_duplicates", 0),
      errors: Map.get(counters, "memory_events_errors", 0),
      scope: :since_process_start
    }
  end
  ```

  If `snapshot/0` raises, `collect_regions/1` tags the entire runtime region as
  an error. Do not turn a failed region into zero, `[]`, or an empty map.

- [ ] **Step 6: Run overview GREEN tests**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/operations/overview_test.exs apps/backplane_memory/test/backplane/memory/operations/streams_test.exs apps/backplane_memory/test/backplane/memory/operations/events_test.exs
  ```

  Expected: all six regions are independently tagged and time buckets are deterministic.

- [ ] **Step 7: Detect scope and commit**

  Run `gitnexus_detect_changes()`, inspect the direct diff, then:

  ```bash
  git add apps/backplane_memory/lib/backplane/memory/operations.ex \
    apps/backplane_memory/lib/backplane/memory/operations/query.ex \
    apps/backplane_memory/test/backplane/memory/operations/overview_test.exs
  git diff --cached --check
  git commit -m "feat(memory): add v2 operations overview"
  ```

### Task 8: Add concurrent keyset indexes

**Files:**

- Create: `apps/backplane_system/priv/repo/migrations/20260717000001_add_memory_v2_admin_indexes.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/events/migration_test.exs`

- [ ] **Step 1: Add index-definition RED assertions**

  Query `pg_indexes` for:

  ```text
  bpm_streams_last_event_stream_idx
  bpm_events_occurred_id_idx
  ```

  Assert their definitions contain:

  ```text
  USING btree (last_event_at DESC NULLS LAST, stream_id DESC)
  USING btree (occurred_at DESC, id DESC)
  ```

  Join `pg_indexes` to `pg_class`/`pg_index` and also assert both indexes have `indisvalid = true` and `indisready = true`.

- [ ] **Step 2: Run the migration test to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/events/migration_test.exs
  ```

  Expected: both new indexes are absent.

- [ ] **Step 3: Add the nonblocking migration**

  Create:

  ```elixir
  defmodule Backplane.Repo.Migrations.AddMemoryV2AdminIndexes do
    use Ecto.Migration

    @disable_ddl_transaction true
    @disable_migration_lock true

    def up do
      execute("DROP INDEX CONCURRENTLY IF EXISTS bpm_streams_last_event_stream_idx")
      execute("DROP INDEX CONCURRENTLY IF EXISTS bpm_events_occurred_id_idx")

      execute("""
      CREATE INDEX CONCURRENTLY bpm_streams_last_event_stream_idx
      ON bpm_streams (last_event_at DESC NULLS LAST, stream_id DESC)
      """)

      execute("""
      CREATE INDEX CONCURRENTLY bpm_events_occurred_id_idx
      ON bpm_events (occurred_at DESC, id DESC)
      """)
    end

    def down do
      execute("DROP INDEX CONCURRENTLY IF EXISTS bpm_events_occurred_id_idx")
      execute("DROP INDEX CONCURRENTLY IF EXISTS bpm_streams_last_event_stream_idx")
    end
  end
  ```

- [ ] **Step 4: Apply the test migration and run GREEN**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres MIX_ENV=test mix ecto.migrate
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/events/migration_test.exs apps/backplane_memory/test/backplane/memory/operations/streams_test.exs apps/backplane_memory/test/backplane/memory/operations/events_test.exs
  ```

  Expected: exact directions/null ordering pass and query tests remain green.

- [ ] **Step 5: Detect scope and commit**

  Run `gitnexus_detect_changes()`, inspect the direct diff, then:

  ```bash
  git add apps/backplane_system/priv/repo/migrations/20260717000001_add_memory_v2_admin_indexes.exs \
    apps/backplane_memory/test/backplane/memory/events/migration_test.exs
  git diff --cached --check
  git commit -m "perf(memory): add v2 admin keyset indexes"
  ```

### Task 9: Establish the protected Memory LiveView boundary and shared UI seams

**Files:**

- Create: `apps/backplane_admin/lib/backplane/admin/plugs/memory_detail_plug.ex`
- Create: `apps/backplane_admin/lib/backplane/admin/components/memory_components.ex`
- Create: `apps/backplane_admin/lib/backplane/admin/live/memory_streams_live.ex`
- Create: `apps/backplane_admin/lib/backplane/admin/live/memory_events_live.ex`
- Create: `apps/backplane_admin/lib/backplane/admin/live/memory_pipeline_live.ex`
- Create: `apps/backplane_admin/test/support/memory_fixtures.ex`
- Modify: `apps/backplane_admin/lib/backplane/admin/router.ex`
- Modify: `apps/backplane_admin/test/backplane/admin/route_boundary_test.exs`

- [ ] **Step 1: Check router/layout blast radius**

  Run impact analysis for `Backplane.Admin.Router`,
  `Backplane.Admin.Layouts.top_nav_items/0`, and `left_nav_items/1`. This task
  establishes all final V2 route names in the protected session; the eight
  legacy routes remain temporarily until Task 14 so intermediate commits stay
  testable.

- [ ] **Step 2: Add protected-route RED tests**

  Define this helper in `route_boundary_test.exs` before the new tests:

  ```elixir
  defp put_memory_credentials(username, password) do
    Application.put_env(:backplane, :admin_username, username)
    Application.put_env(:backplane, :admin_password, password)
  end
  ```

  The module's existing setup remains responsible for restoring both
  application values. Then extend the test with:

  ```elixir
  test "Memory V2 fails closed without credentials", %{conn: conn} do
    assert get(conn, "/memory") |> response(503) ==
             "Admin authentication is not configured"
  end

  test "Memory V2 challenges anonymous requests when credentials exist", %{conn: conn} do
    put_memory_credentials("admin", "secret")
    conn = get(conn, "/memory")
    assert response(conn, 401) == "Unauthorized"
  end

  test "Memory V2 accepts valid basic auth", %{conn: conn} do
    put_memory_credentials("admin", "secret")

    conn =
      conn
      |> put_req_header("authorization", basic_auth_header("admin", "secret"))
      |> get("/memory")

    assert html_response(conn, 200) =~ "Memory"
  end
  ```

  Repeat the absent/partial/blank 503 and configured-anonymous 401 assertions
  across `/memory`, `/memory/streams`, `/memory/events`, `/memory/pipeline`,
  `/memory/streams/missing-stream`, and
  `/memory/events/#{Ecto.UUID.generate()}`. Authentication must run before
  resource lookup on details.
  With valid credentials, also assert `/memory/streams`, `/memory/events`, and
  `/memory/pipeline` return 200; these cases are RED until the route skeletons
  in Step 8 exist.
  Add authenticated requests for
  `/memory/streams/missing-stream` and
  `/memory/events/#{Ecto.UUID.generate()}` and assert literal status 404 with
  body `"not found"`. Add a malformed event UUID case with the same result.

  Add a LiveView session-boundary assertion: open `/dashboard/overview` with no configured credentials, click the Memory top-nav link, and assert it produces a full redirect to `/memory`, not a same-session live patch. Follow with a direct `GET /memory` assertion for 503. This proves router auth cannot be bypassed by the existing `navigate` link.

- [ ] **Step 3: Run route tests to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/route_boundary_test.exs
  ```

  Expected: `/memory` remains optional-auth and the live-session boundary assertion fails.

- [ ] **Step 4: Add the required Memory pipeline and dedicated live session**

  Add:

  ```elixir
  pipeline :memory_admin do
    plug(Backplane.Web.AdminAuthPlug, required: true)
    plug(Backplane.Admin.MemoryDetailPlug)
  end
  ```

  Remove only the current `/memory` route from the existing optional scope.
  Add this separate scope after it with every final V2 route:

  ```elixir
  scope "/", Backplane.Admin do
    pipe_through([:browser, :memory_admin])

    live_session :memory_v2 do
      live("/memory", MemoryOverviewLive, :index)
      live("/memory/streams", MemoryStreamsLive, :index)
      live("/memory/streams/:stream_id", MemoryStreamsLive, :show)
      live("/memory/events", MemoryEventsLive, :index)
      live("/memory/events/:event_id", MemoryEventsLive, :show)
      live("/memory/pipeline", MemoryPipelineLive, :index)
    end
  end
  ```

  The named `:memory_v2` session is required. Navigating between a non-Memory LiveView and Memory must cross sessions and perform a new browser request through required auth.

- [ ] **Step 5: Implement the disconnected detail guard**

  Create:

  ```elixir
  defmodule Backplane.Admin.MemoryDetailPlug do
    @moduledoc false

    import Plug.Conn

    alias Backplane.Memory.Operations

    def init(opts), do: opts

    def call(%{path_params: %{"stream_id" => id}} = conn, _opts) do
      guard_resource(conn, Operations.get_stream(id))
    end

    def call(%{path_params: %{"event_id" => id}} = conn, _opts) do
      guard_resource(conn, Operations.get_event(id))
    end

    def call(conn, _opts), do: conn

    defp guard_resource(conn, {:ok, _resource}), do: conn

    defp guard_resource(conn, {:error, :not_found}) do
      conn
      |> send_resp(404, "not found")
      |> halt()
    end

    defp guard_resource(conn, {:error, _reason}) do
      conn
      |> send_resp(503, "memory unavailable")
      |> halt()
    end
  end
  ```

  Required auth precedes this plug, so an unauthenticated caller cannot probe record existence.

- [ ] **Step 6: Add Memory test fixtures**

  Create this complete support module:

  ```elixir
  defmodule Backplane.Admin.MemoryFixtures.FailingRepo do
    def all(_query), do: raise("forced memory repository failure")
    def get(_schema, _id), do: raise("forced memory repository failure")
    def one(_query), do: raise("forced memory repository failure")
  end

  defmodule Backplane.Admin.MemoryFixtures.FailingSettings do
    def get_many(keys), do: Backplane.Settings.get_many(keys)
    def subscribe, do: Backplane.Settings.subscribe()

    def set_if(_key, _value, _expectations),
      do: {:error, :forced_setting_failure}
  end

  defmodule Backplane.Admin.MemoryFixtures do
    import Plug.Conn

    alias Backplane.Memory.Events
    alias Backplane.Settings

    @gate_keys [
      "memory.pipeline.enabled",
      "memory.events.enabled",
      "memory.events.dual_write"
    ]

    def setup_memory_auth(%{conn: conn}) do
      previous = %{
        username: Application.fetch_env(:backplane, :admin_username),
        password: Application.fetch_env(:backplane, :admin_password)
      }

      Application.put_env(:backplane, :admin_username, "memory-admin")
      Application.put_env(:backplane, :admin_password, "memory-secret")

      ExUnit.Callbacks.on_exit(fn ->
        restore_application_env(:admin_username, previous.username)
        restore_application_env(:admin_password, previous.password)
      end)

      encoded = Base.encode64("memory-admin:memory-secret")

      {:ok,
       conn:
         put_req_header(
           conn,
           "authorization",
           "Basic #{encoded}"
         )}
    end

    def setup_memory_gates(_context) do
      previous = Map.new(@gate_keys, &{&1, Settings.get(&1)})
      Enum.each(@gate_keys, &assert_ok(Settings.set(&1, false)))

      ExUnit.Callbacks.on_exit(fn ->
        Enum.each(previous, fn {key, value} ->
          assert_ok(Settings.set(key, value))
        end)
      end)

      :ok
    end

    def event_fixture(attrs \\ %{}) do
      attrs =
        attrs
        |> Map.new()
        |> Map.put_new(
          :stream_id,
          "fixture-stream-#{System.unique_integer([:positive, :monotonic])}"
        )
        |> Map.put_new(:event_type, "task.created")

      {:ok, event} = Events.append(attrs)
      event
    end

    def safe_summary(event) do
      Map.take(event, [
        :id,
        :stream_id,
        :event_type,
        :project,
        :agent_id,
        :session_id,
        :run_id,
        :tool_name,
        :status,
        :occurred_at
      ])
    end

    def fail_memory_reads! do
      previous = Application.fetch_env(:backplane_memory, :repo)

      Application.put_env(
        :backplane_memory,
        :repo,
        Backplane.Admin.MemoryFixtures.FailingRepo
      )

      ExUnit.Callbacks.on_exit(fn ->
        case previous do
          {:ok, repo} -> Application.put_env(:backplane_memory, :repo, repo)
          :error -> Application.delete_env(:backplane_memory, :repo)
        end
      end)

      :ok
    end

    def fail_memory_settings! do
      previous =
        Application.fetch_env(
          :backplane_memory,
          :settings_adapter
        )

      Application.put_env(
        :backplane_memory,
        :settings_adapter,
        Backplane.Admin.MemoryFixtures.FailingSettings
      )

      ExUnit.Callbacks.on_exit(fn ->
        case previous do
          {:ok, adapter} ->
            Application.put_env(
              :backplane_memory,
              :settings_adapter,
              adapter
            )

          :error ->
            Application.delete_env(
              :backplane_memory,
              :settings_adapter
            )
        end
      end)

      :ok
    end

    defp restore_application_env(key, {:ok, value}) do
      Application.put_env(:backplane, key, value)
    end

    defp restore_application_env(key, :error) do
      Application.delete_env(:backplane, key)
    end

    defp assert_ok(:ok), do: :ok
    defp assert_ok({:error, reason}), do: raise("setting write failed: #{inspect(reason)}")
  end
  ```

  Every Memory LiveView test imports `Backplane.Admin.MemoryFixtures` and
  declares:

  ```elixir
  setup :setup_memory_auth
  setup :setup_memory_gates
  ```

  The fixtures persist through the shared synchronous test sandbox. Actual
  cross-connection commit timing remains isolated to `event_notifier_test.exs`.

  Keep every Memory LiveView test module `async: false` because application environment, Settings ETS, PubSub, and the shared repository are involved.

- [ ] **Step 7: Add query-free shared components**

  Create `Backplane.Admin.MemoryComponents` with `use Backplane.Admin, :html`. Implement:

  ```elixir
  memory_page_header/1
  memory_region/1
  memory_empty_state/1
  event_type_badge/1
  status_badge/1
  gate_state_badges/1
  event_color/1
  identity_value/1
  format_datetime/1
  datetime_local_value/1
  format_json/1
  ```

  Use these complete component bodies:

  ```elixir
  attr :title, :string, required: true
  attr :subtitle, :string, required: true

  def memory_page_header(assigns) do
    ~H"""
    <header class="mb-6">
      <h1 class="text-2xl font-bold tracking-tight">{@title}</h1>
      <p class="mt-1 text-sm text-on-surface-variant">{@subtitle}</p>
    </header>
    """
  end

  attr :result, :any, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  def memory_region(assigns) do
    {ok?, value} =
      case assigns.result do
        {:ok, value} -> {true, value}
        {:error, _reason} -> {false, nil}
      end

    assigns = assign(assigns, ok?: ok?, value: value)

    ~H"""
    <section aria-label={@title}>
      <div :if={@ok?}>{render_slot(@inner_block, @value)}</div>
      <.dm_alert :if={!@ok?} variant="error" title={@title} compact>
        Memory data is unavailable. Retry after checking the database connection.
      </.dm_alert>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :rollout, :map, required: true

  def memory_empty_state(assigns) do
    ~H"""
    <.dm_card variant="bordered" padding="lg" class="text-center">
      <h2 class="text-lg font-semibold">{@title}</h2>
      <p class="mt-2 text-sm text-on-surface-variant">
        Pipeline is {if @rollout.pipeline.effective, do: "effective", else: "disabled"};
        Events is {if @rollout.events.effective, do: "effective", else: "disabled"}.
      </p>
      <div class="mt-4">
        <.dm_btn navigate={~p"/memory/pipeline"} variant="primary">Open Pipeline</.dm_btn>
      </div>
    </.dm_card>
    """
  end

  attr :event_type, :string, required: true

  def event_type_badge(assigns) do
    ~H"""
    <.dm_badge variant="info" size="sm" soft>
      <span class="font-mono">{@event_type}</span>
    </.dm_badge>
    """
  end

  attr :status, :any, default: nil

  def status_badge(assigns) do
    assigns = assign(assigns, :variant, status_variant(assigns.status))

    ~H"""
    <.dm_badge variant={@variant} size="sm" soft>
      {@status || "unknown"}
    </.dm_badge>
    """
  end

  attr :gate, :map, required: true

  def gate_state_badges(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <.dm_badge variant={if @gate.configured, do: "info", else: "neutral"} size="sm">
        {if @gate.configured, do: "Configured on", else: "Configured off"}
      </.dm_badge>
      <.dm_badge
        variant={
          cond do
            @gate.effective -> "success"
            @gate.blocked -> "warning"
            true -> "neutral"
          end
        }
        size="sm"
      >
        {cond do
          @gate.effective -> "Effective"
          @gate.blocked -> "Configured, blocked"
          true -> "Inactive"
        end}
      </.dm_badge>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil

  def identity_value(assigns) do
    ~H"""
    <dt class="text-sm font-medium text-on-surface-variant">{@label}</dt>
    <dd class="min-w-0 break-all font-mono text-sm">{@value || "—"}</dd>
    """
  end

  def format_datetime(nil), do: "—"
  def format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def format_datetime(value), do: to_string(value)

  def format_json(payload), do: Jason.encode!(payload || %{}, pretty: true)

  defp status_variant(status) when status in ["failed", "error"], do: "error"
  defp status_variant(status) when status in ["completed", "success"], do: "success"
  defp status_variant(nil), do: "neutral"
  defp status_variant(_status), do: "info"
  ```

  `memory_region/1` accepts a tagged `result` and a required `:inner_block` slot. It renders the slot for `{:ok, value}` and a compact error `dm_alert` for `{:error, _reason}`. The alert uses a fixed operator-safe message and never renders raw exception/database text. It never invokes a query.

  `format_json/1` returns `Jason.encode!(payload || %{}, pretty: true)`. HEEX callers interpolate the string normally; never use `raw/1`.

  Keep canonical URL timestamps as full UTC ISO-8601, but format them for HTML `datetime-local` controls with:

  ```elixir
  def datetime_local_value(nil), do: ""

  def datetime_local_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime
        |> DateTime.to_naive()
        |> NaiveDateTime.to_iso8601()

      _error -> ""
    end
  end
  ```

  This retains seconds and the stored fractional precision. Every
  `datetime-local` input in Events sets `step="any"` so the browser does not
  invalidate or round those values.

  Define event colors without using arbitrary persisted strings as classes:

  ```elixir
  def event_color(%{status: status}) when status in ["failed", "error"], do: "error"
  def event_color(%{status: status}) when status in ["completed", "success"], do: "success"
  def event_color(_event), do: "primary"
  ```

  Use monospaced `break-all` identity spans and DuskMoon badges. Each of the four Memory LiveViews imports `Backplane.Admin.MemoryComponents` so the shared functions render with local component syntax. Do not add CSS or JavaScript in this task.

- [ ] **Step 8: Add buildable page skeletons for every new route**

  Create the three new LiveView modules before committing the route graph.
  They intentionally expose no data or controls yet:

  ```elixir
  defmodule Backplane.Admin.MemoryStreamsLive do
    use Backplane.Admin, :live_view

    import Backplane.Admin.MemoryComponents

    @impl true
    def mount(_params, _session, socket) do
      {:ok, assign(socket, current_path: "/memory/streams")}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div id="memory-streams-skeleton">
        <.memory_page_header
          title="Streams"
          subtitle="Authoritative Memory V2 stream inventory"
        />
      </div>
      """
    end
  end

  defmodule Backplane.Admin.MemoryEventsLive do
    use Backplane.Admin, :live_view

    import Backplane.Admin.MemoryComponents

    @impl true
    def mount(_params, _session, socket) do
      {:ok, assign(socket, current_path: "/memory/events")}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div id="memory-events-skeleton">
        <.memory_page_header
          title="Events"
          subtitle="Authoritative Memory V2 event explorer"
        />
      </div>
      """
    end
  end

  defmodule Backplane.Admin.MemoryPipelineLive do
    use Backplane.Admin, :live_view

    import Backplane.Admin.MemoryComponents

    @impl true
    def mount(_params, _session, socket) do
      {:ok, assign(socket, current_path: "/memory/pipeline")}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div id="memory-pipeline-skeleton">
        <.memory_page_header
          title="Pipeline"
          subtitle="Guarded Memory V2 rollout controls"
        />
      </div>
      """
    end
  end
  ```

  Put each module in its own file from the task file list. This makes Task 9
  and every later commit independently compilable: verified Overview links
  resolve before the detailed pages are filled in.

- [ ] **Step 9: Run route GREEN tests**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane/test/backplane/web/admin_auth_plug_test.exs apps/backplane_admin/test/backplane/admin/route_boundary_test.exs
  ```

  Expected: Memory is fail-closed, all four top-level V2 routes resolve,
  unknown detail IDs are literal 404s, non-Memory admin behavior stays
  optional, and entering Memory crosses the LiveView session boundary.

- [ ] **Step 10: Detect scope and commit**

  Run `gitnexus_detect_changes()`, inspect the direct diff, then:

  ```bash
  git add apps/backplane_admin/lib/backplane/admin/router.ex \
    apps/backplane_admin/lib/backplane/admin/plugs/memory_detail_plug.ex \
    apps/backplane_admin/lib/backplane/admin/components/memory_components.ex \
    apps/backplane_admin/lib/backplane/admin/live/memory_streams_live.ex \
    apps/backplane_admin/lib/backplane/admin/live/memory_events_live.ex \
    apps/backplane_admin/lib/backplane/admin/live/memory_pipeline_live.ex \
    apps/backplane_admin/test/support/memory_fixtures.ex \
    apps/backplane_admin/test/backplane/admin/route_boundary_test.exs
  git diff --cached --check
  git commit -m "feat(memory): protect v2 admin routes"
  ```

### Task 10: Rewrite Overview as a V2 instrument panel

**Files:**

- Rewrite: `apps/backplane_admin/lib/backplane/admin/live/memory_overview_live.ex`
- Create: `apps/backplane_admin/test/backplane/admin/live/memory_overview_live_test.exs`

- [ ] **Step 1: Check the existing Overview blast radius**

  Run impact analysis for `Backplane.Admin.MemoryOverviewLive.mount/3` and `handle_params/3`. Remove all direct calls to V1 Memories and Graph contexts.

- [ ] **Step 2: Add Overview RED tests**

  Use authenticated Memory fixtures and assert:

  - page heading and V2 operational description;
  - configured and effective badges for Pipeline, Events, and Dual Write;
  - persisted open streams and 24-hour event count;
  - runtime metrics contain the visible label `"Since process start"`;
  - exactly 60 volume-bar elements;
  - recent persisted events link to event detail routes;
  - active open streams link to stream detail routes;
  - all five later stages show `"Unavailable"`;
  - an unrelated `{:setting_changed, "services.day.enabled", false}` message
    leaves the LiveView alive and its regions unchanged;
  - no V1 labels such as `"Active Memories"`, `"Graph Nodes"`, or `"Memory by Type"`.

  Render `MemoryComponents.memory_region/1` with one error result and one healthy result and assert the error alert does not suppress healthy content. The backend `collect_regions/1` test already proves independent loading; this assertion proves the UI preserves the tags.

- [ ] **Step 3: Run Overview test to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/live/memory_overview_live_test.exs
  ```

  Expected: V1 labels remain and V2 regions are absent.

- [ ] **Step 4: Subscribe before the first authoritative load**

  Implement:

  ```elixir
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Operations.subscribe_events()
      Operations.subscribe_rollout()
    end

    {:ok,
     assign(socket,
       current_path: "/memory",
       regions: nil
     )}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, regions: Operations.overview())}
  end

  def handle_info({:memory_event_inserted, _summary}, socket) do
    {:noreply, assign(socket, regions: Operations.overview())}
  end

  def handle_info({:setting_changed, key, _value}, socket)
      when key in [
             "memory.pipeline.enabled",
             "memory.events.enabled",
             "memory.events.dual_write"
           ] do
    {:noreply, assign(socket, regions: Operations.overview())}
  end
  ```

  `Settings.subscribe/0` uses one shared topic for every setting. After the
  Memory-key clause, add:

  ```elixir
  def handle_info({:setting_changed, _key, _value}, socket) do
    {:noreply, socket}
  end
  ```

  Put this fallback after the more specific Memory clauses in every LiveView
  that subscribes to rollout changes, so an unrelated setting update cannot
  cause a function-clause crash.

  Render a DuskMoon loading skeleton only while `@regions` is `nil`. Once loaded, never replace a failed region with a zero or empty collection.

- [ ] **Step 5: Render the six tagged regions**

  Replace the V1 render function with:

  ```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.memory_page_header
        title="Memory"
        subtitle="Authoritative streams, committed events, and guarded V2 rollout"
      />

      <.dm_card
        :if={is_nil(@regions)}
        id="memory-overview-loading"
        variant="bordered"
      >
        Loading Memory V2 operations…
      </.dm_card>

      <div :if={@regions} class="space-y-6">
        <.memory_region
          title="Rollout state"
          result={@regions.pipeline}
          :let={rollout}
        >
          <div class="grid gap-3 md:grid-cols-3">
            <.dm_card
              :for={gate <- [
                rollout.pipeline,
                rollout.events,
                rollout.dual_write
              ]}
              variant="bordered"
              padding="sm"
            >
              <h2 class="mb-3 font-semibold">{gate.label}</h2>
              <.gate_state_badges gate={gate} />
            </.dm_card>
          </div>

          <section class="mt-4" aria-label="Later stages">
            <h2 class="mb-2 font-semibold">Later stages</h2>
            <div class="flex flex-wrap gap-2">
              <.dm_badge
                :for={stage <- rollout.later}
                variant="neutral"
                size="sm"
              >
                {stage.label}: Unavailable
              </.dm_badge>
            </div>
          </section>
        </.memory_region>

        <.memory_region
          title="Persisted activity"
          result={@regions.persisted_counts}
          :let={counts}
        >
          <.dm_card variant="bordered" padding="none">
            <div class="grid sm:grid-cols-2">
              <.dm_stat
                title="Open streams"
                value={Integer.to_string(counts.open_streams)}
              />
              <.dm_stat
                title="Events persisted in 24 hours"
                value={Integer.to_string(counts.events_last_24h)}
              />
            </div>
          </.dm_card>
        </.memory_region>

        <.memory_region
          title="Persisted event volume"
          result={@regions.event_volume}
          :let={volume}
        >
          <.dm_card variant="bordered" padding="sm">
            <div
              id="memory-volume"
              class="grid h-28 grid-cols-[repeat(60,minmax(2px,1fr))] items-end gap-px"
            >
              <div
                :for={bucket <- volume}
                class="min-h-px rounded-t-sm bg-primary"
                data-bucket={DateTime.to_iso8601(bucket.at)}
                data-count={bucket.count}
                style={"height: #{volume_height(bucket.count, volume)}%"}
                title={"#{bucket.count} events at #{format_datetime(bucket.at)}"}
              />
            </div>
          </.dm_card>
        </.memory_region>

        <.memory_region
          title="Runtime ingestion"
          result={@regions.runtime_metrics}
          :let={metrics}
        >
          <.dm_card variant="bordered" padding="none">
            <p class="px-4 pt-4 text-sm text-on-surface-variant">
              Since process start
            </p>
            <div class="grid sm:grid-cols-3">
              <.dm_stat
                title="Appended"
                value={Integer.to_string(metrics.appended)}
              />
              <.dm_stat
                title="Duplicates"
                value={Integer.to_string(metrics.duplicates)}
              />
              <.dm_stat
                title="Errors"
                value={Integer.to_string(metrics.errors)}
                color={if metrics.errors > 0, do: "error", else: nil}
              />
            </div>
          </.dm_card>
        </.memory_region>

        <.memory_region
          title="Recent events"
          result={@regions.recent_events}
          :let={events}
        >
          <div class="overflow-x-auto">
            <.dm_table
              id="memory-recent-events"
              data={events}
              compact
              hover
              zebra
              class="min-w-[48rem]"
            >
              <:col :let={event} label="Event">
                <.link
                  href={~p"/memory/events/#{event.id}"}
                  class="font-mono text-primary hover:underline"
                >
                  {event.event_type}
                </.link>
              </:col>
              <:col :let={event} label="Stream">
                <span class="font-mono text-xs">{event.stream_id}</span>
              </:col>
              <:col :let={event} label="Occurred">
                {format_datetime(event.occurred_at)}
              </:col>
            </.dm_table>
          </div>
        </.memory_region>

        <.memory_region
          title="Active streams"
          result={@regions.active_streams}
          :let={streams}
        >
          <div class="overflow-x-auto">
            <.dm_table
              id="memory-active-streams"
              data={streams}
              compact
              hover
              zebra
              class="min-w-[48rem]"
            >
              <:col :let={stream} label="Stream">
                <.link
                  href={~p"/memory/streams/#{stream.stream_id}"}
                  class="font-mono text-primary hover:underline"
                >
                  {stream.stream_id}
                </.link>
              </:col>
              <:col :let={stream} label="Project">
                {stream.project || "—"}
              </:col>
              <:col :let={stream} label="Last activity">
                {format_datetime(stream.last_event_at)}
              </:col>
            </.dm_table>
          </div>
        </.memory_region>
      </div>
    </div>
    """
  end
  ```

  Define `volume_height/2` so it returns an integer from 1 through 100:

  ```elixir
  defp volume_height(count, volume) do
    max_count =
      volume
      |> Enum.map(& &1.count)
      |> Enum.max(fn -> 0 end)
      |> max(1)

    max(1, round(count / max_count * 100))
  end
  ```

  This keeps an all-zero series safe and leaves zero buckets as a visible 1% baseline.

- [ ] **Step 6: Run Overview GREEN test**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/live/memory_overview_live_test.exs apps/backplane_memory/test/backplane/memory/operations/overview_test.exs
  ```

  Expected: V2 regions render, failures stay explicit, and future stages have no controls.

- [ ] **Step 7: Detect scope and commit**

  Run `gitnexus_detect_changes()`, inspect the direct diff, then:

  ```bash
  git add apps/backplane_admin/lib/backplane/admin/live/memory_overview_live.ex \
    apps/backplane_admin/test/backplane/admin/live/memory_overview_live_test.exs
  git diff --cached --check
  git commit -m "feat(memory): replace overview with v2 operations"
  ```

### Task 11: Build Streams inventory and bounded detail

**Files:**

- Modify: `apps/backplane_admin/lib/backplane/admin/live/memory_streams_live.ex`
- Create: `apps/backplane_admin/test/backplane/admin/live/memory_streams_live_test.exs`

- [ ] **Step 1: Replace the Streams skeleton contract**

  Confirm Task 9 already registered:

  ```elixir
  live("/memory/streams", MemoryStreamsLive, :index)
  live("/memory/streams/:stream_id", MemoryStreamsLive, :show)
  ```

  Keep the authenticated literal-404 guard assertion added in Task 9 green
  while replacing only the skeleton page behavior.

- [ ] **Step 2: Add Streams LiveView RED tests**

  Cover:

  - the inventory table and intentional empty state;
  - the empty state shows current Pipeline/Events effective status and a `/memory/pipeline` link;
  - each URL-backed filter: state, project, agent, host, session, run;
  - filter form patches that trim blanks and remove the cursor;
  - a successful load replace-patches trimmed values, removes blanks and an
    explicit default limit, and preserves the merged canonical sequence query
    on detail routes;
  - an invalid cursor patches with `replace: true`, retains valid filters, and flashes;
  - at most 100 visible rows and a single opaque next cursor;
  - stable tied timestamp/null traversal via successive URLs;
  - direct shareable detail route;
  - detail shows stream ID, project, agent, host, client, session, run, first activity, last activity, closure time/state, and current sequence;
  - displayed current sequence is `max(next_sequence - 1, 0)`;
  - initial latest 100 events in ascending sequence order;
  - older and newer boundary links;
  - no duplicate/skip after older/newer round trip;
  - no close, edit, delete, replay, or retry controls;
  - matching event notification reloads newest inventory/latest selected window;
  - a historical cursor/window shows `"New events available"` without replacing rows.
  - an unrelated Settings message leaves the LiveView alive;
  - after a healthy row/detail load, `fail_memory_reads!/0` plus a matching
    notification retains the row and selected detail and renders the fixed
    repository error alert.

  Use this failure-shape test:

  ```elixir
  event = event_fixture(project: "last-good-stream")

  {:ok, view, _html} =
    live(conn, ~p"/memory/streams/#{event.stream_id}")

  assert has_element?(view, "#stream-identity", event.stream_id)
  :ok = fail_memory_reads!()
  send(view.pid, {:memory_event_inserted, safe_summary(event)})

  assert has_element?(view, "#stream-query-error")
  assert has_element?(view, "#stream-identity", event.stream_id)

  send(
    view.pid,
    {:setting_changed, "services.day.enabled", false}
  )

  assert Process.alive?(view.pid)
  ```

- [ ] **Step 3: Run Streams tests to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/live/memory_streams_live_test.exs apps/backplane_admin/test/backplane/admin/route_boundary_test.exs
  ```

  Expected: the Task 9 skeleton renders, but inventory, detail, filtering,
  failure, and notification assertions fail.

- [ ] **Step 4: Implement subscribe-before-reload state**

  Mount with:

  ```elixir
  if connected?(socket) do
    Operations.subscribe_events()
    Operations.subscribe_rollout()
  end

  assign(socket,
    current_path: "/memory/streams",
    rollout: Operations.rollout_state(),
    filters: %{},
    page: %{streams: [], next_cursor: nil, filters: %{}},
    selected_stream: nil,
    sequence_page: %{events: [], older_before: nil, newer_after: nil, window: :latest, params: %{}},
    query_error: nil,
    new_events_available: false
  )
  ```

  Add the complete loading and canonicalization boundary:

  ```elixir
  @impl true
  def handle_params(params, _uri, socket) do
    inventory_params =
      if socket.assigns.live_action == :show do
        Map.drop(params, ["stream_id", "before", "after"])
      else
        Map.drop(params, ["stream_id"])
      end

    sequence_params =
      if socket.assigns.live_action == :show,
        do: Map.take(params, ["before", "after"]),
        else: %{}

    inventory_result = Operations.list_streams(inventory_params)

    detail_result =
      case socket.assigns.live_action do
        :index ->
          {:ok, nil,
           %{
             events: [],
             older_before: nil,
             newer_after: nil,
             window: :latest,
             params: %{}
           }}

        :show ->
          with {:ok, stream} <- Operations.get_stream(params["stream_id"]),
               {:ok, sequence_page} <-
                 Operations.stream_events(stream.stream_id, sequence_params) do
            {:ok, stream, sequence_page}
          end
      end

    apply_stream_results(socket, params, inventory_result, detail_result)
  end

  defp apply_stream_results(
         socket,
         params,
         {:ok, page},
         {:ok, selected_stream, sequence_page}
       ) do
    canonical = Map.merge(page.filters, sequence_page.params)

    socket =
      assign(socket,
        page: page,
        filters: page.filters,
        selected_stream: selected_stream,
        sequence_page: sequence_page,
        query_error: nil,
        new_events_available: false
      )

    {:noreply, replace_stream_query(socket, params, canonical, false)}
  end

  defp apply_stream_results(
         socket,
         params,
         {:error, {:invalid_param, _key, inventory_query}},
         {:ok, _stream, sequence_page}
       ) do
    {:noreply,
     replace_stream_query(
       socket,
       params,
       Map.merge(inventory_query, sequence_page.params),
       true
     )}
  end

  defp apply_stream_results(
         socket,
         params,
         {:ok, page},
         {:error, {:invalid_param, _key, sequence_query}}
       ) do
    {:noreply,
     replace_stream_query(
       socket,
       params,
       Map.merge(page.filters, sequence_query),
       true
     )}
  end

  defp apply_stream_results(
         socket,
         params,
         {:error, {:invalid_param, _key, inventory_query}},
         {:error, {:invalid_param, _other_key, sequence_query}}
       ) do
    {:noreply,
     replace_stream_query(
       socket,
       params,
       Map.merge(inventory_query, sequence_query),
       true
     )}
  end

  defp apply_stream_results(socket, _params, _inventory, {:error, :not_found}) do
    {:noreply,
     socket
     |> put_flash(:error, "The selected stream no longer exists.")
     |> push_navigate(to: ~p"/memory/streams")}
  end

  defp apply_stream_results(socket, _params, {:error, reason}, _detail) do
    {:noreply, assign(socket, query_error: reason)}
  end

  defp apply_stream_results(socket, _params, _inventory, {:error, reason}) do
    {:noreply, assign(socket, query_error: reason)}
  end

  defp replace_stream_query(socket, params, canonical, invalid?) do
    submitted = Map.drop(params, ["stream_id"])

    if connected?(socket) and (invalid? or submitted != canonical) do
      socket =
        if invalid?,
          do:
            put_flash(
              socket,
              :error,
              "One invalid stream parameter was removed."
            ),
          else: socket

      push_patch(socket,
        to:
          streams_path(
            socket.assigns.live_action,
            params["stream_id"],
            canonical
          ),
        replace: true
      )
    else
      socket
    end
  end
  ```

  This preserves the raw route ID while canonicalizing, so an invalid initial
  detail query cannot accidentally patch to the index. Successful trimming,
  blank removal, and default-limit removal also use `replace: true`, with the
  equality guard preventing loops. Read failures retain the last good assigns.

  Put this alert above the inventory:

  ```heex
  <.dm_alert
    :if={@query_error}
    id="stream-query-error"
    variant="error"
    title="Streams unavailable"
    compact
  >
    The last loaded stream data is still shown. Retry after checking the database connection.
  </.dm_alert>
  ```

- [ ] **Step 5: Implement URL-backed filtering and bounded navigation**

  Render one form:

  ```heex
  <.form id="stream-filters" for={%{}} as={:filters} phx-change="filter" phx-submit="filter">
    <.dm_select
      id="stream-state"
      name="filters[state]"
      value={@filters["state"]}
      label="State"
      options={[{"", "All states"}, {"open", "Open"}, {"closed", "Closed"}]}
    />
    <.dm_input id="stream-project" name="filters[project]" value={@filters["project"]} label="Project" phx-debounce="300" />
    <.dm_input id="stream-agent" name="filters[agent]" value={@filters["agent"]} label="Agent" phx-debounce="300" />
    <.dm_input id="stream-host" name="filters[host]" value={@filters["host"]} label="Host" phx-debounce="300" />
    <.dm_input id="stream-session" name="filters[session]" value={@filters["session"]} label="Session" phx-debounce="300" />
    <.dm_input id="stream-run" name="filters[run]" value={@filters["run"]} label="Run" phx-debounce="300" />
  </.form>
  ```

  Add:

  ```elixir
  def handle_event("filter", %{"filters" => raw}, socket) do
    normalized =
      raw
      |> Map.drop(["cursor", "before", "after"])
      |> Operations.normalize_stream_params()

    {query, invalid?} =
      case normalized do
        {:ok, %{query: query}} -> {query, false}
        {:error, {:invalid_param, _key, query}} -> {query, true}
      end

    stream_id =
      case socket.assigns.selected_stream do
        %{stream_id: stream_id} -> stream_id
        nil -> nil
      end

    socket =
      if invalid? do
        put_flash(socket, :error, "One invalid stream parameter was removed.")
      else
        socket
      end

    {:noreply,
     push_patch(socket,
       to:
         streams_path(
           socket.assigns.live_action,
           stream_id,
           query
         ),
       replace: true
     )}
  end

  defp streams_path(:show, stream_id, query) when is_binary(stream_id) do
    ~p"/memory/streams/#{stream_id}?#{query}"
  end

  defp streams_path(_action, _stream_id, query) do
    ~p"/memory/streams?#{query}"
  end
  ```

  The handler canonicalizes through the Operations facade before patching and
  always drops inventory/sequence cursors when filters change.

  Inventory pagination replaces the current bounded page; it never appends pages to socket state. Sequence links set only one of `before` or `after` and preserve inventory filters.

- [ ] **Step 6: Render DuskMoon inventory and responsive detail**

  Wrap:

  ```heex
  <.dm_table id="memory-streams-table" data={@page.streams} compact hover zebra class="min-w-[64rem]">
    <:col :let={stream} label="Stream">
      <.link href={stream_detail_path(stream.stream_id, @filters)} class="font-mono text-primary hover:underline">
        {stream.stream_id}
      </.link>
    </:col>
    <:col :let={stream} label="Project">{stream.project || "—"}</:col>
    <:col :let={stream} label="Session / Run">
      <span class="font-mono text-xs">{stream.session_id || stream.run_id || "—"}</span>
    </:col>
    <:col :let={stream} label="Sequence">
      <span class="font-mono">{max(stream.next_sequence - 1, 0)}</span>
    </:col>
    <:col :let={stream} label="Last activity">{format_datetime(stream.last_event_at)}</:col>
    <:col :let={stream} label="State">
      <.dm_badge variant={if stream.closed_at, do: "neutral", else: "success"}>
        {if stream.closed_at, do: "Closed", else: "Open"}
      </.dm_badge>
    </:col>
  </.dm_table>
  ```

  in `<div class="overflow-x-auto">`. Use a normal `href` detail link retaining the canonical query so the disconnected detail guard runs.

  The installed DuskMoon table intentionally gives `<thead>` the responsive
  `hidden md:table-header-group` classes. This repository already overrides
  that behavior with the more-specific rule below in
  `apps/backplane_admin/assets/css/app.css`:

  ```css
  .table thead {
    display: table-header-group;
  }
  ```

  Keep that existing supported class-based override unchanged. Assert the
  rendered Stream column headers in the LiveView test and verify computed
  `display: table-header-group` at 390px in Task 16.

  Define the referenced path helper in `MemoryStreamsLive`:

  ```elixir
  defp stream_detail_path(stream_id, filters) do
    ~p"/memory/streams/#{stream_id}?#{filters}"
  end
  ```

  Use a responsive grid:

  ```heex
  <div class={["grid min-w-0 gap-4", @selected_stream && "xl:grid-cols-[minmax(0,3fr)_minmax(22rem,2fr)]"]}>
  ```

  In the selected-stream card, render an immutable `<dl id="stream-identity">` with:

  ```heex
  <dl id="stream-identity" class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2">
    <.identity_value label="Stream ID" value={@selected_stream.stream_id} />
    <.identity_value label="Project" value={@selected_stream.project} />
    <.identity_value label="Agent" value={@selected_stream.agent_id} />
    <.identity_value label="Host" value={@selected_stream.host_id} />
    <.identity_value label="Client" value={@selected_stream.client_id} />
    <.identity_value label="Session" value={@selected_stream.session_id} />
    <.identity_value label="Run" value={@selected_stream.run_id} />
    <.identity_value label="First activity" value={format_datetime(@selected_stream.inserted_at)} />
    <.identity_value label="Last activity" value={format_datetime(@selected_stream.last_event_at)} />
    <.identity_value label="Closed at" value={format_datetime(@selected_stream.closed_at)} />
    <.identity_value label="Current sequence" value={max(@selected_stream.next_sequence - 1, 0)} />
  </dl>
  ```

  `Stream.inserted_at` is the stream creation/first-ingestion time; label it as first activity. Render open/closed state as a separate badge. Do not render a form or mutation button in this card.

  Render sequence events with `dm_timeline`, ascending by sequence:

  ```heex
  <.dm_timeline id="stream-sequence" size="sm">
    <:item
      :for={event <- @sequence_page.events}
      title={"##{event.sequence} · #{event.event_type}"}
      time={format_datetime(event.occurred_at)}
      color={event_color(event)}
    >
      <span class="break-words text-sm">{event.content}</span>
    </:item>
  </.dm_timeline>
  ```

  Complete the render envelope with bounded navigation and the historical
  indicator:

  ```heex
  <.dm_alert
    :if={@new_events_available}
    id="stream-new-events"
    variant="info"
    title="New events available"
    compact
  >
    <.dm_btn
      patch={
        streams_path(
          @live_action,
          @selected_stream && @selected_stream.stream_id,
          Map.drop(@filters, ["cursor"])
        )
      }
      replace
      size="sm"
    >
      Refresh newest
    </.dm_btn>
  </.dm_alert>

  <.dm_btn
    :if={@page.next_cursor}
    patch={
      streams_path(
        @live_action,
        @selected_stream && @selected_stream.stream_id,
        @filters
        |> Map.merge(@sequence_page.params)
        |> Map.put("cursor", @page.next_cursor)
      )
    }
  >
    Next page
  </.dm_btn>

  <.dm_btn
    :if={@selected_stream && @sequence_page.older_before}
    patch={
      streams_path(
        :show,
        @selected_stream.stream_id,
        @filters
        |> Map.delete("after")
        |> Map.put("before", @sequence_page.older_before)
      )
    }
  >
    Older events
  </.dm_btn>

  <.dm_btn
    :if={@selected_stream && @sequence_page.newer_after}
    patch={
      streams_path(
        :show,
        @selected_stream.stream_id,
        @filters
        |> Map.delete("before")
        |> Map.put("after", @sequence_page.newer_after)
      )
    }
  >
    Newer events
  </.dm_btn>
  ```

  Replace the skeleton `render/1` with the complete composition below. This is
  the authoritative placement of the exact form, alert, table, detail, and
  pagination contracts from this task:

  ```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-streams">
      <.memory_page_header
        title="Streams"
        subtitle="Authoritative Memory V2 stream inventory"
      />

      <.dm_alert
        :if={@query_error}
        id="stream-query-error"
        variant="error"
        title="Streams unavailable"
        compact
      >
        The last loaded stream data is still shown. Retry after checking the
        database connection.
      </.dm_alert>

      <.dm_alert
        :if={@new_events_available}
        id="stream-new-events"
        variant="info"
        title="New events available"
        compact
      >
        <.dm_btn
          patch={
            streams_path(
              @live_action,
              @selected_stream && @selected_stream.stream_id,
              Map.drop(@filters, ["cursor"])
            )
          }
          replace
          size="sm"
        >
          Refresh newest
        </.dm_btn>
      </.dm_alert>

      <.form
        id="stream-filters"
        for={%{}}
        as={:filters}
        phx-change="filter"
        phx-submit="filter"
        class="grid gap-3 sm:grid-cols-2 xl:grid-cols-6"
      >
        <.dm_select
          id="stream-state"
          name="filters[state]"
          value={@filters["state"]}
          label="State"
          options={[
            {"", "All states"},
            {"open", "Open"},
            {"closed", "Closed"}
          ]}
        />
        <.dm_input
          id="stream-project"
          name="filters[project]"
          value={@filters["project"]}
          label="Project"
          phx-debounce="300"
        />
        <.dm_input
          id="stream-agent"
          name="filters[agent]"
          value={@filters["agent"]}
          label="Agent"
          phx-debounce="300"
        />
        <.dm_input
          id="stream-host"
          name="filters[host]"
          value={@filters["host"]}
          label="Host"
          phx-debounce="300"
        />
        <.dm_input
          id="stream-session"
          name="filters[session]"
          value={@filters["session"]}
          label="Session"
          phx-debounce="300"
        />
        <.dm_input
          id="stream-run"
          name="filters[run]"
          value={@filters["run"]}
          label="Run"
          phx-debounce="300"
        />
      </.form>

      <.memory_empty_state
        :if={@page.streams == [] and is_nil(@selected_stream)}
        title="No streams match these filters"
        rollout={@rollout}
      />

      <div class={[
        "mt-4 grid min-w-0 gap-4",
        @selected_stream &&
          "xl:grid-cols-[minmax(0,3fr)_minmax(22rem,2fr)]"
      ]}>
        <section class="min-w-0">
          <div class="overflow-x-auto">
            <.dm_table
              id="memory-streams-table"
              data={@page.streams}
              compact
              hover
              zebra
              class="min-w-[64rem]"
            >
              <:col :let={stream} label="Stream">
                <.link
                  href={stream_detail_path(stream.stream_id, @filters)}
                  class="font-mono text-primary hover:underline"
                >
                  {stream.stream_id}
                </.link>
              </:col>
              <:col :let={stream} label="Project">
                {stream.project || "—"}
              </:col>
              <:col :let={stream} label="Session / Run">
                <span class="font-mono text-xs">
                  {stream.session_id || stream.run_id || "—"}
                </span>
              </:col>
              <:col :let={stream} label="Sequence">
                <span class="font-mono">
                  {max(stream.next_sequence - 1, 0)}
                </span>
              </:col>
              <:col :let={stream} label="Last activity">
                {format_datetime(stream.last_event_at)}
              </:col>
              <:col :let={stream} label="State">
                <.dm_badge
                  variant={if stream.closed_at, do: "neutral", else: "success"}
                >
                  {if stream.closed_at, do: "Closed", else: "Open"}
                </.dm_badge>
              </:col>
            </.dm_table>
          </div>

          <div class="mt-3 flex justify-end">
            <.dm_btn
              :if={@page.next_cursor}
              patch={
                streams_path(
                  @live_action,
                  @selected_stream && @selected_stream.stream_id,
                  @filters
                  |> Map.merge(@sequence_page.params)
                  |> Map.put("cursor", @page.next_cursor)
                )
              }
            >
              Next page
            </.dm_btn>
          </div>
        </section>

        <aside :if={@selected_stream} class="min-w-0">
          <.dm_card variant="bordered" padding="sm">
            <div class="mb-4 flex items-center justify-between gap-3">
              <.dm_badge
                variant={
                  if @selected_stream.closed_at,
                    do: "neutral",
                    else: "success"
                }
              >
                {if @selected_stream.closed_at, do: "Closed", else: "Open"}
              </.dm_badge>
              <.dm_btn
                patch={streams_path(:index, nil, @filters)}
                size="sm"
                variant="ghost"
              >
                Close detail
              </.dm_btn>
            </div>

            <dl
              id="stream-identity"
              class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2"
            >
              <.identity_value label="Stream ID" value={@selected_stream.stream_id} />
              <.identity_value label="Project" value={@selected_stream.project} />
              <.identity_value label="Agent" value={@selected_stream.agent_id} />
              <.identity_value label="Host" value={@selected_stream.host_id} />
              <.identity_value label="Client" value={@selected_stream.client_id} />
              <.identity_value label="Session" value={@selected_stream.session_id} />
              <.identity_value label="Run" value={@selected_stream.run_id} />
              <.identity_value
                label="First activity"
                value={format_datetime(@selected_stream.inserted_at)}
              />
              <.identity_value
                label="Last activity"
                value={format_datetime(@selected_stream.last_event_at)}
              />
              <.identity_value
                label="Closed at"
                value={format_datetime(@selected_stream.closed_at)}
              />
              <.identity_value
                label="Current sequence"
                value={max(@selected_stream.next_sequence - 1, 0)}
              />
            </dl>

            <.dm_timeline id="stream-sequence" size="sm" class="mt-5">
              <:item
                :for={event <- @sequence_page.events}
                title={"##{event.sequence} · #{event.event_type}"}
                time={format_datetime(event.occurred_at)}
                color={event_color(event)}
              >
                <span class="break-words text-sm">{event.content}</span>
              </:item>
            </.dm_timeline>

            <div class="mt-4 flex flex-wrap gap-2">
              <.dm_btn
                :if={@sequence_page.older_before}
                patch={
                  streams_path(
                    :show,
                    @selected_stream.stream_id,
                    @filters
                    |> Map.delete("after")
                    |> Map.put("before", @sequence_page.older_before)
                  )
                }
              >
                Older events
              </.dm_btn>
              <.dm_btn
                :if={@sequence_page.newer_after}
                patch={
                  streams_path(
                    :show,
                    @selected_stream.stream_id,
                    @filters
                    |> Map.delete("before")
                    |> Map.put("after", @sequence_page.newer_after)
                  )
                }
              >
                Newer events
              </.dm_btn>
            </div>
          </.dm_card>
        </aside>
      </div>
    </div>
    """
  end
  ```

- [ ] **Step 7: Handle event notifications without moving historical views**

  Add the complete notification and Settings handlers:

  ```elixir
  @memory_setting_keys [
    "memory.pipeline.enabled",
    "memory.events.enabled",
    "memory.events.dual_write"
  ]

  @impl true
  def handle_info({:memory_event_inserted, summary}, socket) do
    reload_inventory? = is_nil(socket.assigns.filters["cursor"])

    reload_detail? =
      match?(
        %{stream_id: stream_id} when stream_id == summary.stream_id,
        socket.assigns.selected_stream
      ) and socket.assigns.sequence_page.window == :latest

    socket =
      if reload_inventory?,
        do: reload_stream_inventory(socket),
        else: assign(socket, new_events_available: true)

    socket =
      case socket.assigns.selected_stream do
        %{stream_id: stream_id}
        when stream_id == summary.stream_id and reload_detail? ->
          reload_latest_stream_detail(socket)

        %{stream_id: stream_id} when stream_id == summary.stream_id ->
          assign(socket, new_events_available: true)

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:setting_changed, key, _value}, socket)
      when key in @memory_setting_keys do
    {:noreply, assign(socket, rollout: Operations.rollout_state())}
  end

  def handle_info({:setting_changed, _key, _value}, socket) do
    {:noreply, socket}
  end

  defp reload_stream_inventory(socket) do
    case Operations.list_streams(socket.assigns.filters) do
      {:ok, page} ->
        assign(socket,
          page: page,
          filters: page.filters,
          query_error: nil,
          new_events_available: false
        )

      {:error, reason} ->
        assign(socket, query_error: reason)
    end
  end

  defp reload_latest_stream_detail(socket) do
    stream_id = socket.assigns.selected_stream.stream_id

    with {:ok, stream} <- Operations.get_stream(stream_id),
         {:ok, sequence_page} <- Operations.stream_events(stream_id, %{}) do
      assign(socket,
        selected_stream: stream,
        sequence_page: sequence_page
      )
    else
      {:error, :not_found} ->
        assign(socket, selected_stream: nil)

      {:error, reason} ->
        assign(socket, query_error: reason)
    end
  end
  ```

  Never prepend the notification summary. Both reload helpers preserve the
  last good page/detail on transient errors.

- [ ] **Step 8: Run Streams GREEN tests**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/live/memory_streams_live_test.exs apps/backplane_admin/test/backplane/admin/route_boundary_test.exs apps/backplane_memory/test/backplane/memory/operations/streams_test.exs
  ```

  Expected: authenticated routes, literal unknown-ID 404, bounded windows, filters, and live behavior pass.

- [ ] **Step 9: Detect scope and commit**

  Run `gitnexus_detect_changes()`, inspect the direct diff, then:

  ```bash
  git add apps/backplane_admin/lib/backplane/admin/live/memory_streams_live.ex \
    apps/backplane_admin/test/backplane/admin/live/memory_streams_live_test.exs
  git diff --cached --check
  git commit -m "feat(memory): add v2 stream explorer"
  ```

### Task 12: Build Events explorer and safe detail

**Files:**

- Modify: `apps/backplane_admin/lib/backplane/admin/live/memory_events_live.ex`
- Create: `apps/backplane_admin/test/backplane/admin/live/memory_events_live_test.exs`

- [ ] **Step 1: Replace the Events skeleton contract**

  Confirm Task 9 already registered:

  ```elixir
  live("/memory/events", MemoryEventsLive, :index)
  live("/memory/events/:event_id", MemoryEventsLive, :show)
  ```

  Keep the authenticated literal-404 assertions from Task 9 green while
  replacing only the skeleton page behavior.

- [ ] **Step 2: Add Events LiveView RED tests**

  Cover:

  - empty state and compact table;
  - the empty state shows current Pipeline/Events effective status and a `/memory/pipeline` link;
  - URL-backed stream, project, agent, session, run, type, tool, status, from, and to filters;
  - UTC ISO-8601 URL times render as valid offset-free `datetime-local` input values;
  - second and fractional-second time bounds survive changing an unrelated
    filter without truncation;
  - filter patch removes cursor and preserves valid canonical values;
  - a successful load of a minute-precision `datetime-local` value and an
    explicit default limit replace-patches the full canonical UTC timestamp
    while omitting the default limit;
  - malformed time/cursor drops only that value, uses `replace: true`, and flashes;
  - maximum 100 rows and `"Load older"` cursor;
  - shareable detail retaining inventory filters;
  - event type, status, sequence, both timestamps, all identity fields, actor/role/importance/namespace/correlation/idempotency/causation values;
  - escaped content;
  - pretty, escaped payload JSON and visible `_backplane` metadata;
  - no edit/delete/replay/retry controls;
  - a matching newest-page notification triggers an authoritative reload;
  - a nonmatching notification does not reload;
  - a matching historical-page notification shows `"New events available"`;
  - a delayed event is sorted by persisted `occurred_at DESC, id DESC`, not arrival order.
  - an unrelated Settings message leaves the LiveView alive;
  - after a healthy page/detail load, `fail_memory_reads!/0` plus a matching
    notification retains the page and selected detail and renders the fixed
    repository error alert.

  In the delayed test, persist the event first, send `{:memory_event_inserted, safe_summary(event)}` directly to the LiveView, and assert the complete visible ID order after reload.

  Use this failure-shape test:

  ```elixir
  event = event_fixture(project: "last-good-event")

  {:ok, view, _html} =
    live(conn, ~p"/memory/events/#{event.id}?project=last-good-event")

  assert has_element?(view, "#event-payload")
  :ok = fail_memory_reads!()
  send(view.pid, {:memory_event_inserted, safe_summary(event)})

  assert has_element?(view, "#event-query-error")
  assert has_element?(view, "#event-payload")

  send(
    view.pid,
    {:setting_changed, "services.day.enabled", false}
  )

  assert Process.alive?(view.pid)
  ```

- [ ] **Step 3: Run Events tests to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/live/memory_events_live_test.exs apps/backplane_admin/test/backplane/admin/route_boundary_test.exs
  ```

  Expected: the Task 9 skeleton renders, but event filtering, detail, failure,
  pagination, and live-tail assertions fail.

- [ ] **Step 4: Implement subscribe-before-reload and canonical params**

  Mount with:

  ```elixir
  if connected?(socket) do
    Operations.subscribe_events()
    Operations.subscribe_rollout()
  end

  assign(socket,
    current_path: "/memory/events",
    rollout: Operations.rollout_state(),
    filters: %{},
    page: %{events: [], next_cursor: nil, filters: %{}},
    selected_event: nil,
    query_error: nil,
    new_events_available: false
  )
  ```

  Add the complete page/detail loading and canonicalization boundary:

  ```elixir
  @impl true
  def handle_params(params, _uri, socket) do
    query = Map.drop(params, ["event_id"])
    page_result = Operations.timeline(query)

    event_result =
      case socket.assigns.live_action do
        :show -> Operations.get_event(params["event_id"])
        :index -> {:ok, nil}
      end

    case {page_result, event_result} do
      {_page, {:error, :not_found}} ->
        {:noreply,
         socket
         |> put_flash(:error, "The selected event no longer exists.")
         |> push_navigate(to: ~p"/memory/events")}

      {{:ok, page}, {:ok, selected_event}} ->
        socket =
          assign(socket,
            page: page,
            filters: page.filters,
            selected_event: selected_event,
            query_error: nil,
            new_events_available: false
          )

        {:noreply, replace_event_query(socket, params, page.filters, false)}

      {{:error, {:invalid_param, _key, canonical}}, {:ok, _event}} ->
        {:noreply, replace_event_query(socket, params, canonical, true)}

      {{:error, reason}, _event} ->
        {:noreply, assign(socket, query_error: reason)}

      {_page, {:error, reason}} ->
        {:noreply, assign(socket, query_error: reason)}
    end
  end

  defp replace_event_query(socket, params, canonical, invalid?) do
    submitted = Map.drop(params, ["event_id"])

    if connected?(socket) and (invalid? or submitted != canonical) do
      socket =
        if invalid?,
          do:
            put_flash(
              socket,
              :error,
              "One invalid event parameter was removed."
            ),
          else: socket

      push_patch(socket,
        to:
          events_path(
            socket.assigns.live_action,
            params["event_id"],
            canonical
          ),
        replace: true
      )
    else
      socket
    end
  end
  ```

  The raw route ID is preserved during canonicalization, successful trimming
  and default-limit removal use `replace: true`, and the equality guard
  prevents loops. Repository failures update only `query_error`, retaining
  the last good bounded page and selected detail.

  Put this alert above the event table:

  ```heex
  <.dm_alert
    :if={@query_error}
    id="event-query-error"
    variant="error"
    title="Events unavailable"
    compact
  >
    The last loaded event data is still shown. Retry after checking the database connection.
  </.dm_alert>
  ```

- [ ] **Step 5: Implement all URL-backed filters**

  Render this wrapping DuskMoon form:

  ```heex
  <.form
    id="event-filters"
    for={%{}}
    as={:filters}
    phx-change="filter"
    phx-submit="filter"
    class="grid gap-3 sm:grid-cols-2 xl:grid-cols-5"
  >
    <.dm_input
      id="event-stream"
      name="filters[stream]"
      value={@filters["stream"]}
      label="Stream"
      phx-debounce="300"
    />
    <.dm_input
      id="event-project"
      name="filters[project]"
      value={@filters["project"]}
      label="Project"
      phx-debounce="300"
    />
    <.dm_input
      id="event-agent"
      name="filters[agent]"
      value={@filters["agent"]}
      label="Agent"
      phx-debounce="300"
    />
    <.dm_input
      id="event-session"
      name="filters[session]"
      value={@filters["session"]}
      label="Session"
      phx-debounce="300"
    />
    <.dm_input
      id="event-run"
      name="filters[run]"
      value={@filters["run"]}
      label="Run"
      phx-debounce="300"
    />
    <.dm_input
      id="event-type"
      name="filters[type]"
      value={@filters["type"]}
      label="Event type"
      phx-debounce="300"
    />
    <.dm_input
      id="event-tool"
      name="filters[tool]"
      value={@filters["tool"]}
      label="Tool"
      phx-debounce="300"
    />
    <.dm_input
      id="event-status"
      name="filters[status]"
      value={@filters["status"]}
      label="Status"
      phx-debounce="300"
    />
    <.dm_input
      id="event-from"
      name="filters[from]"
      value={datetime_local_value(@filters["from"])}
      label="From (UTC)"
      type="datetime-local"
      step="any"
    />
    <.dm_input
      id="event-to"
      name="filters[to]"
      value={datetime_local_value(@filters["to"])}
      label="To (UTC)"
      type="datetime-local"
      step="any"
    />
  </.form>
  ```

  Add the exact handler/path boundary:

  ```elixir
  def handle_event("filter", %{"filters" => raw}, socket) do
    normalized =
      raw
      |> Map.drop(["cursor"])
      |> Operations.normalize_timeline_params()

    {query, invalid?} =
      case normalized do
        {:ok, %{query: query}} -> {query, false}
        {:error, {:invalid_param, _key, query}} -> {query, true}
      end

    event_id =
      case socket.assigns.selected_event do
        %{id: event_id} -> event_id
        nil -> nil
      end

    socket =
      if invalid? do
        put_flash(socket, :error, "One invalid event parameter was removed.")
      else
        socket
      end

    {:noreply,
     push_patch(socket,
       to:
         events_path(
           socket.assigns.live_action,
           event_id,
           query
         ),
       replace: true
     )}
  end

  defp events_path(:show, event_id, query) when is_binary(event_id) do
    ~p"/memory/events/#{event_id}?#{query}"
  end

  defp events_path(_action, _event_id, query) do
    ~p"/memory/events?#{query}"
  end
  ```

  The Operations facade trims/drops blanks and validates times before the
  patch.
  `"Load older"` patches the same index/show path with
  `Map.put(@filters, "cursor", @page.next_cursor)` and replaces the bounded
  page.

- [ ] **Step 6: Render the table and safe responsive detail**

  Use:

  ```heex
  <.dm_table id="memory-events-table" data={@page.events} compact hover zebra class="min-w-[72rem]">
    <:col :let={event} label="Event">
      <.link href={event_detail_path(event.id, @filters)} class="font-mono text-primary hover:underline">
        {event.event_type}
      </.link>
    </:col>
    <:col :let={event} label="Stream / Sequence">
      <span class="font-mono text-xs">{event.stream_id} · #{event.sequence}</span>
    </:col>
    <:col :let={event} label="Project / Agent">
      <span>{event.project || "—"}</span>
      <span class="block font-mono text-xs text-on-surface-variant">{event.agent_id || "—"}</span>
    </:col>
    <:col :let={event} label="Tool">{event.tool_name || "—"}</:col>
    <:col :let={event} label="Status">
      <.status_badge status={event.status} />
    </:col>
    <:col :let={event} label="Occurred">{format_datetime(event.occurred_at)}</:col>
  </.dm_table>
  ```

  Wrap the table in `<div class="overflow-x-auto">`. Use a normal
  authenticated `href` to the detail route with the current query. Put the
  table and selected detail in:

  The existing `.table thead { display: table-header-group; }` rule in
  `apps/backplane_admin/assets/css/app.css` has greater specificity than
  DuskMoon's `hidden` utility. Keep that supported override unchanged, assert
  the Event column headers in the LiveView test, and verify the computed
  narrow-screen display in Task 16.

  ```heex
  <div class={[
    "grid min-w-0 gap-4",
    @selected_event &&
      "xl:grid-cols-[minmax(0,3fr)_minmax(22rem,2fr)]"
  ]}>
  ```

  The grid stacks on narrow screens.

  Define the referenced path helper in `MemoryEventsLive`:

  ```elixir
  defp event_detail_path(event_id, filters) do
    ~p"/memory/events/#{event_id}?#{filters}"
  end
  ```

  Render content by ordinary HEEX interpolation. Render payload as:

  ```heex
  <aside :if={@selected_event} class="min-w-0">
    <.dm_card variant="bordered" padding="sm">
      <div class="mb-4 flex items-start justify-between gap-3">
        <div>
          <.event_type_badge event_type={@selected_event.event_type} />
          <.status_badge status={@selected_event.status} />
        </div>
        <.dm_btn patch={~p"/memory/events?#{@filters}"} size="sm">
          Close
        </.dm_btn>
      </div>

      <dl
        id="event-identity"
        class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2"
      >
        <.identity_value label="Event ID" value={@selected_event.id} />
        <.identity_value label="Sequence" value={@selected_event.sequence} />
        <.identity_value
          label="Occurred"
          value={format_datetime(@selected_event.occurred_at)}
        />
        <.identity_value
          label="Persisted"
          value={format_datetime(@selected_event.inserted_at)}
        />
        <.identity_value label="Stream" value={@selected_event.stream_id} />
        <.identity_value label="Project" value={@selected_event.project} />
        <.identity_value label="Agent" value={@selected_event.agent_id} />
        <.identity_value label="Host" value={@selected_event.host_id} />
        <.identity_value label="Client" value={@selected_event.client_id} />
        <.identity_value label="Session" value={@selected_event.session_id} />
        <.identity_value label="Run" value={@selected_event.run_id} />
        <.identity_value label="Tool" value={@selected_event.tool_name} />
        <.identity_value label="Actor" value={@selected_event.actor_type} />
        <.identity_value label="Role" value={@selected_event.role} />
        <.identity_value
          label="Importance"
          value={@selected_event.importance}
        />
        <.identity_value label="Namespace" value={@selected_event.namespace} />
        <.identity_value
          label="Correlation"
          value={@selected_event.correlation_id}
        />
        <.identity_value
          label="Idempotency"
          value={@selected_event.idempotency_key}
        />
        <.identity_value
          label="Causation"
          value={@selected_event.causation_id}
        />
      </dl>

      <section class="mt-5">
        <h2 class="mb-2 font-semibold">Content</h2>
        <p id="event-content" class="whitespace-pre-wrap break-words text-sm">
          {@selected_event.content || "—"}
        </p>
      </section>

      <section class="mt-5">
        <h2 class="mb-2 font-semibold">Payload</h2>
        <pre
          id="event-payload"
          class="max-h-[32rem] overflow-auto whitespace-pre-wrap break-all rounded-lg bg-surface-container-high p-3 font-mono text-xs text-on-surface"
        >{format_json(@selected_event.payload)}</pre>
      </section>
    </.dm_card>
  </aside>
  ```

  Complete the render envelope with bounded cursor navigation and the
  historical indicator:

  ```heex
  <.dm_alert
    :if={@new_events_available}
    id="event-new-events"
    variant="info"
    title="New events available"
    compact
  >
    <.dm_btn
      patch={
        events_path(
          @live_action,
          @selected_event && @selected_event.id,
          Map.delete(@filters, "cursor")
        )
      }
      replace
      size="sm"
    >
      Refresh newest
    </.dm_btn>
  </.dm_alert>

  <.dm_btn
    :if={@page.next_cursor}
    patch={
      events_path(
        @live_action,
        @selected_event && @selected_event.id,
        Map.put(@filters, "cursor", @page.next_cursor)
      )
    }
  >
    Load older
  </.dm_btn>
  ```

  Replace the skeleton `render/1` with this complete composition:

  ```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-events">
      <.memory_page_header
        title="Events"
        subtitle="Authoritative Memory V2 event explorer"
      />

      <.dm_alert
        :if={@query_error}
        id="event-query-error"
        variant="error"
        title="Events unavailable"
        compact
      >
        The last loaded event data is still shown. Retry after checking the
        database connection.
      </.dm_alert>

      <.dm_alert
        :if={@new_events_available}
        id="event-new-events"
        variant="info"
        title="New events available"
        compact
      >
        <.dm_btn
          patch={
            events_path(
              @live_action,
              @selected_event && @selected_event.id,
              Map.delete(@filters, "cursor")
            )
          }
          replace
          size="sm"
        >
          Refresh newest
        </.dm_btn>
      </.dm_alert>

      <.form
        id="event-filters"
        for={%{}}
        as={:filters}
        phx-change="filter"
        phx-submit="filter"
        class="grid gap-3 sm:grid-cols-2 xl:grid-cols-5"
      >
        <.dm_input
          id="event-stream"
          name="filters[stream]"
          value={@filters["stream"]}
          label="Stream"
          phx-debounce="300"
        />
        <.dm_input
          id="event-project"
          name="filters[project]"
          value={@filters["project"]}
          label="Project"
          phx-debounce="300"
        />
        <.dm_input
          id="event-agent"
          name="filters[agent]"
          value={@filters["agent"]}
          label="Agent"
          phx-debounce="300"
        />
        <.dm_input
          id="event-session"
          name="filters[session]"
          value={@filters["session"]}
          label="Session"
          phx-debounce="300"
        />
        <.dm_input
          id="event-run"
          name="filters[run]"
          value={@filters["run"]}
          label="Run"
          phx-debounce="300"
        />
        <.dm_input
          id="event-type"
          name="filters[type]"
          value={@filters["type"]}
          label="Event type"
          phx-debounce="300"
        />
        <.dm_input
          id="event-tool"
          name="filters[tool]"
          value={@filters["tool"]}
          label="Tool"
          phx-debounce="300"
        />
        <.dm_input
          id="event-status"
          name="filters[status]"
          value={@filters["status"]}
          label="Status"
          phx-debounce="300"
        />
        <.dm_input
          id="event-from"
          name="filters[from]"
          value={datetime_local_value(@filters["from"])}
          label="From (UTC)"
          type="datetime-local"
          step="any"
        />
        <.dm_input
          id="event-to"
          name="filters[to]"
          value={datetime_local_value(@filters["to"])}
          label="To (UTC)"
          type="datetime-local"
          step="any"
        />
      </.form>

      <.memory_empty_state
        :if={@page.events == [] and is_nil(@selected_event)}
        title="No events match these filters"
        rollout={@rollout}
      />

      <div class={[
        "mt-4 grid min-w-0 gap-4",
        @selected_event &&
          "xl:grid-cols-[minmax(0,3fr)_minmax(22rem,2fr)]"
      ]}>
        <section class="min-w-0">
          <div class="overflow-x-auto">
            <.dm_table
              id="memory-events-table"
              data={@page.events}
              compact
              hover
              zebra
              class="min-w-[72rem]"
            >
              <:col :let={event} label="Event">
                <.link
                  href={event_detail_path(event.id, @filters)}
                  class="font-mono text-primary hover:underline"
                >
                  {event.event_type}
                </.link>
              </:col>
              <:col :let={event} label="Stream / Sequence">
                <span class="font-mono text-xs">
                  {event.stream_id} · #{event.sequence}
                </span>
              </:col>
              <:col :let={event} label="Project / Agent">
                <span>{event.project || "—"}</span>
                <span class="block font-mono text-xs text-on-surface-variant">
                  {event.agent_id || "—"}
                </span>
              </:col>
              <:col :let={event} label="Tool">
                {event.tool_name || "—"}
              </:col>
              <:col :let={event} label="Status">
                <.status_badge status={event.status} />
              </:col>
              <:col :let={event} label="Occurred">
                {format_datetime(event.occurred_at)}
              </:col>
            </.dm_table>
          </div>

          <div class="mt-3 flex justify-end">
            <.dm_btn
              :if={@page.next_cursor}
              patch={
                events_path(
                  @live_action,
                  @selected_event && @selected_event.id,
                  Map.put(@filters, "cursor", @page.next_cursor)
                )
              }
            >
              Load older
            </.dm_btn>
          </div>
        </section>

        <aside :if={@selected_event} class="min-w-0">
          <.dm_card variant="bordered" padding="sm">
            <div class="mb-4 flex items-start justify-between gap-3">
              <div class="flex flex-wrap gap-2">
                <.event_type_badge event_type={@selected_event.event_type} />
                <.status_badge status={@selected_event.status} />
              </div>
              <.dm_btn
                patch={events_path(:index, nil, @filters)}
                size="sm"
                variant="ghost"
              >
                Close detail
              </.dm_btn>
            </div>

            <dl
              id="event-identity"
              class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2"
            >
              <.identity_value label="Event ID" value={@selected_event.id} />
              <.identity_value label="Sequence" value={@selected_event.sequence} />
              <.identity_value
                label="Occurred"
                value={format_datetime(@selected_event.occurred_at)}
              />
              <.identity_value
                label="Persisted"
                value={format_datetime(@selected_event.inserted_at)}
              />
              <.identity_value label="Stream" value={@selected_event.stream_id} />
              <.identity_value label="Project" value={@selected_event.project} />
              <.identity_value label="Agent" value={@selected_event.agent_id} />
              <.identity_value label="Host" value={@selected_event.host_id} />
              <.identity_value label="Client" value={@selected_event.client_id} />
              <.identity_value label="Session" value={@selected_event.session_id} />
              <.identity_value label="Run" value={@selected_event.run_id} />
              <.identity_value label="Tool" value={@selected_event.tool_name} />
              <.identity_value label="Actor" value={@selected_event.actor_type} />
              <.identity_value label="Role" value={@selected_event.role} />
              <.identity_value label="Importance" value={@selected_event.importance} />
              <.identity_value label="Namespace" value={@selected_event.namespace} />
              <.identity_value
                label="Correlation"
                value={@selected_event.correlation_id}
              />
              <.identity_value
                label="Idempotency"
                value={@selected_event.idempotency_key}
              />
              <.identity_value
                label="Causation"
                value={@selected_event.causation_id}
              />
            </dl>

            <section class="mt-5">
              <h2 class="mb-2 font-semibold">Content</h2>
              <p
                id="event-content"
                class="whitespace-pre-wrap break-words text-sm"
              >
                {@selected_event.content || "—"}
              </p>
            </section>

            <section class="mt-5">
              <h2 class="mb-2 font-semibold">Payload</h2>
              <pre
                id="event-payload"
                class="max-h-[32rem] overflow-auto whitespace-pre-wrap break-all rounded-lg bg-surface-container-high p-3 font-mono text-xs text-on-surface"
              >{format_json(@selected_event.payload)}</pre>
            </section>
          </.dm_card>
        </aside>
      </div>
    </div>
    """
  end
  ```

  Never call `raw/1`, `Phoenix.HTML.raw/1`, or inject payload into an attribute.

- [ ] **Step 7: Implement authoritative live-tail behavior**

  Handle:

  ```elixir
  def handle_info({:memory_event_inserted, summary}, socket) do
    cond do
      not Operations.notification_matches?(summary, socket.assigns.filters) ->
        {:noreply, socket}

      is_nil(socket.assigns.filters["cursor"]) ->
        {:noreply, reload_events(socket)}

      true ->
        {:noreply, assign(socket, new_events_available: true)}
    end
  end
  ```

  `reload_events/1` calls `Operations.timeline/1` and reloads a selected event by ID. It never prepends the summary, because a caller-supplied delayed timestamp may place the committed row below or outside the visible top 100.

  Implement it as:

  ```elixir
  defp reload_events(socket) do
    with {:ok, page} <- Operations.timeline(socket.assigns.filters),
         {:ok, selected_event} <-
           reload_selected_event(socket.assigns.selected_event) do
      assign(socket,
        page: page,
        filters: page.filters,
        selected_event: selected_event,
        query_error: nil,
        new_events_available: false
      )
    else
      {:error, reason} ->
        assign(socket,
          query_error: reason
        )
    end
  end

  defp reload_selected_event(nil), do: {:ok, nil}

  defp reload_selected_event(selected) do
    case Operations.get_event(selected.id) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @memory_setting_keys [
    "memory.pipeline.enabled",
    "memory.events.enabled",
    "memory.events.dual_write"
  ]

  def handle_info({:setting_changed, key, _value}, socket)
      when key in @memory_setting_keys do
    {:noreply, assign(socket, rollout: Operations.rollout_state())}
  end

  def handle_info({:setting_changed, _key, _value}, socket) do
    {:noreply, socket}
  end
  ```

  A transient timeline or detail failure changes only `query_error`; the last
  page and selected detail stay visible. Only an authoritative `:not_found`
  clears a stale selected event.

- [ ] **Step 8: Run Events GREEN tests**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/live/memory_events_live_test.exs apps/backplane_admin/test/backplane/admin/route_boundary_test.exs apps/backplane_memory/test/backplane/memory/operations/events_test.exs
  ```

  Expected: filters, safe detail, bounded pagination, delayed ordering, and historical indicators pass.

- [ ] **Step 9: Detect scope and commit**

  Run `gitnexus_detect_changes()`, inspect the direct diff, then:

  ```bash
  git add apps/backplane_admin/lib/backplane/admin/live/memory_events_live.ex \
    apps/backplane_admin/test/backplane/admin/live/memory_events_live_test.exs
  git diff --cached --check
  git commit -m "feat(memory): add v2 event explorer"
  ```

### Task 13: Build guarded Pipeline controls

**Files:**

- Modify: `apps/backplane_admin/lib/backplane/admin/live/memory_pipeline_live.ex`
- Create: `apps/backplane_admin/test/backplane/admin/live/memory_pipeline_live_test.exs`

- [ ] **Step 1: Replace the Pipeline skeleton contract**

  Confirm Task 9 already registered:

  ```elixir
  live("/memory/pipeline", MemoryPipelineLive, :index)
  ```

- [ ] **Step 2: Add Pipeline LiveView RED tests**

  Cover:

  - three and only three accessible switches;
  - switch checked values reflect configured values;
  - badges reflect effective values;
  - dependency-disabled helpers explain the required order;
  - literal `"true"` and `"false"` are accepted;
  - any other submitted value is rejected without mutation;
  - enabling Pipeline, then Events succeeds;
  - disabling a parent with a configured child fails and retains state;
  - an inconsistent configured child is visibly blocked and can be disabled;
  - turning Dual Write on shows a confirmation state without writing;
  - confirm writes Dual Write; cancel does not;
  - turning Dual Write off is immediate;
  - dependency/write errors render a DuskMoon error alert and reload persisted state;
  - a `{:setting_changed, key, value}` message reloads state;
  - an unrelated Settings message leaves the LiveView alive;
  - after `fail_memory_settings!/0`, a valid form change renders the fixed
    save error, leaves the configured switch value unchanged, and clears no
    other gate state;
  - exactly five unavailable later stages render;
  - no future-stage input, switch, form, or mutation event exists.

  Use selectors:

  ```elixir
  assert has_element?(view, "#pipeline-gate[role=switch]")
  assert has_element?(view, "#events-gate[role=switch]")
  assert has_element?(view, "#dual-write-gate[role=switch]")
  refute has_element?(view, ~s|[name*="window_summaries"]|)
  refute has_element?(view, ~s|[name*="session_summary_v2"]|)
  refute has_element?(view, ~s|[name*="fact_extraction_v2"]|)
  refute has_element?(view, ~s|[name*="procedure_extraction_v2"]|)
  refute has_element?(view, ~s|[name*="recall_v2"]|)
  ```

  Use this adapter-failure test:

  ```elixir
  {:ok, view, _html} = live(conn, ~p"/memory/pipeline")
  refute has_element?(view, "#pipeline-gate[checked]")

  :ok = fail_memory_settings!()

  render_change(view, "set-gate", %{
    "gate" => %{"name" => "pipeline", "value" => "true"}
  })

  assert has_element?(view, "#pipeline-mutation-error")
  refute has_element?(view, "#pipeline-gate[checked]")

  send(
    view.pid,
    {:setting_changed, "services.day.enabled", false}
  )

  assert Process.alive?(view.pid)
  ```

- [ ] **Step 3: Run Pipeline test to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/live/memory_pipeline_live_test.exs
  ```

  Expected: the Task 9 skeleton renders, but gate controls, dependency,
  confirmation, adapter-failure, and unavailable-stage assertions fail.

- [ ] **Step 4: Subscribe before initial rollout load**

  Implement:

  ```elixir
  def mount(_params, _session, socket) do
    if connected?(socket), do: Operations.subscribe_rollout()

    {:ok,
     assign(socket,
       current_path: "/memory/pipeline",
       rollout: Operations.rollout_state(),
       mutation_error: nil,
       pending_dual_write: false
     )}
  end

  @memory_setting_keys [
    "memory.pipeline.enabled",
    "memory.events.enabled",
    "memory.events.dual_write"
  ]

  @impl true
  def handle_info({:setting_changed, key, _value}, socket)
      when key in @memory_setting_keys do
    {:noreply, assign(socket, rollout: Operations.rollout_state())}
  end

  def handle_info({:setting_changed, _key, _value}, socket) do
    {:noreply, socket}
  end
  ```

  Reload through `Operations.rollout_state/0` after every write attempt and
  relevant Settings message. Never optimistically mutate configured/effective
  assigns.

- [ ] **Step 5: Render literal-boolean DuskMoon switches**

  Replace the skeleton render with this complete page and private gate
  component:

  ```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-pipeline">
      <.memory_page_header
        title="Pipeline"
        subtitle="Guarded Memory V2 rollout controls"
      />

      <.dm_alert
        :if={@mutation_error}
        id="pipeline-mutation-error"
        variant="error"
        title="Rollout change not saved"
        compact
      >
        {@mutation_error}
      </.dm_alert>

      <section aria-labelledby="implemented-gates-heading">
        <h2 id="implemented-gates-heading" class="mb-3 text-lg font-semibold">
          Implemented gates
        </h2>

        <div class="grid gap-4 lg:grid-cols-3">
          <.gate_control
            form_id="pipeline-gate-form"
            input_id="pipeline-gate"
            name="pipeline"
            gate={@rollout.pipeline}
            disabled={pipeline_disabled?(@rollout)}
            helper="Master gate for Memory V2. Disable Events and Dual Write before turning it off."
          />

          <.gate_control
            form_id="events-gate-form"
            input_id="events-gate"
            name="events"
            gate={@rollout.events}
            disabled={events_disabled?(@rollout)}
            helper="Requires effective Pipeline. Disable Dual Write before turning Events off."
          />

          <.gate_control
            form_id="dual-write-gate-form"
            input_id="dual-write-gate"
            name="dual_write"
            gate={@rollout.dual_write}
            disabled={dual_write_disabled?(@rollout)}
            helper="Requires effective Events. Enabling requires confirmation."
          />
        </div>
      </section>

      <.dm_alert
        :if={@pending_dual_write}
        id="dual-write-confirmation"
        variant="warning"
        title="Enable Dual Write?"
        class="mt-4"
      >
        New writes will also enter the Memory V2 event pipeline.

        <div class="mt-3 flex flex-wrap gap-2">
          <.dm_btn
            id="confirm-dual-write"
            variant="warning"
            phx-click="confirm-dual-write"
            type="button"
          >
            Confirm
          </.dm_btn>
          <.dm_btn
            id="cancel-dual-write"
            variant="ghost"
            phx-click="cancel-dual-write"
            type="button"
          >
            Cancel
          </.dm_btn>
        </div>
      </.dm_alert>

      <section
        id="later-stages"
        aria-labelledby="later-stages-heading"
        class="mt-8"
      >
        <h2 id="later-stages-heading" class="mb-3 text-lg font-semibold">
          Later stages
        </h2>

        <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
          <.dm_card
            :for={stage <- @rollout.later}
            class="later-stage"
            variant="bordered"
            padding="sm"
          >
            <div class="flex items-start justify-between gap-2">
              <h3 class="font-medium">{stage.label}</h3>
              <.dm_badge variant="neutral" size="sm">Unavailable</.dm_badge>
            </div>
            <p class="mt-2 text-sm text-on-surface-variant">
              This stage has no production consumer.
            </p>
          </.dm_card>
        </div>
      </section>
    </div>
    """
  end

  attr :form_id, :string, required: true
  attr :input_id, :string, required: true
  attr :name, :string, required: true
  attr :gate, :map, required: true
  attr :disabled, :boolean, required: true
  attr :helper, :string, required: true

  defp gate_control(assigns) do
    ~H"""
    <.dm_card variant="bordered" padding="sm">
      <.form id={@form_id} for={%{}} phx-change="set-gate">
        <input type="hidden" name="gate[name]" value={@name} />
        <.dm_switch
          id={@input_id}
          name="gate[value]"
          checked={@gate.configured}
          label={@gate.label}
          helper={@helper}
          horizontal
          disabled={@disabled}
        />
      </.form>

      <div class="mt-3">
        <.gate_state_badges gate={@gate} />
      </div>
    </.dm_card>
    """
  end
  ```

  DuskMoon emits hidden `"false"` and checked `"true"` values. Pattern-match
  only those two strings in the event handler; reject every other shape/value.
  `gate_state_badges/1` renders configured and effective state separately,
  including `"Configured, blocked"` for an ineffective configured child.

  Use these exact UI disable helpers while retaining backend enforcement:

  ```elixir
  defp pipeline_disabled?(rollout) do
    rollout.events.configured or rollout.dual_write.configured
  end

  defp events_disabled?(rollout) do
    if rollout.events.configured do
      rollout.dual_write.configured
    else
      not rollout.pipeline.effective or rollout.dual_write.configured
    end
  end

  defp dual_write_disabled?(rollout) do
    not rollout.dual_write.configured and not rollout.events.effective
  end
  ```

- [ ] **Step 6: Implement server-controlled Dual Write confirmation**

  Use:

  ```elixir
  def handle_event(
        "set-gate",
        %{"gate" => %{"name" => "dual_write", "value" => "true"}},
        socket
      ) do
    {:noreply, assign(socket, pending_dual_write: true, mutation_error: nil)}
  end

  def handle_event("confirm-dual-write", _params, socket) do
    mutate_gate(socket, :dual_write, true)
  end

  def handle_event("cancel-dual-write", _params, socket) do
    {:noreply, assign(socket, pending_dual_write: false)}
  end
  ```

  Render a warning `dm_alert` plus DuskMoon confirm/cancel buttons only while pending. Do not write until confirmation. This avoids client-side modal state or a new JavaScript hook.

  All other valid changes call `Operations.set_gate/2` immediately. `mutate_gate/3` reloads persisted rollout state on both success and error, retains a safe human-readable error, and clears pending confirmation.

  Implement the general parsing and mutation boundary as:

  ```elixir
  @gate_names %{
    "pipeline" => :pipeline,
    "events" => :events,
    "dual_write" => :dual_write
  }

  def handle_event(
        "set-gate",
        %{"gate" => %{"name" => name, "value" => value}},
        socket
      )
      when is_map_key(@gate_names, name) and value in ["true", "false"] do
    mutate_gate(socket, Map.fetch!(@gate_names, name), value == "true")
  end

  def handle_event("set-gate", _params, socket) do
    {:noreply, assign(socket, mutation_error: "The submitted gate value is invalid.")}
  end

  defp mutate_gate(socket, gate, value) do
    result = Operations.set_gate(gate, value)
    rollout = Operations.rollout_state()

    case result do
      :ok ->
        {:noreply,
         assign(socket,
           rollout: rollout,
           mutation_error: nil,
           pending_dual_write: false
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           rollout: rollout,
           mutation_error: gate_error(reason),
           pending_dual_write: false
         )}
    end
  end

  defp gate_error({:dependency, :pipeline, true}), do: "Enable Pipeline first."
  defp gate_error({:dependency, :events, true}), do: "Enable Events first."
  defp gate_error({:dependency, :dual_write, false}), do: "Disable Dual Write first."
  defp gate_error({:blocked_descendant, :events}), do: "Disable Events first."
  defp gate_error({:blocked_descendant, :dual_write}), do: "Disable Dual Write first."
  defp gate_error(:invalid_gate), do: "The submitted gate is invalid."
  defp gate_error(:invalid_boolean), do: "The submitted gate value is invalid."
  defp gate_error(_reason), do: "The rollout setting could not be saved."
  ```

  Place the special Dual Write `"true"` clause before this general clause so it enters confirmation instead of calling `mutate_gate/3`.

  Render `@mutation_error` only through this fixed alert boundary:

  ```heex
  <.dm_alert
    :if={@mutation_error}
    id="pipeline-mutation-error"
    variant="error"
    title="Rollout change not saved"
    compact
  >
    {@mutation_error}
  </.dm_alert>
  ```

  `gate_error/1` maps all adapter/database failures to the fixed final clause;
  never render the inspected error term.

- [ ] **Step 7: Render later stages without controls**

  Use the exact `:for={stage <- @rollout.later}` card block in Step 5. Verify
  its DOM contains five `.later-stage` cards, five `"Unavailable"` badges,
  no descendant `input`, `form`, `[phx-click]`, or `[phx-change]`, and no
  configured value for any unavailable key.

- [ ] **Step 8: Run Pipeline GREEN tests**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/live/memory_pipeline_live_test.exs apps/backplane_memory/test/backplane/memory/operations/rollout_test.exs
  ```

  Expected: dependency order, confirmation, literal booleans, PubSub reload, and unavailable stages pass.

- [ ] **Step 9: Detect scope and commit**

  Run `gitnexus_detect_changes()`, inspect the direct diff, then:

  ```bash
  git add apps/backplane_admin/lib/backplane/admin/live/memory_pipeline_live.ex \
    apps/backplane_admin/test/backplane/admin/live/memory_pipeline_live_test.exs
  git diff --cached --check
  git commit -m "feat(memory): add v2 pipeline controls"
  ```

### Task 14: Cut over navigation and delete the legacy Memory UI

**Files:**

- Modify: `apps/backplane_admin/lib/backplane/admin/router.ex`
- Modify: `apps/backplane_admin/lib/backplane/admin/components/layouts.ex`
- Modify: `apps/backplane_admin/test/backplane/admin/route_boundary_test.exs`
- Delete: `apps/backplane_admin/lib/backplane/admin/live/memory_live.ex`
- Delete: `apps/backplane_admin/lib/backplane/admin/live/memory_stats_live.ex`
- Delete: `apps/backplane_admin/lib/backplane/admin/live/memory_observations_live.ex`
- Delete: `apps/backplane_admin/lib/backplane/admin/live/memory_sessions_live.ex`
- Delete: `apps/backplane_admin/lib/backplane/admin/live/memory_graph_live.ex`
- Delete: `apps/backplane_admin/lib/backplane/admin/live/memory_actions_live.ex`
- Delete: `apps/backplane_admin/lib/backplane/admin/live/memory_audit_live.ex`
- Delete: `apps/backplane_admin/lib/backplane/admin/live/memory_config_live.ex`
- Delete: `apps/backplane_admin/test/backplane/admin/live/memory_live_test.exs`

- [ ] **Step 1: Add final cutover RED tests**

  Assert the Memory sidebar contains exactly:

  ```elixir
  [
    {"Overview", "/memory"},
    {"Streams", "/memory/streams"},
    {"Events", "/memory/events"},
    {"Pipeline", "/memory/pipeline"}
  ]
  ```

  Assert all four authenticated pages return 200.

  For each removed route:

  ```elixir
  ~w(
    /memory/browse
    /memory/stats
    /memory/observations
    /memory/sessions
    /memory/graph
    /memory/actions
    /memory/audit
    /memory/config
  )
  ```

  assert a valid authenticated request returns status 404 and exact body `"not found"`. Also assert no redirect location exists.

  Assert unknown stream/event IDs return 404 only after valid auth; with configured credentials and no header they return 401 before resource lookup.

- [ ] **Step 2: Run route tests to verify RED**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/route_boundary_test.exs
  ```

  Expected: legacy paths still resolve and old nav entries remain.

- [ ] **Step 3: Remove every legacy route**

  Delete these eight declarations from the optional admin scope:

  ```elixir
  live("/memory/observations", MemoryObservationsLive, :index)
  live("/memory/sessions", MemorySessionsLive, :index)
  live("/memory/graph", MemoryGraphLive, :index)
  live("/memory/actions", MemoryActionsLive, :index)
  live("/memory/audit", MemoryAuditLive, :index)
  live("/memory/config", MemoryConfigLive, :index)
  live("/memory/browse", MemoryLive, :index)
  live("/memory/stats", MemoryStatsLive, :index)
  ```

  Do not add redirects. The router's existing catch-all owns the hard 404.

- [ ] **Step 4: Replace Memory navigation**

  Replace the Memory branch in `left_nav_items/1` with:

  ```elixir
  [
    %{label: "Overview", path: "/memory", match: :exact, icon: "brain"},
    %{label: "Streams", path: "/memory/streams", icon: "source-branch"},
    %{label: "Events", path: "/memory/events", icon: "timeline-text-outline"},
    %{label: "Pipeline", path: "/memory/pipeline", icon: "pipe"}
  ]
  ```

  Keep the Memory top-nav item and the rest of the admin shell unchanged.

- [ ] **Step 5: Delete only legacy UI modules/tests**

  Delete the eight legacy LiveView files and the aggregate legacy test listed above. Do not delete V1 contexts, schemas, migrations, workers, tools, or tests for backend projection behavior.

- [ ] **Step 6: Run final cutover GREEN tests**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_admin/test/backplane/admin/route_boundary_test.exs apps/backplane_admin/test/backplane/admin/live/memory_overview_live_test.exs apps/backplane_admin/test/backplane/admin/live/memory_streams_live_test.exs apps/backplane_admin/test/backplane/admin/live/memory_events_live_test.exs apps/backplane_admin/test/backplane/admin/live/memory_pipeline_live_test.exs
  ```

  Expected: four V2 destinations pass and every legacy route is a hard 404.

- [ ] **Step 7: Detect scope and commit**

  Run `gitnexus_detect_changes()`, inspect the deletion list carefully, then:

  ```bash
  git add -A apps/backplane_admin/lib/backplane/admin/router.ex \
    apps/backplane_admin/lib/backplane/admin/components/layouts.ex \
    apps/backplane_admin/lib/backplane/admin/live \
    apps/backplane_admin/test/backplane/admin/route_boundary_test.exs \
    apps/backplane_admin/test/backplane/admin/live
  git diff --cached --check
  git commit -m "refactor(memory): drop legacy admin pages"
  ```

### Task 15: Run scoped regression, compile, and asset verification

**Files:**

- Verify all files in this plan.
- Do not modify out-of-scope failures.

- [ ] **Step 1: Run the full in-scope Memory core suite**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane_memory/test/backplane/memory/events apps/backplane_memory/test/backplane/memory/operations apps/backplane_memory/test/backplane/memory/observations_test.exs apps/backplane_memory/test/backplane/memory/config_test.exs apps/backplane_memory/test/backplane/memory/namespace_contract_test.exs
  ```

  Expected: all in-scope Memory tests pass. If an out-of-scope test fails, report it and stop rather than repairing unrelated code.

- [ ] **Step 2: Run the full in-scope auth/admin suite**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix test apps/backplane/test/backplane/web/admin_auth_plug_test.exs apps/backplane_system/test/backplane/runtime_config_test.exs apps/backplane_admin/test/backplane/admin/endpoint_test.exs apps/backplane_admin/test/backplane/admin/route_boundary_test.exs apps/backplane_admin/test/backplane/admin/live/memory_overview_live_test.exs apps/backplane_admin/test/backplane/admin/live/memory_streams_live_test.exs apps/backplane_admin/test/backplane/admin/live/memory_events_live_test.exs apps/backplane_admin/test/backplane/admin/live/memory_pipeline_live_test.exs
  ```

  Expected: all focused auth and admin tests pass.

- [ ] **Step 3: Compile with an isolated build path**

  ```bash
  MIX_BUILD_PATH=/tmp/backplane-memory-v2-ui-build devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix compile --warnings-as-errors
  ```

  This avoids false module-conflict noise from a live process that owns `_build/dev`.

- [ ] **Step 4: Build admin assets**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix do --app backplane_admin assets.build
  ```

  Expected: Bun and Tailwind exit zero. Generated `priv/static` output remains ignored and must not be committed.

- [ ] **Step 5: Check formatting and direct scope**

  ```bash
  devenv shell -- env PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres mix format --check-formatted
  git diff --check
  git status --short
  ```

  Only files listed by this plan may be modified.

### Task 16: Verify runtime security, remote binding, themes, responsive layout, and accessibility

**Files:**

- Verify the running application.
- Modify only a file already listed in this plan if browser evidence reveals an in-scope defect, then rerun its focused test and Task 15.

- [ ] **Step 1: Prove fail-closed startup without credentials**

  Start the application without the two admin variables:

  ```bash
  devenv shell -- env \
    -u BACKPLANE_ADMIN_USERNAME \
    -u BACKPLANE_ADMIN_PASSWORD \
    PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres \
    mix backplane.run
  ```

  In another terminal:

  ```bash
  curl -i http://127.0.0.1:4221/memory
  ```

  Expected: status 503 and body `Admin authentication is not configured`. Stop this process cleanly.

- [ ] **Step 2: Start remote development with credentials**

  ```bash
  devenv shell -- env \
    PGHOST=/home/gao/Workspace/gsmlg-opt/backplane/.devenv/run/postgres \
    BACKPLANE_ADMIN_USERNAME=codex \
    BACKPLANE_ADMIN_PASSWORD=codex-memory-v2 \
    mix backplane.run
  ```

  Confirm the literal bind:

  ```bash
  ss -ltnp | rg '0\\.0\\.0\\.0:4221'
  ```

  `0.0.0.0` is a bind address, not a browser destination. Use `127.0.0.1` or the remote host address for requests.

- [ ] **Step 3: Prove 401/200/404 boundaries**

  ```bash
  curl -i http://127.0.0.1:4221/memory
  curl -i -u codex:codex-memory-v2 http://127.0.0.1:4221/memory
  curl -i -u codex:codex-memory-v2 http://127.0.0.1:4221/memory/browse
  ```

  Expected respectively: 401 with Basic challenge, 200, and hard 404 with no redirect.

- [ ] **Step 4: Invoke the browser verification skill**

  Invoke `chrome-devtools-mcp` before browser actions. Open the authenticated admin endpoint and verify all four pages in both `moonlight` and `sunshine`.

  At desktop width, verify:

  - overview has all six independent regions and five unavailable stages;
  - filters and detail URLs remain bookmarkable;
  - Stream/Event tables have visible headers;
  - detail panels do not mutate records;
  - gate switches expose accessible names and configured/effective state;
  - Dual Write requires the explicit confirm action;
  - a newly committed matching event appears without manual refresh.

- [ ] **Step 5: Verify the 390px narrow layout**

  Set viewport width to 390px and inspect computed layout:

  - filters wrap without clipping;
  - list/detail grids stack;
  - the table wrapper owns horizontal scrolling;
  - table `<thead>` computed `display` is `table-header-group`;
  - large payload text wraps/scrolls inside its bounded `<pre>`;
  - the page itself has no unintended horizontal overflow;
  - all four navigation items remain reachable.

- [ ] **Step 6: Verify keyboard and accessibility behavior**

  Use keyboard traversal only. Confirm visible focus, logical order, switch labels, `role="switch"`, correct `aria-checked`, reachable filter controls, reachable pagination, and a clear confirmation/cancel path. Run the DevTools accessibility inspection for unlabeled form controls and duplicate IDs.

- [ ] **Step 7: Capture evidence and repair only proven in-scope defects**

  Record the tested URLs, themes, viewport sizes, auth status codes, bind output, and any screenshots in the implementation handoff. If browser evidence finds an in-scope defect, first add or tighten a focused test, make the smallest correction in an already listed file, rerun that test, then repeat Tasks 15 and 16.

### Task 17: Final review and completion commit

**Files:**

- Review every changed file against `docs/superpowers/specs/2026-07-17-memory-v2-admin-ui-design.md`.

- [ ] **Step 1: Invoke code review**

  Invoke `requesting-code-review` and review the complete branch diff from `19ed221`. Resolve all correctness, security, transaction-boundary, pagination, privacy, and accessibility findings within scope. Rerun the focused test covering each correction.

- [ ] **Step 2: Invoke verification-before-completion**

  Invoke `verification-before-completion` and use fresh outputs from Tasks 15 and 16. Do not claim completion from earlier logs.

- [ ] **Step 3: Run final change detection**

  Run `gitnexus_detect_changes()`. Compare it with:

  ```bash
  git status --short
  git diff --stat 19ed221
  git diff --check 19ed221
  ```

  Confirm:

  - no V1 backend file was deleted;
  - no notification contains content/payload;
  - every event insert path reaches transactional `pg_notify`;
  - Memory LiveViews call only `Backplane.Memory.Operations`;
  - only three implemented settings are mutable;
  - all eight legacy UI routes are absent;
  - the four Memory routes remain in the dedicated required-auth live session.

- [ ] **Step 4: Commit any review-only corrections**

  If review produced changes:

  ```bash
  git add -A
  git diff --cached --check
  git commit -m "fix(memory): address v2 admin review"
  ```

  If review produced no changes, do not create an empty commit.

- [ ] **Step 5: Report the completed branch**

  Report commit IDs, exact test/compile/asset commands and results, runtime auth/bind results, browser/theme/viewport evidence, and any out-of-scope failures. Do not push, merge, or deploy unless the user explicitly asks.
