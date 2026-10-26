# Internal requests #115–#119 and next release

Date: 2026-10-27

Status: proposed feature designs awaiting user approval. #118 is implemented and
locally verified; publication has not started. Planned version: 1.10.43, subject
to verifying that it is still the next unpublished version before dispatch.

## Frozen scope

| Issue | Change | State |
| --- | --- | --- |
| [#115](https://github.com/gsmlg-opt/backplane/issues/115) | First-party Linux PTY within the existing native command lifecycle | Proposed design |
| [#116](https://github.com/gsmlg-opt/backplane/issues/116) | Canonical inline user PDFs for Anthropic and Google | Proposed design |
| [#117](https://github.com/gsmlg-opt/backplane/issues/117) | Restore settled archived child identity/history, then explicitly follow up | Proposed design |
| [#118](https://github.com/gsmlg-opt/backplane/issues/118) | Treat a procfs ESRCH entry as vanished while continuing group reconciliation | Implemented locally in `bded83d2` |
| [#119](https://github.com/gsmlg-opt/backplane/issues/119) | Reconcile failed child, manager, Registry and Session closure from exact evidence | Proposed design |

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

## Delivery boundary

Work remains on the current `main`; create no branch or Git worktree. Preserve
and exclude the unrelated unpublished Memory commit `793cd3cf`. Remote main also
contains an independent already published documentation commit `48f6303d`.
Do not push local whole history and accidentally publish Memory. Construct and
audit the scoped publication against actual remote main, preserving existing local
history, then run CI on that exact intended release source.

After approved implementation, complete focused tests, required package/workflow
contracts and CI. Use canonical `.github/workflows/release.yml` from main with the
available version and `release_apps=all`. Wait for every downstream publication
job; verify official GitHub assets/checksums/provenance, all five Hex packages and
HexDocs, fresh official-package behavior and GHCR metadata. Report publication
separately from deployment and downstream production acceptance.
