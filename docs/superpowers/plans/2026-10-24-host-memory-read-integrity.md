# Host Memory Read Integrity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Implement approved internal requests #83/#84 and qualify release 1.10.34 after the upstream native-download fix is published and verified.

**Architecture:** Keep the existing contract, authenticated Service, partition, Access ticket, MemoryFacade and Store boundaries. Filter candidates before caps and pagination, reject filters that cannot be faithfully represented, and retrieve exact canonical records online through the same authenticated path on HTTP and MCP.

**Tech Stack:** Elixir/OTP, ExUnit, Ecto/PostgreSQL, host Turso mirror, Plug/Gaoxy, GitHub Actions.

The user approved `docs/superpowers/specs/2026-10-24-host-memory-read-integrity-design.md` and direct work on main. Independent file ownership below permits parallel implementation; the coordinator alone runs Mix/Devenv, stages, commits and publishes. Preserve the baseline dirty files recorded under `/tmp/backplane-1.10.34-internal-requests-ur2c91tz`.

## Task 1: Shared contracts and canonical exact read

**Owner:** canonical-get implementation worker.

**Files:**
- Modify `apps/backplane_memory_contract/lib/backplane/memory_tool_contract.ex` and its test.
- Create `apps/backplane_memory_contract/lib/backplane/memory_read_request.ex` and its test.
- Modify `apps/backplane_memory/lib/backplane/memory/service.ex`, `memories.ex` and their scoped tests.
- Modify `authorization.ex` only if needed to admit get without the mutator creator restriction.

- [x] Add regression tests asserting the get schema rejects raw authority and unknown keys, metadata is canonical/online, and permission is memory.read.

```elixir
assert {:ok, %{"backplane" => %{"availability" => "online", "consistency" => "canonical"}}} =
         Backplane.MemoryToolContract.metadata("memory::get")
assert {:ok, "memory.read"} = Backplane.MemoryToolContract.permission("memory::get")
```

- [x] Add pure `MemoryReadRequest.validate(method, args)` returning `{:ok, normalized_args}` or `{:error, :invalid_arguments}` for recall/list/get. Validate user keys before trusted injection; normalize project with NFC, whitespace folding, trim and 1024-byte bound. Validate exact-read UUID/source constraints using MemoryRepository; expose `normalize_project/1` returning `{:ok, normalized_or_nil}` or the same error.
- [x] The coordinator runs contract regressions to demonstrate failure before implementation, then reruns the same tests after changes.
- [x] Add a dedicated canonical public point-read query with partition, deletion, expiry, lifecycle and same-association source predicates; preserve internal get/2.
- [x] Add get to Service, including shared calls and final authority revalidation. Return complete content and actual provenance in the approved canonical envelope. Reject unsupported legacy recall constraints explicitly.

```elixir
assert {:error, :not_found} = Service.call("memory::get", %{"id" => deleted_id}, auth)
assert {:error, :not_found} = Service.call("memory::get", %{"id" => other_partition_id}, auth)
```

- [x] Add domain tests for shared cross-creator access, project/source matching, non-memory IDs, expiry, deletion, lifecycle and authority revocation. Return test commands and exact changed paths for review.

## Task 2: Offline and online filtering

**Owner:** filter implementation worker.

**Files:**
- Modify `apps/backplane_host_agent/lib/backplane/host_agent/memory_facade.ex`.
- Modify `apps/backplane_host_agent/lib/backplane/host_agent/memory.ex`.
- Modify `apps/backplane_host_agent/lib/backplane/host_agent/memory/mirror/store.ex` and mirror entry point only if required.
- Modify their focused tests or add `memory/read_filters_test.exs`.

- [x] Add a regression with two projects containing the same query and more than 100 newer nonmatching entries. Assert every returned collection remains within the project filter and matching older entries survive candidate caps.
- [x] The coordinator runs the new regression before implementation.
- [x] Call MemoryReadRequest.validate/2 after authority checks and before trusted partition injection. Route agent identity remains context, rather than an implicit user filter.
- [x] Apply project/type/tag/q/default-working predicates during candidate selection, before caps/limit/offset across private/shared pending, acknowledged and mirror results. Keep pending forget suppression independent.
- [x] Reject unrepresentable fallback constraints using `{:error, {:unsupported_filter, fields}}`, where fields is a sorted list of content-free names. Preserve transport-only fallback and existing private provisional-only pagination.
- [x] For online unrepresentable constraints, check otherwise-eligible upserts before caps; return unsupported_filter when they would be composed. Otherwise retain canonical constrained results and forget suppression.
- [x] Test canonical errors without fallback, supported type/tag/plain-q selection, unsupported wildcards/offset/agent/facets/ranking, default working exclusion, shared/private and online/offline paths.
- [x] Hand facade ownership to coordinator for exact-get integration after worker edits finish.

## Task 3: Host, channel and HTTP integration

**Owner:** coordinator; facade edits wait for Task 2 handoff.

**Files:**
- Modify `apps/backplane_host_agent/lib/backplane/host_agent/services/memory.ex`, `memory_proxy.ex`, `memory_router.ex`.
- Integrate get in `memory_facade.ex` after Task 2.
- Modify `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex` and `apps/backplane_memory/lib/backplane/memory/router.ex`.
- Add scoped service/router/proxy/facade/channel tests; change Access only if a test proves it necessary.

- [x] Add tests proving direct and MCP get return identical full content, and outage calls no local/mirror/HubProxy adapter.

```elixir
assert {:error, :canonical_unavailable} = MemoryFacade.call("get", %{"id" => id}, context)
refute_received {:local_read, _}
refute_received {:hub_call, _}
```

- [x] Add get to the host facade/service and proxy method allowlists. Disable agent_id injection for get. Select shared/private authority through existing Access requests and revalidate before returning.
- [x] Convert the fully encoded reply envelope over 524288 bytes to payload_too_large before Access.finish_request; prove a subsequent valid read still succeeds.
- [x] Map recognized old-server unknown method/tool errors to unsupported_operation; transport outages to canonical_unavailable. Preserve other canonical errors.
- [x] Route gateway point reads through Service. For new get map not_found404, unauthorized403, canonical_unavailable503, invalid_arguments/unsupported_filter400, payload_too_large413 and unsupported_operation501; keep MCP classifications consistent.
- [x] Run focused integration tests, then spec-compliance review, followed by code-quality review and repair any findings.

## Task 4: Verification, upstream adoption and release

**Owner:** coordinator; read-only release investigation can be delegated.

- [x] Run tests for changed contract, Memory domain, Host Agent and API/channel paths in serialized Devenv commands. Run scoped format, compile warnings-as-errors, Credo and relevant type checks.
- [ ] Verify upstream 10.0.4 complete package publication and published installation matrix before adopting it. If unavailable, finish unblocked source work and report the release dependency without a local workaround.
- [ ] Update both Bundler minimum constraints and eight existing DuskMoon lock entries only after the gate; preserve unrelated lock edits.
- [x] Review staged paths with git diff --check and GitNexus.detect_changes; commit coherent scoped changes with Conventional Commits and fixes #83/#84.
- [ ] Run release and CI workflow contract checks on exact committed source.
- [ ] After the dependency gate, use scripts/set-version.sh and canonical release.yml for 1.10.34 without changing reserved tag1.10.33.
- [ ] Wait for qualification, all builds, installed smoke and all publication jobs. Verify tag/main source convergence, archives/checksums, five Hex/HexDocs packages and GHCR provenance. No production deployment.
- [ ] Update approved design/plan completion state and evaluate one coherent Agent Note implementation review after validation; do not create per-fix status notes.

## Validation and remaining release gate

- Scoped regression suite: 464 tests, zero failures across contract, Memory, Host Agent and API/channel paths. Two existing API tests exceeded their 100ms message wait on the first final run; both passed unchanged individually and in the complete same-seed rerun.
- Formatting, warnings-as-errors compilation, scoped strict Credo and Dialyzer for 14 changed modules passed with existing repository ignore rules.
- Independent spec review passed after repairing default-partition authorization drift and deletion suppression at full upsert caps. Code-quality re-review passed after fencing selected channel/generation before get pushes and making uncapped forget accumulation linear.
- Staged-path and diff checks passed. GitNexus reported no indexed changed symbols for the Elixir changes; source callers and scoped tests provide the impact evidence. All49 pre-existing dirty/untracked files retain their baseline hashes.
- Upstream readiness checked at 2026-10-24 04:53 UTC: formal10.0.4 release run40063695995 is building native packages; latest published release remains10.0.3, all eight required10.0.4 Hex releases are absent and published installation qualification is incomplete. No dependency workaround or Backplane release dispatch.
