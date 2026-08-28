# ADR: Canonical Memory-Space Partition

- **Status:** Accepted (staged)
- **Date:** 2026-08-29
- **Baseline:** `55835fbd799c81238e455446f8fa43701a5adda6`
- **Decision scope:** Canonical ownership, partition derivation, authorization, and rollout compatibility for Memory V2

## Context

Backplane is the sole authority for durable memory. The host-agent captures and transports evidence, may retain bounded non-authoritative state for delivery or offline use, and must not choose the durable owner of an event or memory.

The v2 capture envelope illustrates the source runtime as `client_id: "codex-cli"`, the source project as a path, and `scope` as a project label. The current implementation uses the same `client_id` field for a different purpose:

- `Backplane.Memory.Partition.resolve/1` resolves an authenticated principal to `host:<host_id>` and returns that value as `partition_id`.
- `Backplane.Memory.Authorization.authorize_tool/3` validates any supplied `client_id` against that partition ID and then writes the partition ID back into trusted tool arguments as `client_id`.
- `Backplane.Memory.Ingest.Upcaster.V1.upcast/2` also constructs `host:<authenticated_host_id>`, persists it as `client_id`, and overwrites `raw_envelope.client_id` with that owner value.
- The host channel's capture auth context contains authenticated `host_id`, token ID, and global host-agent permissions, but no resolved canonical memory partition.
- The v1 event validators make `client_id`, `project`, and `scope` optional. The upcaster persists source `project` and source `scope` directly; the event changeset does not require `host_id`, `client_id`, or `scope`.

Consequently, a capture event can receive an accepted durable ACK with a missing or unvalidated scope and later fail a projection that requires a complete owner partition. A source runtime identity can be lost when `client_id` is overwritten, and the surviving source scope can appear authoritative even though it was not resolved from authentication.

The current host-private model is safe as a temporary authorization boundary, but its overloaded names prevent a sound cross-host model. Sharing based only on equal project paths, project labels, or source scopes would let provenance become authority.

## Current Conflict

The same fields currently carry incompatible meanings:

| Concept | Current representation | Conflict |
|---|---|---|
| Authenticated caller | Auth context `client_id` or host-channel identity | Identifies a credential/principal, not necessarily a durable memory owner |
| Durable owner | Memory/event `client_id = "host:<host_id>"` | Reuses the caller-provenance name for an owner partition |
| Source runtime | Capture-envelope `client_id`, such as `codex-cli` | Overwritten during v1 upcasting and therefore not reliably retained |
| Capture host | `host_id` | Currently also embedded into the owner identifier, preventing ownership from evolving independently |
| Project | Source path or label | Provenance can differ across hosts and must not grant access |
| Scope | Optional source claim and canonical query field | Can survive ingestion without canonical resolution or validation |
| Namespace | Usually `private` | Is currently part of query partitioning but is not an owner identity |

The system needs an owner identity that remains stable while hosts, source runtimes, tokens, projects, scopes, and namespace policy change independently.

## Decision

Memory V2 adopts an explicit canonical memory-space model:

| Field | Authoritative meaning |
|---|---|
| `memory_space_id` | Stable authoritative owner of canonical events, memories, projections, governance state, and edge-feed revisions |
| `host_id` | Authenticated capture provenance and delivery target; never the durable owner by implication |
| `source_client_id` | Source runtime provenance, such as `codex-cli`; never an authorization grant |
| `source_scope` | Privacy-safe scope label supplied by the source runtime; provenance only and never an authorization grant |
| `scope` | Authorized subpartition within a memory space |
| `namespace` | Visibility and lifecycle boundary within a memory-space subpartition |
| `project` | Capture provenance only; it neither selects an owner nor grants access |

The initial rollout preserves current capture behavior: each registered host maps to exactly one private memory space, its registered `memory_scope` supplies the default capture scope, and `private` is the default capture namespace. This is a compatibility stage, not a declaration that hosts permanently own memory or that `private` is the only existing authorized namespace.

For each mapped memory space, the initial authorized scope/namespace set is derived only from current durable server-side entitlements. It includes the host registration's default `{memory_scope, private}` pair and every additional scope/namespace pair already granted by durable authorization state. Existing `shared` and `team:*` rows are preserved with their exact scope and namespace during backfill; their existence alone does not create a new entitlement. If no durable entitlement authorizes such a row under the canonical model, it remains available through the authorized legacy compatibility path until an audited operator disposition is applied.

Cross-host sharing is deferred. A second host may access a memory space only after a separate, explicit entitlement model defines membership, permitted scopes/namespaces, delivery, revocation, and audit behavior. Equal project paths, project labels, source scopes, or runtime client IDs never imply entitlement.

The server resolves the complete canonical partition from the authenticated principal and durable server-side registration or entitlement state before persistence:

```text
authenticated principal
  -> authenticated host
  -> entitled memory space
  -> authorized scope
  -> authorized namespace
  -> complete canonical partition
```

Caller-provided partition fields are claims to validate, not defaults to trust. A missing claim may be filled from the one unambiguous server-side mapping. A conflicting claim is rejected before an accepted ACK; it is not silently overwritten. Project, working-directory, integration, `source_client_id`, and `source_scope` values are provenance and do not participate in the authorization decision. For new events, any supplied source scope that is safe to persist after privacy filtering is retained logically as `source_scope`. A protocol may consistency-check that value against the resolved target scope, but no match or mismatch can grant access.

This ADR deliberately does not prescribe a concrete table, migration name, identifier encoding, or association schema. The implementation must satisfy the identity, mapping, backfill, authorization, and compatibility requirements below.

## Invariants

1. Every accepted canonical event has a complete `memory_space_id`, `scope`, and `namespace`, plus its authenticated capture `host_id` where the ingress is host-based.
2. `memory_space_id` is the authoritative owner key. It is not inferred from project text, a working directory, integration name, source client, or source scope.
3. `host_id` records capture provenance and selects entitled edge delivery. Host token rotation does not change ownership.
4. `source_client_id` records runtime provenance only. It cannot select a memory space, widen scope, or authorize a read or write.
5. `source_scope` records a privacy-safe source label only. It cannot select a memory space, widen scope, or authorize a read or write; when supplied for a new event it is retained even if a protocol also consistency-checks it.
6. `scope` partitions data inside an entitled memory space. It is not an owner identity and cannot create entitlement.
7. `namespace` controls visibility and lifecycle policy inside a memory-space/scope pair. It is not an owner identity and cannot create entitlement.
8. Source `project` and source scope remain provenance. If a compatibility protocol uses `scope` as a canonical claim, the server validates it against the resolved canonical scope before preserving the source value separately as `source_scope`.
9. A caller may omit a partition claim only when the server can derive exactly one complete authorized partition. Zero or ambiguous mappings fail closed.
10. Any supplied owner, host, scope, or namespace claim that conflicts with the resolved canonical partition is rejected before persistence and before an accepted ACK.
11. An accepted ACK means the persisted event is complete enough for authorized canonical projection. Later optional processing may fail, but partition absence or conflict cannot be deferred to a worker.
12. Every query, mutation, rebuild, governance action, and edge-feed selection uses the same canonical partition semantics.
13. Cross-host delivery requires explicit entitlement to the same `memory_space_id`; project similarity alone is insufficient.
14. Revoking a host entitlement stops future reads, writes, and delivery for that host without changing the memory space's identity or deleting canonical memory by implication.
15. Changing a host's default `memory_scope` affects new capture only. Previously authorized or populated subpartitions remain mapped and readable until an explicit, audited migration or revocation disposes of them.
16. Historical source identity that cannot be recovered is recorded as unknown, not reconstructed from a legacy owner value.

## Alternatives Considered

| Alternative | Authorization | Offline delivery | Cross-host sharing | Migration complexity | Revocation | Rollback |
|---|---|---|---|---|---|---|
| Host-private owner | Simple one-host boundary | Natural one-host target | Not supported without copying or redefining ownership | Low | Coupled to the host | Easy, but preserves the identity conflict |
| Project-shared owner | Requires a trusted project registry; source paths/labels are unsafe | Requires project membership and multi-host fan-out | Natural after entitlement exists | High because current projects are provenance strings | Must revoke membership without deleting project memory | Risky while project identity is unresolved |
| User-owned owner | Requires a stable user identity and host-to-user entitlement absent from the capture channel | Requires per-user device membership and delivery policy | Natural across a user's devices | High and broadens the current single-owner product model | Must separate user, device, and token revocation | Poor until user ownership exists end to end |
| Explicit memory space | Server resolves a stable owner and explicit entitlements | Host is a delivery target for entitled spaces | Supported later without changing owner semantics | Moderate; needs durable mapping and compatibility | Entitlement can be revoked independently of data ownership | Good during the host-private compatibility stage |

### Why the Other Alternatives Are Not Chosen Now

- **Host-private ownership** describes the initial deployment behavior but makes host identity permanently carry two responsibilities. It is retained only as a mapping policy during rollout.
- **Project-shared ownership** cannot safely use caller-provided paths or labels as an authorization root. A canonical project registry and entitlement policy are not approved in PR0.
- **User ownership** assumes an authenticated user-to-host relationship that is not present consistently across host capture, MCP, offline delivery, and governance.
- **Explicit memory spaces** separate ownership from provenance now and permit either private or shared policy later without reinterpreting source fields.

## Staged Compatibility and Backfill

### Stage 0: Record the Decision

PR0 changes no runtime behavior or schema. The existing host-private implementation remains the baseline while this vocabulary becomes the contract for subsequent work.

### Stage 1: Establish Stable Private-Space Mappings

- Establish a durable, unambiguous mapping from each registered host to one private `memory_space_id`.
- Seed each memory space's authorized scope/namespace set from current durable entitlements. The registered host's existing `{memory_scope, private}` pair is the default capture target, not an exclusive namespace rule.
- Treat later `memory_scope` changes as default changes for new capture. Keep prior subpartitions mapped and readable until an explicit migration or revocation records their disposition.
- Keep legacy owner identifiers such as `host:<host_id>` as compatibility identifiers or aliases. Do not relabel them as source runtime IDs.
- New host registrations must receive a stable mapping before capture can be accepted.

### Stage 2: Backfill Canonical Ownership

- Backfill every in-scope durable row through the durable host-to-private-space mapping. A row is in scope when it either carries any legacy partition field (`host_id`, owner `client_id`, `scope`, or `namespace`), inherits ownership through a relation to such a row, or affects partition-sensitive recall, projection, idempotency, governance, deletion, audit, import, or synchronization behavior.
- This includes captured events and streams; memories, remember requests, evidence, relations, tombstones, and revocations; observations, sessions, summaries, lessons, crystals, profiles, graph, activity, replay, and recall traces; coordination records; imports; partition-sensitive audit/idempotency state; synchronization mappings, fact state, and pending durable jobs that embed a legacy partition. Nullable, malformed, conflicting, soft-deleted, archived, and historical rows are still in scope and cannot be excluded merely because they are difficult to map.
- Preserve every existing scope and namespace value exactly, including `shared` and `team:*`. Backfill does not collapse them to the default `{memory_scope, private}` pair and an existing row does not grant a new entitlement.
- Make the backfill repeatable, observable, and conflict-detecting. Map a row automatically only from one trustworthy durable owner relationship; ambiguous or incomplete rows are not guessed.
- Do not reinterpret historical `client_id = "host:<host_id>"` as `source_client_id`. Preserve it as legacy owner data during compatibility.
- Populate historical `source_client_id` only from trustworthy retained source evidence. Otherwise leave it explicitly unknown.
- Populate historical `source_scope` only from privacy-safe retained source evidence. Preserve historical project and source-scope values as provenance; do not use them to choose a different owner.
- Before cutover, every in-scope row must be mapped, or have an explicit audited operator disposition that records why it cannot be mapped and what migration, revocation, quarantine, or retirement action applies. Dispositioned rows remain readable through the authorized legacy path until that action completes.
- Cutover requires zero unresolved in-scope rows. Verify row counts, exact scope/namespace preservation, identity mappings, operator dispositions, and legacy readability before read cutover.

### Stage 3: Dual Compatibility and Fail-Closed Ingest

- Resolve the canonical partition before accepting new events or tool mutations.
- Persist the explicit canonical partition while retaining the legacy fields needed by v1 readers and rollback.
- Route reads and authorization through the canonical mapping, with comparison telemetry or audits for any legacy/canonical mismatch.
- Reject conflicting claims as permanent authorization/validation failures so the host does not retry them indefinitely.

### Stage 4: Cut Over and Retire Ambiguity

- Cut reads, projections, rebuilds, governance, and edge delivery to `memory_space_id` only after backfill and parity validation pass.
- Retain legacy aliases and protocol translation for the documented compatibility window.
- Remove overloaded legacy behavior only in a later reviewed migration after rollback no longer depends on it.

Rollback during the compatibility stages means returning readers to legacy fields while keeping newly accepted data representable under the original host-private behavior. Cross-host sharing must remain disabled during this window because shared writes cannot be faithfully represented by the old one-host owner model.

## Protocol Implications

- `host_memory.v1` remains supported during rollout. Its announced scope and host identity are translated through the server-side private-space mapping; neither creates entitlement.
- A v1 source that omits scope may be accepted only when the server derives one complete authorized target scope. A supplied v1 scope is retained as `source_scope` after privacy filtering and, because v1 also presents it as a target claim, is consistency-checked; a conflict is permanently rejected before ACK.
- Capture protocol evolution must distinguish canonical `memory_space_id` and `scope` from provenance `source_client_id`, `project`, and `source_scope`. Changes must be versioned; v1 field meanings must not silently change.
- A future `host_memory.v2` join, delta, snapshot, and ACK identifies the canonical memory-space partition and verifies that the authenticated host is an entitled delivery target.
- Edge revisions and cursors belong to the canonical memory-space partition, while applied cursors remain associated with a delivery host. This ADR defines the identities, not the concrete cursor protocol or storage schema.
- Authorization and partition mismatch are permanent errors. Transport or storage availability failures remain retryable under their existing classifications.
- Legacy open or installation-wide modes may resolve a partition only when exactly one authorized mapping exists. Ambiguity remains unauthorized.

## Consequences

### Benefits

- Durable ownership no longer changes meaning when a runtime, credential, host token, project path, or delivery host changes.
- Capture ingestion can guarantee projection-safe partition completeness at the accepted ACK boundary.
- Runtime provenance survives without being confused with ownership.
- Cross-host sharing has a safe future seam based on explicit entitlement rather than project-string coincidence.
- Host revocation and canonical data governance become independent operations.
- Rebuilds, recall, governance, audit, and edge synchronization can use one partition vocabulary.

### Costs and Constraints

- Subsequent PRs need durable mapping, backfill, dual compatibility, and mismatch observability.
- Historical source runtime identity may be unrecoverable because v1 upcasting overwrote it; the migration must represent that uncertainty honestly.
- Compatibility code must keep old host-private clients working until version negotiation and cutover complete.
- Initial deployments gain no cross-host sharing; two hosts with the same project remain isolated.
- Operators and developers must distinguish authentication client IDs, source client IDs, memory-space IDs, scopes, and namespaces in APIs, logs, and telemetry.
- Revocation, deletion, recall, and edge-delivery tests must cover both owner and delivery identities.

## Validation

Implementation of this ADR is not complete until automated tests prove:

1. A missing source scope remains unknown provenance while canonical scope is derived from one authorized target or the event is rejected before ACK.
2. A privacy-safe supplied source scope is retained as `source_scope` on every new accepted event and never changes authorization; a v1 source-scope claim that conflicts with its canonical target is rejected before ACK.
3. A host cannot read, write, recall, govern, or receive delivery for another memory space without explicit entitlement.
4. Every accepted canonical event persists a complete `memory_space_id`, scope, namespace, and authenticated host provenance.
5. Direct tool operations and captured events resolve to the same canonical partition.
6. Projection and replay rebuilds cannot create ownerless rows or fail solely because canonical partition fields are absent.
7. Summary, semantic, procedural, lesson, crystal, graph, profile, activity, recall-trace, and coordination workers reject ownerless writes.
8. Backfill covers every defined in-scope row once, is idempotent, reports conflicts, and never treats legacy owner `client_id` as source provenance.
9. Existing `shared` and `team:*` rows retain their exact scope/namespace and remain legacy-readable until mapped or explicitly dispositioned.
10. Changing a host's default `memory_scope` does not orphan or silently revoke its prior subpartitions.
11. Cutover is blocked by any unresolved in-scope row; every exception has an audited operator disposition and remains legacy-readable until the disposition completes.
12. Legacy v1 clients continue to operate within their mapped private space during the compatibility window.
13. Canonical and legacy reads produce equivalent host-private results before cutover, including governance and tombstones.
14. Revoking host delivery entitlement prevents subsequent sync without changing or deleting the canonical owner space.
15. Rollback before cross-host sharing restores legacy reads without losing newly accepted canonical data.

Operational validation must also report ownerless canonical events/memories, legacy-to-canonical mapping conflicts, mixed partitions within a session, rejected conflicting claims, and host delivery attempts without entitlement.

## Rejected Shortcuts

- Keep using `client_id` for both source runtime and durable owner.
- Treat `host_id` as the permanent owner rather than a staged private-space mapping.
- Infer shared ownership from equal project paths, repository names, source scopes, or namespace strings.
- Let source-provided scope or project grant authorization.
- Silently overwrite a conflicting owner, host, scope, or namespace claim.
- ACK an incomplete event and rely on a projection worker to reject or repair it later.
- Backfill `source_client_id` from the legacy `host:<host_id>` owner value.
- Perform a destructive big-bang rename or reinterpret existing identifiers in place.
- Enable cross-host delivery before membership, revocation, audit, and rollback semantics are explicit.
- Introduce nullable canonical owner writes as a transition mechanism.
- Define a concrete database schema in this ADR before the compatibility requirements and implementation audit are reviewed.

## Non-Goals

- Designing or enabling cross-host sharing or its entitlement administration.
- Choosing a concrete database table layout, migration sequence, ID encoding, or index set.
- Defining the full `host_memory.v2` revision, delta, snapshot, or cursor protocol.
- Implementing the remote-first host memory facade or bounded edge mirror.
- Deciding host-edge encryption; that is covered by a separate ADR.
- Replacing Backplane's authentication system or broadening host permissions.
- Adding multi-tenant isolation beyond the approved Memory V2 product scope.
- Changing memory taxonomy, recall ranking, lifecycle algorithms, or retention policy beyond defining namespace as their policy boundary.

## References

This ADR is self-contained. The handoff listed below was reviewed as external planning input but is not required to interpret or implement this decision.

- `docs/memory/backplane-memory-agentmemory-parity-design-v2.md` — authoritative v2 ownership, capture envelope, ingestion, namespace/scope, and compatibility direction.
- `docs/memory/backplane-memory-agentmemory-parity-prd-v2.md` — v2 ingestion, authorization, namespace, rebuild, and release requirements.
- `/home/gao/Workspace/gsmlg-opt/backplane/docs/memory/backplane-memory-v2-codex-handoff.md` — external, user-owned planning input that was untracked at baseline and reviewed from the primary checkout; it is not copied into or required by this branch.
- `apps/backplane_memory/lib/backplane/memory/partition.ex` — current authenticated host-private partition resolution.
- `apps/backplane_memory/lib/backplane/memory/authorization.ex` — current tool claim validation, trusted argument overwrite, and owned-memory checks.
- `apps/backplane_memory/lib/backplane/memory/ingest.ex` — current host capture authorization, partial ACK, filtering, and persistence boundary.
- `apps/backplane_memory/lib/backplane/memory/ingest/event_validator.ex` — current optional source identity, project, and scope validation.
- `apps/backplane_memory/lib/backplane/memory/ingest/upcaster/v1.ex` — current `host:<host_id>` owner construction, source-scope persistence, and raw-envelope overwrite.
- `apps/backplane_memory/lib/backplane/memory/events/event.ex` — current persisted event fields and required-field boundary.
- `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex` — current capture auth context and host-memory principal metadata.
- `apps/backplane_host_agent/lib/backplane/host_agent/memory/event_envelope.ex` — current v1 capture envelope field requirements.
- `apps/backplane_skills/lib/backplane/skills/host.ex` — current registered host and `memory_scope` source.
