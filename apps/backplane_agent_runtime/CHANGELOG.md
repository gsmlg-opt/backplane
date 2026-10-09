# Changelog

## 1.10.15

- Add validated `provider_output_limit: non_neg_integer() | :infinity` for
  streamed and direct provider effects. Count logical text, thinking and tool
  arguments once across deltas, snapshots, completed calls and terminal usage;
  support final-only content and reset accounting per provider response.
  Keep `output_limit` independently finite and reject invalid bounds before
  dispatch. Finite provider breaches include scope, content size and limit.

## Unreleased

- Add `ToolEffects.reject/2` for trusted host-backend rejection before dispatch.
  Validate the exact operation before provider continuation; plain errors,
  mismatched/replayed identities and unknown outcomes remain fail-closed.

- R22: retain already-dispatched mutating tool invocations when a nested worker
  dies, times out, or returns an uncertain result. Outer success cannot settle
  the effect; confirmed read-only failures remain recoverable.
- R23: owner-wide command cancellation fences existing never-launched
  reservations before acknowledging cancellation, including after receipt
  consumption and eviction.
- R24: verified command cleanup updates retained output cleanup status for the
  exact session, owner, and incarnation, while preserving the original execution
  outcome, output, and historical cleanup error.
- Codex command non-start refusals use the validated backend receipt contract
  repaired in v1.10.12. Generic host tools use the explicit pre-dispatch rejection
  contract above; error classes alone remain insufficient evidence.
- R18/R21: distinguish trusted pre-launch refusal from ambiguous command launch;
  retain cancellation fencing and actionable conflicts, and bound recent
  confirmed-release receipts separately from tracked cleanup obligations.
- R19-runtime: fence mutable Conversation deadlines with independent timer
  generations and prevent late interaction checkpoints from reviving stopped work.
- R20: revoke failed nested producers' staging and callbacks before settlement
  acknowledgement; allow a caught failure to retry discovery in the same outer
  invocation, publishing only acknowledged success at the existing boundary.
- Defer Code Mode backend selection/migration and engine-level verification.
  Denox NIF is a preferred future candidate, not an adopted backend. Preserve
  the opt-in/fail-closed gates and existing native tests; shared-runtime tests
  do not establish engine conformance.
- R13: make collaboration close idempotent and tree-aware. Repeated or recursive
  close requests now preserve partial and uncertain settlement evidence, fence
  stale monitor events, and leave unrelated peers supervised.
- R14: retain authoritative command ownership and cleanup evidence after bounded
  output records expire. Per-session and owner-wide reconciliation now share the
  same evidence and distinguish unknown, pending, uncertain, and confirmed states.
- R15-R17: serialize nested Conversation transitions behind one Store commit
  coordinator; bind catalog staging to producer and publication-boundary
  invocations; and suspend root, effect, nested, and Code Mode deadlines during
  supported human interaction while restoring only the remaining budget.
- Repair Codex patch hunk matching, contextual anchors, EOF handling and
  rename-with-edit; preserve partial mutations and uncertain-write evidence.
- Preserve supervised Code Mode cells across provider turns and rebind nested
  dispatch to the current invocation. Decode bounded NDJSON incrementally in
  Deno and Elixir, including fragmented UTF-8 and explicit EOF failures.
- Separate stable collaboration identities from execution runs, retaining
  committed history, remaining quotas, and authority without replaying work.
- Separate command response truncation from host output hard limits and apply
  response budgets to stdin polling, retaining cleanup and truncation evidence.
- Track command resources before launch, clean resources on every run terminal
  path, and retain uncertain cleanup for reconciliation. Add optional command
  adapter `cancel_confirmed/3`; a cancellation request alone is not confirmation.
- R8: make Code Mode cell workers temporary so supervisor completion, cancellation,
  protocol failure, and crashes never replay a cell with stale creator arguments.
- R9: bind closed-agent snapshots to their run/incarnation and clear them only
  after a successful replacement, preserving recovery evidence on failure.
- R10: carry a stable command session identity through reservation and launch;
  individual cleanup no longer invokes owner-wide cancellation, and adapters
  without per-invocation confirmation report uncertainty.
- R11: construct direct and nested effect contexts through the same trusted path,
  including catalog staging/publication callbacks and resource ownership.
- R12: gate Code Mode on verified process-lifecycle capability before spawning;
  Deno availability alone is not sufficient, and unsupported hosts fail closed.
- Keep the Codex compatibility revision pinned to
  `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`. These repairs do not establish
  complete native-wire parity, durable session recovery, or live-service parity.

## 1.9.0

- Add pinned, opt-in Codex profiles for local execution, interaction/context,
  supervised collaboration V1/V2, scoped extensions, dynamic MCP/plugin tools,
  Code Mode, service adapters, provider-hosted declarations, and explicit
  multi-family composition. All model-callable operations use the existing
  `Conversation -> Execution` admission and commit boundary.
- Add owner-bound command, interaction, collaboration, extension, discovery,
  and continuation resources with run/incarnation fencing and conservative
  cleanup. The bundled extension backend remains explicitly ephemeral.
- Package an exact 66-entry source inventory for Codex revision
  `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`, independently classified
  compatibility evidence, a real local command/patch example, and isolated
  artifact consumer verification. Native wire, live provider/service, macOS
  process-group/PTY, and durable extension parity remain outside the claim.
- Scope provider output accounting to each provider response so multi-step tool
  conversations do not consume one cumulative turn limit. Include the limit,
  observed size, and accounting scope when an event stream exceeds its bound.
- Add explicit strict batch tool admission with opt-in schema quarantine at the
  ToolCatalog/Conversation boundary. Quarantine only removes direct
  `:unsupported_capability` schema results and returns accepted/rejected bundle
  diagnostics without changing execution-time argument validation.
- Declare `decimal` explicitly so the standalone
  package runs the complete Draft 2020-12 numeric conformance suite.
- Bind admission authority to the expected run, support executable per-tool
  revision grants, keep empty catalogs valid, and avoid retaining raw rejection
  bundles in Conversation options.

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
