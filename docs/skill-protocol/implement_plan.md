# Backplane Skill Protocol — Implementation Plan

Status: executable proposal; no implementation/test results asserted  
Prepared: 2026-09-11  
Repository allowed to change: `gsmlg-opt/backplane` only  
Requirements: [prd.md](prd.md)  
Launch instructions: [codex_prompt.md](codex_prompt.md)

## 1. Assignment and completion boundary

Implement `apps/backplane_skill_protocol`, adopt it inside Backplane, add immutable Skill distribution and a read SDK/cache, and prove independent consumption. Complete BP-00 through BP-06 in dependency order. Do not treat package scaffolding, a parser extraction, or mock-only HTTP tests as completion.

This plan supersedes the earlier SKP-00 through SKP-08 cross-repository assignment **for this Backplane run**. External migrations formerly assigned to Sigma/Synapsis are deferred, not silently counted as done. Those repositories, Samgita, and host-agent must not be modified or required to execute this plan. The local consumer fixtures below are the portability gate.

The prior source snapshot is historical. Inspect the actual checkout first, reuse already implemented work, and preserve unrelated changes. No requirement calls for a new Agent runtime, tool executor, provider integration, or authentication system.

## 2. Work breakdown and ownership

| Work package | Scope | Dependencies | Primary gate |
| --- | --- | --- | --- |
| BP-00 | Current baseline, compatibility inventory, contracts, package skeleton | None | One agreed type/wire/fixture contract |
| BP-01 | Independent document/discovery/resolution core | BP-00 | Standalone core and compatibility fixtures |
| BP-02 | Complete bundles, bounded materialization, resource access | BP-00; integrate BP-01 | Complete resources and adversarial inputs |
| BP-03 | Real Backplane adoption via thin facades | BP-01, BP-02 | Existing production paths delegate to library |
| BP-04 | Retained revisions, generated snapshots, backfill, v1 server | BP-03 | Resolve A, publish B, fetch A safely |
| BP-05 | Client/source adapter, cache, bounded retry/offline policy | BP-01, BP-02; real integration BP-04 | Real client/server and cache behavior |
| BP-06 | Release qualification, CI, migration/rollback and consumer handoff | BP-03, BP-04, BP-05 | All PRD acceptance gates with evidence |

One contract owner controls public structs, errors, wire schemas, and shared fixtures. BP-01/BP-02 may run in parallel after BP-00; merge the integrated path before BP-03. BP-04/BP-05 may run in parallel after M1. A single Codex session can execute the same sequence serially.

Use small, reviewable change groups. Do not push or open PRs automatically. Do not let multiple workers independently edit `mix.lock`, shared type files, the same migration sequence, or the wire schema. Assign ownership explicitly when using parallel worktrees.

**Milestones:** M1 = BP-00–03; M2 = BP-04–05 plus real integration; M3 = BP-06. M3 finishes this Backplane assignment, not external product adoption.

## 3. Contracts to freeze in BP-00

These are design defaults, not descriptions of existing endpoints. Follow them unless the verified checkout provides a material reason to amend both documents and the conformance fixtures.

### 3.1 Library surface and host boundary

Public namespace: `Backplane.SkillProtocol`. Keep the implementation small; modules below indicate responsibilities, not a demand for a framework or one process per concern.

| Responsibility | Suggested modules | Contract |
| --- | --- | --- |
| Content | `Document`, `Parser`, `Validator`, `Diagnostic` | Parse bytes; separately validate standard/compatibility profiles; retain original data. |
| Discovery | `Descriptor`, `SkillRef`, `Source.Local`, `Catalog`, `Resolver` | Explicit source roots and precedence; deterministic results and conflicts. |
| Eligibility | `Eligibility` | Pure evaluation of trigger, recognized extension flags, and host policy. No execution grants. |
| Resources | `Bundle`, `BundleManifest`, `PreparedSkill`, `Resource` | Inspect/pack/prepare/read bounded content within a verified root. |
| Remote | `Client`, `Source.Backplane`, `Wire`, `Error` | Host-owned configuration; shared v1 schemas; normalized results/errors. |
| Cache | `Cache` | Explicit root/context/lifetime, atomic installation, capacity and offline policy. |

Public operations return tagged success/error results. Expected bad inputs do not raise uncontrolled exceptions. Keep exception recovery narrow enough that programming bugs are not disguised as valid empty catalogs.

No global mutable catalog is required. Do not add an application-start scan, polling loop, globally named cache, or hidden credential lookup. A host may explicitly start an instance-scoped helper if the implementation genuinely needs supervision.

### 3.2 Document and compatibility rules

Keep raw document bytes independently from any normalized representation. Preserve string-keyed unknown fields, while validating standard fields against the format profile pinned during BP-00. Existing Backplane field mappings belong in a host adapter, not in the generic parser.

Use strict validation for new standard publications; preserve safe existing reads through an explicit legacy profile. Missing discovery metadata is a diagnostic, never generated text. Recognized invocation flags with malformed types must be rejected or withheld from activation, not treated as false.

A declared unsupported mandatory capability is terminal. Unknown informational fields may survive decoding. Record this distinction in schema fixtures, including which extensions affect eligibility.

Validation of a Skill name against its directory uses the logical bundle root, not the outer content-addressed cache directory name. New bundles use one declared root containing its entrypoint `SKILL.md`; a nested example named `SKILL.md` is an ordinary resource unless explicitly selected by a separate source, not another implicit entrypoint.

### 3.3 Identity and manifest

Source identity is supplied/configured by the host and scoped to the endpoint/trust domain. Existing IDs that contain `/` remain opaque strings. Freeze stable published IDs; never derive identity from the latest display name on every lookup.

An exact `SkillRef` contains source identity, Skill ID, revision, and `artifact_digest`. The manifest freezes document metadata and resource inventory for that revision. Its required wire fields should include:

- Protocol version and required capability/profile identifiers.
- Skill ID, opaque revision, immutable metadata, and logical root/entrypoint.
- Artifact format `tar+gzip`, exact `artifact_digest`, and compressed size.
- Inventory of regular resource paths, lengths, and per-file SHA-256 values, plus total unpacked bytes.

Compute inventory from inspected bytes, not user claims. Artifact integrity uses the exact stored gzip bytes. Do not regenerate the archive during fetch. Do not expose internal `blob_ref`, `archive_ref`, credentials, or server paths in the v1 contract.

Author `version` metadata is descriptive. Wire v1, package SemVer, and content revision are independent.

### 3.4 Read API

Proposed namespace relative to the existing API mount: `/skill-protocol/v1`. Record the actual complete public path in `contract-v1.md` after inspecting the router. Do not accidentally double an existing `/api` prefix.

| Operation | Relative route | Input | Output |
| --- | --- | --- | --- |
| Catalog | `GET /catalog` | `q`, optional tags/filter profile, `cursor`, `limit` | `protocol_version`, lightweight `data`, `next_cursor` |
| Resolve | `GET /resolve` | required `skill_id`; optional exact `revision` | One immutable manifest; omitted revision resolves current once |
| Fetch | `GET /artifact` | required `skill_id` and exact `revision` | Exact tar.gz bytes for the authorized reference |

This chooses a reference-qualified fetch rather than the earlier bare-digest route sketch. The digest remains the integrity key; a request always carries the Skill/revision needed for access checks. Do not implement both shapes in v1 without a demonstrated compatibility need.

The fetch response has the archive content type, byte length when available, and a strong ETag derived from its artifact digest. The client hashes the actual archive representation. Do not let HTTP content transformations silently change the byte definition. Conditional responses must still perform access checks; a 304 is not an authorization shortcut.

Catalog metadata comes from the committed publication, not mixed-in mutable document fields. Apply live availability/authorization filters. Freeze deterministic keyset ordering and bind cursors to the relevant filter/access context. Pagination over a changing catalog is explicitly best-effort rather than a claimed snapshot; immutable exact references make later content reads stable. Invalid cursors fail explicitly and page sizes are bounded.

### 3.5 Error and failure contract

Use a versioned JSON error envelope with a stable code, bounded human message, and retryability. Suggested codes: `invalid_request`, `invalid_document`, `invalid_bundle`, `ambiguous_skill`, `not_found`, `revision_unavailable`, `unauthorized`, `forbidden`, `unsupported_protocol`, `unsupported_capability`, `integrity_mismatch`, `limit_exceeded`, `capacity_exceeded`, `timeout`, `cancelled`, and `temporarily_unavailable`.

Map HTTP 400/401/403/404/409/410/413/429/503 consistently with the actual host's access-disclosure policy. A deployment may conceal inaccessible references as 404; it must not serve their artifacts. Malformed successful responses are protocol errors, not empty success.

Retry eligible transport failures and selected transient server responses only. A 429 delay must fit the same deadline. Do not automatically retry integrity failures, denied access, malformed content, or missing explicit revisions. Do not implicitly try legacy endpoints or another source after failure.

### 3.6 Proposed engineering limits

These are configurable Backplane defaults, not Agent Skills standard limits. Verify suitability with real local fixtures, document justified changes, and test both boundaries and overrides. A legacy facade may preserve a documented lower historical limit; new safety ceilings must not disappear in compatibility mode.

| Budget | Initial default |
| --- | --- |
| Document bytes / frontmatter bytes | 2 MiB / 256 KiB |
| Parsed nesting depth | 32 |
| Local scan depth / visited entries | 16 / 10,000 per operation |
| Archive compressed bytes | 16 MiB |
| Archive expanded bytes / individual regular file | 64 MiB / 8 MiB |
| All archive entries, including directory/extension records | 1,000 |
| Archive path depth | 16 |
| JSON response bytes | 4 MiB |
| Catalog default / maximum page size | 20 / 100 |
| Overall remote operation deadline | 30 seconds, including retry delays |
| Maximum remote attempts | 3 total, not 3 additional retries |
| Bundle preparation deadline | 30 seconds |
| Managed cache capacity | 512 MiB, including staging/reservations |
| Offline reuse | Disabled unless the host opts in with a maximum age |

Configure per-read/connect budgets below the remaining total deadline. Disk usage and archive budgets account for simultaneous staging. If the YAML/archive library cannot enforce a needed bound directly, contain its input or use a bounded intermediate representation; do not claim safety from checking sizes after unbounded allocation.

## 4. BP-00 — Verify baseline and establish the implementation contract

**Owned areas:** documentation, package skeleton/public contract files, root dependency changes only where required.

Read applicable `AGENTS.md` and repository development instructions. Record `git status`, current commit/branch, relevant package versions, and uncommitted changes. Discover the actual Skill modules, API mount, DB/migration conventions, blob backend, existing generated publishers, tests, and CI. Inspect existing or in-flight Skill/shared-package work to avoid duplication.

Run the smallest existing Skill tests in the repository's documented environment when possible. Record baseline failures separately from later changes. If dependencies/services are unavailable, identify the exact blocker and continue work that does not need them.

Inventory every content/metadata writer and blob cleanup path, not just the obvious Loader. Include upload, import/export, generated refresh, UI/API updates, disable/delete, source replacement, and cleanup workers. Trace fields affecting model eligibility and the historical meanings of `content_hash`.

Create/update:

- `docs/skill-protocol/baseline.md`: actual SHA, source map, compatibility cases, environment, baseline test results, and scope.
- `docs/skill-protocol/contract-v1.md`: decisions in section 3, complete mount, field/error definitions, and capability rules.
- JSON schemas and success/error fixtures in one repository-standard location consumable by both client and server tests.
- `apps/backplane_skill_protocol/` skeleton with package metadata and shared types.

Use local Backplane samples plus clearly labelled synthetic future-consumer fixtures. The absence of Sigma/Synapsis access is not a blocker and must not be reported as a missing repository needed to finish this assignment.

**Exit gate:** contracts and fixtures are coherent, current baseline is recorded, and ownership is clear. Empty stubs remain marked incomplete. Update docs to reflect decisions, not to falsely assert implementation.

## 5. BP-01 — Implement the independent content and catalog core

**Owned areas:** library content, validation, discovery/resolution/eligibility modules and their tests.

Implement bounded parsing with raw-byte preservation and structured diagnostics. Use the repository's suitable YAML dependency if possible, but ensure the library declares it independently. Test comments on boolean flags, quoted/non-boolean flags, multiline scalars, nested extensions, unknown keys, duplicate keys, malformed encodings, CRLF/BOM behavior, large input, and excessive nesting.

Implement strict validation separately from the explicit Backplane legacy adapter contract. Standard field failures and unsupported critical invocation extensions are not silently ignored. No shell/LLM/template evaluation belongs in parsing.

Implement explicit-root discovery with deterministic ordering, early bounds, cycle detection, and a declared symlink policy. A local approved linked root may be supported after canonical containment validation; remote archive links remain a different, rejecting policy. Stop treating every arbitrary external `SKILL.md` filename as authorized.

Build source-aware descriptors, catalogs, deterministic resolution, and pure eligibility. Preserve qualified identities; return conflicts for equal-precedence unqualified candidates. Manual-only and disabled cases must have separate tests. Do not parse a product's chat command syntax here.

Begin `scripts/verify_skill_protocol_package.sh` with a copied-package test outside the umbrella. The new Mix project cannot reference `../../config/config.exs`, sibling apps, or root-only helper files to succeed there. Establish a minimal consumer fixture without DB/provider dependencies.

**Acceptance:** AC-01 initial isolation, AC-02–05, and initial AC-17. M1 is not finished yet.

## 6. BP-02 — Implement complete safe bundles and prepared resources

**Owned areas:** bundle/manifest/resource modules, bounded I/O helpers, adversarial fixtures/tests.

Extract reusable mechanisms from the existing archive implementation rather than assuming it already installs a full bundle. New publication packing and downloaded-bundle reading must agree on root, entrypoint, path canonicalization, inventory, bytes, and supported tar records.

Choose a deliberately supported tar profile. Handle PAX/GNU extension records explicitly where accepted; count/bound their payloads and effective names. Reject unsupported records with a diagnostic. A direct unbounded `erl_tar.table`/extract followed by a limit check is not evidence of bounded processing. Streaming limits or a bounded decompressed intermediate are acceptable designs.

Verify every actual file and total expanded bytes. Test traversal, encoded/alternate separators according to the frozen path profile, absolute/drive paths, symlinks, hardlinks, devices, duplicate files, file/directory conflicts, and target collisions on supported filesystems. Ignore archive ownership and unsafe mode metadata. Preserve ordinary resource bytes, including binary assets.

Prepare into an owned staging directory. Validation must finish before atomic publication on the same filesystem. Cancellation/error removes only operation-owned temporary files; never an existing verified cache entry. Test resource access after preparation, including stale/escaped paths.

Provide an explicit lifetime API or host-managed immutable-root contract. Do not add automatic garbage collection in this work package. A prepared Skill exposes content and resource access, not a command to execute scripts.

**Acceptance:** AC-06–07 plus manifest/digest tests needed by AC-08. Integration with BP-01 must pass before adoption.

## 7. BP-03 — Make Backplane use the shared core

**Owned areas:** `backplane_skills` facades/context tests and necessary dependency wiring; no revision migration yet.

Convert `Backplane.Skills.Loader` and reusable archive entry points into thin adapters to the library. Keep schema mapping, old API serialization, blob storage, search/Registry refresh, and business operations in their existing host ownership.

Preserve intended legacy outputs explicitly. For example, a facade may preserve a historical trimmed-body/hash calculation while the shared document retains original bytes. Test those mappings; do not corrupt shared raw data to imitate one host's old behavior.

Connect actual ingestion/generated-validation entry paths to the new core. Demonstrate the delegation through code-path tests or testable seams, not merely the presence of a dependency declaration. Remove duplicated generic parsing/extraction from migrated active paths. Retain compatibility entry functions where callers need them.

Preflight local representative content before tightening publication rules. Existing legacy routes may still accept safe legacy input; v1 readiness must later be represented separately for invalid standard content. Document intentional changes, especially security fixes, rather than weakening assertions until the suite is green.

Run existing Loader/Archive/Ingest/API/Export tests and ordinary application boot tests relevant to the change. Do not widen this PR to unrelated shared runtime/provider projects.

**Acceptance:** AC-03, AC-16, legacy-path portion of AC-11, and standalone tests remain green. **M1 gate:** Backplane actually uses an independently consumable content/bundle core.

## 8. BP-04 — Retained revisions, generated snapshots, and v1 serving

**Owned areas:** host persistence/migrations, publication/cleanup, API routes/controllers, backfill, server tests. No database dependency may enter the shared package.

### 8.1 Expand storage and make publication safe

Add an immutable revision entity with Skill ID, opaque revision, artifact digest, immutable manifest/document metadata, blob reference, and publication timestamp. Add a current pointer or equivalent relationship. Match actual PK/FK types and migration placement in the checkout. Enforce uniqueness and immutability through appropriate constraints and application paths.

Stage/store bytes before making a revision visible. Serialize competing publication updates or use a checked compare-and-set so the pointer and revision commit coherently. Readers must not observe a committed pointer to an unavailable staged blob. Define retry idempotence for the same publication intent.

Audit and fix old replaced-blob deletion before enabling the new protocol. All retained references count, not only the current Skill row. A failed publisher must not eagerly delete a shared digest that another publisher is committing; defer orphan cleanup conservatively unless exclusive staging ownership proves immediate cleanup safe.

Explicit Skill deletion/withdrawal must preserve existing user-facing intent and deny further v1 reads. Decide its internal retention handling in the contract; never enable a bare-digest bypass. Artifact replacement and deliberate deletion are distinct operations. Test multiple Skills sharing identical bytes.

### 8.2 Migrate/backfill without inventing history

Implement a dry-run report and an idempotent backfill. Convert existing retrievable standard-compatible archives into initial revisions without rewriting their stored bytes. Retain original legacy data. Report absent blobs, invalid metadata, conflicting identities, and unsupported records. Do not manufacture prior versions from an author version string.

Ensure all audited legacy/generated writers either publish coherently or leave v1 current unchanged with explicit publication status. Live enabled/deleted/access state is checked independently. A mutable row must not accidentally overwrite the metadata of a published revision.

### 8.3 Support generated Skills

For a valid generated Skill, build a standard complete bundle from a consistent source snapshot, store it once, and publish it. A subsequent generated change creates a different revision rather than mutating the old artifact. Repeated reads of a revision return exactly the same bytes.

If a generator provides body plus real metadata rather than a `SKILL.md`, constructing a faithful document is allowed. Inventing a missing required description or silently stripping significant metadata is not. Invalid records produce an operator diagnostic. At least one actual generated source path and its tests must complete; leaving all generated sources as `unsupported` does not meet M2.

### 8.4 Serve the shared wire contract

Implement catalog/resolve/artifact routes under the verified existing mount. Decode/encode via the shared wire schemas/types, with persistence-to-wire adapters in the host. Apply existing authorization integration to each read and conditional response. Keep storage internals out of responses.

Catalog comes from coherent published revisions plus live visibility. Freeze filtering/order/cursor behavior. Resolve by exact revision or snapshot current once. Fetch checks the Skill/revision authorization before returning bytes; it does not re-resolve current.

Preserve and test legacy reserved routes, including export/import and archive handling, so a generic route does not shadow them.

**Acceptance:** AC-08–11, server portion of AC-18. Include crash/concurrent-publication and shared-blob retention tests. M2 still requires BP-05 actual client integration.

## 9. BP-05 — Implement the remote source, client, and cache

**Owned areas:** shared Client/Source.Backplane/Cache modules and tests. Develop with fixtures in parallel with BP-04, but finish against the real server.

### 9.1 Client and transport

Declare transport dependencies in the package; choose a maintained dependency compatible with the checkout rather than introducing a custom HTTP stack. Keep host endpoint, credentials, timeout, source identity, and access-context configuration explicit and instance-scoped.

Implement page-at-a-time catalog, resolve, and exact artifact fetch. Decode supported protocol/profile versions and mandatory capabilities. Bound response bytes and all retry attempts under one monotonic overall deadline. Propagate cancellation to HTTP/file work and clean owned staging.

Use only the configured endpoint and frozen relative routes. Reject cross-origin redirects by default; never forward credentials to an unapproved location. Properly encode opaque IDs. Validate the digest and manifest association even when the server reports success. No silent legacy or latest fallback.

### 9.2 Cache and offline behavior

Separate immutable artifact bytes from scoped reference/verification metadata. Index associations by source identity, access-context identity, Skill ID, revision, and digest. Do not conflate display slug with identity. A verified manifest/ref mismatch is terminal.

Use unique staging and atomic final installation. Coordinate concurrent prepares so no reader sees partial content, and quota reservations include concurrent temporary data. A VM-local lock is not a cross-process guarantee: either enforce exclusive cache-root ownership or implement and test safe shared-root coordination. Distinct consumers may use private roots in v1.

Use conservative retention and explicit cleanup; automatic LRU eviction is not required. Active prepared views are protected. Capacity exhaustion returns a typed error rather than deleting active revisions. Define how prior verification survives restart and detect missing/corrupt cached files before returning them as verified.

Offline mode is explicit and age-bounded. It only uses a previously verified exact association. Do not silently resolve an unpinned `current` to an arbitrary old cache entry. Known denial/withdrawal must inhibit fallback for the affected access context until explicit successful revalidation, including across restart where offline cache state persists. Integrity failure is not a network outage.

### 9.3 Real integration, not only stubs

Start the actual Backplane v1 router through the repository's HTTP test setup on loopback and point the package's real transport at it. Use a test DB/blob backend and deterministic fixtures; no external LLM/Backplane deployment is needed.

Run the sequence: publish A with reference/asset/script files; enumerate and resolve A; publish B; fetch/prepare A; read A's resources; prepare B separately; deny or withdraw A; verify known-denial behavior. Add pagination, interruption, checksum mismatch, malformed JSON, retry budget, cancellation, and concurrent cache tests. Deterministic transport fault fixtures may supplement but never replace the real server/client success/retention path.

**Acceptance:** AC-11–15 and cross-path AC-17. **M2 gate:** the implementation, not only schemas/mocks, interoperates over HTTP.

## 10. BP-06 — Consumer-ready verification, CI, and final evidence

**Owned areas:** package verification script, minimal consumer fixtures, focused CI, operational docs, implementation report. External repositories stay untouched.

Complete `scripts/verify_skill_protocol_package.sh` (or a documented repository-conventional equivalent). It must:

1. Copy/export the package into an owned temporary directory outside the umbrella and run its compile/tests there.
2. Build a clean consumer with the package as an ordinary dependency in production dependency mode; verify that the dependency graph does not pull Backplane host apps or database services.
3. Exercise pinned Git-subdirectory consumption. For uncommitted work, a temporary Git snapshot containing only the required reviewed files may be created in an isolated repository; record its provenance and do not commit/stash/reset the user's checkout. This tests dependency mechanics, not a remote published release.
4. Exercise parser, local bundle resources, and an available test endpoint using the shared public API. Fail rather than silently skipping a promised check.
5. Verify package contents and build a package artifact using repository tooling where available. Building is not publishing; record the artifact/checksum and any environment blocker honestly.

The core isolation fixture must not need a DB. Real service integration runs in a separate CI job using the normal test database/blob backend. Cache dependencies as the repository does; do not make ordinary tests depend on public network availability or live credentials.

Publish documentation under `docs/skill-protocol/`:

- `baseline.md` and final `contract-v1.md`.
- `verification.md`: environment, checkout SHA, executed commands/results, AC matrix, skipped checks, blockers, and artifact provenance.
- `consumer-handoff.md`: supported APIs, explicit source/credential/cache ownership, dependency mechanism, declared compatibility profile, and deferred Sigma/Synapsis/Samgita work.
- `migration.md`: feature switch, backfill dry-run/report, publication sequencing, retention, withdrawal, rollback, and unavailable-history limits.

Keep the original PRD and plan accurate. Mark progress as implemented/verified/blocked per task; do not convert a skipped test into a passed requirement. Remove migrated duplicate mechanisms only after their replacements are covered, retaining genuine compatibility facades.

**Acceptance:** AC-01–18 all have evidence. **M3 gate:** Backplane is ready for later consumer adoption, with no claim that it has already happened.

## 11. Test execution and evidence rules

Use the repository's documented development environment and supported Elixir/OTP versions. Record actual commands rather than assuming a Nix/devcontainer/Make target exists. Typical command categories include formatting checks, compile with warnings as errors, focused package tests, host Skill tests, migration tests, and the standalone verifier.

Running `mix test` from a directory still inside an umbrella is not standalone evidence. Calling a Plug router directly is useful server coverage but is not a real HTTP client/server integration test. A copied-file/path-dependency test alone is not a Git-subdirectory dependency test.

For every command report working directory, relevant environment, exit status, and a concise result. Keep secrets out. Distinguish existing failures from regressions. Do not run destructive commands or migrations on a non-test database to obtain evidence.

Minimum fixture families:

| Family | Examples |
| --- | --- |
| Standard document | Complete metadata, nested extension, multiline description, CRLF, binary-preserved source |
| Compatibility | Previously accepted missing description, older custom fields, legacy hash mapping |
| Invocation | Boolean with comment, malformed value, manual-only, disabled, unsupported required capability |
| Discovery | Same name/different source, equal-priority conflict, linked root, cycle, scan limit |
| Complete bundle | Entry, nested reference, binary asset, script source, nested example `SKILL.md` |
| Malicious bundle | Traversal, absolute/drive names, links/devices, duplicate/colliding paths, expansion limit |
| Publication | A/B revision race, shared digest, failed publisher, repeat backfill, mutable metadata writer |
| Generated | Valid stable snapshot, update creates new revision, missing required metadata |
| Transport/cache | Page cursor, opaque ID, denial, timeout, cancellation, partial data, corruption, concurrent prepare, offline expiry |

A failure to access another repository is not an implementation blocker. Missing local compiler/dependencies/DB may block a particular verification gate; continue independent work and report exactly what remains unverified.

## 12. Rollout, rollback, and final reporting

Use expand → adopt → publish → verify. First ship the independent core and retention-safe host paths, then backfill supported content and expose v1. Do not remove old routes or data during this run. Any rollout switch must be exercised both enabled and disabled.

Rollback can disable v1 and preserve retained revisions. Do not roll back to old deletion/replace code while publication continues. Freeze publication or retain the cleanup fix. No automatic destructive down migration or silent different-version fallback is acceptable.

The final Codex report must include:

- Work packages completed, partial, or blocked and the actual checkout/change scope.
- Important implementation choices/deviations and files changed.
- Tests executed with actual results; required tests not executed and why.
- The verified API mount, compatibility and migration/backfill behavior, and retention guarantees/limits.
- Package artifact/consumer verification evidence, not an assertion of external product adoption.
- Any remaining Backplane requirements and a separate list of deferred external integration work.

Do not stop after a milestone merely because the initial parser now compiles. Continue through the Backplane scope unless a real blocker prevents progress. When blocked, preserve working changes, complete independent tasks, and report partial completion accurately rather than fabricating a green finish.
