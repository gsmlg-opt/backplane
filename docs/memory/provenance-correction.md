# Direct Memory browsing and source provenance

## Scope and review baseline

The authoritative attached correction requires Memory to open without host, project, space, client, scope, or namespace setup. Host and repository identify sources and optional filters, not authorization. The checkout was inspected at `c7044093f0aedcb97434a0c0caba03b864c99bb3` on branch `codex/memory-local-live-acceptance`; substantial earlier uncommitted Memory work is retained.

The reviewed mandatory `exact_partition/1` gate was present in the inspected baseline. The screenshot's host/project picker and unavailable-selection wording were also found in local uncommitted operator components and hook code. This established the inappropriate dependency in that checkout, not the cause of an unobserved deployed database failure. The committed correction removes this prerequisite from trusted admin browsing while retaining optional source filters.

## Verification and delivery

The pre-correction read-only dev inventory contains 205 memories in two distinct host-associated spaces, including 17 tombstones. A separate content-free history baseline records fingerprints of all 205 memory rows (excluding embeddings and read counters) and 710 evidence rows. Private artifacts are `.devenv/provenance-correction/canonical-before.json` and `history-before.json`. The earlier 203-row baseline also compared unchanged before this correction. After the source implementation and focused tests, the live database still has exactly 205 memory rows and 710 evidence rows: no baseline IDs are missing and no protected row fingerprints changed (`history-after-source.json`). The later local runtime check is recorded below and separately verifies preservation after synthetic writes and cleanup.

## Source representation and compatibility

```mermaid
flowchart LR
  Admin[Trusted admin inventory] --> Query[One filtered SQL collection query]
  Query --> Spaces[Existing canonical spaces]
  Public[Public MCP / REST] --> Auth[Existing credential authorization]
  Auth --> Target[Authorized canonical target]
  Host[Host capture or explicit write] --> Git[Local Git discovery]
  Git --> Payload[Additive source metadata]
  Payload --> Ingress[Authenticated canonical ingress]
  Ingress --> Evidence[Stored memory and evidence]
  Evidence --> Derived[Derived source associations]
  Derived --> Recall[Recall output and admin details]
```

New source attribution uses the additive `repository_sources` array in existing event payloads and memory metadata. Each association describes `repository_id`, `checkout_root`, and `cwd` when available; multiple evidence sources are retained instead of inventing one origin. Historical `project` values remain unchanged. Repository identity is obtained locally from Git context at the supplied capture/write directory, not from the service process's working directory. Historical imports do not rediscover today's remote and rewrite old provenance.

Memory detail renders every stored repository association with its checkout root and working directory, including distinct paths for the same repository. Missing repository identities remain explicitly unresolved; historical project text is shown separately. HEEx escapes source values. Inventory rows retain their compact source display. This presentation reads existing metadata without rewriting historical records or changing authorization.

Remote normalization and source validation are pure shared transformations; Git execution belongs to the host boundary. Remote selection uses `origin` when present, otherwise the sole configured remote; multiple remotes without `origin` remain unresolved. Standard SSH/HTTPS spellings normalize to the same credential-free `host/path` identifier. Case-sensitive repository paths, distinct servers and nonstandard ports remain distinct; raw local/relative remotes never become repository identities. Missing Git/remotes/non-Git paths remain valid sources without a fabricated remote identity. Admin source filtering is additive and does not create a new public recall API or change credential authorization.

No storage-space merge, ownership backfill, table recreation, or mandatory host configuration is part of this correction. New provenance is additive JSON metadata and requires no schema migration or historical backfill. The compatibility prerequisite uses upstream `phoenix_socket_client` 0.8.8 and its exact HTTP transport closure, removing the old direct transport override; upstream issues #98 and #107 are closed.

## Current delivery status

The compatibility prerequisite and initial correction are committed as `55dde54f` and `a9879ac0`, integrated with remote main at `d8151295`. This follow-up repairs the detail presentation and removes two obsolete operator-view branches. Follow-up verification and release qualification remain separate from the initial committed implementation.

Local root-checkout evidence (2026-10-21):

- Contract 4/0 and host 93/0 from the source implementation; final domain 139/0, Inventory 6/0 and Admin 120/0. Both changed owning apps passed test-environment warnings-as-errors compilation; scoped formatting/whitespace checks passed.
- Supported gateway and both local hosts restarted. Playwright opened `/memory` plus 15 ordinary tabs without query parameters: all HTTP 200, connected LiveViews, no setup gates or page JavaScript errors. Default total 188 matched SQL before synthetic writes.
- Two local hosts wrote distinct memories from two worktree/checkout paths of one offline synthetic Git repository. Canonical rows retained the same normalized repository ID, distinct paths and authenticated host IDs in separate existing spaces. Duplicate requests kept the same request identity.
- Browser checks matched global newest/oldest SQL order, totals, pagination/back, cross-host search, combined host/repository filters, clear filters, native filter submission and detail refresh. Stopping host B left its existing and new durable memories visible.
- Detail host/repository attribution rendered, but checkout/cwd paths were hidden when a repository ID was present. The browser assertion reproduced this remaining acceptance gap; the full browser inventory run therefore exited 1, not passed.
- Own synthetic records were tombstoned through supported host APIs; no historical rows were manually changed. The final fingerprint comparison preserved all original 205 memories and 710 evidence rows unchanged. Exactly two new memory/evidence rows remain from the synthetic checks. Host B returned to its original configuration and the owned relay stopped.

The coordinated follow-up local run cold-started the gateway and two hosts, then passed cross-host writes/idempotency, global inventory/search/order/pagination/source filters, detail checkout/cwd visibility, all 16 direct pages, and durable visibility with host B offline. Both hosts were restored and the two new records tombstoned through supported APIs. All 207 pre-run memory and 712 evidence fingerprints remained unchanged; the final totals were 209/714. Evidence is under `.devenv/provenance-correction/resumed-72/`: `browser/inventory-report.json`, `browser/direct/report.json`, `browser/offline-report.json`, `live-sources.json`, `cleanup-report.json`, and `runtime-integrity.json`. Root-only compatibility work supported that cold start; this does not establish installed-release migration compatibility or cross-machine acceptance. The bounded root source verification separately passed 34 focused tests, owning warnings-as-errors compilation, formatting, and raw Dialyzer closure analysis over 13 BEAMs without diagnostics (`task72-astra3-{tests,admin-compile,format,dialyzer-closure-raw}.log`).

An independent detached delivery worktree at the review baseline contained the correction, excluding unfinished shared-access/consolidation/stage/revision features. Its isolated focused checks passed: Contract 4/0, Memory 120/0, Host 38/0 and Admin 90/0 (252 tests total). Test-environment warnings-as-errors compilation passed for memory_contract, memory, host_agent and admin; scoped formatting passed for 55 files and whitespace checks passed. Admin test logs include asynchronous GeneratedSkills sandbox teardown warnings despite exit 0 and zero test failures; these are not evidence that the complete repository gate passed. Root runtime evidence and isolated artifact checks remain distinct. The subsequent authorized detail repair was extracted into a detached follow-up worktree at `d8151295`. On a fresh `_task77_delivery` test database, schema creation/migration and the three focused Admin suites passed (21 tests, zero failures). Owning Admin force compilation with warnings as errors, formatting of the seven changed source/test files, and whitespace checks passed. Logs are retained at `.devenv/provenance-correction/task77-delivery/{schema,tests,admin-compile,format}.log`. These tests cover all stored path associations, unresolved and escaped historical values, and filter error/clear/recovery behavior. The original failed browser run above remains historical evidence. The existing release workflow requires dispatch from `main`, immutable-SHA qualification and installed-release migration artifacts. Earlier L13/L18 acceptance and the baseline-proven router Dialyzer failures are separate retained limitations; none is reported as passing or waived by this correction.
