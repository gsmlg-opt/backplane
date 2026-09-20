# Changelog

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
