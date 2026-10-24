# Runtime internal requests 86–89 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the approved managed-child Session protocol, pinned metadata search, owner isolation and async call identity in published 1.10.36.

**Architecture:** Keep Session resource ownership separate from root manager ownership. Partition DynamicRuntime by caller/run/incarnation, then use pure Elixir pinned text/token/BM25 helpers. Conversation supplies authoritative async call identity at its live producer boundary.

**Tech Stack:** Elixir 1.18+, OTP 28+, ExUnit, existing Store/ResourceRegistry/ToolCatalog; pinned Rust development oracle only.

---

Approved specification: `docs/superpowers/specs/2026-10-25-managed-child-search-async-identity-design.md`.
Baseline: `ab8f2f5d`; initial scope: #86–#89. Three independently testable work
packages follow. Use separate issue worktrees. The user approved execution and
release; AGENTS.md selects parallel work for disjoint changes. #88 precedes #87.
All BEAM commands acquire `/tmp/backplane-1.10.36-beam.lock`; tests use a source
mirror of the relevant worktree with separate build directories and pinned
standalone dependencies. Never run simultaneous Mix/devenv builds.

## Work package A: managed-child Sessions (#86)

Ownership: `codex/session.ex`, `codex/multi_agent.ex`, new
`codex/managed_child_session.ex` helper only if it keeps association checks local,
dedicated `codex_managed_child_session_test.exs`, Session and collaboration tests,
and `docs/agent-runtime/codex-tools/session-resources.md`.

### Task A1: reproduce the public attach failure

- [ ] Add an ExUnit integration using two real Sessions, unchanged
  `MultiAgent.contracts/2`, a local native `update_plan` profile, a root
  Conversation and a real manager-created child through `child_options/3`.
  Adapt the public lifecycle setup in `codex_session_lifetime_test.exs`; assert
  the child provider is reached and its update_plan call succeeds.

```elixir
assert {:ok, root_binding} = Session.bind(root_session, root_authority)
assert {:ok, child_binding} = Session.bind(child_session, child_authority,
  incarnation: child_incarnation)
assert root_binding.owner_id != child_binding.owner_id
assert_receive {:provider, :child, %{run_id: child_run_id}, child_provider}
assert child_run_id == child_binding.run_id
```

- [ ] Run the dedicated test through the locked standalone wrapper. Confirm the
  missing-adoption refusal, rather than fixture/compile failure.
- [ ] Add `Session.adopt_managed_child/3` and local association validation:

```elixir
def adopt_managed_child(binding, admission, authority) do
  GenServer.call(binding.session, {:adopt_managed_child, binding, admission, authority})
end
```

  Validate manager caller PID, exact reserved binding, run/incarnation,
  immutable manager/agent ownership, supported authority shape and semantic
  subset (tool names, revisions and binding fingerprints). Reject malformed
  data with Runtime Error values. Record/monitor the adopted manager.
- [ ] In MultiAgent, record prospective Session obligations before adoption,
  call adoption after option/authority checks and before `start_child`, and
  require the same retained Session for a successful follow-up.
- [ ] Separate root-owned manager calls from adopted child local attach/detach.
  Run the new test and existing Session lifetime/incarnation tests; commit the
  coherent admission and attach implementation after green.

### Task A2: authenticate children and retain native resources

- [ ] Add real native and bound collaboration calls from adopted children, plus
  malformed manager/agent/attempt/run/incarnation, stale binding and changed
  ancestor grant/revision cases. Verify rejection before effects.
- [ ] Extend existing manager owner authentication to match the exact current
  adopted binding and validated Session owner. Preserve root and sessionless
  child branches and current Policy checks.
- [ ] Add command, plan and Code Mode retention across successful follow-up.
  Reject a new child Session while the old retained obligation is open; permit
  a new infrastructure Session after confirmed old closure.
- [ ] Run dedicated and bound/mailbox/birth/lifecycle regression tests. Commit
  after green; do not modify Conversation unless a narrow integration gap is
  demonstrated and coordinated with work package C.

### Task A3: close all child resource obligations conservatively

- [ ] Add child close/cancel isolation, V2 target-only interrupt, V1/root recursive
  cleanup including idle children, manager/owner/Session loss after follow-up,
  and first-target-uncertain/second-target-retained tests.
- [ ] Add off-manager Session-close receipt collection to existing settlement
  workers. Fence all recursive targets, attempt all obligations, aggregate
  uncertainty, and never substitute a retained Conversation snapshot for a
  confirmed Session-close receipt.
- [ ] Use current Session PID/owner incarnation for infrastructure DOWN; use the
  full attempt/run/binding identity for run-level asynchronous notifications.
  Late notifications must not mutate a newer activation.
- [ ] Add startup/prompt/receipt/Store finish failure and lost-ack tests. Retain
  unknown obligations/reservations; never close explicitly rejected foreign
  Sessions or retry unknown effects.
- [ ] Run scoped tests and the normal-stop infrastructure regression. Document
  public child_options usage and host responsibility for unreturned/rejected
  allocations. Commit `feat(agent-runtime): support managed child sessions (fixes #86)`.

## Work package B: owner-local pinned search (#88 then #87)

Ownership: `codex/dynamic_runtime.ex`, `codex/dynamic.ex`, focused
`codex/tool_search*.ex` modules, `priv/codex/tool_search/`, CT07 and new search
tests, pinned oracle fixtures and compatibility evidence. Shared release docs
remain parent-owned until integration.

### Task B1: partition discovery (#88)

- [ ] Add the exact public two-run reproduction to `codex_ct07_test.exs` using
  a query that has no matches, so no stage callback is required:

```elixir
for run_id <- ["run-one", "run-two"] do
  operation = %{tool_name: "tool_search", run_id: run_id, incarnation: 1,
    arguments: %{"query" => "missing", "limit" => 8},
    backend_context: %{runtime: runtime}}
  assert {:ok, %{tools: [], publication: %{status: :no_matches}}} =
    DynamicRuntime.call(operation)
end
```

- [ ] Run it and observe the second-run namespace collision.
- [ ] Store a Dynamic per `{caller_identity, run_id, incarnation}`. A missing
  caller maps to private `:host_direct`; present callers must be nonempty
  binaries. Validate run/incarnation before lookup. Keep plugin state separate.
- [ ] Test caller/run/incarnation partitioning, within-owner collisions, failed
  staging rollback, correct next-turn publication, and unchanged low-level
  Dynamic collision/snapshot semantics. Run CT07; commit
  `fix(agent-runtime): isolate deferred candidates by run owner (fixes #88)`.

### Task B2: pin metadata text and tokenizer evidence (#87)

- [ ] Add description-only credential-query and empty-query regressions. Run
  them and confirm existing name-only/list-all behavior fails assertions.
- [ ] Add a standalone Rust development oracle with exact Cargo.lock versions
  from the approved Codex pin. Generate checked-in fixtures for text, tokens,
  FxHash32 identities and scores. Record crate checksums and source/licensing.
  Rust must not be needed by normal Mix tests or the published package.
- [ ] Implement focused text/token helpers using `contract.name`, named
  namespace/default description, function underscore expansion, recursive
  schema descriptions/sorted properties/items/anyOf, and custom format.syntax.
  Reject malformed optional text; exclude output/backend/credential fields.
- [ ] Vendor exact deunicode data/notices and stopwords under `priv`; port
  ASCII word boundaries, English Snowball and FxHash32 with overflow and Rust
  string hashing. Qualify text/tokens/hashes against pinned fixtures.
- [ ] Include contractions/decimals/underscores, English exceptions, accents,
  CJK, emoji, unknown Unicode, stopwords and a broad stemmer vocabulary.

### Task B3: implement ranking and publication safety

- [ ] Fit the current owner's discovered-only corpus and compute BM25 using
  per-operation f32 rounding, including this exact grouping:

```text
tf_weight = tf * (k1 + 1) / (tf + k1 * (1 - b + b * (len / avgdl)))
idf = ln(1 + (N - df + 0.5) / (df + 0.5))
score = sum(idf * tf_weight, for each occurrence of a query token)
```

- [ ] Use `k1=1.2`, `b=.75`, source avgdl conversion/fallback256, repeated
  query tokens, positive matches and canonical-name ties. Compare non-tied
  ordering and score tolerance against the oracle.
- [ ] Validate UTF-8/nonblank query and explicit positive bounded limit.
  Omitted limit remains 8 and must fit the configured bound; stopword-only
  input yields no matches. Malformed input must leave Runtime alive.
- [ ] Remove successfully staged published entries from corpus statistics;
  failed staging preserves state. Test cross-owner isolation, stale producer,
  run/incarnation/revision checks, cancellation and same-batch execution fence.
- [ ] Run search and CT07 suites; document exact generic-algorithm scope and
  retained-owner/cancellation limits. Commit
  `feat(agent-runtime): search pinned Codex tool metadata (fixes #87)`.

## Work package C: native async identity (#89)

Ownership: `conversation.ex`, `codex_control_profile_test.exs`, dedicated async
identity tests and public event documentation. Coordinate any A changes to
Conversation before editing shared regions.

### Task C1: reproduce direct and nested identity gaps

- [ ] Add a provider step with two identical async questions and one async
  message. Assert distinct invocation IDs and preserved provider call IDs:

```elixir
assert first.questions == second.questions
assert is_binary(first.invocation_id)
assert first.invocation_id != second.invocation_id
assert first.tool_call_id == "question-one"
assert second.tool_call_id == "question-two"
```

- [ ] Run the test and confirm missing identity fields fail it.
- [ ] At `{:chunk, token, event}`, enrich only the two async native event types
  from an executing current direct/nested invocation. Override payload IDs;
  reject provider/preparation/stale producers. Keep generic metadata emissions.
- [ ] Add nested Code Mode, spoofed ID, stale/cancelled callback and
  subscriber:nil cases. Verify event IDs against persisted tool invocation
  records and JSON-safe public projection. Do not add notification replay.
- [ ] Run focused control/Conversation/nested suites. Commit
  `fix(agent-runtime): correlate native async events (fixes #89)`.

## Integration and release

- [ ] Independently review each work package against the spec, then review
  code quality. Fix review findings and re-run affected checks before merge.
- [ ] Integrate issue commits into the release worktree; update CODEX,
  EMBEDDING, CHANGELOG and the approved acceptance matrix with actual evidence.
- [ ] Run the complete Runtime suite serially with `--max-cases 1`, warnings-as-
  errors compilation, scoped formatting/static checks and standalone package
  smoke. Do not repair unrelated pre-existing Credo findings.
- [ ] Merge approved/tested work into clean main, run exact-main release/CI/Hex
  contract checks, and use `scripts/set-version.sh 1.10.36 all` for versioning.
- [ ] Push authorized commits and dispatch `.github/workflows/release.yml`
  with its currently declared inputs. Wait through terminal publication.
- [ ] Verify main/tag/remote convergence, archive checksums and packaged
  BuildInfo, Hex/HexDocs, GHCR metadata, and a fresh published 1.10.36 consumer
  exercising all four request contracts and a selected backend effect.
- [ ] Close the original requests with verified release evidence, remove only
  fully integrated task worktrees/branches, and report release URL/run/status.
