# Design Specification: In-House `backplane_json_schema`

**Date**: 2026-11-07  
**Status**: Approved  
**Author**: Antigravity & User  
**Target Umbrella App**: `apps/backplane_json_schema`  

---

## 1. Overview & Motivation

Backplane requires JSON Schema validation for Model Context Protocol (MCP) tool call arguments and agent runtime boundaries. Currently, `apps/backplane_agent_runtime` depends on the external third-party Hex package `:jsonschex`.

To eliminate third-party supply chain risks and establish a trusted, 100% first-party foundation under the project's direct control, we are creating the in-house umbrella application:
`apps/backplane_json_schema` (`:backplane_json_schema`).

This application will:
1. Provide a modern, clean, and modular architecture inspired by `ex_json_schema`.
2. Fully support **JSON Schema Draft 2020-12** (and backward compatibility for **Draft 7**), conforming to the official JSON Schema Test Suite.
3. Expose a strict, modern `compile/validate` API surface.
4. Replace `:jsonschex` across `backplane_agent_runtime`, release scripts, and tests.

---

## 2. API Surface

The top-level module `Backplane.JsonSchema` provides:

```elixir
defmodule Backplane.JsonSchema do
  @type schema :: %Backplane.JsonSchema.Schema{}
  @type data :: term()
  @type error :: %Backplane.JsonSchema.Error{} | map()

  @doc "Compiles a raw schema map or boolean into an executable Schema struct."
  @spec compile(map() | boolean(), keyword()) :: {:ok, schema()} | {:error, term()}
  def compile(raw_schema, opts \\ [])

  @doc "Compiles a raw schema or raises on error."
  @spec compile!(map() | boolean(), keyword()) :: schema()
  def compile!(raw_schema, opts \\ [])

  @doc "Validates data against a compiled schema."
  @spec validate(schema(), data(), keyword()) :: :ok | {:error, [error()]}
  def validate(compiled_schema, data, opts \\ [])

  @doc "Formats a validation error into a human-readable string."
  @spec format_error(error()) :: String.t()
  def format_error(error)
end
```

### Options Supported

- `:schema_registry` - Pre-loaded map of URI string -> schema maps.
- `:schema_loader` / `:loader` - Custom resolver function `(String.t() -> {:ok, map() | boolean()} | {:error, term()})`. External network requests are never performed by default; loaders are explicitly supplied.
- `:format_assertion` - `boolean()`, defaults to `false` (annotation-only per Draft 2020-12 spec unless explicitly enabled).
- `:content_assertion` - `boolean()`, defaults to `false`.

---

## 3. Architecture & Module Organization

The design combines `ex_json_schema`'s clean separation of concerns with the modern Draft 2020-12 AST and evaluation rules:

```
apps/backplane_json_schema/
├── lib/
│   ├── backplane/
│   │   └── json_schema/
│   │       ├── compiler.ex              # AST compiler & schema normalization
│   │       ├── compiler/
│   │       │   ├── fragment.ex          # Subschema fragment indexing
│   │       │   ├── fragment/bundle.ex   # Dynamic fragment bundling
│   │       │   ├── predicates.ex        # Type & numerical constraint checks
│   │       │   ├── predicates/multiple_of.ex
│   │       │   ├── cache.ex             # In-memory compile cache
│   │       │   └── ecma_regex.ex        # ECMA-262 regex translation
│   │       ├── validator.ex             # Validation dispatcher & runner
│   │       ├── validator/
│   │       │   ├── keywords.ex          # Keyword execution pipeline
│   │       │   ├── reference.ex         # Reference resolver ($ref, $dynamicRef)
│   │       │   ├── pattern.ex           # Regex pattern matching
│   │       │   └── rules.ex             # Core evaluation rules
│   │       ├── draft202012/             # Draft 2020-12 dialect & vocabularies
│   │       │   ├── dialect.ex
│   │       │   ├── vocabulary.ex        # Core, Applicator, Validation, Unevaluated, Content
│   │       │   ├── scope_scanner.ex     # $defs, $id, $anchor, $dynamicAnchor
│   │       │   └── schemas.ex           # Embedded Draft 2020-12 meta-schemas
│   │       ├── draft7/                  # Draft 7 dialect
│   │       │   ├── dialect.ex
│   │       │   ├── scope_scanner.ex
│   │       │   └── schemas.ex           # Embedded Draft 7 meta-schemas
│   │       ├── formats/                 # Standard format validators
│   │       │   ├── datetime.ex
│   │       │   ├── email.ex
│   │       │   ├── hostname.ex
│   │       │   ├── ip.ex
│   │       │   ├── regex.ex
│   │       │   └── uri_template.ex
│   │       ├── schema.ex                # %Backplane.JsonSchema.Schema{} struct
│   │       ├── types.ex                 # Common type definitions
│   │       ├── error_formatter.ex       # Error formatting logic
│   │       ├── uri_util.ex              # URI normalization & resolution
│   │       └── resource_context.ex      # Dynamic scope & resource tracking
│   └── backplane_json_schema.ex         # Public API module
└── test/
    ├── backplane/
    │   └── json_schema/
    │       ├── compiler_test.exs
    │       ├── validator_test.exs
    │       └── draft202012_test.exs
    ├── fixtures/
    │   └── json_schema_test_suite/      # Official Draft 2020-12 test suite
    └── test_helper.exs
```

---

## 4. Key Engine Capabilities

1. **Complete Draft 2020-12 Vocabularies**:
   - **Core**: `$schema`, `$id`, `$ref`, `$anchor`, `$dynamicRef`, `$dynamicAnchor`, `$defs`, `$comment`.
   - **Applicator**: `allOf`, `anyOf`, `oneOf`, `not`, `if`, `then`, `else`, `dependentSchemas`, `prefixItems`, `items`, `contains`, `properties`, `patternProperties`, `additionalProperties`, `propertyNames`.
   - **Unevaluated**: `unevaluatedProperties`, `unevaluatedItems` tracking evaluated dynamic scopes across sibling and referenced applicators.
   - **Validation**: `type`, `enum`, `const`, `multipleOf`, `maximum`, `exclusiveMaximum`, `minimum`, `exclusiveMinimum`, `maxLength`, `minLength`, `pattern`, `maxItems`, `minItems`, `uniqueItems`, `maxContains`, `minContains`, `maxProperties`, `minProperties`, `required`, `dependentRequired`.
   - **Format / Content**: Annotation by default, assertions configurable.

2. **Full Draft 7 Backward Compatibility**:
   - Supports `definitions`, boolean/array `items`, `dependencies`, and Draft 7 meta-schemas.

3. **Zero Implicit Network Calls**:
   - Internal meta-schemas are pre-compiled and embedded in memory.
   - External references require explicit `:schema_registry` or `:schema_loader`, ensuring fail-closed sandboxing.

---

## 5. Migration & Integration Strategy

### Step 1: Create `apps/backplane_json_schema`
- Scaffold the umbrella app with `apps/backplane_json_schema/mix.exs`.
- Implement all modules under the namespace `Backplane.JsonSchema.*`.
- Port the official JSON Schema Test Suite into `apps/backplane_json_schema/test/`.
- Ensure all tests pass.

### Step 2: Update `apps/backplane_agent_runtime`
- In `apps/backplane_agent_runtime/mix.exs`:
  - Replace `{:jsonschex, "~> 0.11"}` with `{:backplane_json_schema, in_umbrella: true}`.
- In `apps/backplane_agent_runtime/lib/backplane/agent_runtime/input_schema.ex`:
  - Replace `JSONSchex.*` calls with `Backplane.JsonSchema.*`.
  - Replace `JSONSchex.Draft202012.Schemas.fetch/1` with `Backplane.JsonSchema.Draft202012.Schemas.fetch/1`.
  - Replace `JSONSchex.Types.Schema` with `Backplane.JsonSchema.Schema`.
- In `apps/backplane_agent_runtime/test/backplane/agent_runtime/json_schema_draft202012_test.exs`:
  - Update tests to invoke `Backplane.JsonSchema`.

### Step 3: Clean up references and dependencies
- Remove `:jsonschex` from `mix.lock` and `apps/backplane_agent_runtime/mix.lock`.
- Update `scripts/verify_agent_runtime_package.sh` and `test/release_config_test.exs` to reflect `:backplane_json_schema` instead of `:jsonschex`.
- Update documentation in `apps/backplane_agent_runtime/SCHEMAS.md`, `README.md`, and `CHANGELOG.md`.

---

## 6. Verification Plan

1. **Compilation**: `mix compile --warnings-as-errors`
2. **Formatting & Linting**: `mix format --check-formatted` and `mix credo --strict`
3. **App Suite**: `mix test apps/backplane_json_schema`
4. **Agent Runtime Suite**: `mix test apps/backplane_agent_runtime`
5. **Full Acceptance**: Run existing live acceptance and release qualification tests.
