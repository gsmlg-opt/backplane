# Backplane JSON Schema Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create an in-house `apps/backplane_json_schema` umbrella application providing Draft 2020-12 and Draft 7 JSON Schema validation with a strict `compile/validate` API and `ex_json_schema`-style modular architecture, replacing the third-party `:jsonschex` dependency.

**Architecture:** A standalone umbrella app `apps/backplane_json_schema` (`Backplane.JsonSchema`) that compiles schemas into structured AST structs with cached fragment scopes, evaluates Draft 2020-12 dynamic references (`$dynamicRef`/`$dynamicAnchor`) and unevaluated properties/items across applicators, and verifies payloads in memory with zero implicit network fetches.

**Tech Stack:** Elixir 1.18, OTP 28, Jason, ExJsonPointer, Decimal (optional arbitrary precision).

---

### Task 1: Scaffold `apps/backplane_json_schema` Umbrella Application

**Files:**
- Create: `apps/backplane_json_schema/mix.exs`
- Create: `apps/backplane_json_schema/test/test_helper.exs`

- [ ] **Step 1: Create `apps/backplane_json_schema/mix.exs`**
  Define `Backplane.JsonSchema.MixProject` with:
  - app: `:backplane_json_schema`
  - version: `"1.10.58"`
  - build_path: `"../../_build"`
  - config_path: `"../../config/config.exs"`
  - deps_path: `"../../deps"`
  - lockfile: `"../../mix.lock"`
  - deps: `[{:ex_json_pointer, "~> 0.9"}, {:decimal, "~> 3.2", optional: true}, {:jason, "~> 1.4"}]`

- [ ] **Step 2: Create `apps/backplane_json_schema/test/test_helper.exs`**
  Initialize `ExUnit.start()`.

- [ ] **Step 3: Verify umbrella compilation**
  Run: `mix compile --warnings-as-errors`
  Expected: Success, recognizing `:backplane_json_schema`.

- [ ] **Step 4: Commit**
  ```bash
  git add apps/backplane_json_schema
  git commit -m "feat(json_schema): scaffold backplane_json_schema umbrella app"
  ```

---

### Task 2: Port Core Types, Schema Struct, URI Utility & Resource Context

**Files:**
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/types.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/schema.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/uri_util.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/resource_context.ex`
- Test: `apps/backplane_json_schema/test/backplane/json_schema/uri_util_test.exs`

- [ ] **Step 1: Write URI util test**
  Test URI normalization, anchor resolution, and reference path resolution.

- [ ] **Step 2: Implement `types.ex`, `schema.ex`, `uri_util.ex`, and `resource_context.ex`**
  - Define `Backplane.JsonSchema.Types` and `%Backplane.JsonSchema.Schema{}` struct.
  - Implement URI resolution without external network requests.
  - Implement `ResourceContext` managing base URIs, dynamic scopes, and vocabularies.

- [ ] **Step 3: Run URI tests**
  Run: `mix test apps/backplane_json_schema/test/backplane/json_schema/uri_util_test.exs`
  Expected: PASS.

- [ ] **Step 4: Commit**
  ```bash
  git add apps/backplane_json_schema/lib apps/backplane_json_schema/test
  git commit -m "feat(json_schema): add schema struct, types, and URI utilities"
  ```

---

### Task 3: Implement Draft 2020-12 & Draft 7 Dialects and Embedded Meta-Schemas

**Files:**
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/draft202012/schemas.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/draft202012/dialect.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/draft202012/vocabulary.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/draft202012/scope_scanner.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/draft7/schemas.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/draft7/dialect.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/draft7/scope_scanner.ex`
- Test: `apps/backplane_json_schema/test/backplane/json_schema/draft_schemas_test.exs`

- [ ] **Step 1: Implement embedded meta-schemas**
  Embed the canonical JSON Schema Draft 2020-12 (core, applicator, validation, unevaluated, meta-data, format-annotation, content) and Draft 7 schemas so they are resolved in-memory without network calls.

- [ ] **Step 2: Implement dialect and scope scanners**
  - `Draft202012.ScopeScanner`: recognize `$id`, `$anchor`, `$dynamicAnchor`, and `$defs`.
  - `Draft7.ScopeScanner`: recognize `id`, `$id`, and `definitions`.
  - `Draft202012.Vocabulary`: manage required vocabularies and default assertion vs annotation behavior.

- [ ] **Step 3: Test dialect schema fetching**
  Test `Draft202012.Schemas.fetch/1` and `Draft7.Schemas.fetch/1`.
  Run: `mix test apps/backplane_json_schema/test/backplane/json_schema/draft_schemas_test.exs`
  Expected: PASS.

- [ ] **Step 4: Commit**
  ```bash
  git add apps/backplane_json_schema/lib/backplane/json_schema/draft* apps/backplane_json_schema/test
  git commit -m "feat(json_schema): add draft202012 and draft7 dialects with embedded schemas"
  ```

---

### Task 4: Implement Compiler & Subschema Indexing

**Files:**
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/compiler/ecma_regex.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/compiler/predicates.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/compiler/predicates/multiple_of.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/compiler/cache.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/compiler/fragment.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/compiler/fragment/bundle.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/compiler.ex`
- Test: `apps/backplane_json_schema/test/backplane/json_schema/compiler_test.exs`

- [ ] **Step 1: Implement predicates & ECMA regex translation**
  - Numeric comparisons with optional `Decimal` support for precision.
  - ECMA-262 compatible regex translation to Erlang `:re`.

- [ ] **Step 2: Implement Fragment indexing & Compiler**
  - Build subschema map index from root and nested fragments.
  - Index `$id`, `$anchor`, `$dynamicAnchor`, `$defs`.
  - Compile raw schema into `%Backplane.JsonSchema.Schema{}`.

- [ ] **Step 3: Test schema compilation**
  Run: `mix test apps/backplane_json_schema/test/backplane/json_schema/compiler_test.exs`
  Expected: PASS.

- [ ] **Step 4: Commit**
  ```bash
  git add apps/backplane_json_schema/lib/backplane/json_schema/compiler* apps/backplane_json_schema/test
  git commit -m "feat(json_schema): implement compiler and subschema fragment indexing"
  ```

---

### Task 5: Implement Formats, Validator Rules, and Public API

**Files:**
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/formats.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/formats/*.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/validator/rules.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/validator/keywords.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/validator/reference.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/validator/pattern.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/validator.ex`
- Create: `apps/backplane_json_schema/lib/backplane/json_schema/error_formatter.ex`
- Create: `apps/backplane_json_schema/lib/backplane_json_schema.ex`
- Test: `apps/backplane_json_schema/test/backplane/json_schema/validator_test.exs`

- [ ] **Step 1: Implement format validators and keyword rules**
  - Validation rules for core types, bounds, strings, arrays, objects.
  - Applicator rules (`allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`).
  - Unevaluated keyword state tracking (`unevaluatedProperties`, `unevaluatedItems`).
  - Static and dynamic reference resolution (`$ref`, `$dynamicRef`).

- [ ] **Step 2: Implement top-level API & error formatter**
  - `Backplane.JsonSchema.compile/1,2`, `compile!/1,2`, `validate/2,3`, `format_error/1`.

- [ ] **Step 3: Test end-to-end compilation & validation**
  Run: `mix test apps/backplane_json_schema/test/backplane/json_schema/validator_test.exs`
  Expected: PASS.

- [ ] **Step 4: Commit**
  ```bash
  git add apps/backplane_json_schema/lib apps/backplane_json_schema/test
  git commit -m "feat(json_schema): implement validation engine and public API"
  ```

---

### Task 6: Conformance Testing with Official JSON Schema Draft 2020-12 Test Suite

**Files:**
- Test: `apps/backplane_json_schema/test/backplane/json_schema/conformance_test.exs`

- [ ] **Step 1: Wire official JSON Schema test runner**
  Run the test suite against the vendored JSON Schema Test Suite fixtures in `apps/backplane_agent_runtime/test/fixtures/json_schema_test_suite`.

- [ ] **Step 2: Run conformance tests**
  Run: `mix test apps/backplane_json_schema/test/backplane/json_schema/conformance_test.exs`
  Expected: All required Draft 2020-12 test cases pass.

- [ ] **Step 3: Commit**
  ```bash
  git add apps/backplane_json_schema/test
  git commit -m "test(json_schema): add official Draft 2020-12 conformance tests"
  ```

---

### Task 7: Migrate `apps/backplane_agent_runtime` to `Backplane.JsonSchema`

**Files:**
- Modify: `apps/backplane_agent_runtime/mix.exs`
- Modify: `apps/backplane_agent_runtime/lib/backplane/agent_runtime/input_schema.ex`
- Modify: `apps/backplane_agent_runtime/test/backplane/agent_runtime/json_schema_draft202012_test.exs`
- Modify: `apps/backplane_agent_runtime/SCHEMAS.md`, `README.md`, `CHANGELOG.md`

- [ ] **Step 1: Update dependencies in `backplane_agent_runtime/mix.exs`**
  Replace `{:jsonschex, "~> 0.11"}` with `{:backplane_json_schema, in_umbrella: true}`.

- [ ] **Step 2: Update `Backplane.AgentRuntime.InputSchema`**
  Replace all `JSONSchex.*` calls with `Backplane.JsonSchema.*`:
  - `JSONSchex.compile/2` -> `Backplane.JsonSchema.compile/2`
  - `JSONSchex.validate/2,3` -> `Backplane.JsonSchema.validate/2,3`
  - `JSONSchex.Draft202012.Schemas.fetch/1` -> `Backplane.JsonSchema.Draft202012.Schemas.fetch/1`
  - `JSONSchex.format_error/1` -> `Backplane.JsonSchema.format_error/1`
  - `%JSONSchex.Types.Schema{}` -> `%Backplane.JsonSchema.Schema{}`

- [ ] **Step 3: Update `json_schema_draft202012_test.exs`**
  Switch from `JSONSchex` to `Backplane.JsonSchema`.

- [ ] **Step 4: Run agent runtime tests**
  Run: `mix test apps/backplane_agent_runtime`
  Expected: PASS.

- [ ] **Step 5: Commit**
  ```bash
  git add apps/backplane_agent_runtime
  git commit -m "refactor(agent_runtime): switch from jsonschex to backplane_json_schema"
  ```

---

### Task 8: Package Verification & CI Cleanup

**Files:**
- Modify: `scripts/verify_agent_runtime_package.sh`
- Modify: `test/release_config_test.exs`
- Modify: `mix.lock` (remove unused `:jsonschex`)

- [ ] **Step 1: Update packaging & release verification**
  Update `scripts/verify_agent_runtime_package.sh` and `test/release_config_test.exs` to reflect `:backplane_json_schema`.

- [ ] **Step 2: Clean unused dependencies**
  Run: `mix deps.unlock --unused`

- [ ] **Step 3: Run full CI suite locally**
  Run:
  - `mix compile --warnings-as-errors`
  - `mix format --check-formatted`
  - `mix credo --strict`
  - `mix test apps/backplane_json_schema`
  - `mix test apps/backplane_agent_runtime`

- [ ] **Step 4: Commit**
  ```bash
  git add scripts/verify_agent_runtime_package.sh test/release_config_test.exs mix.lock
  git commit -m "chore(ci): remove jsonschex dependency and update package verification"
  ```
