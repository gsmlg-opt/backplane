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
- [x] Verify upstream 10.0.4 package publication and the consumed native-platform downloads. Record remaining third-party installation-matrix failures separately; require Backplane's exact dependency, build and installed-release qualification before publication. Do not add a local downloader workaround.
- [x] Update four Bundler/runtime minimum constraints and eight existing DuskMoon lock entries to10.0.4; preserve every other lock entry. Independent review confirmed public tarball checksums and the six repaired native callsites.
- [x] Review staged paths with git diff --check and GitNexus.detect_changes; commit coherent scoped changes with Conventional Commits and fixes #83/#84.
- [x] Run release and CI workflow contract checks on exact committed source.
- [x] Prepare isolated1.10.34 candidate with scripts/set-version.sh all, without changing reserved tag1.10.33.
- [x] Push only candidate049c5909 to remote main, require its CI, then dispatch canonical release.yml for1.10.34. The first release stopped before qualification or publication on the third-party MDExNative download described below; the repaired candidate still requires new-source CI and a fresh dispatch.
- [x] Wait for qualification, all six builds, installed migrations/HTTP smoke and GitHub publication at9504a2bf in run40070601038. The later Hex packaging failure is preserved below.
- [ ] Complete only the missing runtime Hex publication through qualified recovery, then publish Docker from9504a2bf. Verify immutable tag/source, archives/checksums, five Hex/HexDocs packages and GHCR provenance. The original canonical run remains failed; recovery must carry its own explicit source-bound evidence. No production deployment.
- [x] Update approved design/plan implementation and candidate verification state; one coherent Agent Note implementation review was captured. Final publication evidence remains pending below; do not create per-fix status notes.

## Validation and remaining release gate

- Scoped regression suite: 464 tests, zero failures across contract, Memory, Host Agent and API/channel paths. Two existing API tests exceeded their 100ms message wait on the first final run; both passed unchanged individually and in the complete same-seed rerun.
- Formatting, warnings-as-errors compilation, scoped strict Credo and Dialyzer for 14 changed modules passed with existing repository ignore rules.
- Independent spec review passed after repairing default-partition authorization drift and deletion suppression at full upsert caps. Code-quality re-review passed after fencing selected channel/generation before get pushes and making uncapped forget accumulation linear.
- Staged-path and diff checks passed. GitNexus reported no indexed changed symbols for the Elixir changes; source callers and scoped tests provide the impact evidence. All49 pre-existing dirty/untracked files retain their baseline hashes.
- Clean detached-source workflow checks at7b90b6ed passed: CI contract8 tests and release configuration26 tests. An implementation review was captured and read back in Agent Note, project=backplane, id5a647f70-2253-46f3-97fd-626ec79e7ee9.
- The full CI application matrix found directly affected fixtures outside the first focused list: Connector/Worker/Memory.Supervisor recall calls omitted the now-required query, and the Clients permission inventory omitted get. Updated only those fixture arguments and inventory assertions; all80 tests in the four affected files passed. Existing WorkerTest edits are excluded from staging.
- Exact source0166c5e2 passed all five CI jobs and all20 application Test jobs. Memory1405/0, Host Agent676/0, System519/0 and Llama610/0; unchanged Audio tests also passed. No Audio edits were needed.
- Upstream10.0.4 is published at8cf7bbe50f073c7203edd0e34c53a0193141bfc0: release40063695995 passed, all47 native archives and all nine Hex packages are available. Tests40066226848 passed public artifacts and all four published-native platform jobs, each exercising all six NIF consumers. Registry and ARM musl installation fixtures still fail on third-party lazy_html0.1.13 download/source fallback without make; upgrade was skipped. This is not a complete upstream installation-matrix pass. The approved design requires verification of the DuskMoon repair and exact Backplane release qualification, rather than unrelated upstream fixtures. Backplane's normal Linux builds already install build-essential; no downloader patch, dependency-check bypass or extra fallback is introduced.
- User instructed publication of this task only. The release candidate starts at remote main0166c5e2 in .trees/release-memory-1.10.34; five unrelated local main commits7c29755c..46c1bbe4 remain untouched and are excluded from the push.
- Isolated candidate with10.0.4 passed warnings-as-errors compilation, changed-manifest formatting, all542 scoped tests(seed214782), CI contract8/0, release configuration26/0 and Hex dependency contract5/0. Frozen npm installation and both admin/API Tailwind+JavaScript builds passed. No unrelated lock entry changed; resolved #5 TODO removed after adoption verification.
- Candidate049c5909 passed all six remote workflows: CI5/5, Test20/20, Agent Runtime2/2, AI Protocol2/2, Skill Protocol2/2 and Audio Integration2/2. Test's unchanged failed-job retry passed; no Audio source was modified.
- First formal release40068713984 checked out049c5909 but failed before qualification tests in MDExNative0.2.12's GitHub NIF download: redirect headers exceeded OTP's10240-byte limit. No tag, release, packages or image were published. Exact-version cold probes reproduced the GitHub failure and passed warnings-as-errors compilation plus native Markdown execution with the package's documented `artifact_source: :cloudflare` setting. All four consumed Linux GNU/macOS x64/arm64 archives returned200 without redirects and matched the published SHA256 map. The compile-time config selects this official distribution host; versions, artifact targets and checksum enforcement are unchanged. No downloader patch or source-build fallback is introduced.
- Configuration follow-up passed scoped formatting, forced MDExNative recompilation, umbrella warnings-as-errors compilation, native Markdown execution and CI8/0, release26/0 and Hex5/0 contracts. New-source remote CI and a fresh complete formal release remain required.
- Source9504a2bf passed new-source CI5/5, Test20/20 and Audio2/2 on their first attempt. Release40070601038 passed qualification, all six platform builds, packaged migration idempotency and HTTP asset smoke, and published all25 GitHub assets. The manifest and five report hashes bind9504a2bf; all archive sidecars and asset API digests match.
- The release then failed building the runtime Hex package inside the umbrella: its two internal protocol dependencies were classified as non-Hex. Exact-source export outside the umbrella passes Hex build and documentation generation; all101 packaged source files match9504a2bf, with both required protocol dependencies present in package metadata. Local publish dry-run reached the missing local authentication gate; no local publication occurred. Plugin/AI/Skill/MCP1.10.34 packages and versioned documentation already exist, including MCP whose job was cancelled after publication. Only runtime remains missing; Docker did not run.
- Repair only publication orchestration: stage runtime source outside the umbrella for normal and qualified publication; preserve the normal release's controlled version transformation. Qualified recovery can select runtime alone and reuses the existing original-run qualification verifier. Keep tagv1.10.34 and product/package source at9504a2bf; publish only the missing package, then the same-source Docker image. Do not republish four existing packages, retag, or substitute a newer product revision. Final verification must report the original failure and successful recovery separately.
