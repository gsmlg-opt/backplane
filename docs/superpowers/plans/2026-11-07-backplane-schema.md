# Backplane Schema (`apps/backplane_schema`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port `:peri` (`v0.12.0`) into an in-house `apps/backplane_schema` umbrella application (`Backplane.Schema`), migrate `apps/backplane_mcp_protocol` off `:peri`, and update CI, Hex release workflows, and standalone package verifiers.

**Architecture:** A pure-Elixir, zero-framework-dependency umbrella app `apps/backplane_schema` (`Backplane.Schema`) providing declarative raw data validation (`defschema`, `validate`, `conforms?`), type coercion (`decode`/`encode`), schema AST traversal (`walk`), and JSON Schema Draft 7 conversion (`to_json_schema`/`from_json_schema`), with optional `Jason.Encoder` error serialization.

**Tech Stack:** Elixir 1.18+, OTP 28+, Jason (optional), ExUnit.

---

### Task 1: Scaffold `apps/backplane_schema` Umbrella Application

**Files:**
- Create: `apps/backplane_schema/mix.exs`
- Create: `apps/backplane_schema/.formatter.exs`
- Create: `apps/backplane_schema/README.md`
- Create: `apps/backplane_schema/LICENSE`
- Create: `apps/backplane_schema/test/test_helper.exs`

- [ ] **Step 1: Create `apps/backplane_schema/mix.exs`**

```elixir
defmodule Backplane.Schema.MixProject do
  use Mix.Project

  @version "1.10.58"

  def project do
    [
      app: :backplane_schema,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "Declarative raw data structure schema validator and coercer for Backplane",
      docs: [main: "readme", extras: ["README.md"]],
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/gsmlg-opt/backplane"},
        files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
      ]
    ] ++ umbrella_paths()
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4", optional: true},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp umbrella_paths do
    root = Path.expand("../..", __DIR__)

    if File.regular?(Path.join(root, "mix.exs")) and File.dir?(Path.join(root, "apps")) do
      [
        build_path: "../../_build",
        config_path: "../../config/config.exs",
        deps_path: "../../deps",
        lockfile: "../../mix.lock"
      ]
    else
      []
    end
  end
end
```

- [ ] **Step 2: Create `apps/backplane_schema/.formatter.exs`, `README.md`, `LICENSE`, and `test/test_helper.exs`**

```elixir
# apps/backplane_schema/.formatter.exs
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: [defschema: 2, defschema: 3],
  export: [locals_without_parens: [defschema: 2, defschema: 3]]
]
```

```elixir
# apps/backplane_schema/test/test_helper.exs
ExUnit.start()
```

- [ ] **Step 3: Verify umbrella recognition**
  Run: `mix compile --warnings-as-errors`
  Expected: Compiles cleanly with `:backplane_schema` registered in the umbrella.

---

### Task 2: Port Core Support Modules (`Parser`, `Error`, `InvalidSchema`, `Walker`)

**Files:**
- Create: `apps/backplane_schema/lib/backplane/schema/parser.ex`
- Create: `apps/backplane_schema/lib/backplane/schema/error.ex`
- Create: `apps/backplane_schema/lib/backplane/schema/invalid_schema.ex`
- Create: `apps/backplane_schema/lib/backplane/schema/walker.ex`
- Test: `apps/backplane_schema/test/backplane/schema/structured_errors_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/error_encoding_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/walker_test.exs`

- [ ] **Step 1: Implement `Backplane.Schema.Parser` (`lib/backplane/schema/parser.ex`)**
  Port `Peri.Parser` to `Backplane.Schema.Parser`, tracking `data`, `errors`, `root_data`, and `path_rev` during recursive field traversal.

- [ ] **Step 2: Implement `Backplane.Schema.Error` & `Backplane.Schema.InvalidSchema`**
  Port `Peri.Error` to `Backplane.Schema.Error` (including `error_to_map/1`, `humanize/1`, `traverse/2`, `format_messages/2`, `update_error_paths/2`, and conditional `Jason.Encoder` implementation) and `Peri.InvalidSchema` to `Backplane.Schema.InvalidSchema`.

- [ ] **Step 3: Implement `Backplane.Schema.Walker` (`lib/backplane/schema/walker.ex`)**
  Port `Peri.Walker` to `Backplane.Schema.Walker` for pre-order depth-first schema tree transformation.

- [ ] **Step 4: Run support module tests**
  Run: `mix test apps/backplane_schema/test/backplane/schema/walker_test.exs`
  Expected: PASS.

---

### Task 3: Port JSON Schema Encoder/Decoder & Main `Backplane.Schema` Engine

**Files:**
- Create: `apps/backplane_schema/lib/backplane/schema/json_schema/encoder.ex`
- Create: `apps/backplane_schema/lib/backplane/schema/json_schema/decoder.ex`
- Create: `apps/backplane_schema/lib/backplane_schema.ex`
- Test: `apps/backplane_schema/test/backplane/schema/schema_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/json_schema_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/coerce_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/compose_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/conformance_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/custom_callback_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/custom_errors_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/humanize_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/list_constraints_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/meta_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/multi_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/nested_list_callback_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/nested_list_key_atomization_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/permissive_mode_test.exs`
- Test: `apps/backplane_schema/test/backplane/schema/ref_test.exs`

- [ ] **Step 1: Implement `Backplane.Schema.JSONSchema.Encoder` and `Decoder`**
  Port `Peri.JSONSchema.Encoder` and `Peri.JSONSchema.Decoder` to `Backplane.Schema.JSONSchema.Encoder` and `Backplane.Schema.JSONSchema.Decoder`.

- [ ] **Step 2: Implement `Backplane.Schema` (`lib/backplane_schema.ex`)**
  Port `Peri` to `Backplane.Schema`:
  - `defschema/2,3` macro (without `Ecto` changeset generation)
  - `validate/2,3`, `validate_schema/1`, `conforms?/2,3`, `decode/2,3`, `encode/2,3`, `walk/2`, `to_json_schema/1,2`, `from_json_schema/1,2`
  - Clean up any Credo (`--strict`) and Dialyzer warnings (such as nesting depth, pipe chains, or large function cyclomatic complexity where required by Backplane's `.credo.exs`).

- [ ] **Step 3: Port and run all `apps/backplane_schema` tests**
  Run:
  - `mix test apps/backplane_schema`
  - `mix format --check-formatted`
  - `mix credo --strict apps/backplane_schema`
  Expected: All tests pass, zero warnings, zero Credo issues.

---

### Task 4: Migrate `apps/backplane_mcp_protocol` from `:peri` to `:backplane_schema`

**Files:**
- Modify: `apps/backplane_mcp_protocol/mix.exs`
- Modify: `apps/backplane_mcp_protocol/.formatter.exs`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/elicitation.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/json_schema_converter.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/sampling.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/mcp/elicitation_schema.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/mcp/message.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/schema_validator/peri.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/authorization.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/component.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/component/prompt.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/component/schema.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/frame.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/response.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/session.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/sse.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/stdio.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/sse.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/stdio.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/websocket.ex`
- Modify: `apps/backplane_mcp_protocol/lib/mix/tasks/sse.interactive.ex`
- Modify: `apps/backplane_mcp_protocol/lib/mix/tasks/streamable_http.interactive.ex`
- Modify: `apps/backplane_mcp_protocol/lib/mix/tasks/websocket.interactive.ex`
- Modify: `apps/backplane_mcp_protocol/test/**/*_test.exs`

- [ ] **Step 1: Update `apps/backplane_mcp_protocol/mix.exs` and `.formatter.exs`**
  In `apps/backplane_mcp_protocol/mix.exs`, replace `{:peri, "~> 0.12"}` with `protocol_dependency(:backplane_schema)`:
  ```elixir
  defp protocol_dependency(:backplane_schema) do
    if File.dir?(Path.expand("../../apps", __DIR__)) do
      {:backplane_schema, in_umbrella: true}
    else
      {:backplane_schema, "~> 1.10.58"}
    end
  end
  ```
  In `apps/backplane_mcp_protocol/.formatter.exs`, replace `import_deps: [:peri]` with `import_deps: [:backplane_schema]`.

- [ ] **Step 2: Replace `Peri` references with `Backplane.Schema` in `apps/backplane_mcp_protocol`**
  - Replace `import Peri` -> `import Backplane.Schema`
  - Replace `Peri.validate` -> `Backplane.Schema.validate`
  - Replace `Peri.walk` -> `Backplane.Schema.walk`
  - Replace `Peri.to_json_schema` -> `Backplane.Schema.to_json_schema`
  - Replace `Peri.from_json_schema` -> `Backplane.Schema.from_json_schema`
  - Replace `Peri.Error` -> `Backplane.Schema.Error`
  - Replace `Peri.InvalidSchema` -> `Backplane.Schema.InvalidSchema`
  - Replace `Peri.schema` / `Peri.schema_def` -> `Backplane.Schema.schema` / `Backplane.Schema.schema_def`
  - In `lib/mix/tasks/*.interactive.ex`: replace `:peri` with `:backplane_schema`.

- [ ] **Step 3: Run `backplane_mcp_protocol` and `backplane_agent_runtime` tests**
  Run:
  - `mix test apps/backplane_mcp_protocol`
  - `mix test apps/backplane_agent_runtime`
  Expected: PASS.

---

### Task 5: Update CI, Release Workflows, Lockfiles, and Standalone Package Verifiers

**Files:**
- Modify: `.github/workflows/test.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `.github/workflows/publish-hex.yml`
- Modify: `scripts/verify_mcp_protocol_package.sh`
- Modify: `scripts/verify_agent_runtime_package.sh`
- Modify: `test/hex_release_dependencies_test.exs`
- Modify: `mix.lock`
- Modify: `apps/backplane_agent_runtime/mix.lock`

- [ ] **Step 1: Update `.github/workflows/test.yml`, `release.yml`, and `publish-hex.yml`**
  - Add `backplane_schema` to `.github/workflows/test.yml` app matrix in alphabetical order.
  - Add `backplane_schema` to selective release rejection in `.github/workflows/release.yml`, add `hex-schema` job, and add `hex-schema` to `hex-mcp-protocol` and `hex-packages` `needs`.
  - Add `backplane_schema` to `.github/workflows/publish-hex.yml` options and `all` package matrix.

- [ ] **Step 2: Update `scripts/verify_mcp_protocol_package.sh` and `scripts/verify_agent_runtime_package.sh`**
  Stage candidate `apps/backplane_schema` into a built Hex tarball unpacked directory (`SCHEMA_SOURCE`) so standalone package verification for both `backplane_mcp_protocol` and `backplane_agent_runtime` resolves `:backplane_schema` locally before Hex publication.

- [ ] **Step 3: Clean unused `:peri` and `:stream_data` from `mix.lock` and update `test/hex_release_dependencies_test.exs`**
  - Remove `"peri"` and `"stream_data"` (if unused) from `mix.lock` and `apps/backplane_agent_runtime/mix.lock`.
  - Update `test/hex_release_dependencies_test.exs` to assert `hex-schema` publication order and `publish-hex.yml` options.

- [ ] **Step 4: Run full verification suite**
  Run:
  - `mix compile --warnings-as-errors`
  - `mix format --check-formatted`
  - `mix credo --strict`
  - `mix test apps/backplane_schema`
  - `mix test apps/backplane_mcp_protocol`
  - `mix test apps/backplane_agent_runtime`
  - `mix run --no-start test/ci_workflow_test.exs`
  - `mix run --no-start test/hex_release_dependencies_test.exs`
  - `mix run --no-start test/release_config_test.exs`
  Expected: All checks and tests pass with 0 failures.
