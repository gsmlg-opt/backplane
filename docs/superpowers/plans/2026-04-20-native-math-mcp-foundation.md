# Native Math MCP — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the native Math server's shared infrastructure — AST, parsers, printer, engine behaviour, router, sandbox, config, supervisor — plus one exemplar tool (`math::evaluate`) that proves the full request path from the MCP endpoint to a returned result. Everything else (arithmetic helpers, linear algebra, statistics, number theory) is scoped to follow-on plans that depend on this foundation.

**Architecture:** A new `Backplane.Math.*` subtree under `apps/backplane/lib/backplane/math/`. Tool registration reuses the existing `Backplane.Tools.ToolModule` behaviour and `Backplane.Registry.ToolRegistry.register_native/1`; tool names use the hub-wide `::` separator (PRD decision #14 about switching to `_` is a hub-wide refactor, out of scope for this plan). A `Math.Supervisor` owns a `Math.Config` GenServer, a `Math.Sandbox` Task.Supervisor, and tool registration hooks into `Backplane.Application.register_native_tools/0`. The engine layer uses a `Backplane.Math.Engine` behaviour with a `Native` engine (no SymPy in Phase 1). All user input is parsed to a canonical AST before reaching any engine — there is no string-eval path anywhere.

**Tech Stack:** Elixir 1.18+ / OTP 28+, `decimal` (arbitrary-precision decimals), `complex` (complex numbers), `nx` with `BinaryBackend` default (tensors for later linear-algebra plan), `nimble_parsec` (infix parser), `stream_data` (property tests, dev/test only). No Python, no EXLA, no NIFs.

**PRD section coverage:** MH-1 (contract — via existing ToolModule), MH-2 (engine layering), MH-3 (registry registration — via existing ToolRegistry), MH-4 (tool-to-handler mapping), MH-5 (dual-encoded result), MH-6 (canonical AST), MH-7 infix + JSON (LaTeX parser deferred to Phase 3), MH-8 (printer), MH-9.1 (`math::evaluate` only — remaining arithmetic tools in follow-on plan), MH-19 (AST-only path), MH-20 (complexity caps), MH-21 (timeouts), MH-23 (config table + agent; admin UI in follow-on plan).

**Out of scope — explicit non-goals:**
- Arithmetic tools beyond `evaluate` (to_decimal, to_rational, convert_units) — follow-on plan B
- Linear algebra — follow-on plan C
- Statistics, distributions, hypothesis tests — follow-on plan D
- Number theory — follow-on plan E
- Admin LiveView for config — follow-on plan F
- LaTeX input parser, SymPy sidecar, EXLA backend — Phase 2/3

---

## File Structure

```
apps/backplane/lib/backplane/math/
├── supervisor.ex                     # Backplane.Math.Supervisor
├── config.ex                         # Backplane.Math.Config (GenServer + ETS cache)
├── config/
│   └── record.ex                     # Ecto schema for mcp_native_math_config row
├── sandbox.ex                        # Backplane.Math.Sandbox (Task.Supervisor wrapper)
├── router.ex                         # Backplane.Math.Router (caps + timeout + dispatch)
├── tools.ex                          # Backplane.Math.Tools — implements ToolModule behaviour
├── engine.ex                         # Backplane.Math.Engine behaviour
├── engine/
│   └── native.ex                     # Backplane.Math.Engine.Native (dispatcher shell + :evaluate op)
├── expression/
│   ├── ast.ex                        # Canonical AST types + guards + helpers
│   ├── parser_json.ex                # JSON-shaped AST validator
│   ├── parser_infix.ex               # Infix expression parser (NimbleParsec)
│   └── printer.ex                    # to_text/1, to_json/1, to_latex/1

apps/backplane/priv/repo/migrations/
└── 20260420000001_create_mcp_native_math_config.exs

apps/backplane/test/backplane/math/
├── supervisor_test.exs
├── config_test.exs
├── sandbox_test.exs
├── router_test.exs
├── tools_test.exs
├── engine/
│   └── native_test.exs
└── expression/
    ├── ast_test.exs
    ├── parser_json_test.exs
    ├── parser_infix_test.exs
    └── printer_test.exs

apps/backplane/test/integration/
└── math_evaluate_round_trip_test.exs
```

**Files modified (not created):**
- `apps/backplane/mix.exs` — add `:decimal`, `:complex`, `:nx`, `:nimble_parsec`, `:stream_data`
- `apps/backplane/lib/backplane/application.ex` — start `Backplane.Math.Supervisor`; add `Backplane.Math.Tools` to `tool_modules` list

---

## Task 1: Add Dependencies

**Files:**
- Modify: `apps/backplane/mix.exs`

- [ ] **Step 1: Add new dependencies to `defp deps`**

Open `apps/backplane/mix.exs` and replace the `defp deps do [...] end` block so the returned list contains these additions alongside the existing entries:

```elixir
defp deps do
  [
    {:relayixir, in_umbrella: true},
    {:day_ex, in_umbrella: true},

    # Web — Phoenix core (for PubSub, JSON, Plug)
    {:phoenix, "~> 1.8"},
    {:phoenix_ecto, "~> 4.6"},
    {:bandit, "~> 1.5"},
    {:jason, "~> 1.4"},

    # HTTP client
    {:req, "~> 0.5"},

    # Database
    {:ecto_sql, "~> 3.12"},
    {:postgrex, "~> 0.19"},
    {:pgvector, "~> 0.3"},

    # Job processing
    {:oban, "~> 2.18"},

    # Auth
    {:bcrypt_elixir, "~> 3.0"},

    # Config
    {:toml, "~> 0.7"},
    {:yaml_elixir, "~> 2.9"},

    # File watching (local skill sources)
    {:file_system, "~> 1.0"},

    # Timezone data
    {:tzdata, "~> 1.1"},

    # Telemetry
    {:telemetry_metrics, "~> 1.0"},
    {:telemetry_poller, "~> 1.1"},

    # Math
    {:decimal, "~> 2.1"},
    {:complex, "~> 0.5"},
    {:nx, "~> 0.7"},
    {:nimble_parsec, "~> 1.4"},

    # Dev/Test
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:floki, ">= 0.30.0", only: :test},
    {:lazy_html, ">= 0.1.0", only: :test},
    {:ex_machina, "~> 2.8", only: :test},
    {:mox, "~> 1.1", only: :test},
    {:stream_data, "~> 1.1", only: [:dev, :test]}
  ]
end
```

- [ ] **Step 2: Fetch deps**

Run: `mix deps.get`

Expected output ends with `* Getting decimal ...`, `* Getting complex ...`, `* Getting nx ...`, `* Getting nimble_parsec ...`, `* Getting stream_data ...`, and no errors.

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`

Expected: compiles clean. If any warning is printed by the new deps (they should compile clean in these versions), investigate before continuing — do not silence.

- [ ] **Step 4: Commit**

```bash
git add apps/backplane/mix.exs mix.lock
git commit -m "feat(math): add decimal, complex, nx, nimble_parsec, stream_data deps"
```

---

## Task 2: Config Table Migration

**Files:**
- Create: `apps/backplane/priv/repo/migrations/20260420000001_create_mcp_native_math_config.exs`

- [ ] **Step 1: Write the migration**

Create `apps/backplane/priv/repo/migrations/20260420000001_create_mcp_native_math_config.exs`:

```elixir
defmodule Backplane.Repo.Migrations.CreateMcpNativeMathConfig do
  use Ecto.Migration

  def change do
    create table(:mcp_native_math_config, primary_key: false) do
      add :id, :integer, primary_key: true, default: 1, null: false

      add :enabled, :boolean, null: false, default: true
      add :sympy_enabled, :boolean, null: false, default: false
      add :sympy_pool_size, :integer, null: false, default: 2
      add :sympy_rpc_timeout_ms, :integer, null: false, default: 4_000
      add :exla_enabled, :boolean, null: false, default: false
      add :timeout_default_ms, :integer, null: false, default: 5_000
      add :timeout_per_tool, :map, null: false, default: %{}
      add :max_expr_nodes, :integer, null: false, default: 10_000
      add :max_expr_depth, :integer, null: false, default: 64
      add :max_integer_bits, :integer, null: false, default: 4_096
      add :max_matrix_dim, :integer, null: false, default: 512
      add :max_factor_bits, :integer, null: false, default: 128
      add :decimal_precision, :integer, null: false, default: 28
      add :units_system, :text, null: false, default: "si"

      timestamps(type: :utc_datetime_usec, inserted_at: false)
    end

    create constraint(:mcp_native_math_config, :singleton, check: "id = 1")
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`

Expected output includes `[info] == Running ... Backplane.Repo.Migrations.CreateMcpNativeMathConfig.change/0 forward` and `[info] create table mcp_native_math_config` and `[info] == Migrated ...`.

- [ ] **Step 3: Sanity-check at the DB level**

Run: `mix ecto.rollback && mix ecto.migrate`

Expected: rollback drops the table cleanly; re-migrate re-creates it.

- [ ] **Step 4: Commit**

```bash
git add apps/backplane/priv/repo/migrations/20260420000001_create_mcp_native_math_config.exs
git commit -m "feat(math): add mcp_native_math_config table"
```

---

## Task 3: Config Ecto Schema

**Files:**
- Create: `apps/backplane/lib/backplane/math/config/record.ex`
- Create: `apps/backplane/test/backplane/math/config/record_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/backplane/test/backplane/math/config/record_test.exs`:

```elixir
defmodule Backplane.Math.Config.RecordTest do
  use Backplane.DataCase, async: true

  alias Backplane.Math.Config.Record

  describe "changeset/2" do
    test "accepts valid attrs" do
      cs = Record.changeset(%Record{}, %{
        enabled: true,
        timeout_default_ms: 3_000,
        max_expr_nodes: 5_000,
        timeout_per_tool: %{"evaluate" => 1_000}
      })

      assert cs.valid?
    end

    test "rejects non-positive timeout_default_ms" do
      cs = Record.changeset(%Record{}, %{timeout_default_ms: 0})
      refute cs.valid?
      assert "must be greater than 0" in errors_on(cs).timeout_default_ms
    end

    test "rejects unknown units_system" do
      cs = Record.changeset(%Record{}, %{units_system: "cubits"})
      refute cs.valid?
      assert "is invalid" in errors_on(cs).units_system
    end
  end

  describe "defaults/0" do
    test "returns a Record struct populated with PRD defaults" do
      r = Record.defaults()
      assert r.enabled == true
      assert r.sympy_enabled == false
      assert r.timeout_default_ms == 5_000
      assert r.max_expr_nodes == 10_000
      assert r.max_matrix_dim == 512
      assert r.units_system == "si"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane/test/backplane/math/config/record_test.exs`

Expected: fails with `(CompileError)` or `(UndefinedFunctionError)` because `Backplane.Math.Config.Record` doesn't exist.

- [ ] **Step 3: Write the schema module**

Create `apps/backplane/lib/backplane/math/config/record.ex`:

```elixir
defmodule Backplane.Math.Config.Record do
  @moduledoc "Singleton row storing runtime config for the native Math server."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}

  schema "mcp_native_math_config" do
    field :enabled, :boolean, default: true
    field :sympy_enabled, :boolean, default: false
    field :sympy_pool_size, :integer, default: 2
    field :sympy_rpc_timeout_ms, :integer, default: 4_000
    field :exla_enabled, :boolean, default: false
    field :timeout_default_ms, :integer, default: 5_000
    field :timeout_per_tool, :map, default: %{}
    field :max_expr_nodes, :integer, default: 10_000
    field :max_expr_depth, :integer, default: 64
    field :max_integer_bits, :integer, default: 4_096
    field :max_matrix_dim, :integer, default: 512
    field :max_factor_bits, :integer, default: 128
    field :decimal_precision, :integer, default: 28
    field :units_system, :string, default: "si"

    timestamps(type: :utc_datetime_usec, inserted_at: false)
  end

  @all_fields ~w(
    enabled sympy_enabled sympy_pool_size sympy_rpc_timeout_ms exla_enabled
    timeout_default_ms timeout_per_tool max_expr_nodes max_expr_depth
    max_integer_bits max_matrix_dim max_factor_bits decimal_precision
    units_system
  )a

  @units_systems ~w(si imperial both)

  def changeset(record, attrs) do
    record
    |> cast(attrs, @all_fields)
    |> validate_number(:timeout_default_ms, greater_than: 0)
    |> validate_number(:sympy_pool_size, greater_than_or_equal_to: 0)
    |> validate_number(:sympy_rpc_timeout_ms, greater_than: 0)
    |> validate_number(:max_expr_nodes, greater_than: 0)
    |> validate_number(:max_expr_depth, greater_than: 0)
    |> validate_number(:max_integer_bits, greater_than: 0)
    |> validate_number(:max_matrix_dim, greater_than: 0)
    |> validate_number(:max_factor_bits, greater_than: 0)
    |> validate_number(:decimal_precision, greater_than: 0, less_than_or_equal_to: 200)
    |> validate_inclusion(:units_system, @units_systems)
  end

  @doc "Returns a Record struct populated with the defaults the migration sets."
  def defaults, do: %__MODULE__{id: 1}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/backplane/test/backplane/math/config/record_test.exs`

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane/lib/backplane/math/config/record.ex apps/backplane/test/backplane/math/config/record_test.exs
git commit -m "feat(math): add Config.Record Ecto schema with validations"
```

---

## Task 4: Config GenServer with ETS Cache

**Files:**
- Create: `apps/backplane/lib/backplane/math/config.ex`
- Create: `apps/backplane/test/backplane/math/config_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/backplane/test/backplane/math/config_test.exs`:

```elixir
defmodule Backplane.Math.ConfigTest do
  use Backplane.DataCase, async: false

  alias Backplane.Math.Config

  setup do
    # Config is started by the test harness once; force a reload for a known baseline.
    :ok = Config.reload()
    :ok
  end

  describe "get/0 and get/1" do
    test "returns defaults when the table is empty" do
      Backplane.Repo.delete_all(Backplane.Math.Config.Record)
      :ok = Config.reload()

      cfg = Config.get()
      assert cfg.enabled == true
      assert cfg.timeout_default_ms == 5_000
      assert cfg.max_expr_nodes == 10_000
      assert cfg.units_system == "si"
    end

    test "get/1 returns a single field" do
      assert Config.get(:timeout_default_ms) == 5_000
      assert Config.get(:units_system) == "si"
    end
  end

  describe "save/1" do
    test "persists changes and updates the cache" do
      assert {:ok, _} = Config.save(%{timeout_default_ms: 7_500, max_matrix_dim: 256})
      assert Config.get(:timeout_default_ms) == 7_500
      assert Config.get(:max_matrix_dim) == 256
    end

    test "rejects invalid attrs without touching the cache" do
      before = Config.get(:timeout_default_ms)
      assert {:error, %Ecto.Changeset{}} = Config.save(%{timeout_default_ms: 0})
      assert Config.get(:timeout_default_ms) == before
    end
  end

  describe "reload/0" do
    test "broadcasts a pubsub event" do
      Phoenix.PubSub.subscribe(Backplane.PubSub, "math:config")
      :ok = Config.reload()
      assert_receive {:math_config_changed, %Backplane.Math.Config.Record{}}, 100
    end
  end

  describe "tool_timeout/1" do
    test "returns per-tool override when set, otherwise default" do
      {:ok, _} = Config.save(%{
        timeout_default_ms: 5_000,
        timeout_per_tool: %{"integrate" => 30_000}
      })

      assert Config.tool_timeout("integrate") == 30_000
      assert Config.tool_timeout("evaluate") == 5_000
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane/test/backplane/math/config_test.exs`

Expected: fails with `UndefinedFunctionError` for `Backplane.Math.Config.reload/0`.

- [ ] **Step 3: Implement the config module**

Create `apps/backplane/lib/backplane/math/config.ex`:

```elixir
defmodule Backplane.Math.Config do
  @moduledoc """
  Runtime config for the native Math server.

  Backed by the singleton `mcp_native_math_config` row. GenServer owns writes
  and the ETS cache; readers hit ETS directly for lock-free access.
  """

  use GenServer
  require Logger

  alias Backplane.Math.Config.Record
  alias Backplane.Repo

  @table :backplane_math_config
  @topic "math:config"

  # ---- Public API ----

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Return the current config as a Record struct."
  @spec get() :: Record.t()
  def get do
    case :ets.lookup(@table, :config) do
      [{:config, record}] -> record
      [] -> Record.defaults()
    end
  end

  @doc "Return a single field from the cached config."
  @spec get(atom()) :: term()
  def get(field) when is_atom(field), do: Map.fetch!(get(), field)

  @doc "Return the per-tool timeout in ms (override → default)."
  @spec tool_timeout(String.t()) :: pos_integer()
  def tool_timeout(tool_name) when is_binary(tool_name) do
    cfg = get()

    case Map.get(cfg.timeout_per_tool, tool_name) do
      nil -> cfg.timeout_default_ms
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> cfg.timeout_default_ms
    end
  end

  @doc "Force a reload from the database. Broadcasts a pubsub event."
  @spec reload() :: :ok
  def reload, do: GenServer.call(__MODULE__, :reload)

  @doc "Validate + persist changes. Returns {:ok, record} or {:error, changeset}."
  @spec save(map()) :: {:ok, Record.t()} | {:error, Ecto.Changeset.t()}
  def save(attrs) when is_map(attrs), do: GenServer.call(__MODULE__, {:save, attrs})

  # ---- GenServer callbacks ----

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, nil, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    do_reload()
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    do_reload()
    {:reply, :ok, state}
  end

  def handle_call({:save, attrs}, _from, state) do
    record = Repo.get(Record, 1) || %Record{id: 1}
    changeset = Record.changeset(record, attrs)

    case Repo.insert_or_update(changeset) do
      {:ok, updated} ->
        :ets.insert(@table, {:config, updated})
        broadcast(updated)
        {:reply, {:ok, updated}, state}

      {:error, cs} ->
        {:reply, {:error, cs}, state}
    end
  end

  # ---- Private ----

  defp do_reload do
    record = Repo.get(Record, 1) || Record.defaults()
    :ets.insert(@table, {:config, record})
    broadcast(record)
  end

  defp broadcast(record),
    do: Phoenix.PubSub.broadcast(Backplane.PubSub, @topic, {:math_config_changed, record})
end
```

- [ ] **Step 4: Wire Config into the test harness supervisor**

The config needs to be started before tests run. For now add it to `apps/backplane/lib/backplane/application.ex` children. Modify the `children` list so `Backplane.Math.Config` starts after `ToolRegistry`:

Find the line `ToolRegistry,` in `apps/backplane/lib/backplane/application.ex` and add `Backplane.Math.Config` immediately after it:

```elixir
ToolRegistry,
Backplane.Math.Config,
SkillsRegistry,
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test apps/backplane/test/backplane/math/config_test.exs`

Expected: 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add apps/backplane/lib/backplane/math/config.ex \
        apps/backplane/test/backplane/math/config_test.exs \
        apps/backplane/lib/backplane/application.ex
git commit -m "feat(math): add Config GenServer with ETS cache and pubsub reload"
```

---

## Task 5: AST Types and Guards

**Files:**
- Create: `apps/backplane/lib/backplane/math/expression/ast.ex`
- Create: `apps/backplane/test/backplane/math/expression/ast_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/backplane/test/backplane/math/expression/ast_test.exs`:

```elixir
defmodule Backplane.Math.Expression.AstTest do
  use ExUnit.Case, async: true

  alias Backplane.Math.Expression.Ast

  describe "well_formed?/1" do
    test "integers, floats, Decimals, and Complex are valid :num" do
      assert Ast.well_formed?({:num, 1})
      assert Ast.well_formed?({:num, 1.5})
      assert Ast.well_formed?({:num, Decimal.new("3.14")})
      assert Ast.well_formed?({:num, Complex.new(1, 2)})
    end

    test "rejects :num with non-numeric payload" do
      refute Ast.well_formed?({:num, "1"})
      refute Ast.well_formed?({:num, :atom})
    end

    test "vars must be atoms" do
      assert Ast.well_formed?({:var, :x})
      refute Ast.well_formed?({:var, "x"})
    end

    test "recognised sym values" do
      assert Ast.well_formed?({:sym, :pi})
      assert Ast.well_formed?({:sym, :e})
      refute Ast.well_formed?({:sym, :tau_too_many_symbols})
    end

    test ":op and :app require all children well-formed" do
      good = {:op, :+, [{:num, 1}, {:num, 2}]}
      assert Ast.well_formed?(good)

      bad = {:op, :+, [{:num, 1}, "two"]}
      refute Ast.well_formed?(bad)
    end

    test ":app checks known function arities" do
      assert Ast.well_formed?({:app, :sin, [{:var, :x}]})
      refute Ast.well_formed?({:app, :sin, [{:var, :x}, {:var, :y}]})
    end

    test ":mat requires rectangular grid of well-formed exprs" do
      assert Ast.well_formed?({:mat, [[{:num, 1}, {:num, 2}], [{:num, 3}, {:num, 4}]]})
      refute Ast.well_formed?({:mat, [[{:num, 1}, {:num, 2}], [{:num, 3}]]})
    end
  end

  describe "size/1" do
    test "counts every node including leaves" do
      assert Ast.size({:num, 1}) == 1
      assert Ast.size({:op, :+, [{:num, 1}, {:num, 2}]}) == 3
      assert Ast.size({:op, :+, [{:op, :*, [{:num, 1}, {:num, 2}]}, {:num, 3}]}) == 5
    end
  end

  describe "depth/1" do
    test "leaf has depth 1" do
      assert Ast.depth({:num, 1}) == 1
      assert Ast.depth({:var, :x}) == 1
    end

    test "nested ops grow depth" do
      assert Ast.depth({:op, :+, [{:num, 1}, {:num, 2}]}) == 2
      assert Ast.depth({:op, :+, [{:op, :*, [{:num, 1}, {:num, 2}]}, {:num, 3}]}) == 3
    end
  end

  describe "max_integer_bits/1" do
    test "returns the bit-width of the largest integer in the tree" do
      assert Ast.max_integer_bits({:num, 7}) == 3
      assert Ast.max_integer_bits({:op, :+, [{:num, 1}, {:num, 1_000_000}]}) == 20
      assert Ast.max_integer_bits({:num, 1.5}) == 0
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane/test/backplane/math/expression/ast_test.exs`

Expected: fails with `UndefinedFunctionError` for `Backplane.Math.Expression.Ast.well_formed?/1`.

- [ ] **Step 3: Implement the module**

Create `apps/backplane/lib/backplane/math/expression/ast.ex`:

```elixir
defmodule Backplane.Math.Expression.Ast do
  @moduledoc """
  Canonical math AST.

      expr ::
          {:num, number() | Decimal.t() | Complex.t()}
          | {:var, atom()}
          | {:sym, atom()}              # :pi | :e | :inf | :nan | :i
          | {:app, atom(), [expr]}
          | {:op, atom(), [expr]}
          | {:mat, [[expr]]}
          | {:set, [expr]}
  """

  @type expr ::
          {:num, number() | Decimal.t() | struct()}
          | {:var, atom()}
          | {:sym, atom()}
          | {:app, atom(), [expr]}
          | {:op, atom(), [expr]}
          | {:mat, [[expr]]}
          | {:set, [expr]}

  @known_syms ~w(pi e inf nan i)a

  # (name, arity) — arity :any means variadic, checked ≥ 1
  @known_apps %{
    sin: 1, cos: 1, tan: 1,
    asin: 1, acos: 1, atan: 1, atan2: 2,
    sinh: 1, cosh: 1, tanh: 1,
    exp: 1, log: 1, log10: 1, log2: 1, logb: 2,
    sqrt: 1, cbrt: 1, abs: 1, sign: 1,
    floor: 1, ceil: 1, round: 2,
    factorial: 1, gamma: 1,
    min: :any, max: :any
  }

  @known_ops %{
    :+ => :any, :- => :any, :* => :any, :/ => 2,
    :^ => 2, :! => 1, :neg => 1, :mod => 2
  }

  @spec well_formed?(term()) :: boolean()
  def well_formed?({:num, n}) when is_integer(n) or is_float(n), do: true
  def well_formed?({:num, %Decimal{}}), do: true
  def well_formed?({:num, %Complex{}}), do: true
  def well_formed?({:num, _}), do: false

  def well_formed?({:var, a}) when is_atom(a), do: true
  def well_formed?({:var, _}), do: false

  def well_formed?({:sym, s}) when is_atom(s), do: s in @known_syms
  def well_formed?({:sym, _}), do: false

  def well_formed?({:app, name, args}) when is_atom(name) and is_list(args) do
    case Map.fetch(@known_apps, name) do
      {:ok, :any} -> args != [] and Enum.all?(args, &well_formed?/1)
      {:ok, n} when is_integer(n) -> length(args) == n and Enum.all?(args, &well_formed?/1)
      :error -> false
    end
  end

  def well_formed?({:op, name, args}) when is_atom(name) and is_list(args) do
    case Map.fetch(@known_ops, name) do
      {:ok, :any} -> args != [] and Enum.all?(args, &well_formed?/1)
      {:ok, n} when is_integer(n) -> length(args) == n and Enum.all?(args, &well_formed?/1)
      :error -> false
    end
  end

  def well_formed?({:mat, rows}) when is_list(rows) and rows != [] do
    case rows do
      [first | _] ->
        cols = length(first)
        cols > 0 and
          Enum.all?(rows, fn r -> is_list(r) and length(r) == cols and Enum.all?(r, &well_formed?/1) end)

      _ ->
        false
    end
  end

  def well_formed?({:set, members}) when is_list(members),
    do: Enum.all?(members, &well_formed?/1)

  def well_formed?(_), do: false

  @spec size(expr()) :: non_neg_integer()
  def size({:num, _}), do: 1
  def size({:var, _}), do: 1
  def size({:sym, _}), do: 1
  def size({:app, _, args}), do: 1 + Enum.reduce(args, 0, &(size(&1) + &2))
  def size({:op, _, args}), do: 1 + Enum.reduce(args, 0, &(size(&1) + &2))
  def size({:mat, rows}),
    do: 1 + Enum.reduce(rows, 0, fn row, acc -> acc + Enum.reduce(row, 0, &(size(&1) + &2)) end)
  def size({:set, members}), do: 1 + Enum.reduce(members, 0, &(size(&1) + &2))

  @spec depth(expr()) :: pos_integer()
  def depth({:num, _}), do: 1
  def depth({:var, _}), do: 1
  def depth({:sym, _}), do: 1
  def depth({:app, _, args}), do: 1 + max_depth(args)
  def depth({:op, _, args}), do: 1 + max_depth(args)
  def depth({:mat, rows}), do: 1 + max_depth(List.flatten(rows))
  def depth({:set, members}), do: 1 + max_depth(members)

  defp max_depth([]), do: 0
  defp max_depth(list), do: list |> Enum.map(&depth/1) |> Enum.max()

  @spec max_integer_bits(expr()) :: non_neg_integer()
  def max_integer_bits({:num, n}) when is_integer(n) and n != 0,
    do: :math.log2(abs(n)) |> Float.ceil() |> trunc()
  def max_integer_bits({:num, 0}), do: 1
  def max_integer_bits({:num, _}), do: 0
  def max_integer_bits({:var, _}), do: 0
  def max_integer_bits({:sym, _}), do: 0
  def max_integer_bits({:app, _, args}), do: max_leaf_bits(args)
  def max_integer_bits({:op, _, args}), do: max_leaf_bits(args)
  def max_integer_bits({:mat, rows}), do: max_leaf_bits(List.flatten(rows))
  def max_integer_bits({:set, members}), do: max_leaf_bits(members)

  defp max_leaf_bits([]), do: 0
  defp max_leaf_bits(list), do: list |> Enum.map(&max_integer_bits/1) |> Enum.max()
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/backplane/test/backplane/math/expression/ast_test.exs`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane/lib/backplane/math/expression/ast.ex \
        apps/backplane/test/backplane/math/expression/ast_test.exs
git commit -m "feat(math): add canonical AST with guards, size, depth, bit-width"
```

---

## Task 6: JSON AST Parser

**Files:**
- Create: `apps/backplane/lib/backplane/math/expression/parser_json.ex`
- Create: `apps/backplane/test/backplane/math/expression/parser_json_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/backplane/test/backplane/math/expression/parser_json_test.exs`:

```elixir
defmodule Backplane.Math.Expression.ParserJsonTest do
  use ExUnit.Case, async: true

  alias Backplane.Math.Expression.ParserJson

  describe "parse/1" do
    test "parses a numeric literal" do
      assert {:ok, {:num, 3}} = ParserJson.parse(%{"num" => 3})
      assert {:ok, {:num, 3.14}} = ParserJson.parse(%{"num" => 3.14})
    end

    test "parses a variable" do
      assert {:ok, {:var, :x}} = ParserJson.parse(%{"var" => "x"})
    end

    test "parses a symbolic constant" do
      assert {:ok, {:sym, :pi}} = ParserJson.parse(%{"sym" => "pi"})
    end

    test "parses an op with nested args" do
      json = %{"op" => "+", "args" => [%{"num" => 1}, %{"num" => 2}]}
      assert {:ok, {:op, :+, [{:num, 1}, {:num, 2}]}} = ParserJson.parse(json)
    end

    test "parses an app with nested args" do
      json = %{"app" => "sin", "args" => [%{"var" => "x"}]}
      assert {:ok, {:app, :sin, [{:var, :x}]}} = ParserJson.parse(json)
    end

    test "parses a matrix literal" do
      json = %{"mat" => [[%{"num" => 1}, %{"num" => 2}], [%{"num" => 3}, %{"num" => 4}]]}
      assert {:ok, {:mat, [[{:num, 1}, {:num, 2}], [{:num, 3}, {:num, 4}]]}} = ParserJson.parse(json)
    end

    test "rejects a tree that fails well_formed?" do
      json = %{"app" => "sin", "args" => [%{"num" => 1}, %{"num" => 2}]}
      assert {:error, {:parse, :invalid_ast, _}} = ParserJson.parse(json)
    end

    test "rejects unknown tags" do
      assert {:error, {:parse, :unknown_tag, "widget"}} =
               ParserJson.parse(%{"widget" => %{}})
    end

    test "rejects malformed input" do
      assert {:error, {:parse, :not_a_map, _}} = ParserJson.parse("not a map")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane/test/backplane/math/expression/parser_json_test.exs`

Expected: fails — module undefined.

- [ ] **Step 3: Implement the parser**

Create `apps/backplane/lib/backplane/math/expression/parser_json.ex`:

```elixir
defmodule Backplane.Math.Expression.ParserJson do
  @moduledoc """
  Validates and converts JSON-shaped AST input into the canonical AST.

  Accepted shapes (string keys):
      %{"num" => n}
      %{"var" => "name"}
      %{"sym" => "pi"}
      %{"op" => "+", "args" => [...]}
      %{"app" => "sin", "args" => [...]}
      %{"mat" => [[...]]}
      %{"set" => [...]}
  """

  alias Backplane.Math.Expression.Ast

  @spec parse(term()) :: {:ok, Ast.expr()} | {:error, term()}
  def parse(json) do
    case to_ast(json) do
      {:error, _} = err ->
        err

      {:ok, ast} ->
        if Ast.well_formed?(ast) do
          {:ok, ast}
        else
          {:error, {:parse, :invalid_ast, ast}}
        end
    end
  end

  defp to_ast(n) when is_integer(n) or is_float(n), do: {:ok, {:num, n}}

  defp to_ast(map) when is_map(map) do
    cond do
      Map.has_key?(map, "num") -> wrap_num(map["num"])
      Map.has_key?(map, "var") -> wrap_var(map["var"])
      Map.has_key?(map, "sym") -> wrap_sym(map["sym"])
      Map.has_key?(map, "op") -> wrap_children(:op, map["op"], map["args"])
      Map.has_key?(map, "app") -> wrap_children(:app, map["app"], map["args"])
      Map.has_key?(map, "mat") -> wrap_mat(map["mat"])
      Map.has_key?(map, "set") -> wrap_set(map["set"])
      true -> {:error, {:parse, :unknown_tag, Map.keys(map) |> List.first()}}
    end
  end

  defp to_ast(other), do: {:error, {:parse, :not_a_map, other}}

  defp wrap_num(n) when is_integer(n) or is_float(n), do: {:ok, {:num, n}}
  defp wrap_num(other), do: {:error, {:parse, :bad_num, other}}

  defp wrap_var(name) when is_binary(name), do: {:ok, {:var, String.to_atom(name)}}
  defp wrap_var(other), do: {:error, {:parse, :bad_var, other}}

  defp wrap_sym(name) when is_binary(name), do: {:ok, {:sym, String.to_atom(name)}}
  defp wrap_sym(other), do: {:error, {:parse, :bad_sym, other}}

  defp wrap_children(tag, name, args) when is_binary(name) and is_list(args) do
    args
    |> Enum.reduce_while({:ok, []}, fn child, {:ok, acc} ->
      case to_ast(child) do
        {:ok, a} -> {:cont, {:ok, [a | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, {tag, String.to_atom(name), Enum.reverse(built)}}
      err -> err
    end
  end

  defp wrap_children(_tag, _name, _), do: {:error, {:parse, :bad_children, nil}}

  defp wrap_mat(rows) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case wrap_row(row) do
        {:ok, r} -> {:cont, {:ok, [r | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, {:mat, Enum.reverse(built)}}
      err -> err
    end
  end

  defp wrap_mat(_), do: {:error, {:parse, :bad_mat, nil}}

  defp wrap_row(row) when is_list(row) do
    row
    |> Enum.reduce_while({:ok, []}, fn cell, {:ok, acc} ->
      case to_ast(cell) do
        {:ok, c} -> {:cont, {:ok, [c | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      err -> err
    end
  end

  defp wrap_row(_), do: {:error, {:parse, :bad_mat_row, nil}}

  defp wrap_set(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn m, {:ok, acc} ->
      case to_ast(m) do
        {:ok, a} -> {:cont, {:ok, [a | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, {:set, Enum.reverse(built)}}
      err -> err
    end
  end

  defp wrap_set(_), do: {:error, {:parse, :bad_set, nil}}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/backplane/test/backplane/math/expression/parser_json_test.exs`

Expected: 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane/lib/backplane/math/expression/parser_json.ex \
        apps/backplane/test/backplane/math/expression/parser_json_test.exs
git commit -m "feat(math): add JSON AST parser with well-formedness gate"
```

---

## Task 7: Infix Expression Parser

**Files:**
- Create: `apps/backplane/lib/backplane/math/expression/parser_infix.ex`
- Create: `apps/backplane/test/backplane/math/expression/parser_infix_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/backplane/test/backplane/math/expression/parser_infix_test.exs`:

```elixir
defmodule Backplane.Math.Expression.ParserInfixTest do
  use ExUnit.Case, async: true

  alias Backplane.Math.Expression.ParserInfix

  describe "parse/1 — literals" do
    test "integer" do
      assert {:ok, {:num, 42}} = ParserInfix.parse("42")
    end

    test "float" do
      assert {:ok, {:num, 3.14}} = ParserInfix.parse("3.14")
    end

    test "variable" do
      assert {:ok, {:var, :x}} = ParserInfix.parse("x")
    end

    test "pi and e as constants" do
      assert {:ok, {:sym, :pi}} = ParserInfix.parse("pi")
      assert {:ok, {:sym, :e}} = ParserInfix.parse("e")
    end
  end

  describe "parse/1 — arithmetic" do
    test "left-associative plus" do
      assert {:ok, {:op, :+, [{:num, 1}, {:num, 2}]}} = ParserInfix.parse("1 + 2")
    end

    test "precedence: * binds tighter than +" do
      assert {:ok,
              {:op, :+,
               [{:num, 1}, {:op, :*, [{:num, 2}, {:num, 3}]}]}} =
               ParserInfix.parse("1 + 2 * 3")
    end

    test "parentheses override precedence" do
      assert {:ok,
              {:op, :*,
               [{:op, :+, [{:num, 1}, {:num, 2}]}, {:num, 3}]}} =
               ParserInfix.parse("(1 + 2) * 3")
    end

    test "right-associative exponent" do
      assert {:ok,
              {:op, :^,
               [{:num, 2}, {:op, :^, [{:num, 3}, {:num, 4}]}]}} =
               ParserInfix.parse("2 ^ 3 ^ 4")
    end

    test "unary minus" do
      assert {:ok, {:op, :neg, [{:var, :x}]}} = ParserInfix.parse("-x")
      assert {:ok, {:op, :+, [{:num, 1}, {:op, :neg, [{:num, 2}]}]}} = ParserInfix.parse("1 + -2")
    end

    test "function application" do
      assert {:ok, {:app, :sin, [{:var, :x}]}} = ParserInfix.parse("sin(x)")
    end

    test "function with multiple args" do
      assert {:ok, {:app, :atan2, [{:var, :y}, {:var, :x}]}} = ParserInfix.parse("atan2(y, x)")
    end
  end

  describe "parse/1 — errors" do
    test "unterminated paren" do
      assert {:error, {:parse, _, _}} = ParserInfix.parse("1 + (2")
    end

    test "empty input" do
      assert {:error, {:parse, _, _}} = ParserInfix.parse("")
    end

    test "trailing operator" do
      assert {:error, {:parse, _, _}} = ParserInfix.parse("1 +")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane/test/backplane/math/expression/parser_infix_test.exs`

Expected: fails — module undefined.

- [ ] **Step 3: Implement the parser**

Create `apps/backplane/lib/backplane/math/expression/parser_infix.ex`:

```elixir
defmodule Backplane.Math.Expression.ParserInfix do
  @moduledoc """
  Infix expression parser.

  Grammar (precedence low → high, all left-assoc except `^`):
      expr   := add
      add    := mul (("+"|"-") mul)*
      mul    := pow (("*"|"/") pow)*
      pow    := unary ("^" pow)?              # right-assoc
      unary  := "-" unary | call
      call   := atom ( "(" arglist? ")" )?
      atom   := number | ident | "(" expr ")"
  """

  import NimbleParsec
  alias Backplane.Math.Expression.Ast

  whitespace = ignore(ascii_string([?\s, ?\t, ?\n, ?\r], min: 1))
  optional_ws = repeat(ignore(ascii_string([?\s, ?\t, ?\n, ?\r], min: 1)))

  number =
    optional(string("-"))
    |> ascii_string([?0..?9], min: 1)
    |> optional(string(".") |> ascii_string([?0..?9], min: 1))
    |> reduce({Enum, :join, [""]})
    |> map({__MODULE__, :to_number, []})

  identifier =
    ascii_string([?a..?z, ?A..?Z, ?_], 1)
    |> optional(ascii_string([?a..?z, ?A..?Z, ?0..?9, ?_], min: 1))
    |> reduce({Enum, :join, [""]})

  # Token tags
  lparen = ignore(string("("))
  rparen = ignore(string(")"))
  comma = ignore(string(","))

  defcombinatorp(:expr, parsec(:add_expr))

  defcombinatorp(
    :add_expr,
    parsec(:mul_expr)
    |> repeat(
      optional_ws
      |> choice([string("+"), string("-")])
      |> concat(optional_ws)
      |> parsec(:mul_expr)
    )
    |> reduce({__MODULE__, :reduce_left, [:add]})
  )

  defcombinatorp(
    :mul_expr,
    parsec(:pow_expr)
    |> repeat(
      optional_ws
      |> choice([string("*"), string("/")])
      |> concat(optional_ws)
      |> parsec(:pow_expr)
    )
    |> reduce({__MODULE__, :reduce_left, [:mul]})
  )

  defcombinatorp(
    :pow_expr,
    parsec(:unary_expr)
    |> optional(
      optional_ws
      |> ignore(string("^"))
      |> concat(optional_ws)
      |> parsec(:pow_expr)
    )
    |> reduce({__MODULE__, :reduce_pow, []})
  )

  defcombinatorp(
    :unary_expr,
    choice([
      ignore(string("-"))
      |> concat(optional_ws)
      |> parsec(:unary_expr)
      |> reduce({__MODULE__, :wrap_neg, []}),
      parsec(:call_expr)
    ])
  )

  defcombinatorp(
    :call_expr,
    parsec(:atom)
    |> optional(
      lparen
      |> concat(optional_ws)
      |> optional(
        parsec(:expr)
        |> repeat(
          optional_ws
          |> concat(comma)
          |> concat(optional_ws)
          |> parsec(:expr)
        )
      )
      |> concat(optional_ws)
      |> concat(rparen)
      |> tag(:call_args)
    )
    |> reduce({__MODULE__, :fold_call, []})
  )

  defcombinatorp(
    :atom,
    choice([
      lparen
      |> concat(optional_ws)
      |> parsec(:expr)
      |> concat(optional_ws)
      |> concat(rparen),
      number,
      identifier |> map({__MODULE__, :ident_to_ast, []})
    ])
  )

  defparsec(:do_parse, optional_ws |> parsec(:expr) |> concat(optional_ws) |> eos())

  @spec parse(String.t()) :: {:ok, Ast.expr()} | {:error, {:parse, term(), term()}}
  def parse(input) when is_binary(input) do
    case do_parse(input) do
      {:ok, [ast], "", _, _, _} -> {:ok, ast}
      {:ok, _, rest, _, _, _} -> {:error, {:parse, :trailing_input, rest}}
      {:error, reason, rest, _, line, col} -> {:error, {:parse, {line, col, reason}, rest}}
    end
  end

  # ---- reducers called by NimbleParsec ----

  @doc false
  def to_number(str) do
    cond do
      String.contains?(str, ".") -> {:num, String.to_float(str)}
      str == "-" -> raise ArgumentError, "dangling minus"
      true -> {:num, String.to_integer(str)}
    end
  end

  @doc false
  def ident_to_ast("pi"), do: {:sym, :pi}
  def ident_to_ast("e"), do: {:sym, :e}
  def ident_to_ast("inf"), do: {:sym, :inf}
  def ident_to_ast("nan"), do: {:sym, :nan}
  def ident_to_ast(name), do: {:ident, name}

  @doc false
  def reduce_left([single], _), do: single

  def reduce_left([left | rest], _), do: reduce_left_pairs(left, rest)

  defp reduce_left_pairs(acc, []), do: acc

  defp reduce_left_pairs(acc, [op, right | rest]) do
    reduce_left_pairs({:op, to_op_atom(op), [acc, right]}, rest)
  end

  defp to_op_atom("+"), do: :+
  defp to_op_atom("-"), do: :-
  defp to_op_atom("*"), do: :*
  defp to_op_atom("/"), do: :/

  @doc false
  def reduce_pow([single]), do: single
  def reduce_pow([base, exp]), do: {:op, :^, [base, exp]}

  @doc false
  def wrap_neg([inner]), do: {:op, :neg, [inner]}

  @doc false
  def fold_call([atom]), do: materialize(atom)

  def fold_call([atom, {:call_args, args}]) do
    case materialize(atom) do
      {:ident, name} -> {:app, String.to_atom(name), Enum.map(args, &materialize/1)}
      {:sym, _} = s -> s
      other -> {:error, {:non_callable, other, args}}
    end
  end

  defp materialize({:ident, name}), do: {:var, String.to_atom(name)}
  defp materialize(other), do: other
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/backplane/test/backplane/math/expression/parser_infix_test.exs`

Expected: 12 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane/lib/backplane/math/expression/parser_infix.ex \
        apps/backplane/test/backplane/math/expression/parser_infix_test.exs
git commit -m "feat(math): add infix expression parser (NimbleParsec)"
```

---

## Task 8: Printer (LaTeX, Text, JSON)

**Files:**
- Create: `apps/backplane/lib/backplane/math/expression/printer.ex`
- Create: `apps/backplane/test/backplane/math/expression/printer_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/backplane/test/backplane/math/expression/printer_test.exs`:

```elixir
defmodule Backplane.Math.Expression.PrinterTest do
  use ExUnit.Case, async: true

  alias Backplane.Math.Expression.Printer

  describe "to_text/1" do
    test "numeric literal" do
      assert Printer.to_text({:num, 42}) == "42"
      assert Printer.to_text({:num, 3.14}) == "3.14"
    end

    test "variable and symbolic constants" do
      assert Printer.to_text({:var, :x}) == "x"
      assert Printer.to_text({:sym, :pi}) == "π"
      assert Printer.to_text({:sym, :e}) == "e"
    end

    test "arithmetic operators render left-to-right" do
      assert Printer.to_text({:op, :+, [{:num, 1}, {:num, 2}]}) == "1 + 2"
      assert Printer.to_text({:op, :*, [{:num, 2}, {:var, :x}]}) == "2 * x"
    end

    test "unary negation" do
      assert Printer.to_text({:op, :neg, [{:var, :x}]}) == "-x"
    end

    test "function application" do
      assert Printer.to_text({:app, :sin, [{:var, :x}]}) == "sin(x)"
    end
  end

  describe "to_latex/1" do
    test "numeric literal" do
      assert Printer.to_latex({:num, 42}) == "42"
    end

    test "fractions for division" do
      assert Printer.to_latex({:op, :/, [{:num, 1}, {:num, 2}]}) == "\\frac{1}{2}"
    end

    test "exponent" do
      assert Printer.to_latex({:op, :^, [{:var, :x}, {:num, 2}]}) == "x^{2}"
    end

    test "pi as \\pi" do
      assert Printer.to_latex({:sym, :pi}) == "\\pi"
    end

    test "trig functions" do
      assert Printer.to_latex({:app, :sin, [{:var, :x}]}) == "\\sin\\left(x\\right)"
    end
  end

  describe "to_json/1" do
    test "round-trips via ParserJson" do
      ast = {:op, :+, [{:num, 1}, {:app, :sin, [{:var, :x}]}]}
      json = Printer.to_json(ast)
      assert {:ok, ^ast} = Backplane.Math.Expression.ParserJson.parse(json)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane/test/backplane/math/expression/printer_test.exs`

Expected: fails — module undefined.

- [ ] **Step 3: Implement the printer**

Create `apps/backplane/lib/backplane/math/expression/printer.ex`:

```elixir
defmodule Backplane.Math.Expression.Printer do
  @moduledoc "Pure-Elixir printer: AST → plain text, AST → LaTeX, AST → canonical JSON."

  alias Backplane.Math.Expression.Ast

  # ---- Plain text ----

  @spec to_text(Ast.expr()) :: String.t()
  def to_text({:num, %Decimal{} = d}), do: Decimal.to_string(d)
  def to_text({:num, %Complex{} = c}), do: Complex.to_string(c)
  def to_text({:num, n}), do: to_string(n)
  def to_text({:var, a}), do: Atom.to_string(a)
  def to_text({:sym, :pi}), do: "π"
  def to_text({:sym, :e}), do: "e"
  def to_text({:sym, :inf}), do: "∞"
  def to_text({:sym, :nan}), do: "NaN"
  def to_text({:sym, :i}), do: "i"
  def to_text({:op, :neg, [a]}), do: "-" <> text_with_parens(a)
  def to_text({:op, op, args}), do: args |> Enum.map_join(" #{op} ", &text_with_parens/1)
  def to_text({:app, name, args}), do: "#{name}(#{Enum.map_join(args, ", ", &to_text/1)})"
  def to_text({:mat, rows}) do
    body = rows |> Enum.map_join("; ", fn r -> Enum.map_join(r, ", ", &to_text/1) end)
    "[#{body}]"
  end

  defp text_with_parens({:op, _, _} = e), do: "(" <> to_text(e) <> ")"
  defp text_with_parens(other), do: to_text(other)

  # ---- LaTeX ----

  @spec to_latex(Ast.expr()) :: String.t()
  def to_latex({:num, %Decimal{} = d}), do: Decimal.to_string(d)
  def to_latex({:num, %Complex{} = c}), do: Complex.to_string(c)
  def to_latex({:num, n}), do: to_string(n)
  def to_latex({:var, a}), do: Atom.to_string(a)
  def to_latex({:sym, :pi}), do: "\\pi"
  def to_latex({:sym, :e}), do: "e"
  def to_latex({:sym, :inf}), do: "\\infty"
  def to_latex({:sym, :nan}), do: "\\text{NaN}"
  def to_latex({:sym, :i}), do: "i"
  def to_latex({:op, :neg, [a]}), do: "-" <> latex_with_parens(a)
  def to_latex({:op, :/, [num, den]}), do: "\\frac{#{to_latex(num)}}{#{to_latex(den)}}"
  def to_latex({:op, :^, [base, exp]}), do: "#{latex_with_parens(base)}^{#{to_latex(exp)}}"

  def to_latex({:op, op, args}) do
    sep = latex_op(op)
    Enum.map_join(args, " #{sep} ", &latex_with_parens/1)
  end

  def to_latex({:app, name, args}) do
    "\\#{latex_fn_name(name)}\\left(#{Enum.map_join(args, ", ", &to_latex/1)}\\right)"
  end

  def to_latex({:mat, rows}) do
    body = rows |> Enum.map_join(" \\\\ ", fn r -> Enum.map_join(r, " & ", &to_latex/1) end)
    "\\begin{bmatrix}#{body}\\end{bmatrix}"
  end

  defp latex_with_parens({:op, op, _} = e) when op in [:+, :-, :*, :/], do: "\\left(#{to_latex(e)}\\right)"
  defp latex_with_parens(other), do: to_latex(other)

  defp latex_op(:+), do: "+"
  defp latex_op(:-), do: "-"
  defp latex_op(:*), do: "\\cdot"
  defp latex_op(op), do: to_string(op)

  defp latex_fn_name(:sin), do: "sin"
  defp latex_fn_name(:cos), do: "cos"
  defp latex_fn_name(:tan), do: "tan"
  defp latex_fn_name(:exp), do: "exp"
  defp latex_fn_name(:log), do: "ln"
  defp latex_fn_name(:sqrt), do: "sqrt"
  defp latex_fn_name(name), do: "operatorname{#{name}}"

  # ---- JSON ----

  @spec to_json(Ast.expr()) :: map()
  def to_json({:num, n}) when is_integer(n) or is_float(n), do: %{"num" => n}
  def to_json({:num, %Decimal{} = d}), do: %{"num" => Decimal.to_string(d)}
  def to_json({:num, %Complex{} = c}), do: %{"num" => Complex.to_string(c)}
  def to_json({:var, a}), do: %{"var" => Atom.to_string(a)}
  def to_json({:sym, a}), do: %{"sym" => Atom.to_string(a)}
  def to_json({:op, name, args}),
    do: %{"op" => Atom.to_string(name), "args" => Enum.map(args, &to_json/1)}
  def to_json({:app, name, args}),
    do: %{"app" => Atom.to_string(name), "args" => Enum.map(args, &to_json/1)}
  def to_json({:mat, rows}),
    do: %{"mat" => Enum.map(rows, fn r -> Enum.map(r, &to_json/1) end)}
  def to_json({:set, members}), do: %{"set" => Enum.map(members, &to_json/1)}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/backplane/test/backplane/math/expression/printer_test.exs`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane/lib/backplane/math/expression/printer.ex \
        apps/backplane/test/backplane/math/expression/printer_test.exs
git commit -m "feat(math): add AST printer (text, LaTeX, JSON)"
```

---

## Task 9: Engine Behaviour and Native Shell

**Files:**
- Create: `apps/backplane/lib/backplane/math/engine.ex`
- Create: `apps/backplane/lib/backplane/math/engine/native.ex`
- Create: `apps/backplane/test/backplane/math/engine/native_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/backplane/test/backplane/math/engine/native_test.exs`:

```elixir
defmodule Backplane.Math.Engine.NativeTest do
  use ExUnit.Case, async: true

  alias Backplane.Math.Engine.Native

  describe "describe/0 and supports?/1" do
    test "reports id and version" do
      assert %{id: :native, version: _} = Native.describe()
    end

    test "supports :evaluate" do
      assert Native.supports?(:evaluate)
    end

    test "does not support :integrate" do
      refute Native.supports?(:integrate)
    end
  end

  describe "run/2 — :evaluate" do
    test "evaluates a literal" do
      assert {:ok, 42} = Native.run(:evaluate, %{ast: {:num, 42}})
    end

    test "evaluates addition" do
      assert {:ok, 3} = Native.run(:evaluate, %{ast: {:op, :+, [{:num, 1}, {:num, 2}]}})
    end

    test "evaluates nested expressions" do
      ast = {:op, :+, [{:num, 1}, {:op, :*, [{:num, 2}, {:num, 3}]}]}
      assert {:ok, 7} = Native.run(:evaluate, %{ast: ast})
    end

    test "evaluates unary negation" do
      assert {:ok, -5} = Native.run(:evaluate, %{ast: {:op, :neg, [{:num, 5}]}})
    end

    test "evaluates sin(0)" do
      assert {:ok, val} = Native.run(:evaluate, %{ast: {:app, :sin, [{:num, 0}]}})
      assert_in_delta val, 0.0, 1.0e-12
    end

    test "substitutes variables" do
      ast = {:op, :+, [{:var, :x}, {:num, 1}]}
      assert {:ok, 3} = Native.run(:evaluate, %{ast: ast, vars: %{x: 2}})
    end

    test "raises on unbound variable" do
      ast = {:var, :y}
      assert {:error, {:unbound_var, :y}} = Native.run(:evaluate, %{ast: ast})
    end

    test "handles pi and e" do
      assert {:ok, val_pi} = Native.run(:evaluate, %{ast: {:sym, :pi}})
      assert_in_delta val_pi, :math.pi(), 1.0e-12
      assert {:ok, val_e} = Native.run(:evaluate, %{ast: {:sym, :e}})
      assert_in_delta val_e, :math.exp(1), 1.0e-12
    end
  end

  describe "run/2 — unsupported op" do
    test "returns :unsupported error" do
      assert {:error, {:unsupported_op, :integrate}} = Native.run(:integrate, %{})
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane/test/backplane/math/engine/native_test.exs`

Expected: module undefined.

- [ ] **Step 3: Implement engine behaviour and native shell with `:evaluate`**

Create `apps/backplane/lib/backplane/math/engine.ex`:

```elixir
defmodule Backplane.Math.Engine do
  @moduledoc "Behaviour for math engines (Native, Sympy, etc)."

  @type op :: atom()
  @type params :: map()
  @type value :: term()

  @callback describe() :: %{id: atom(), version: String.t()}
  @callback supports?(op()) :: boolean()
  @callback run(op(), params()) :: {:ok, value()} | {:error, term()}
end
```

Create `apps/backplane/lib/backplane/math/engine/native.ex`:

```elixir
defmodule Backplane.Math.Engine.Native do
  @moduledoc """
  Native Elixir math engine (no Python, no external processes).

  Phase 1 ops: :evaluate. Additional ops (to_decimal, to_rational, matrix_op,
  summary, factor_integer, etc.) are added by follow-on plans.
  """

  @behaviour Backplane.Math.Engine

  @supported MapSet.new([:evaluate])

  @impl true
  def describe, do: %{id: :native, version: "0.1.0"}

  @impl true
  def supports?(op) when is_atom(op), do: MapSet.member?(@supported, op)

  @impl true
  def run(:evaluate, %{ast: ast} = params) do
    vars = Map.get(params, :vars, %{})

    try do
      {:ok, eval(ast, vars)}
    catch
      {:unbound_var, _} = err -> {:error, err}
      {:eval_error, reason} -> {:error, {:eval_error, reason}}
    end
  end

  def run(op, _params), do: {:error, {:unsupported_op, op}}

  # ---- numeric evaluator ----

  defp eval({:num, n}, _vars) when is_integer(n) or is_float(n), do: n
  defp eval({:num, %Decimal{} = d}, _vars), do: Decimal.to_float(d)
  defp eval({:num, %Complex{} = c}, _vars), do: c

  defp eval({:var, a}, vars) do
    case Map.fetch(vars, a) do
      {:ok, v} -> v
      :error -> throw({:unbound_var, a})
    end
  end

  defp eval({:sym, :pi}, _), do: :math.pi()
  defp eval({:sym, :e}, _), do: :math.exp(1.0)
  defp eval({:sym, :inf}, _), do: :infinity
  defp eval({:sym, :nan}, _), do: :nan
  defp eval({:sym, :i}, _), do: Complex.new(0, 1)

  defp eval({:op, :neg, [a]}, vars), do: -eval(a, vars)

  defp eval({:op, :+, args}, vars), do: Enum.reduce(args, 0, &(eval(&1, vars) + &2))
  defp eval({:op, :-, [a, b]}, vars), do: eval(a, vars) - eval(b, vars)
  defp eval({:op, :-, [a]}, vars), do: -eval(a, vars)
  defp eval({:op, :*, args}, vars), do: Enum.reduce(args, 1, &(eval(&1, vars) * &2))
  defp eval({:op, :/, [a, b]}, vars), do: eval(a, vars) / eval(b, vars)
  defp eval({:op, :^, [a, b]}, vars), do: :math.pow(eval(a, vars), eval(b, vars))
  defp eval({:op, :mod, [a, b]}, vars), do: rem(eval(a, vars), eval(b, vars))

  defp eval({:app, :sin, [a]}, vars), do: :math.sin(eval(a, vars))
  defp eval({:app, :cos, [a]}, vars), do: :math.cos(eval(a, vars))
  defp eval({:app, :tan, [a]}, vars), do: :math.tan(eval(a, vars))
  defp eval({:app, :exp, [a]}, vars), do: :math.exp(eval(a, vars))
  defp eval({:app, :log, [a]}, vars), do: :math.log(eval(a, vars))
  defp eval({:app, :log10, [a]}, vars), do: :math.log10(eval(a, vars))
  defp eval({:app, :log2, [a]}, vars), do: :math.log2(eval(a, vars))
  defp eval({:app, :sqrt, [a]}, vars), do: :math.sqrt(eval(a, vars))
  defp eval({:app, :abs, [a]}, vars), do: abs(eval(a, vars))
  defp eval({:app, :floor, [a]}, vars), do: Float.floor(eval(a, vars) * 1.0) |> trunc()
  defp eval({:app, :ceil, [a]}, vars), do: Float.ceil(eval(a, vars) * 1.0) |> trunc()
  defp eval({:app, :min, args}, vars), do: args |> Enum.map(&eval(&1, vars)) |> Enum.min()
  defp eval({:app, :max, args}, vars), do: args |> Enum.map(&eval(&1, vars)) |> Enum.max()

  defp eval(other, _vars), do: throw({:eval_error, {:unhandled, other}})
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/backplane/test/backplane/math/engine/native_test.exs`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane/lib/backplane/math/engine.ex \
        apps/backplane/lib/backplane/math/engine/native.ex \
        apps/backplane/test/backplane/math/engine/native_test.exs
git commit -m "feat(math): add Engine behaviour + Native shell with :evaluate"
```

---

## Task 10: Sandbox (Task Supervisor with Timeouts)

**Files:**
- Create: `apps/backplane/lib/backplane/math/sandbox.ex`
- Create: `apps/backplane/test/backplane/math/sandbox_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/backplane/test/backplane/math/sandbox_test.exs`:

```elixir
defmodule Backplane.Math.SandboxTest do
  use ExUnit.Case, async: false

  alias Backplane.Math.Sandbox

  describe "run/2" do
    test "returns the function's result on success" do
      assert {:ok, 42} = Sandbox.run(fn -> 42 end, 1_000)
    end

    test "returns {:error, :timeout} when function exceeds deadline" do
      assert {:error, :timeout} = Sandbox.run(fn -> Process.sleep(200); :done end, 50)
    end

    test "isolates crashes — caller survives and gets an error" do
      assert {:error, {:exit, _}} = Sandbox.run(fn -> raise "boom" end, 1_000)
      assert Process.alive?(self())
    end

    test "brutal-kills the task on timeout (no zombie processes)" do
      parent = self()

      Sandbox.run(
        fn ->
          send(parent, {:child, self()})
          Process.sleep(10_000)
        end,
        50
      )

      assert_receive {:child, pid}, 100
      refute Process.alive?(pid)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane/test/backplane/math/sandbox_test.exs`

Expected: fails — module undefined.

- [ ] **Step 3: Implement the sandbox**

Create `apps/backplane/lib/backplane/math/sandbox.ex`:

```elixir
defmodule Backplane.Math.Sandbox do
  @moduledoc """
  Bounded-execution wrapper for Math operations.

  Spawns tasks under a `Task.Supervisor` named `Backplane.Math.Sandbox`.
  Enforces a hard deadline using `Task.yield/2` + `Task.shutdown/2, :brutal_kill`.
  """

  @name __MODULE__

  @doc "Child spec for the Math supervision tree."
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task.Supervisor, :start_link, [[name: @name]]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Runs `fun` under the sandbox with a `timeout_ms` deadline.

  * `{:ok, result}` — function returned normally.
  * `{:error, :timeout}` — deadline exceeded; the task was brutal-killed.
  * `{:error, {:exit, reason}}` — function raised or the task exited abnormally.
  """
  @spec run((-> term()), pos_integer()) ::
          {:ok, term()} | {:error, :timeout | {:exit, term()}}
  def run(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    task = Task.Supervisor.async_nolink(@name, fun)

    case Task.yield(task, timeout_ms) do
      {:ok, value} -> {:ok, value}
      {:exit, reason} -> {:error, {:exit, reason}}
      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end
end
```

- [ ] **Step 4: Wire the Sandbox into the supervision tree (stub)**

Math.Supervisor does not exist yet — Task 14 wires it in. For this task, add the sandbox directly to `apps/backplane/lib/backplane/application.ex` children list right after `Backplane.Math.Config`:

```elixir
ToolRegistry,
Backplane.Math.Config,
Backplane.Math.Sandbox,
SkillsRegistry,
```

(Task 14 will move this under a dedicated `Backplane.Math.Supervisor`.)

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test apps/backplane/test/backplane/math/sandbox_test.exs`

Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```bash
git add apps/backplane/lib/backplane/math/sandbox.ex \
        apps/backplane/test/backplane/math/sandbox_test.exs \
        apps/backplane/lib/backplane/application.ex
git commit -m "feat(math): add Sandbox task supervisor with brutal-kill timeout"
```

---

## Task 11: Router (Caps + Timeout + Engine Dispatch)

**Files:**
- Create: `apps/backplane/lib/backplane/math/router.ex`
- Create: `apps/backplane/test/backplane/math/router_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/backplane/test/backplane/math/router_test.exs`:

```elixir
defmodule Backplane.Math.RouterTest do
  use Backplane.DataCase, async: false

  alias Backplane.Math.Config
  alias Backplane.Math.Router

  setup do
    :ok = Config.reload()
    :ok
  end

  describe "call/3" do
    test "dispatches :evaluate with AST input to the native engine" do
      assert {:ok, 3} = Router.call("evaluate", :evaluate, %{ast: {:op, :+, [{:num, 1}, {:num, 2}]}})
    end

    test "returns :unknown_tool when no engine supports the op" do
      assert {:error, {:engine_unavailable, :integrate}} =
               Router.call("integrate", :integrate, %{})
    end

    test "enforces max_expr_nodes cap" do
      {:ok, _} = Config.save(%{max_expr_nodes: 3})
      huge = {:op, :+, [{:num, 1}, {:op, :+, [{:num, 2}, {:num, 3}]}]}

      assert {:error, {:complexity_limit, :max_expr_nodes, actual, 3}} =
               Router.call("evaluate", :evaluate, %{ast: huge})

      assert actual > 3

      {:ok, _} = Config.save(%{max_expr_nodes: 10_000})
    end

    test "enforces max_expr_depth cap" do
      {:ok, _} = Config.save(%{max_expr_depth: 2})
      deep = {:op, :+, [{:op, :+, [{:num, 1}, {:num, 2}]}, {:num, 3}]}

      assert {:error, {:complexity_limit, :max_expr_depth, _, 2}} =
               Router.call("evaluate", :evaluate, %{ast: deep})

      {:ok, _} = Config.save(%{max_expr_depth: 64})
    end

    test "enforces max_integer_bits cap" do
      {:ok, _} = Config.save(%{max_integer_bits: 8})

      assert {:error, {:complexity_limit, :max_integer_bits, _, 8}} =
               Router.call("evaluate", :evaluate, %{ast: {:num, 1_000}})

      {:ok, _} = Config.save(%{max_integer_bits: 4_096})
    end

  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane/test/backplane/math/router_test.exs`

Expected: fails — module undefined.

- [ ] **Step 3: Implement the router**

Create `apps/backplane/lib/backplane/math/router.ex`:

```elixir
defmodule Backplane.Math.Router do
  @moduledoc """
  Routes tool calls to engines, enforcing complexity caps and timeouts.

  Call path:
      Math.Tools.call/1
        → Math.Router.call(tool_name, op, params)
          → complexity_check(params)
          → Sandbox.run(fn -> Engine.run(op, params) end, tool_timeout)
  """

  alias Backplane.Math.Config
  alias Backplane.Math.Engine.Native
  alias Backplane.Math.Expression.Ast
  alias Backplane.Math.Sandbox

  @engines_in_priority_order [Native]

  @spec call(String.t(), atom(), map()) :: {:ok, term()} | {:error, term()}
  def call(tool_name, op, params) when is_binary(tool_name) and is_atom(op) and is_map(params) do
    with :ok <- complexity_check(params),
         {:ok, engine} <- pick_engine(op) do
      timeout = Config.tool_timeout(tool_name)

      case Sandbox.run(fn -> engine.run(op, params) end, timeout) do
        {:ok, {:ok, value}} -> {:ok, value}
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, :timeout} -> {:error, :timeout}
        {:error, {:exit, reason}} -> {:error, {:engine_crash, reason}}
      end
    end
  end

  # ---- caps ----

  @spec complexity_check(map()) :: :ok | {:error, {:complexity_limit, atom(), integer(), integer()}}
  def complexity_check(params) do
    cfg = Config.get()

    with :ok <- check_ast(params, :max_expr_nodes, &Ast.size/1, cfg.max_expr_nodes),
         :ok <- check_ast(params, :max_expr_depth, &Ast.depth/1, cfg.max_expr_depth),
         :ok <- check_ast(params, :max_integer_bits, &Ast.max_integer_bits/1, cfg.max_integer_bits) do
      :ok
    end
  end

  defp check_ast(%{ast: ast}, name, measure, limit) do
    actual = measure.(ast)

    if actual <= limit do
      :ok
    else
      {:error, {:complexity_limit, name, actual, limit}}
    end
  end

  defp check_ast(_other, _name, _measure, _limit), do: :ok

  # ---- engine selection ----

  defp pick_engine(op) do
    case Enum.find(@engines_in_priority_order, fn e -> e.supports?(op) end) do
      nil -> {:error, {:engine_unavailable, op}}
      engine -> {:ok, engine}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/backplane/test/backplane/math/router_test.exs`

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane/lib/backplane/math/router.ex \
        apps/backplane/test/backplane/math/router_test.exs
git commit -m "feat(math): add Router with complexity caps and sandboxed dispatch"
```

---

## Task 12: Math.Tools — ToolModule Implementation + `math::evaluate`

**Files:**
- Create: `apps/backplane/lib/backplane/math/tools.ex`
- Create: `apps/backplane/test/backplane/math/tools_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/backplane/test/backplane/math/tools_test.exs`:

```elixir
defmodule Backplane.Math.ToolsTest do
  use Backplane.DataCase, async: false

  alias Backplane.Math.Tools

  setup do
    :ok = Backplane.Math.Config.reload()
    :ok
  end

  describe "tools/0" do
    test "emits at least math::evaluate in Phase 1" do
      names = Enum.map(Tools.tools(), & &1.name)
      assert "math::evaluate" in names
    end

    test "each tool has the ToolModule-shaped fields" do
      for tool <- Tools.tools() do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.input_schema)
        assert tool.module == Tools
        assert is_atom(tool.handler)
      end
    end
  end

  describe "call/1 — evaluate via JSON AST" do
    test "computes 1 + 2" do
      args = %{"_handler" => "evaluate", "ast" => %{"op" => "+", "args" => [%{"num" => 1}, %{"num" => 2}]}}
      assert {:ok, result} = Tools.call(args)

      assert %{
               "value" => 3,
               "ast" => %{"num" => 3},
               "latex" => "3",
               "text" => "3"
             } = result
    end

    test "computes with variable bindings" do
      args = %{
        "_handler" => "evaluate",
        "ast" => %{"op" => "+", "args" => [%{"var" => "x"}, %{"num" => 1}]},
        "vars" => %{"x" => 2}
      }

      assert {:ok, %{"value" => 3}} = Tools.call(args)
    end
  end

  describe "call/1 — evaluate via infix expression" do
    test "parses 2 * (3 + 4) and evaluates" do
      args = %{"_handler" => "evaluate", "expr" => "2 * (3 + 4)"}
      assert {:ok, %{"value" => 14}} = Tools.call(args)
    end
  end

  describe "call/1 — errors" do
    test "rejects a payload with neither ast nor expr" do
      args = %{"_handler" => "evaluate"}
      assert {:error, {:bad_request, :missing_expression}} = Tools.call(args)
    end

    test "surfaces parse errors" do
      args = %{"_handler" => "evaluate", "expr" => "1 + ("}
      assert {:error, {:parse, _, _}} = Tools.call(args)
    end

    test "surfaces complexity cap errors" do
      {:ok, _} = Backplane.Math.Config.save(%{max_expr_nodes: 2})

      args = %{
        "_handler" => "evaluate",
        "ast" => %{"op" => "+", "args" => [%{"num" => 1}, %{"num" => 2}]}
      }

      assert {:error, {:complexity_limit, :max_expr_nodes, _, 2}} = Tools.call(args)

      {:ok, _} = Backplane.Math.Config.save(%{max_expr_nodes: 10_000})
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane/test/backplane/math/tools_test.exs`

Expected: module undefined.

- [ ] **Step 3: Implement the Tools module**

Create `apps/backplane/lib/backplane/math/tools.ex`:

```elixir
defmodule Backplane.Math.Tools do
  @moduledoc """
  Native MCP tool module for the Math server.

  Each tool entry carries `module: __MODULE__, handler: :atom` per the
  `Backplane.Tools.ToolModule` contract. The MCP transport layer injects
  `"_handler"` into args, which `call/1` pattern-matches on to dispatch.
  """

  @behaviour Backplane.Tools.ToolModule

  alias Backplane.Math.Expression.{ParserInfix, ParserJson, Printer}
  alias Backplane.Math.Router

  @impl true
  def tools do
    [
      %{
        name: "math::evaluate",
        description:
          "Numerically evaluate a math expression. Accepts either an infix string " <>
          "(`expr`) or a JSON AST (`ast`), with optional variable bindings (`vars`).",
        input_schema: %{
          "type" => "object",
          "oneOf" => [
            %{"required" => ["expr"]},
            %{"required" => ["ast"]}
          ],
          "properties" => %{
            "expr" => %{
              "type" => "string",
              "description" => "Infix expression, e.g. \"2 * (3 + 4)\" or \"sin(pi/4)\""
            },
            "ast" => %{
              "type" => "object",
              "description" => "Canonical JSON AST (same shape as returned by any math:: tool)"
            },
            "vars" => %{
              "type" => "object",
              "description" => "Variable bindings (var name → numeric value)",
              "additionalProperties" => %{"type" => "number"}
            }
          }
        },
        module: __MODULE__,
        handler: :evaluate
      }
    ]
  end

  @impl true
  def call(%{"_handler" => "evaluate"} = args) do
    with {:ok, ast} <- parse_expression(args),
         {:ok, vars} <- parse_vars(args),
         {:ok, value} <- Router.call("math::evaluate", :evaluate, %{ast: ast, vars: vars}) do
      value_ast = value_to_ast(value)

      {:ok,
       %{
         "value" => jsonable(value),
         "ast" => Printer.to_json(value_ast),
         "latex" => Printer.to_latex(value_ast),
         "text" => Printer.to_text(value_ast)
       }}
    end
  end

  def call(%{"_handler" => other}), do: {:error, {:unknown_handler, other}}
  def call(_), do: {:error, {:bad_request, :missing_handler}}

  # ---- parsing ----

  defp parse_expression(%{"ast" => json}) when is_map(json), do: ParserJson.parse(json)
  defp parse_expression(%{"expr" => str}) when is_binary(str), do: ParserInfix.parse(str)
  defp parse_expression(_), do: {:error, {:bad_request, :missing_expression}}

  defp parse_vars(%{"vars" => map}) when is_map(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
      cond do
        not is_binary(k) -> {:halt, {:error, {:bad_request, {:var_name, k}}}}
        not (is_integer(v) or is_float(v)) -> {:halt, {:error, {:bad_request, {:var_value, k, v}}}}
        true -> {:cont, {:ok, Map.put(acc, String.to_atom(k), v)}}
      end
    end)
  end

  defp parse_vars(_), do: {:ok, %{}}

  # ---- result wrapping ----

  defp value_to_ast(v) when is_integer(v) or is_float(v), do: {:num, v}
  defp value_to_ast(%Decimal{} = d), do: {:num, d}
  defp value_to_ast(%Complex{} = c), do: {:num, c}
  defp value_to_ast(:infinity), do: {:sym, :inf}
  defp value_to_ast(:nan), do: {:sym, :nan}
  defp value_to_ast(other), do: {:num, other}

  defp jsonable(v) when is_integer(v) or is_float(v) or is_binary(v) or is_boolean(v) or is_nil(v),
    do: v

  defp jsonable(%Decimal{} = d), do: Decimal.to_string(d)
  defp jsonable(%Complex{} = c), do: Complex.to_string(c)
  defp jsonable(:infinity), do: "infinity"
  defp jsonable(:nan), do: "nan"
  defp jsonable(other), do: inspect(other)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/backplane/test/backplane/math/tools_test.exs`

Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane/lib/backplane/math/tools.ex \
        apps/backplane/test/backplane/math/tools_test.exs
git commit -m "feat(math): add Math.Tools with math::evaluate"
```

---

## Task 13: Register Math Tools at Boot

**Files:**
- Modify: `apps/backplane/lib/backplane/application.ex`

- [ ] **Step 1: Write the failing test**

Create a test file `apps/backplane/test/backplane/math/registration_test.exs`:

```elixir
defmodule Backplane.Math.RegistrationTest do
  use Backplane.DataCase, async: false

  alias Backplane.Registry.ToolRegistry

  test "math::evaluate is registered at boot" do
    tool_names = ToolRegistry.list_all() |> Enum.map(& &1.name)
    assert "math::evaluate" in tool_names
  end

  test "math::evaluate resolves to Backplane.Math.Tools" do
    assert {:native, Backplane.Math.Tools, :evaluate} =
             ToolRegistry.resolve("math::evaluate")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane/test/backplane/math/registration_test.exs`

Expected: fails — `math::evaluate` not in the registry, because it isn't registered yet.

- [ ] **Step 3: Add `Backplane.Math.Tools` to the native tool modules list**

Open `apps/backplane/lib/backplane/application.ex`. Locate:

```elixir
defp register_native_tools do
  tool_modules = [Skill, Hub, Admin]
```

Change to:

```elixir
defp register_native_tools do
  tool_modules = [Skill, Hub, Admin, Backplane.Math.Tools]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/backplane/test/backplane/math/registration_test.exs`

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane/lib/backplane/application.ex \
        apps/backplane/test/backplane/math/registration_test.exs
git commit -m "feat(math): register math::evaluate as native tool at boot"
```

---

## Task 14: Math.Supervisor Consolidation

**Files:**
- Create: `apps/backplane/lib/backplane/math/supervisor.ex`
- Create: `apps/backplane/test/backplane/math/supervisor_test.exs`
- Modify: `apps/backplane/lib/backplane/application.ex`

- [ ] **Step 1: Write the failing test**

Create `apps/backplane/test/backplane/math/supervisor_test.exs`:

```elixir
defmodule Backplane.Math.SupervisorTest do
  use ExUnit.Case, async: false

  test "Backplane.Math.Supervisor is running" do
    assert pid = Process.whereis(Backplane.Math.Supervisor)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "supervises Config and Sandbox" do
    children = Supervisor.which_children(Backplane.Math.Supervisor)
    names = Enum.map(children, fn {name, _pid, _type, _mods} -> name end)

    assert Backplane.Math.Config in names
    assert Backplane.Math.Sandbox in names
  end

  test "Sandbox restarts after a kill; Config is unaffected" do
    config_pid = Process.whereis(Backplane.Math.Config)
    sandbox_pid = Process.whereis(Backplane.Math.Sandbox)
    assert is_pid(sandbox_pid)

    Process.exit(sandbox_pid, :kill)
    :timer.sleep(50)

    new_sandbox_pid = Process.whereis(Backplane.Math.Sandbox)
    assert is_pid(new_sandbox_pid)
    assert new_sandbox_pid != sandbox_pid
    assert Process.whereis(Backplane.Math.Config) == config_pid
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane/test/backplane/math/supervisor_test.exs`

Expected: fails — `Backplane.Math.Supervisor` is not registered.

- [ ] **Step 3: Implement the supervisor**

Create `apps/backplane/lib/backplane/math/supervisor.ex`:

```elixir
defmodule Backplane.Math.Supervisor do
  @moduledoc """
  Math subtree supervisor.

  Children (rest_for_one so Config failure cascades to dependents):

      Math.Config    — ETS-cached runtime config (GenServer)
      Math.Sandbox   — Task.Supervisor for bounded execution
  """

  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    children = [
      Backplane.Math.Config,
      Backplane.Math.Sandbox
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

- [ ] **Step 4: Replace individual children with the supervisor in Application**

In `apps/backplane/lib/backplane/application.ex`, replace:

```elixir
ToolRegistry,
Backplane.Math.Config,
Backplane.Math.Sandbox,
SkillsRegistry,
```

with:

```elixir
ToolRegistry,
Backplane.Math.Supervisor,
SkillsRegistry,
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test apps/backplane/test/backplane/math/supervisor_test.exs`

Expected: 3 tests pass.

- [ ] **Step 6: Re-run all Math tests**

Run: `mix test apps/backplane/test/backplane/math/`

Expected: all tests across `config`, `sandbox`, `router`, `tools`, `registration`, `supervisor`, `expression`, and `engine` pass.

- [ ] **Step 7: Commit**

```bash
git add apps/backplane/lib/backplane/math/supervisor.ex \
        apps/backplane/test/backplane/math/supervisor_test.exs \
        apps/backplane/lib/backplane/application.ex
git commit -m "feat(math): consolidate Config and Sandbox under Math.Supervisor"
```

---

## Task 15: End-to-End Integration Test

**Files:**
- Create: `apps/backplane/test/integration/math_evaluate_round_trip_test.exs`

- [ ] **Step 1: Write the integration test**

Create `apps/backplane/test/integration/math_evaluate_round_trip_test.exs`:

```elixir
defmodule Backplane.Integration.MathEvaluateRoundTripTest do
  @moduledoc """
  End-to-end: a client calling POST /mcp with tools/list sees math::evaluate,
  and tools/call returns a correct result with ast/latex/text encodings.
  """

  use Backplane.ConnCase, async: false

  alias Backplane.Math.Config

  setup do
    :ok = Config.reload()
    :ok
  end

  describe "tools/list" do
    test "includes math::evaluate with its schema" do
      resp = mcp_request("tools/list")

      tools = get_in(resp, ["result", "tools"])
      assert is_list(tools)

      evaluate =
        Enum.find(tools, fn t -> t["name"] == "math::evaluate" end)

      assert evaluate
      assert is_binary(evaluate["description"])
      assert %{"type" => "object"} = evaluate["inputSchema"]
    end
  end

  describe "tools/call — math::evaluate" do
    test "computes a JSON AST expression end-to-end" do
      args = %{
        "ast" => %{
          "op" => "*",
          "args" => [
            %{"num" => 2},
            %{"op" => "+", "args" => [%{"num" => 3}, %{"num" => 4}]}
          ]
        }
      }

      resp =
        mcp_request("tools/call", %{"name" => "math::evaluate", "arguments" => args})

      refute resp["error"]
      result = get_in(resp, ["result", "content"]) || get_in(resp, ["result"])
      # Result is whatever shape the transport wraps the handler output in;
      # assert on the numeric value being present.
      assert inspect(result) =~ "14"
    end

    test "computes an infix expression end-to-end" do
      resp =
        mcp_request("tools/call", %{
          "name" => "math::evaluate",
          "arguments" => %{"expr" => "sin(0) + 2"}
        })

      refute resp["error"]
      assert inspect(get_in(resp, ["result"])) =~ "2"
    end

    test "surfaces complexity cap rejection as an MCP error" do
      {:ok, _} = Config.save(%{max_expr_nodes: 2})

      resp =
        mcp_request("tools/call", %{
          "name" => "math::evaluate",
          "arguments" => %{
            "ast" => %{"op" => "+", "args" => [%{"num" => 1}, %{"num" => 2}]}
          }
        })

      # Whether the transport surfaces via jsonrpc error or result.isError, both
      # forms are acceptable — assert the cap name is mentioned.
      payload = Jason.encode!(resp)
      assert payload =~ "complexity_limit"

      {:ok, _} = Config.save(%{max_expr_nodes: 10_000})
    end

    test "malicious-looking string is parsed, not executed" do
      # A classic injection payload — ParserInfix should reject it. The test
      # proves there is no string-eval path.
      resp =
        mcp_request("tools/call", %{
          "name" => "math::evaluate",
          "arguments" => %{"expr" => "System.cmd(\"rm\", [\"-rf\", \"/\"])"}
        })

      payload = Jason.encode!(resp)
      assert payload =~ "parse"
      refute File.exists?("/tmp/backplane-math-pwned")
    end
  end
end
```

- [ ] **Step 2: Run the integration test**

Run: `mix test apps/backplane/test/integration/math_evaluate_round_trip_test.exs`

Expected: 4 tests pass. If `tools/call`'s response wrapping differs from the loose `inspect/1` checks above, examine the actual response and tighten the assertion accordingly.

- [ ] **Step 3: Run the full math test tree**

Run: `mix test apps/backplane/test/backplane/math/ apps/backplane/test/integration/math_evaluate_round_trip_test.exs`

Expected: every math test passes; no regressions.

- [ ] **Step 4: Run the full suite to catch regressions elsewhere**

Run: `mix test`

Expected: green across the whole umbrella. If any previously-passing test now fails, fix it before committing.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane/test/integration/math_evaluate_round_trip_test.exs
git commit -m "test(math): end-to-end round-trip for math::evaluate via MCP endpoint"
```

---

## Follow-on Plans (not written yet)

Once this foundation lands, these follow-on plans build on top. Each adds a batch of tools and any engine helpers they need, without touching the foundation modules.

| Plan | Adds | Tools | Engine modules needed |
|------|------|-------|-----------------------|
| B — Arithmetic & Units | Static conversion table, Decimal/rational coercions | `math::to_decimal`, `math::to_rational`, `math::convert_units` | `Engine.Native.Numerics`, `Engine.Native.Units` |
| C — Linear Algebra | Nx BinaryBackend helpers | `math::matrix_op`, `math::linear_solve`, `math::eig`, `math::svd`, `math::decompose` | `Engine.Native.LinearAlgebra` |
| D — Statistics | Pure-Elixir descriptive stats, regression, 5 distributions, hypothesis tests | `math::summary`, `math::regression`, `math::distribution`, `math::hypothesis_test` | `Engine.Native.Statistics`, `Engine.Native.Distributions`, `Engine.Native.HypothesisTest`, `Engine.Native.Special` |
| E — Number Theory | Trial-division factor, Miller-Rabin, CRT | `math::factor_integer`, `math::is_prime`, `math::gcd_lcm`, `math::mod_pow`, `math::crt` | `Engine.Native.NumberTheory` |
| F — Admin UI | LiveView config editor at `/admin/mcp/native/math` | — | — |

After F, Phase 1 per the PRD is complete. Phase 2 (SymPy sidecar + CAS tools) is a separate PRD execution and starts its own plan tree.
