# ADR: Host-Edge Memory Protection

- **Status:** Accepted (staged)
- **Date:** 2026-08-29
- **Baseline:** `55835fbd799c81238e455446f8fa43701a5adda6`
- **Decision scope:** At-rest protection and production enablement of the new canonical edge mirror and its content-bearing provisional fields; existing persistence is inventoried but not retroactively governed except where stated

## Context

Backplane is the authority for long-lived memory. The host-agent may retain three distinct kinds of local state:

1. a bounded capture spool containing privacy-filtered events until durable server ACK;
2. a command outbox containing provisional explicit memory operations; and
3. a bounded, non-authoritative mirror of Backplane-selected canonical memory for visibly stale offline recall.

The existing capture spool already has optional field encryption. The current host memory database does not provide equivalent protection, yet its `memories`, `facts`, and `slots` tables can contain user memory, tags, metadata, and device-local values in plaintext. Expanding that database into a restart-persistent canonical edge mirror would increase both the sensitivity and lifetime of local data.

The v2 design requires host-local privacy filtering before persistence and describes the capture spool as a bounded delivery queue, not a memory database. The remediation handoff separately requires the future edge mirror to survive restart and remain useful offline. That makes at-rest protection of the new mirror and its protected provisional fields a production gate rather than an optional later hardening step.

## Current Protection Inventory

| State | Current storage and protection | Key/config source | Failure behavior and limitation |
|---|---|---|---|
| Capture event envelope | `capture_event_spool.envelope_json` is plaintext when no cipher is configured. With `capture.encryption_key_env`, `Backplane.HostAgent.Memory.Spool.Cipher` stores an authenticated `bpenc:v1:` value using AES-256-GCM and binds it to the event ID with AAD. | The config contains only an environment-variable name. That environment variable must contain a Base64-encoded 32-byte key. | Missing/invalid key configuration prevents encrypted spool startup. A verifier detects a wrong key. Encrypted data opened without a cipher, unsupported `bpenc` versions, authentication failures, migration/checkpoint failures, and rewrite failures return errors rather than being treated as plaintext. |
| Import duplicate envelope | New `capture_import_fingerprints.envelope_json` rows receive the same stored envelope as the spool row, so they are encrypted when the cipher is active. | Same capture-spool key. | Startup rewrite scans `capture_event_spool`, not `capture_import_fingerprints`; therefore protection of fingerprint rows created before encryption was enabled is not established by the current migration path. |
| Capture operational metadata | Event IDs, idempotency keys, session IDs, sequence, sizes, states, reasons, attempts, and timestamps remain ordinary Turso columns. | None. | The field cipher protects event payload JSON, not all activity metadata or the database file as a whole. |
| Current host memories and provisional commands | `Backplane.HostAgent.Memory.Migrations.V1` creates plaintext `memories.content`, `tags`, and `metadata`; `memory_outbox` references those rows. | No memory-store encryption setting exists. | `Backplane.HostAgent.Memory.Store` forwards a database path to `Turso.start_link/1` and configures WAL/busy timeout only. Missing protection does not prevent startup. |
| Current host facts | `facts.content`, `tags`, and `metadata` are plaintext. | None. | These rows are the closest current analogue to an edge mirror, but have no key check, encryption mode, or protected-open failure path. |
| Device-local slots | `slots.value` is plaintext. | None. | This ADR does not classify slots as canonical mirror data, but a slot containing user memory has the same local disclosure risk. |
| Central credential values | `Backplane.Settings.Credentials.store/4` encrypts credential plaintext through `Backplane.Settings.Encryption`; the Ecto field is binary and redacted, `fetch/1` decrypts, and Vault listings omit the encrypted value. | One key is derived from Backplane's `secret_key_base` using HMAC-SHA-256; the encryption primitive is AES-256-GCM with fixed facility AAD. | This is a central credential facility, not a host-edge key lifecycle. It does not currently give a separately deployed host-agent an offline mirror key or per-host rotation protocol. |

The existing capture-spool format is grandfathered for that bounded queue only. It is not a reusable or approved format for the edge mirror.

## Dependency Capability Evidence

The dependency chain at the baseline is:

- root `mix.lock`: `ex_turso 3.0.3`;
- `deps/ex_turso/native/ex_turso/Cargo.lock`: `turso 0.6.1`;
- `deps/ex_turso/native/ex_turso/Cargo.toml`: `turso = { version = "0.6", features = ["sync"] }`.

The locked Rust `turso 0.6.1` crate contains an experimental local database-encryption API: `Builder.experimental_encryption/1` and `Builder.with_encryption/1`. Its package tests create an encrypted database, assert a plaintext marker is absent from the database file, reopen with the correct key, and reject wrong-key and missing-key opens. This is direct evidence that the underlying locked crate has an experimental capability.

The locked `ex_turso 3.0.3` wrapper does not expose that capability:

- `Turso` and `Turso.Connection` document and consume only `:database`, optional `:remote_url`, and optional `:auth_token` as Turso-specific open options.
- `Turso.Native.open/1` accepts only a path.
- the Rust NIF implementation calls `Builder::new_local(&path).experimental_index_method(true).build()` without enabling encryption or supplying `EncryptionOpts`;
- the sync NIF accepts only path, remote URL, and auth token.

Therefore database encryption is present below the wrapper but is not a supported, callable capability of the dependency surface Backplane uses. The experimental upstream API is not sufficient evidence to enable production storage encryption until `ex_turso` exposes it and Backplane validates its file, WAL, backup, error, and key-rotation behavior.

## Threat and Data Classification

### Protected data

- Memory content, provisional remember content, facts, bounded provenance excerpts, tags, and content-bearing metadata are **confidential user data**.
- Scope, namespace, project, source references, timestamps, access patterns, and lifecycle metadata are **sensitive operational metadata** even when content is encrypted.
- Encryption keys, wrapped data keys, recovery material, and rotation secrets are **critical secret material** and must never be stored beside ciphertext in plaintext.

### Threats in scope

- copying or stealing the host database, WAL/SHM files, temporary rewrite files, snapshots, or backups;
- unintended disclosure through a multi-user host, support bundle, filesystem backup, or discarded disk;
- continuing the new mirror or its protected provisional fields in plaintext after a key is missing, wrong, corrupt, or no longer usable;
- partial rotation, crash recovery, or rollback leaving plaintext or an unreadable mixed-key database;
- treating an unprotected local cache as acceptable merely because canonical data also exists in Backplane.

### Threats outside this decision

This ADR does not claim protection from a process or account that can read the live host-agent address space and its active keys, a fully compromised host, malicious plaintext returned by an authorized recall, or traffic interception already covered by the authenticated transport boundary. Operating-system full-disk encryption remains useful defense in depth but is not the application-level production gate.

## Decision

1. **The existing bounded capture-spool cipher may remain.** PR0 does not change its format or optional configuration. Its format must not be copied to the canonical edge mirror.
2. **A long-lived canonical edge mirror is blocked from production enablement** until one of these reviewed protections is implemented:
   - storage encryption exposed through a supported dependency API and validated by Backplane; or
   - field-level envelope encryption built from existing project credential/encryption facilities, with an approved host key lifecycle and format review.
3. **Plaintext persistence of the new canonical edge mirror and its content-bearing provisional fields is permitted only for development and test.** It requires an explicit plaintext-development guard, must be rejected in production, and must emit a visible startup warning plus an observable degraded protection status. This restriction does not change the grandfathered capture-spool behavior or silently reclassify unrelated existing persistence. The default is not permission.
4. **There is no silent plaintext fallback for the new mirror or its protected provisional fields.** Missing keys, wrong keys, unsupported formats, corrupt ciphertext, or unavailable protection prevent mirror open, synchronization writes, and offline reads. A failed rotation has the same effect unless a verified rollback restores one complete, authenticated prior-key state. The host may continue independent capture-spool delivery and online canonical recall when those paths are healthy; it must report offline memory as unavailable rather than opening or recreating a plaintext mirror.
5. **No new custom cryptographic format is approved.** Implementation must use the supported database format or the reviewed project envelope facility. The capture spool's `bpenc:v1:` encoding is not precedent for another format.
6. **The current plaintext `facts`/`memories` database is not an approved production mirror.** Subsequent PRs may add compatible schema while the feature remains disabled, but production canonical deltas and snapshots must not persist content there until this gate passes.

## Alternatives Considered

### Supported database encryption

This is the preferred operational shape if `ex_turso` exposes a stable, reviewed API. It can cover content, indexes, metadata, and database sidecars without teaching every query about ciphertext.

It is not selected for immediate use because the callable `ex_turso 3.0.3` surface omits the locked crate's experimental encryption builder and has no wrapper-level key, cipher, rotation, or compatibility contract. Transitive support must not be reached through a private NIF fork or an unreviewed local patch.

### Field-level envelope encryption using existing facilities

Backplane already has an AES-256-GCM encryption primitive and an encrypted credential store. A reviewed extension could use per-host or per-mirror data keys, store only wrapped key material centrally, version ciphertext/key references, and protect every content-bearing edge field.

This remains acceptable but is not yet designed. The present facility derives one central key from `secret_key_base` and does not solve offline host key availability, per-host separation, searchable fields, metadata leakage, backup recovery, or rotation. Implementation must extend the facility deliberately; it must not copy functions or invent another prefix/blob format at a callsite.

### Deployment restriction

This is the selected immediate alternative. Production deployments cannot enable or persist the new canonical edge mirror or its protected provisional fields. Development/test plaintext for that state is explicitly opted into and visibly unsafe. This preserves the authority and offline-mirror design without making an unsupported security claim and does not alter the grandfathered capture spool.

### Reuse the spool cipher or rely on disk encryption

Rejected. The spool cipher is purpose-bound to event envelopes and event-ID AAD, and its current migration coverage is not a general database-encryption contract. Disk encryption is deployment defense in depth but cannot enforce Backplane's missing/wrong-key and no-plaintext behavior or protect exported database copies by itself.

## Staged Rollout

### Stage 0: Decision gate

PR0 changes documentation only. Existing runtime behavior remains unchanged. The mirror production flag must remain unavailable or false.

### Stage 1: Select and expose the protection mechanism

- Prefer supported database encryption if the dependency API is accepted after upstream review.
- Otherwise produce and review a field-level envelope design using existing project facilities.
- Define the protected column/metadata inventory, key provider, key identifiers, backup/recovery contract, and rotation state machine before writing canonical mirror content.
- Schema and protocol work may proceed behind the disabled production gate, but must not make plaintext persistence of canonical mirror or protected provisional content the migration default.

### Stage 2: Implement fail-closed protection

- Resolve and verify protection before opening or creating the persistent mirror.
- Encrypt all content-bearing mirror and provisional fields selected by the reviewed design.
- Bind ciphertext to stable record identity and schema/purpose where the selected facility requires AAD.
- Expose protection mode, key identifier (never key material), rotation state, and last successful verification to operations.
- Keep capture spool, command outbox, and edge mirror as separate stores and key purposes.

### Stage 3: Development-only mirror plaintext

- Permit plaintext canonical mirror and protected provisional fields only in `dev`/`test` with an explicit guard.
- Display a persistent warning in startup logs and protection status/diagnostics.
- Refuse that mirror guard in production and refuse implicit mirror/provisional plaintext when the guard is absent. This does not change the capture spool's separate existing configuration.

### Stage 4: Production opt-in

- Enable only after all validation below passes for new databases, upgraded databases, WAL/sidecars, backups, restart, and rotation.
- Roll out per host with observed protection mode and mirror revision.
- Roll back by disabling and removing/rebuilding the non-authoritative mirror; never downgrade it to plaintext.

## Failure Behavior

| Failure | Required behavior |
|---|---|
| Mirror protection not configured in production | Do not create/open the canonical mirror or persist its protected provisional fields; reject production enablement with an actionable error. This does not redefine grandfathered capture-spool startup. |
| Missing or wrong key | Do not open, replace, truncate, resnapshot, or recreate plaintext storage. Mark mirror unavailable. |
| Unsupported cipher/format/key version | Fail closed and preserve files for operator recovery. |
| Corrupt ciphertext or authentication failure | Abort the transaction/batch, do not advance the applied revision or ACK, and surface a classified error without content. |
| Rotation interrupted | Resume through an explicit durable rotation state, or perform and verify rollback to one complete authenticated prior-key state before restoring availability. If neither succeeds, keep the mirror unavailable. Never accept a mixed state as complete. |
| Backup restore lacks its key | Refuse restore/open and report the required key identifier; do not initialize over the restored file. |
| Encryption migration fails | Leave the canonical mirror feature disabled and the previous recoverable state intact. Do not fall back mirror or protected provisional fields to plaintext. |
| Mirror unavailable while online | Continue canonical remote recall if authorized and healthy; report no offline guarantee. |
| Mirror unavailable while offline | Return an explicit unavailable/degraded result, never an empty success or plaintext fallback. |

## Key Lifecycle Requirements

- Generate keys with a cryptographically secure source and keep raw key material out of repository files, ordinary YAML/TOML, database rows, logs, telemetry, crash reports, supervisor child specs, and UI responses.
- Use separate key purpose/domain separation for capture spool and canonical mirror. Sharing a raw key is not approved.
- Assign a non-secret key identifier and format/version to every protected database or record set.
- Provide the host with an offline-capable secret source appropriate to the deployment. A central credential reference alone is insufficient if the mirror must reopen during a Backplane outage.
- Define provisioning, activation, backup/escrow, recovery, rotation, revocation, and destruction before production use.
- Rotation must be crash-safe, restartable, authenticated before cutover, and must not advance the mirror revision until the protected transaction is durable. A rollback may restore availability only after verification proves the entire store is back in one complete prior-key state.
- Retain old key material only for the bounded recovery window; destroy it only after database, sidecar, backup, and restore validation succeeds.
- A lost key makes the non-authoritative mirror disposable, not recoverable through plaintext. Rebuild from Backplane after operator-authorized cleanup and reprovisioning.
- Never log plaintext or raw keys while diagnosing wrong-key, corruption, migration, backup, or rotation failures.

## Consequences

### Benefits

- Backplane does not silently expand a short-lived queue exception into a long-lived plaintext memory database.
- Production behavior fails closed and reports an honest offline-recall capability.
- Either accepted implementation reuses a reviewed storage or project facility instead of introducing another crypto format.
- The edge mirror remains disposable and non-authoritative: protection failure cannot mutate canonical memory or trigger upstream forget.

### Costs and constraints

- Production persistent offline recall remains unavailable until a protection implementation passes review and validation.
- Database encryption depends on an upstream wrapper change and maturity review despite capability in the locked Rust crate.
- Field-level encryption would add key delivery, rotation, query/index, migration, and metadata-classification complexity.
- Development plaintext for the canonical mirror and protected provisional fields requires explicit friction and visible warnings.
- Operators must back up keys and data together while keeping them separately controlled.

## Validation

Production enablement requires automated tests that prove:

1. A protected mirror survives host-agent and machine/process restart with the correct key.
2. Missing-key and wrong-key opens fail without creating, truncating, replacing, or downgrading the database.
3. Unsupported versions and corrupted/authentication-failing ciphertext fail closed.
4. Protection migration and rotation are atomic or durably resumable across failures at every phase; verified rollback restores one complete prior-key state, while incomplete rollback leaves the mirror unavailable.
5. Old and new keys follow the documented recovery window and the old key cannot read post-cutover writes after retirement.
6. Known plaintext markers do not appear in the main database, WAL, SHM, temporary rewrite files, snapshots, exports, backups, support bundles, or ordinary logs after checkpoint and restart scenarios.
7. Backup plus the correct key restores the mirror and revision; a missing or wrong key fails safely.
8. Delta and snapshot application ACK only after protected commit, and a failed decrypt/write does not advance the applied cursor.
9. Eviction, quota enforcement, tombstone/delete convergence, and mirror rebuild do not emit plaintext or upstream forget operations.
10. Development plaintext for the canonical mirror and protected provisional fields requires the explicit guard, emits the visible warning/status, and is rejected under production configuration without changing the capture spool's separate behavior.
11. Protection status and errors expose classifications and key identifiers without content or key material.
12. Capture-spool restart, wrong-key, migration, and delivery behavior remains unchanged by mirror protection work.

Validation must run against the exact locked dependency/native artifacts used by the release, not only a mocked cipher or an upstream crate unit test.

## Escalation Rule

The missing callable database-encryption capability belongs to the internal `ex_turso` package whose declared source is `gsmlg-dev/concord` under `apps/ex_turso`. It is already tracked by open Feature issue [gsmlg-dev/concord#91](https://github.com/gsmlg-dev/concord/issues/91), labelled `internal request` with severity `needed`. Do not create a duplicate issue.

The only deferred escalation action is at the eventual Backplane dependency callsite: add `# TODO(upstream): gsmlg-dev/concord#91`. Until the dependency exposes a reviewed API, do not reach through private NIF internals or add a local cryptographic workaround. A reviewed field-level-envelope implementation is a separate approved alternative, not silent fallback, and the production mirror gate remains closed until one accepted protection path passes validation.

## Non-Goals

- Implementing encryption, keys, schema, protocol, migrations, or feature flags in PR0.
- Changing or replacing the existing capture-spool cipher.
- Making host-agent authoritative for memory or adding local semantic processing, embeddings, or vector search.
- Defining the `host_memory.v2` delta/snapshot schema beyond its protected-commit requirement.
- Protecting the central PostgreSQL deployment, transport, live process memory, or authorized recall output.
- Treating operating-system disk encryption as proof of application-level protection.
- Selecting a cipher, inventing a ciphertext encoding, or blessing the locked crate's experimental API as production-ready.
- Broadening host permissions, memory-space entitlement, or cross-host sharing.

## References

- `docs/memory/backplane-memory-agentmemory-parity-design-v2.md` — authoritative host boundary, bounded spool, at-rest requirement, privacy, and failure model.
- `docs/memory/backplane-memory-agentmemory-parity-prd-v2.md` — capture durability/privacy requirements, host-spool risk, and release criteria.
- `/home/gao/Workspace/gsmlg-opt/backplane/docs/memory/backplane-memory-v2-codex-handoff.md` — external user-owned handoff reviewed from the primary checkout. It is untracked, absent from this worktree, and is not part of PR0. This ADR is self-contained and does not require the handoff to ship with it.
- `apps/backplane_host_agent/lib/backplane/host_agent/config.ex` — separate memory/capture paths and the capture key-environment setting.
- `apps/backplane_host_agent/lib/backplane/host_agent/memory/spool/cipher.ex` — current spool format, AES-256-GCM primitive, AAD, key parsing, verifier, and failure classes.
- `apps/backplane_host_agent/lib/backplane/host_agent/memory/spool/turso.ex` — protected envelope writes/reads, verifier, plaintext migration, rewrite/checkpoint, and fail-closed open behavior.
- `apps/backplane_host_agent/lib/backplane/host_agent/memory/store.ex` — current plaintext Turso pool and WAL/busy-timeout configuration.
- `apps/backplane_host_agent/lib/backplane/host_agent/memory/migrations/v1.ex` — plaintext host-memory, fact, outbox, tombstone, and slot schemas.
- `apps/backplane_system/lib/backplane/settings/encryption.ex` — existing central AES-256-GCM facility and `secret_key_base` key derivation.
- `apps/backplane_system/lib/backplane/settings/credential.ex` — redacted encrypted credential field.
- `apps/backplane_system/lib/backplane/settings/credentials.ex` — encrypted credential store/fetch behavior.
- `apps/backplane_system/lib/backplane/settings/credentials/vault.ex` — encrypted ETS cache and non-secret list surface.
- `mix.lock` — locked `ex_turso 3.0.3` package.
- `deps/ex_turso/lib/turso.ex` and `deps/ex_turso/lib/turso/connection.ex` — exposed Turso options and open path.
- `deps/ex_turso/lib/turso/native.ex` and `deps/ex_turso/native/ex_turso/src/lib.rs` — native callable signatures and builder calls without encryption.
- `deps/ex_turso/native/ex_turso/Cargo.toml` and `deps/ex_turso/native/ex_turso/Cargo.lock` — locked underlying `turso 0.6.1` dependency.
- Locked `turso 0.6.1` crate source, `src/lib.rs` and `tests/integration_tests.rs` — experimental builder API and direct correct/wrong/missing-key file tests.
