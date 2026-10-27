# Internal requests #120–#126 and release 1.10.44

Date: 2026-10-27

Status: approved by the user at design commit `7d82bdb3` and implemented on main
for release 1.10.44. Local integrated verification is complete. Exact-source CI,
remaining native platforms and publication are separate delivery gates.

## Frozen batch and baseline

The user requests fixes on the current `main` followed by the next release.
The live snapshot contains these seven open `internal request` issues, none
labelled `unable to resolve`, and no open issue-fix PRs:

| Issue | Problem and proposed outcome |
| --- | --- |
| [#120](https://github.com/gsmlg-opt/backplane/issues/120) | Replace MCP Protocol's mandatory Finch path with the existing published Fetch client; a real standalone server consumer has no Finch/Mint dependency |
| [#121](https://github.com/gsmlg-opt/backplane/issues/121) | Select a finite tool budget from the final invocation through trusted hooks; direct/nested backends share a live remaining deadline |
| [#122](https://github.com/gsmlg-opt/backplane/issues/122) | Retain bounded per-connection Plugin Session close evidence, including failed activation cleanup and verified stdio child/helper termination |
| [#123](https://github.com/gsmlg-opt/backplane/issues/123) | Add acknowledged caller-owned asynchronous resource list/template/read handles using the current native request lifecycle |
| [#124](https://github.com/gsmlg-opt/backplane/issues/124) | Add an explicit host-verified plugin completion variant without changing legacy requested results |
| [#125](https://github.com/gsmlg-opt/backplane/issues/125) | Accept an explicit Web answer/citations success branch with the current whole-result bound |
| [#126](https://github.com/gsmlg-opt/backplane/issues/126) | Preserve all already-supported bounded JSON message metadata through child export/restore and authoritative history verification |

The initial checkout is clean `main` at
`fd31834b178e40a0ee335fc9c2872fa6dd8182ce`, equal to the live remote main and
`v1.10.43`. Release workflow
[40423914769](https://github.com/gsmlg-opt/backplane/actions/runs/40423914769)
completed successfully; the official latest GitHub release is
[v1.10.43](https://github.com/gsmlg-opt/backplane/releases/tag/v1.10.43).
All five official Hex packages also report latest 1.10.43 and have no 1.10.44
release. Remote `v1.10.44` is absent at design time. Verify package versions and
availability again before dispatch; do not reserve an already published version
or republish one with different source.

Source manifests currently contain 1.10.38. The existing release workflow stamps
all selected manifests, examples and Memory integration manifests in its build
checkouts using `scripts/set-version.sh`; the source tag still points to the
gated main commit. Derive the next release from actual publication, not the older
checked-in build template, and preserve the current workflow's provenance checks.

New issues arriving after this snapshot are a later batch unless the user
explicitly expands it. Preserve unrelated edits and commits. This design does
not authorize new branches/worktrees, downstream source edits, deployment,
managed-process restart or unrelated Memory changes.

## Complete contracts and recommended decisions

The following documents form this design, rather than independent partial
approvals. Their public contracts, alternatives, ownership, failure paths, file
scope and verification requirements apply together:

1. [MCP ownership and cleanup](2026-10-27-mcp-ownership-and-cleanup-design.md)
   covers #120/#122/#123. Reuse `http_fetch` 0.21.17 and its request-completion
   barriers. Extend the existing caller-owned request machinery with dedicated
   resource handles. Keep Plugin Session alive to retain per-activation close
   outcomes, including partial failures. Use a package-owned, explicitly built
   POSIX stdio guardian and one-shot plugin connections. Confirmation covers the
   exact direct child, guardian and local pipe scope; daemonized descendants and
   remote effects need separate host ownership. Verified plugin stdio requires
   the helper and supports Linux/macOS; ordinary direct Client STDIO remains.
2. [Tool deadlines and message archives](2026-10-27-tool-deadlines-and-message-archive-design.md)
   covers #121/#126. An optional trusted `ConversationAdapter` callback selects
   one finite budget after final preparation and approval, before intent and
   dispatch. Direct and supported nested paths share enforcement, enclosing
   deadline clipping and human-wait suspension. A token-fenced getter exposes the
   live accepted deadline. Only selected tool budgets gain the separate maximum
   of 2,147,483,647 ms; unrelated timeout options and low-level `Execution.run/5`
   remain unchanged. Archive message metadata retains supported JSON values;
   outer schemas, Evidence bounds, digest and Store equality checks stay.
3. [Plugin completion and Web answers](2026-10-27-plugin-completion-and-web-answer-design.md)
   covers #124/#125. Explicit `{:ok, {:completed, fields}}` carries verified
   installation fields and the original receipt ID to the native settlement.
   Legacy maps/lists remain requested; uncertainty never becomes completion.
   Explicit answer maps retain content, ordered citations and metadata under
   the existing whole-map result-size metric. Neither feature adds a provider,
   installer scheduler, automatic tool grant or new dispatch path.

The alternatives are documented in each contract. The recommended composition
keeps lifecycle authority in the existing owning packages. A second host scheduler,
global cancellation, dummy results rows, silently promoted completion maps or
metadata stripping would change the reported semantics and is not selected.

## Implementation order and integration ownership

After approval, write a scoped implementation plan using these exact contracts.
Parallel work may use only disjoint files in the current checkout; the
coordinator serializes Git changes, manifests/lockfiles and shared build state.

Implement MCP dependency/HTTP lifecycle changes before integrating Plugin MCP
close, and add resource handles on the existing common owned-request machinery.
Implement verified stdio before claiming the default adapter's stdio close is
confirmed. Plugin completion/Web normalizers and archive metadata are independent
bounded slices; Conversation deadline selection owns its own preparation and
dispatch changes. Integrate the Plugin Session retained reports only after the
underlying adapter receipt contracts are available.

Allowed production writes are restricted to the two owning packages and their
necessary package/build integration, as listed in the component designs. Shared
release writes include required package verification scripts, CI/release/Docker
helper-build integration and their contract tests, documentation and scoped
changelog/version metadata. Lockfile changes must be justified by the actual
dependency change; already resolved Fetch packages need no unrelated refresh.
Do not change Runtime/Store authority, ResourceRegistry success classification,
provider policy, protocol fallback or generic timeout semantics to simplify a fix.

Document implementation corrections in the coherent final design/review. Do not
turn unexecuted acceptance criteria into completion claims. If an owned upstream
dependency is a confirmed blocker, route it through `upstream-issue-routing` and
stop only the blocked path; do not implement a local workaround or silently
remove a release acceptance requirement.

## Verification and delivery gates

First reproduce the reported failures where feasible and add meaningful owning
package regressions. Use ordinary local HTTP/provider/package fixtures and real
managed processes. Do not advertise these as real-provider or downstream
production acceptance. Verify all component acceptance criteria, including:

- A fresh server dependency/application graph without Finch/Mint and an actual
  protocol request; source grep or an umbrella build is insufficient.
- Two caller-owned resource requests on one live client, bounded registration,
  ordinary pagination/read fidelity, observation timeout, cancellation and owner
  exit without connection/global cancellation.
- Mixed plugin cleanup results, retained failed-catalog obligations, responsive
  status during blocked calls, no automatic cleanup replay and real stdio target
  reap plus helper exit. Native Linux/macOS package builds and executable probes
  must identify the platforms actually executed.
- Final-input budget selection, real timer admission for large finite values,
  enclosing run/outer clipping, live pause/resume and cancellation evidence.
- Direct/real-Deno native completion and answer results, next-model input,
  persisted journal fidelity and exact settled replay without repeating effects.
- Real child settlement/closure/reconciliation and metadata-preserving archive
  restore, followed by explicit new-run continuation. Independent cold-BEAM
  evidence must prove retained history/digest and no Provider/tool replay.

Run focused checks before the owning suites. Complete the existing mandatory
strict compile, format, Credo, Dialyzer, workflow/release contracts and package
verification. Serialize Mix/devenv work; use task-owned fixtures/databases if a
database is needed. Record out-of-scope failures without repairing or weakening
them. Local toolchain findings must be checked against the actual CI compiler
before attributing them to product code. Required exact-source remote CI must
pass before publication.

Audit every scoped commit. Before pushing or releasing, compare the actual
release commit range with the frozen scope and the remote main; do not publish
new unrelated local commits. Do not reset/rebase someone else's work or force a
tag to recover a release. Commit/push and the release itself are already
requested; routine in-scope delivery needs no repeated permission after design
approval.

Use the current `.github/workflows/release.yml` from main:

```sh
gh workflow run release.yml --ref main -f version=1.10.44 -f release_apps=all
```

Recheck the current declared inputs and free target version first. The workflow
currently accepts `version` and `release_apps`; it does not accept `git_ref`.
Wait for every qualification, build, publication, Hex, Docker and final release
page job. A tag or partially visible release is not a successful publication.

Verify the tag/gated SHA, GitHub archives/checksums and embedded build provenance,
all five official Hex packages and HexDocs, fresh official-package contract
fixtures including extracted helper builds, and GHCR version/latest metadata.
Inspect final local/remote main convergence without disturbing unrelated work.
Report implemented, source-verified, published and downstream/deployed states
separately. Close/label issues only with accurate scoped evidence; the invoked
internal-request skill authorizes those issue operations.

## Implementation review and local evidence

MCP Protocol now owns Fetch requests through `HTTP.Lifecycle`, including original
completion handles, body workers, redirect hops and bounded close evidence. Only
records with both successful original completion barriers and actual worker DOWN
are compacted; unresolved obligations remain individually visible. Aggregate and
cleanup-worker identities retain their activation and satisfy the unchanged
Runtime report validator. `Client.OwnedRequest` shares logical request custody
between the existing ToolCall and new ResourceRequest facades. Raw timeout values
are validated before constructing the positive-budget Operation value.

`Client.Connection` fences admission and coordinates transport, client workers
and supervisor retirement within one budget. Plugin Session records activation
before allocation and retains failed catalog and close outcomes for observation.
The explicitly built guardian frames target bytes separately from control data,
reaps only its direct child, and requires both its receipt and actual helper exit
before confirmation. Missing evidence remains unknown; neither supervisor DOWN
nor a late successful tool response replaces a cleanup receipt.

Conversation selects a budget after final input approval and before intent ACK,
then owns the armed timer and token-fenced live deadline. Native plugin completion
uses the original request receipt and verified host fields; ordinary host maps
remain requested. Existing Web result lists retain precedence over the new answer
branch. Child archives preserve normalized bounded message metadata while keeping
outer schemas, authoritative Store equality and digest verification intact.

Local Linux x86_64 evidence includes 1,143 Runtime tests, 33 MCP doctests and 1,481
MCP tests, extracted Runtime/MCP package builds, 13 native guardian protocol tests,
real Deno output and separate producer/consumer BEAM recovery checks. Targeted
regressions also passed after the final identity and static-analysis corrections.
The exact general-CI Elixir 1.19.5 / OTP 28.5.0.5 toolchain passed strict compile,
format, Credo and Dialyzer; workflow, release and Hex-dependency contracts passed.
The local development package checks used Elixir 1.18.5 / OTP 28.5.0.8.

macOS and ARM acceptance must come from the native CI matrix. The release must
still verify all five official Hex/HexDocs packages, fresh registry consumers,
GitHub archive checksums and embedded provenance, and GHCR version/latest metadata.
These checks establish no production deployment or downstream adoption.

## Approval boundary

The user approved these concrete contracts at `7d82bdb3`, including the native
Linux/macOS stdio build requirement and the direct-child/helper/local-pipe scope.
The approval authorizes implementation, verification and release 1.10.44 on main
within these boundaries. It does not authorize unrelated repairs, downstream
adoption or deployment.
