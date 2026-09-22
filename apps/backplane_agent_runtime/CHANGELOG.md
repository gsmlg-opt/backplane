# Changelog

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
