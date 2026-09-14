# Backplane Skill Protocol — Product Requirements

Status: proposed implementation handoff; not an implementation or test report  
Prepared: 2026-09-11  
Execution repository: `gsmlg-opt/backplane` only  
Target OTP application: `backplane_skill_protocol`  
Module namespace: `Backplane.SkillProtocol`  
Companion documents: [Implementation plan](implement_plan.md), [Codex launch prompt](codex_prompt.md)

## 1. Objective and execution boundary

Build an independently consumable Elixir library inside `apps/backplane_skill_protocol`. It provides shared Skill document processing, local discovery and resolution, complete bundle preparation, and a client for a versioned Backplane Skill distribution API.

Backplane must adopt this library in its existing production Skill paths. The existing `backplane_skills` application remains the owner of persistence, publication, blob storage, search integration, authorization integration, and HTTP serving.

The complete delivery for this assignment is **Backplane's library, its own adoption, immutable distribution, the client/cache, and executable integration evidence**. A parser-only extraction is an intermediate milestone, not completion.

### Scope correction from the earlier cross-repository plan

This document and its companion plan replace the earlier cross-repository implementation assignment for this run. Sigma, Synapsis, Samgita, and host-agent are future consumers. Do not modify them, require their checkouts, or make their adoption a release gate here. Use clean consumer fixtures maintained in Backplane to test portability. Such fixtures demonstrate package compatibility, not actual adoption by those products.

The work does not depend on completion of the separate shared Agent runtime or LLM protocol projects. Do not introduce a dependency on either.

## 2. Evidence and source boundaries

The preceding review inspected Backplane snapshot `bd5bc83005fded6f67beefe3fa8abac31eae506a`. That is a historical baseline, not a claim about the current checkout. No fresh Backplane source verification or project tests were performed when preparing this handoff. BP-00 must record the actual checkout and reconcile existing work before implementation.

Previously inspected locations, to be rediscovered if moved:

| Location under `apps/backplane_skills/lib/` | Historical observation to verify |
| --- | --- |
| `backplane/skills/loader.ex` | YAML parsing, a required name, an optional description, and a body-based `content_hash`. |
| `backplane/skills/archive.ex` | Archive validation and selective extraction of entrypoint/metadata; not a complete client installer. |
| `backplane/skills/ingest.ex` | Archive-byte hashing, upsert by slug, and cleanup of replaced blobs. |
| `backplane/skills/api_router.ex` | Existing list/detail/archive and mutation routes; the inspected list lacked a cursor. |
| `backplane/skills.ex` | Skill context, archive access, and deletion/update paths. |

The earlier implementation plan supplied with this conversation is the planning input. The requirements below are Backplane-specific design decisions unless explicitly attributed to a reference in section 12. Do not treat previously observed behavior as a current verified defect.

## 3. Product outcomes and non-goals

### Required outcomes

1. The same parser, validator, and bundle mechanisms serve Backplane and an independent consumer.
2. Local and remote Skills yield one coherent prepared-content contract, without starting an Agent.
3. A resolved remote revision is immutable: its document, resources, and activation-relevant metadata cannot change underneath a consumer.
4. Complete resources, including references, assets, and script source, are available within a verified package boundary.
5. Network, parsing, extraction, and cache failures have bounded, explicit outcomes.
6. Existing Backplane interfaces remain covered during a staged migration.

### Explicit non-goals

Do not implement Agent execution, LLM calls, subagents, sessions, slash-command UI, heartbeat/dream/schedule behavior, tool execution, a plugin marketplace, dependency installation, automatic workspace uploads, bidirectional synchronization, WebSocket distribution, or a new authentication/identity system.

A public publishing SDK is deferred. Server-side publication through existing Backplane ingestion/generated-content mechanisms remains in scope because the read protocol requires real published snapshots. Do not publish packages, push branches, deploy, or run production migrations as part of this assignment without separate authorization.

## 4. Ownership and shared contracts

`backplane_skills` depends on `backplane_skill_protocol`; the dependency must not point back toward the host. The library must not depend on a Backplane Repo, sibling application, Ecto schema, Phoenix endpoint, Oban worker, Agent runtime, or provider protocol.

Prefer pure functions for parsing, validation, resolution, and eligibility evaluation. Filesystem and HTTP operations are explicit. Adding the dependency must not scan directories, connect to a service, or start a polling loop. Transport dependencies may use their normal supervision; this is not permission to add hidden Skill synchronization.

| Contract | Responsibility |
| --- | --- |
| `Document` | Original bytes, frontmatter/body boundaries, string-keyed parsed metadata, normalized known fields, preserved extensions, diagnostics. |
| `Descriptor` | Lightweight discovery information, source identity, publication availability, and an exact revision when advertised. Not evidence of local verification. |
| `SkillRef` | Source-instance identity and stable Skill ID. A resolved reference also has an exact revision and artifact digest. |
| `BundleManifest` | Protocol version, reference, entrypoint, immutable document metadata, file inventory, sizes, digest, and bundle profile. |
| `PreparedSkill` | Verified document and a fixed resource view with an explicit resource-lifetime contract. No execution authority. |
| `Diagnostic` / `Error` | Stable code, phase, severity where relevant, reference context, and retryability; no secrets or unbounded input excerpts. |

Mutable host bindings stay outside `Document`: enabled state, aliases, project/Agent assignment, configuration overrides, and actual tool permissions. A descriptor may expose availability, but a document cannot grant itself permission.

## 5. Functional requirements

### R-01 — Independent package

The package must compile and run outside the umbrella, with dependencies declared in its own Mix project. It must not require the repository's root configuration, root aliases, sibling paths, private test helpers, database, or real provider credentials. Include all necessary runtime resources in the distributable package.

Initial consumption may use a pinned Git subdirectory dependency. Publication to Hex is not a completion prerequisite. Test the dependency as a normal consumer, including its production dependency environment; do not validate only through an umbrella/path override.

### R-02 — Document parsing and validation

Use an established YAML parser with bounded input and explicit handling of features that cannot be bounded safely. Preserve original document bytes and unknown extensions; do not create runtime atoms from untrusted keys. Support ordinary multiline values, comments, nested extension data, and line-ending variants without destructive rewriting.

Parsing and strict validation are separate operations. Pin and document the supported Agent Skills format profile using reference S1. New standard publications require valid metadata. Unknown noncritical extensions are preserved; a malformed or unsupported critical invocation requirement must not silently become permissive behavior. Duplicate/ambiguous keys, invalid encodings, excessive nesting, and unsafe parser features need deterministic outcomes.

Client-specific invocation flags are extensions, not universal format fields. The supported Backplane invocation profile must interpret recognized booleans by type, not truthiness. It must not evaluate shell substitutions, templates, or bundled instructions.

### R-03 — Explicit compatibility

Keep existing accepted Backplane content readable through an explicit compatibility facade where safe. Missing metadata must not be invented. Legacy `content_hash` and existing response fields retain their original documented meaning; introduce clearly named fields rather than reinterpreting old data.

A legacy operation may remain successful while its content is not eligible for the new publication contract. In that case, expose an operator-visible publication status/diagnostic, and do not advertise an invalid revision as ready. Separate this compatibility behavior from security invariants: unsafe paths or unauthorized access are never made acceptable by legacy mode.

No automatic rewriting, bulk renaming, metadata invention, or unrecoverable migration is permitted.

### R-04 — Local discovery, resolution, and eligibility

Accept explicit roots and source identities from the host. Do not hard-code another product's home/config directories or infer a working directory globally. Discovery must have traversal, file-count, depth, and byte limits, with cycle detection and an explicit local-link policy.

Use deterministic, host-supplied precedence. Equally ranked unqualified collisions return a conflict; an explicitly qualified reference never silently changes source. Separate discovery from full resource loading.

Provide a pure eligibility operation for an explicit trigger and host policy. Supported manual-only flags exclude automatic selection but permit explicit selection when the host allows it. Host-disabled Skills remain unavailable to either trigger. Shared eligibility is not the host's tool-authorization engine.

### R-05 — Complete bundle preparation

A bundle contains the entrypoint plus its resources, not just Markdown. Inspection, packing where needed, extraction, and resource access share a documented tar.gz profile. The new publication profile must unambiguously select a root and entrypoint; ordinary nested example files must not accidentally become additional entrypoints.

Validate the full archive and actual expanded bytes. Reject escaping/absolute/drive paths, dangerous link/device entries, duplicate or colliding targets, inconsistent inventory, and content outside the declared root. Enforce limits during processing, not after unbounded decompression or directory enumeration.

Downloaded bundles are prepared in private staging, fully verified, then published atomically within the destination filesystem. Failure or cancellation never exposes a partial prepared bundle. Ignore unsafe ownership/permission metadata. Resource reads are relative to the prepared root and recheck the path boundary; a filename alone does not authorize external reads.

Reading script source does not execute it. Markdown links and declared dependencies are not automatically downloaded or installed.

### R-06 — Immutable identity and digest

Keep library version, wire protocol version, author version text, and content revision distinct. Published Skill identity must survive changes to its display name or slug. Names alone are not global identity.

Define `artifact_digest` as `sha256:` followed by the lowercase SHA-256 hex digest of the exact stored/downloaded tar.gz bytes. Hashing only the body is insufficient. A separate document digest, if supplied, must have a different name and an explicit byte definition.

A revision freezes the manifest, content, resources, and invocation-relevant metadata. Resolve current once, then use that exact reference. An explicit missing, withdrawn, or denied revision never falls back to current. Repacking on download must not change the bytes under an existing revision.

### R-07 — Backplane publication and retention

Add an immutable revision record and a mutable current-publication pointer using Backplane's existing persistence/blob infrastructure. Publication must be coherent under concurrent writers, crashes, retries, and failed transactions.

All replacement/deletion/cleanup paths must account for retained revisions and other references to the same blob. Replacing current must not remove the previous published artifact. Deliberate withdrawal/deletion remains an explicit availability transition subject to existing policy; immutability does not override access revocation or promise eternal public availability.

Backfill existing retrievable content idempotently. Report missing blobs, invalid documents, and previously deleted history instead of fabricating revisions. Valid generated Skills must acquire stable bundle snapshots in this delivery. Unsupported or invalid generated records remain explicit diagnostics, not fake download successes.

Audit every writer of content and relevant metadata. It must either publish a coherent new revision or leave the previous publication unchanged and report a pending/invalid publication state. V1 must never combine new mutable metadata with old published bytes. Live disablement, deletion, or authorization withdrawal must gate new reads immediately.

### R-08 — Versioned read API

Add a separate `/skill-protocol/v1` namespace beneath the actual existing API mount; determine the full public prefix in BP-00. Preserve legacy `/skills` route shapes and reserved routes.

The v1 operations are catalog, resolve, and artifact fetch. Freeze their JSON schemas, encoding, pagination, errors, and limits before parallel implementation. Catalog responses are lightweight and paginated. Resolve returns a manifest for one exact revision. Fetch is qualified by Skill ID and revision and checks the existing access boundary before serving those bytes.

A digest is an integrity identifier, not an access credential. Never expose unrestricted blob lookup by digest. Reuse existing upstream/application authorization integration; do not add an unrelated identity service. Public wire metadata excludes storage-internal blob references and server filesystem paths.

### R-09 — Client and Backplane source adapter

Provide a configurable client plus a thin Backplane source adapter returning the shared contracts. Host input owns the endpoint, source identity, non-secret access-context identity, credential supplier, policy, and request budgets.

Implement a page-at-a-time catalog operation, exact resolution, and bounded streamed artifact retrieval. Validate responses rather than trusting arbitrary maps. Encode opaque IDs safely, including IDs containing slashes. Do not follow server-supplied arbitrary download URLs or leak credentials through cross-origin redirects.

Retries are limited to classified transient failures under one overall deadline. Honor cancellation and bounded retry delays. Authentication/authorization denial, malformed protocol data, unsupported required capabilities, and integrity failures are terminal for the attempt. No implicit downgrade to the legacy API, no different-version substitution, and no model-mediated retry loop.

### R-10 — One-shot retrieval and caller-owned destinations

Each remote use requires a fresh destination under a caller-owned task or work directory. Resolve the requested Skill once, download that exact artifact on every invocation, verify the manifest and complete bundle, then publish atomically into the unused destination. Missing, invalid, or existing destinations fail explicitly and are never overwritten, removed, or reused.

A remote or validation failure returns an error and no usable `PreparedSkill`; it never falls back to content from an earlier invocation. Operation-owned temporary files are removed after success or failure. A successful prepared directory remains available until the host removes it, and the library does not scan, migrate, clean, or otherwise manage previous destinations.

This requirement removes consumer-side durable caching, offline policy, quota/eviction, ownership coordination, and native locking. It does not change server-side retained publication artifacts, immutable revisions, authorization, or the versioned HTTP API.

### R-11 — Backplane actually uses the library

Migrate normal parser/archive/ingest/generated-publication paths to shared mechanisms. Keep thin legacy facades as needed; do not retain a second full parser or installer on the active path. Backplane calls the library in-process for content work and does not call its own HTTP API to parse a document.

Server-side mappings to legacy schemas and API fields remain in `backplane_skills`. Existing business behavior must have regression coverage. Updating expectations to hide unintended changes is not an acceptable migration.

### R-12 — Verification and operational visibility

Provide deterministic fixtures, a package-isolation runner, server/client contract tests over actual loopback HTTP, and migration/retention tests. No real LLM or external consumer checkout is required. Service integration may require the repository's normal test database; that must not leak into standalone package tests.

Use existing logging/telemetry conventions for phase, error code, exact reference, operation outcome, duration, and bounded byte counts. Do not log credentials, full Skill bodies, or private host paths by default. The status report must separate implemented code, executed tests, skipped tests, and deferred external adoption.

## 6. Acceptance matrix

| ID | Scenario and required result | Requirements |
| --- | --- | --- |
| AC-01 | Copied package and fresh Git-subdirectory consumer compile and use it without the umbrella, DB, root config, or sibling apps. | R-01 |
| AC-02 | Valid/invalid YAML, line endings, duplicate keys, extensions, comments on booleans, and limits have explicit fixture results; original bytes remain available. | R-02 |
| AC-03 | Legacy reads/fields retain tested behavior; invalid v1 publications have diagnostics and no fabricated metadata. | R-03 |
| AC-04 | Deterministic discovery/conflicts; qualified references never switch source; local links cannot escape approved roots or loop. | R-04 |
| AC-05 | Manual-only and disabled cases obey the declared trigger/host policy; content never grants tools. | R-04 |
| AC-06 | A complete bundle exposes its entrypoint, reference, binary asset, and script source; nothing executes. | R-05 |
| AC-07 | Traversal, links, colliding paths, expansion bombs, bad inventory, and cancellation fail without out-of-root writes or unbounded work. | R-05 |
| AC-08 | Publish A, resolve A, publish B, then fetch A: all A metadata and resource bytes remain A. B is separately available. | R-06, R-07 |
| AC-09 | Backfill is idempotent; failed/concurrent publishers cannot corrupt current or delete another retained blob. | R-07 |
| AC-10 | Valid generated content has a stable immutable artifact; invalid/missing-source records are reported honestly. | R-03, R-07 |
| AC-11 | Real server/client tests cover pagination, opaque IDs, legacy route regressions, missing revisions, and disabled/deleted/denied reads. | R-08, R-09 |
| AC-12 | One-shot preparation either returns a complete verified destination or an error; interrupted work exposes no partial result and does not damage existing files. | R-09, R-10 |
| AC-13 | Timeouts/retries/cancellation terminate within budgets; malformed data and integrity failures are terminal; redirects do not leak credentials. | R-09 |
| AC-14 | Every remote use downloads again, including the same exact revision; a remote error never falls back to content from an earlier use. | R-10 |
| AC-15 | Returned resources remain readable until host cleanup, and preparing or failing another destination does not modify earlier or unrelated destinations. | R-10 |
| AC-16 | Normal Backplane ingestion/loading uses the shared implementation and preserves covered legacy behavior. | R-11 |
| AC-17 | Backplane and independent consumer fixtures produce equivalent normalized content for the same bytes/revision. No claim of real Sigma/Synapsis adoption. | R-01, R-12 |
| AC-18 | Migration/rollback documentation prevents old replacement cleanup from deleting retained revisions; evidence distinguishes pass/skip/block. | R-07, R-12 |

These are required tests, not statements that tests have passed.

## 7. Delivery milestones

**M1 — Shared core in real Backplane use:** BP-00 through BP-03. Standalone package, shared content/bundle behavior, and Backplane migration pass their gates.

**M2 — Backplane distribution works:** BP-04 and BP-05. Retained revisions, generated snapshots, v1 API, client/one-shot source, and actual server/client integration pass.

**M3 — Backplane consumer-ready handoff:** BP-06. Packaging/CI, full acceptance evidence, upgrade/rollback guidance, and a documented external integration contract are complete.

M3 is the end of this assignment. Sigma, Synapsis, Samgita, and host-agent production adoption are separate future work. Do not stop at M1 and describe the whole assignment as finished.

## 8. Rollout and rollback requirements

Use additive storage and an independently controlled v1 exposure switch. Preserve original data and legacy routes. Replace unsafe replacement cleanup before enabling immutable-history guarantees. Dry-run and report the backfill before mutating data in an authorized environment.

Disabling the new API must not delete retained artifacts. Reverting to a binary with old cleanup behavior requires publication to be disabled or the retention fix to remain in place. Do not run destructive down migrations against revisions already referenced by clients. Explicit withdrawal returns an unavailable/denied result, never another revision.

## 9. Definition of done

The Backplane-only assignment is complete when all R-01 through R-12 are implemented, AC-01 through AC-18 have evidence, Backplane uses the shared library, and the client communicates successfully with the implemented server over HTTP. Package-isolation, retention, authorization, and integrity gates cannot be waived by marking a feature flag off.

An environment-blocked required test means verification is incomplete, even if implementation is present. Preserve useful completed work and report the exact blocker; do not fabricate results or broaden scope to unrelated projects.

## 10. Required repository deliverables

- `apps/backplane_skill_protocol/` with documentation, tests, and independently usable package metadata.
- Necessary changes in `backplane_skills`, the actual API mount, existing persistence/migrations, and relevant CI only.
- `docs/skill-protocol/` containing these documents, a verified baseline, a frozen v1 contract, and implementation evidence.
- A standalone package verifier and minimal consumer fixture in repository-standard locations.
- An integration handoff describing host-owned configuration/activation and deferred consumer work.

## 11. Decision discipline

The plan supplies defaults so implementation can proceed without repeated design questions. Adjust physical table/module placement to verified repository conventions. Record material contract deviations with rationale and tests before changing dependent work. Do not silently alter the wire profile or public fields independently in client/server branches.

## 12. References

S1. Agent Skills specification, checked 2026-09-11: `https://agentskills.io/specification`. Used for the standard document/directory shape and strict format profile. Transport, persistence, cache, eligibility, and release policies in this PRD are Backplane design decisions, not requirements of that specification.

S2. Mix dependency documentation, checked 2026-09-11: `https://hexdocs.pm/mix/Mix.Tasks.Deps.html`. Used for Git subdirectory consumption and normal dependency-environment expectations. The supported Elixir/OTP matrix must be taken from the actual checkout, not assumed from the documentation site's displayed version.

S3. Prior source review: Backplane snapshot stated in section 2, with paths there. Revalidate locally; historical source observations are not evidence of current implementation status.
