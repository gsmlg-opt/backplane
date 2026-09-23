# Changelog

## Unreleased

- Add explicit strict batch tool admission with opt-in schema quarantine at the
  ToolCatalog/Conversation boundary. Quarantine only removes direct
  `:unsupported_capability` schema results and returns accepted/rejected bundle
  diagnostics without changing execution-time argument validation.
- Declare the optional `jsonschex` precision dependency so the standalone
  package runs the complete Draft 2020-12 numeric conformance suite.

## 1.8.3

- Replace the hand-written schema subset with `jsonschex 0.10.0`, targeting
  JSON Schema Draft 2020-12 across the catalog preflight and execution gateway.
- Add fixed-commit official Draft 2020-12 conformance coverage, explicit
  external schema registries/loaders, dialect/vocabulary checks, boolean and
  recursive references, and bounded schema/input resource handling.
- Document format/content annotation defaults and the production dependency;
  the package is no longer dependency-free.

## 1.8.2

- Accept the current MCP input-schema forms reported in issue #46: string
  annotations, numeric/string/array assertions, portable patterns, `not`,
  schema-valued `additionalProperties`, null and union types, untyped nested
  schemas, and scalar/array/null composition branches. Preserve recursive
  fail-closed preflight and argument validation before backend execution.

## 1.8.1

- Support `oneOf` alongside object schema constraints at the tool root and in
  nested schemas while enforcing both the sibling constraints and exactly one
  matching branch. Catalog preflight remains recursive and fail-closed.

## 1.7.9

- Accept JSON Schema `default` annotations at every supported schema position
  without inserting values or relaxing constraint validation.

## 1.7.0

- Add atomic, run/incarnation-fenced Conversation tool catalog staging and
  post-batch publication with pinned provider definitions, exact duplicate
  reconciliation, and ephemeral registry/authority handling for issue #42.
- Support typed JSON Schema `enum` constraints, including Sigma's todo action
  and status properties. Preserve type/constraint validation and fail-closed
  unsupported keywords; cover registration, provider dispatch, and rejected
  enum calls with regressions for issue #36.

## 1.6.0

- Add a single-owner embedded conversation driver with lazy provider streams,
  authorized tools, steering/follow-up, hook and interaction adapters, finite
  deadlines and conservative cancellation/recovery. Existing command APIs remain.
- Ship adapter documentation and a scripted embedded example; add artifact
  consumers and optional read-only real Sigma provider/schema verification.
- Include this package in the existing gated Hex release workflow; no publication
  is performed by local verification.

- Support Sigma's current built-in tool schema constraints, including numeric
  minimums, nested array items and `oneOf` composition.
- Add an atomic durable-store incarnation fence and a reusable host-adapter
  conformance runner for commit, restart, recovery, and failure scenarios.

## 0.1.0

- Provide the bounded agent runtime and opt-in tool contracts.
- Bundle local resource and command adapters in the runtime package.
