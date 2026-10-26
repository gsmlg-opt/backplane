# Internal requests #115–#119 and next release

Date: 2026-10-27

Status: approved features and minimum release-validation corrections implemented
and independently reviewed. The complete local runtime package verifier passes,
including 1107 runtime tests, 216 Conversation tests, native PTY consumers and the
real Sigma source probe. The AI protocol suite passes 191 tests; Memory edge
qualification passes 10 tests and the Events Store regressions pass 19 tests.
Planned version: 1.10.43, rechecked as the next unpublished version on 2026-10-27.
Exact-source remote CI and official publication remain delivery gates; no release
has been dispatched.

## Frozen scope

| Issue | Change | State |
| --- | --- | --- |
| [#115](https://github.com/gsmlg-opt/backplane/issues/115) | First-party Linux PTY within the existing native command lifecycle | Implemented; publication pending |
| [#116](https://github.com/gsmlg-opt/backplane/issues/116) | Canonical inline user PDFs for Anthropic and Google | Implemented; publication pending |
| [#117](https://github.com/gsmlg-opt/backplane/issues/117) | Restore settled archived child identity/history, then explicitly follow up | Implemented; publication pending |
| [#118](https://github.com/gsmlg-opt/backplane/issues/118) | Treat a procfs ESRCH entry as vanished while continuing group reconciliation | Published baseline commit `d9d2f539` |
| [#119](https://github.com/gsmlg-opt/backplane/issues/119) | Reconcile failed child, manager, Registry and Session closure from exact evidence | Implemented; publication pending |

New requests arriving after this snapshot are outside the batch. Implementation
stays in the owning runtime and AI protocol packages with necessary package,
documentation and release-build integration. No downstream application changes,
deployment or managed-service restart is included.

## Designs and proposed decisions

1. [Linux PTY](2026-10-27-linux-pty-design.md): opt-in `LocalCommand` transport,
   explicitly built C Port helper, Linux 5.3+/verified pidfd support, default
   24x80 terminal. A broker/guardian owns ordinary terminal-session job-control
   groups. Normal cancellation/Session close requires actual full cleanup proof;
   lost helper evidence remains uncertain. Existing pipe behavior and schemas stay.
2. [Inline PDF](2026-10-27-inline-pdf-design.md): existing exact resource
   `uri`/`mime_type`/base64 `data`, user role only, Anthropic document and Google
   inlineData. URI is preserved as canonical identity and not transmitted in
   inline source blocks. Reject unrepresentable metadata, propagate caller limits,
   keep global defaults, and cap decoded bytes at 10 MiB per document with a
   caller-bounded aggregate PDF collection. Provider/model selection stays host-owned.
3. [Archived child and closure reconciliation](2026-10-27-archived-child-reconciliation-design.md):
   opt-in trusted host adapter, sealed ownership inventories and CAS-persisted
   closure/retirement receipts. Preserve historical unknown outcomes and permanently
   closed Sessions. Archive import executes nothing; later followup uses fresh
   admission, run IDs and bindings. Stable root/scope and manager-qualified run IDs
   prevent restart collisions. Version 1 refuses unknown-outcome continuation and
   requires archived ancestors to receive fresh admission before descendant work.

The individual documents define alternatives, exact API/data contracts, failure
handling, allowed writes and acceptance checks. Approval selects these concrete
boundaries and authorizes implementation followed by the already requested release.

## Completed #118 verification

The deterministic procfs regression first produced 3 expected failures out of
9 tests. With the correction, explicit LocalCommand/procfs/bootstrap and Session
lifetime file lists passed 41 tests. Managed-child Session and MultiAgent closure
files passed another 30 tests. Total: 71 tests, zero failures. Scoped formatting,
warnings-as-errors compilation, Credo and final diff review passed. The extracted
helper preserves existing parsing/read-error behavior and adds no public backend
configuration or timeout change.

These are source-checkout checks, not whole-repository CI, official-package
acceptance or downstream Sigma acceptance. Those gates follow implementation.

## Integrated verification and remaining gates

Source checks passed for warnings-as-errors development and production
compilation, full strict Credo and Dialyzer under the exact CI compiler, workflow
contracts, release configuration, all six Docker build
contract tests and the final integrated diff. A locally assembled gateway OTP
release contains exactly one runtime PTY helper and its capability probe succeeds.
Genuine independent-BEAM recovery is
documented in [cold recovery verification](../plans/2026-10-27-cold-recovery-verification.md).
These checks do not establish official publication or ARM execution.

The user subsequently authorized the minimum release-validation corrections:
align stale Memory qualification fixtures with current access/command contracts,
preserve behavior while clearing Credo and production compiler findings, and
refresh the in-repository Sigma source consumer. This authorizes no new Memory
feature, downstream edit, deployment or service restart. The existing CI compiler
already passes formatting; no formatting-only Memory edit is needed.

The Memory qualification fixtures now use the actual Access owners, explicit
offline leases, persistent command settlement and current immutable ACK/delta
contracts. They retain real server transfers, denial and convergence assertions.
The Events Store change only moves an unchanged metadata predicate before its
conditional; full strict Credo passes. Production protection callers use an
explicit development capability which is always false in production. Strict
production compilation and 62 relevant host-agent regressions pass without
changing protection policy.

The in-repository Sigma probe compiles 17 selected current provider/tool sources
and exercises native tool construction plus a two-turn Conversation using the
actual extracted AI Protocol package. The complete package verifier passes with
this probe enabled. The selected inputs in the dirty sibling Sigma checkout at
`f30be139cade36a2cb70af32e99a0a67203b425e` remain unchanged across verification.
This proves local source compatibility, not Sigma production acceptance. No
downstream source change or skipped failure is part of the repair.

An additional local whole-API run reports 298 tests and three failures outside
the changed paths: the pinned OpenAI audio SDK is absent, and two audio deadline
tests time out before provider dispatch. The unchanged audio pipeline performs
its media capability probes before dispatch and does not use the modified
Runtime or AI codec paths. No audio repair or relaxed assertion is included.
Exact-source remote API CI, which provisions its own media tools and pinned SDK,
must pass before publication.

Local Dialyzer uses Elixir 1.18.5 and reports supervised-Task opaque-reference
warnings, including the new reconciliation callsite. The existing CI compiler is
Elixir 1.19.5, whose Task reference construction addresses that toolchain boundary.
The isolated reproduction has one warning under local 1.18.5 and none under CI's
exact 1.19.5/OTP 28.5.0.5 pair; both execute correctly. Full-project Dialyzer also
passes under that exact CI pair with the existing ignore file unchanged. No
runtime workaround or warning suppression is part of this change.
The current full-project format check also passes with that exact pair; the
local 1.18.5 acceptance-file formatting difference requires no source change.

## Delivery boundary

Work remains on the current `main`; create no branch or Git worktree. At design
time the unrelated Memory commit `793cd3cf` was unpublished and excluded from
this task. Before approved execution, an independent task rebased and published
that work as `dd7813d2`, together with equivalent #118/design commits `d9d2f539`
and `d153846a`. The current checkout and actual remote main now agree at
`d153846a`; this task did not perform that rebase/publication. Preserve this
already published baseline. Memory feature changes remain outside the implementation scope.
Audit each new scoped commit and qualify the exact intended release source.

The later scope approval includes only the release-validation corrections above.
The published Memory baseline is retained; no unrelated commits are republished
or removed. A task-owned migrated test database is used for local qualification,
leaving the existing shared test database unchanged.

After approved implementation, complete focused tests, required package/workflow
contracts and CI. Use canonical `.github/workflows/release.yml` from main with the
available version and `release_apps=all`. Wait for every downstream publication
job; verify official GitHub assets/checksums/provenance, all five Hex packages and
HexDocs, fresh official-package behavior and GHCR metadata. Report publication
separately from deployment and downstream production acceptance.
