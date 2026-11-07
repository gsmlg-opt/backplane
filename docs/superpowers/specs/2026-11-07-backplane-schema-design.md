# Design Specification: In-House `backplane_schema`

**Date**: 2026-11-07  
**Status**: Proposed  
**Author**: Antigravity & User  
**Target Umbrella App**: `apps/backplane_schema`  

---

## 1. Overview & Motivation

Backplane relies on declarative Elixir data schema validation ("Schema as Data") across `apps/backplane_mcp_protocol` for MCP message parsing, tool/prompt input validation, elicitation schemas, server authorization configuration, and Draft 7 JSON Schema conversion. Currently, `apps/backplane_mcp_protocol` depends on the third-party Hex package `:peri` (`~> 0.12`).

Following the same first-party architectural pattern established by `apps/backplane_json_schema` (which replaced `:jsonschex`), we are porting `:peri` into a dedicated, first-party umbrella application:
`apps/backplane_schema` (`:backplane_schema`, namespace `Backplane.Schema`).

This application will:
1. Provide a zero-framework-dependency, pure-Elixir declarative data validation and coercion engine under `Backplane.Schema`.
2. Export `defschema/2,3`, `validate/2,3`, `validate_schema/1`, `conforms?/2,3`, `decode/2,3`, `encode/2,3`, `walk/2`, `to_json_schema/1,2`, and `from_json_schema/1,2`.
3. Omit unused framework-specific adapters (`Ecto`, `Phoenix.HTML`, `StreamData`) to keep the dependency graph strictly bounded for standalone protocol and runtime packages (`backplane_mcp_protocol` and `backplane_agent_runtime`).
4. Replace `:peri` across `apps/backplane_mcp_protocol`, standalone package verifiers, and CI/Hex release workflows.

---

## 2. API Surface

The top-level module `Backplane.Schema` provides:

```elixir
defmodule Backplane.Schema do
  @doc "Defines a named schema function, bang variant, get_schema/1, and __schema_meta__/1."
  defmacro defschema(name, schema, opts \\ [])

  @doc "Guards whether a term is a map or list."
  defguard is_enumerable(data) when is_map(data) or is_list(data)

  @doc "Validates data against a schema definition."
  @spec validate(schema(), term(), validation_opts()) ::
          {:ok, term()} | {:error, [Backplane.Schema.Error.t()] | Backplane.Schema.Error.t()}
  def validate(schema, data, opts \\ [])

  @doc "Validates that a schema definition itself is well-formed."
  @spec validate_schema(schema()) ::
          {:ok, schema()} | {:error, [Backplane.Schema.Error.t()] | Backplane.Schema.Error.t()}
  def validate_schema(schema)

  @doc "Returns true if data conforms to schema, false otherwise."
  @spec conforms?(schema(), term(), validation_opts()) :: boolean()
  def conforms?(schema, data, opts \\ [])

  @doc "Decodes wire data against a schema (alias for validate/3 with coercion)."
  @spec decode(schema(), term(), validation_opts()) :: {:ok, term()} | {:error, term()}
  def decode(schema, data, opts \\ [])

  @doc "Encodes validated data back into wire representation."
  @spec encode(schema(), term(), validation_opts()) :: {:ok, term()} | {:error, term()}
  def encode(schema, data, opts \\ [])

  @doc "Depth-first pre-order traversal and transformation of a schema tree."
  @spec walk(schema(), Backplane.Schema.Walker.walker_fun()) :: schema()
  defdelegate walk(schema, fun), to: Backplane.Schema.Walker

  @doc "Converts a Backplane.Schema definition into a JSON Schema (Draft 7) map."
  @spec to_json_schema(schema(), Backplane.Schema.JSONSchema.Encoder.opts()) :: map()
  defdelegate to_json_schema(schema, opts \\ []),
    to: Backplane.Schema.JSONSchema.Encoder,
    as: :encode

  @doc "Decodes a JSON Schema (Draft 7) map into a Backplane.Schema definition."
  @spec from_json_schema(map(), keyword()) :: {:ok, schema()} | {:error, term()}
  defdelegate from_json_schema(json_schema, opts \\ []),
    to: Backplane.Schema.JSONSchema.Decoder,
    as: :decode
end
```

---

## 3. Architecture & Module Organization

```
apps/backplane_schema/
├── .formatter.exs
├── LICENSE
├── README.md
├── mix.exs
├── lib/
│   ├── backplane/
│   │   └── schema/
│   │       ├── error.ex                 # %Backplane.Schema.Error{} struct, formatting & Jason.Encoder
│   │       ├── invalid_schema.ex        # Backplane.Schema.InvalidSchema exception
│   │       ├── parser.ex                # %Backplane.Schema.Parser{} validation traversal state
│   │       ├── walker.ex                # Pre-order schema AST walker & rewriter
│   │       └── json_schema/
│   │           ├── encoder.ex           # Schema -> JSON Schema Draft 7 encoder
│   │           └── decoder.ex           # JSON Schema Draft 7 -> Schema decoder
│   └── backplane_schema.ex              # Public API & defschema macro (`Backplane.Schema`)
└── test/
    ├── backplane/
    │   └── schema/
    │       ├── coerce_test.exs
    │       ├── compose_test.exs
    │       ├── conformance_test.exs
    │       ├── custom_callback_test.exs
    │       ├── custom_errors_test.exs
    │       ├── error_encoding_test.exs
    │       ├── humanize_test.exs
    │       ├── json_schema_test.exs
    │       ├── list_constraints_test.exs
    │       ├── meta_test.exs
    │       ├── multi_test.exs
    │       ├── nested_list_callback_test.exs
    │       ├── nested_list_key_atomization_test.exs
    │       ├── permissive_mode_test.exs
    │       ├── ref_test.exs
    │       ├── schema_test.exs
    │       ├── structured_errors_test.exs
    │       └── walker_test.exs
    └── test_helper.exs
```

### Dependencies & Boundaries
- **Runtime Dependencies**: `{:jason, "~> 1.4", optional: true}` (for `Jason.Encoder` on `Backplane.Schema.Error`).
- **Excluded Framework Adapters**: `Peri.Ecto`, `Peri.Ecto.Type`, `Peri.Phoenix`, `Peri.Form`, and `Peri.Generatable` (`StreamData`) are intentionally excluded so that `backplane_schema` has zero compile-time or transitive coupling to Ecto, Phoenix, or StreamData, preserving `verify_agent_runtime_package.sh` and `verify_mcp_protocol_package.sh` standalone dependency invariants.

---

## 4. Migration & Integration Strategy

### Step 1: Create `apps/backplane_schema`
- Scaffold `apps/backplane_schema/mix.exs` with `@version "1.10.58"` and conditional `umbrella_paths()`.
- Configure `.formatter.exs` to export `locals_without_parens: [defschema: 2, defschema: 3]`.
- Port core modules under `Backplane.Schema.*` and ensure strict Credo, Dialyzer, and `--warnings-as-errors` compliance.
- Port and pass all unit and conformance tests under `apps/backplane_schema/test/`.

### Step 2: Migrate `apps/backplane_mcp_protocol`
- In `apps/backplane_mcp_protocol/mix.exs`:
  - Replace `{:peri, "~> 0.12"}` with `protocol_dependency(:backplane_schema)` (`{:backplane_schema, in_umbrella: true}` inside the umbrella, `{:backplane_schema, "~> 1.10.58"}` when standalone).
- In `apps/backplane_mcp_protocol/.formatter.exs`:
  - Update `import_deps: [:peri]` to `import_deps: [:backplane_schema]`.
- Across `apps/backplane_mcp_protocol/lib/` and `apps/backplane_mcp_protocol/test/`:
  - Replace `import Peri` with `import Backplane.Schema`.
  - Replace `Peri.*` calls and types with `Backplane.Schema.*` (`Backplane.Schema.validate`, `Backplane.Schema.Error`, `Backplane.Schema.InvalidSchema`, `Backplane.Schema.walk`, `Backplane.Schema.to_json_schema`, `Backplane.Schema.from_json_schema`).
  - Update `:peri` in interactive Mix tasks (`Application.ensure_all_started`) to `:backplane_schema`.

### Step 3: Update CI, Release Workflows, and Standalone Package Verifiers
- Add `backplane_schema` to `.github/workflows/test.yml` matrix.
- Add `hex-schema` job to `.github/workflows/release.yml` (publishing `apps/backplane_schema` before `hex-mcp-protocol` and `hex-packages`) and update selective release gates.
- Add `backplane_schema` to `.github/workflows/publish-hex.yml` options and matrix.
- Update `scripts/verify_mcp_protocol_package.sh` and `scripts/verify_agent_runtime_package.sh` to stage candidate `apps/backplane_schema` packages during local/CI standalone verification.
- Remove `:peri` from `mix.lock` and `apps/backplane_agent_runtime/mix.lock`.
- Update `test/hex_release_dependencies_test.exs` and verify `test/ci_workflow_test.exs` and `test/release_config_test.exs`.

---

## 5. Verification Plan

1. **Compilation**: `mix compile --warnings-as-errors`
2. **Formatting & Linting**: `mix format --check-formatted` and `mix credo --strict`
3. **App Test Suite**: `mix test apps/backplane_schema`
4. **MCP Protocol Test Suite**: `mix test apps/backplane_mcp_protocol`
5. **Agent Runtime Test Suite**: `mix test apps/backplane_agent_runtime`
6. **Workflow & Release Contract Tests**:
   - `mix run --no-start test/ci_workflow_test.exs`
   - `mix run --no-start test/hex_release_dependencies_test.exs`
   - `mix run --no-start test/release_config_test.exs`
