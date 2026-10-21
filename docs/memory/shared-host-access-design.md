# Explicit cross-host Memory access

**Status: OPTION B AUTHORIZED; implementation interfaces frozen.**
Architecture Task58, 2026-10-20. Branch `codex/memory-local-live-acceptance`,
inspected baseline `c7044093f0aedcb97434a0c0caba03b864c99bb3` plus existing
uncommitted work. This document specifies the next implementation; it does not
claim implementation, tests, L13, or L18 have passed. User selected independently
controlled remember and forget in addition to read/delivery. Qualification is
restricted to two distinct host processes on this machine, not cross-machine work.

## Requirement, existing boundaries, and decision

Backplane owns canonical data. Hosts own capture, provisional command intent, and
bounded mirrors. Authority selects exactly `{memory_space_id, scope, namespace}`;
source host/client identity remains provenance. Sharing must preserve private
capture, canonical IDs, tombstones, and the permanent-denial/no-fallback invariant.

The [partition ADR](adr-memory-space-partition.md) deliberately postponed sharing
until membership, operations, delivery, revocation, audit, and rollback were defined.
This decision supplies those definitions without replacing the ADR's identity model.
The [V2 protocol](host-memory-v2-protocol.md) remains the base transport contract;
the explicitly negotiated extensions below are additive to it.

| Inspected source and symbol | Existing behavior / implementation seam |
| --- | --- |
| `apps/backplane_system/lib/backplane/memory_spaces.ex`: `resolve_host_partition/3`, `host_entitlements/1` | Ordinary calls resolve a private alias; feed inventory enumerates active exact entitlements. |
| `apps/backplane_system/lib/backplane/memory_spaces/entitlement.ex` | Existing unique host/space/scope/namespace entitlement; status and default-capture fields. |
| `apps/backplane_memory/lib/backplane/memory/authorization.ex`: `owned_memory/2` | Target validation additionally restricts source host/client; explicit shared forget needs a separate canonical grant check. |
| `apps/backplane_memory/lib/backplane/memory/memories.ex`: `apply_exact_partition/2`, `write_partition/1` | Reads/deletion use the canonical triple; generation validates source identity separately. |
| `apps/backplane_memory/lib/backplane/memory/edge_sync/postgres_store.ex`: `authorize!/3`, `next/3`, `ack/2` | Host-row `FOR SHARE` precedes delivery/cursor operations; lifecycle uses the same row `FOR UPDATE`. |
| `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex`: `dispatch_memory/5`, `active_token?/1` | Private joined partition; explicit raw authority rejection; token check at ingress. |
| `apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex`: `remember_host_item/5`, `forget_host_item/5` | V1 command identity and mappings are host-private; do not reinterpret their wire meaning. |
| `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/syncer.ex`: `read_context/2` | Inventory selects mirror context; that cached map alone is insufficient revocation authority. |
| Host `memory.ex`, `memory/syncer.ex`, `memory/mirror/store.ex` | Command rows/overlays and mirror generations use separate Turso pools; need one admission owner above both. |

Selected B permits four capabilities. Read-only sharing (A) is a valid subset but
cannot satisfy the selected independent mutation requirement. Alias reassignment,
copying content into a second private space, and inserting unrestricted grant rows
are rejected because they change identity or fail to define operation authority.
No new dependencies, gateway subsystem, auth system, or source-provenance rewrite.

| Capability | Exact permitted operation | Dependencies |
| --- | --- | --- |
| `read` | Explicit-target recall, list, stats | None. Online use does not require delivery. |
| `deliver` | V2 delta/snapshot issuance and ACK | Requires `read`: a payload delivery discloses readable content. Reject invalid combinations; never silently add read. |
| `remember` | Create durable command intent and settle remember in this exact target | None. Does not permit read, delivery, forget, or modifying an existing record's facets. |
| `forget` | Create durable deletion intent and tombstone a supplied canonical ID in this exact target | None. Does not permit remember/read/delivery; an ID can be supplied without first reading it. |

Only `recall`, `list`, `stats`, `remember`, and `forget` gain the explicit selector.
Derivation, consolidation, replay, lifecycle-context injection, shared capture,
slots, facet mutation/query, and operator governance do not gain shared authority.
Existing automatic processing of accepted data keeps its current policy. Facets
supplied as part of a new remember retain the existing remember contract.

## Registry schema, defaults, and migration

Extend `bpm_memory_space_entitlements`; retain its UUID as `access_id` and current
unique `(memory_space_id, host_id, scope, namespace)` and active-default indexes.
Do not delete/reinsert a grant on revoke/regrant. Add:

| Field | Storage / default / invariant |
| --- | --- |
| `capabilities` | PostgreSQL `text[]`, non-null, default `[]`; unique sorted subset of `read, deliver, remember, forget`; DB check for allowed values and `deliver => read`. |
| `authority_version` | bigint, non-null, default `1`, positive; increments on every effective status/capability/lease change, including regrant and host-wide revoke. Never decreases. |
| `offline_read_lease_seconds` | integer, non-null, default `0`, range `0..300`; meaningful only with read+deliver; reject nonzero without both. |

Retain `status = active|revoked`, `default_capture`, host ID and canonical tuple.
A shared grant always starts with `default_capture=false`; it cannot edit the tuple,
private alias, default capture, host configuration, or space kind. Granting A's
`private` namespace to B shares that exact existing content without renaming it.

Backfill under a migration transaction: for rows proven by the existing durable
host legacy alias to point to that host's private space, assign all four capabilities
while preserving status, default flag, scope, namespace and version 1. Include
historical nondefault scope/namespace grants backed by that alias; do not reactivate
revoked rows. Existing default capture/provisioning explicitly supplies these
capabilities on newly created private grants. Provisioning/default-scope updates
must not silently reactivate a revoked entitlement or reset its version.

Other pre-existing rows retain status but receive `[]` and cannot authorize shared
operations. Record each in `bpm_memory_space_backfill_issues` with reason
`shared_access_requires_disposition`, source entitlement ID and exact tuple, without
content. An audited explicit grant/change resolves that issue; never infer access
from namespace, source project, or presence of canonical records. No unresolved
row may be exposed by old inventory code during cutover. No data/alias migration.

Add `bpm_memory_access_audits` (owned by system): UUID `id`, UUID `request_id`,
`actor_kind` (`trusted_operator|system`), nullable bounded `actor_ref`, `action`,
`access_id`, `host_id`, exact tuple, previous/new status, previous/new capabilities,
previous/new lease seconds, previous/new authority version (previous null on
creation), bounded nonempty `reason`, and UTC microsecond `inserted_at`. These are
append-only durable authority-change records, independent of telemetry switches.
No token, raw request, content, or invented human identity. Failed validation/CAS
returns an error with no authority transition/audit row; successful no-op requests
return unchanged state without a new version/audit. Host lifecycle revoke creates
one audit row per effective entitlement transition, with actor_kind `system` and
an explicit lifecycle reason in the same transaction.

## Frozen domain interfaces and transaction boundary

```elixir
# Backplane.MemorySpaces; all return {:ok, value} | {:error, reason}
grant_host_access(operator, host_id, partition, capabilities, opts)
change_host_access(operator, access_id, expected_version, attrs, reason)
revoke_host_access(operator, access_id, expected_version, reason)
list_host_access(host_id)                 # admin, includes revoked rows
list_partition_access(partition)          # admin, includes revoked rows
resolve_host_access(host_id, selector, operation) # preview, never sufficient to commit
with_host_access(actor, selector, operation, expected_version, fun)
# fun.(access_context) runs under authority locks in the same Repo transaction.

# Backplane.Memory.Authorization
authorize_access(auth, selector, operation) # validates credential operation and host
# {:ok, actor_with_internal_credential_check, descriptor} | {:error, reason}
# Backplane.Memory.SharedCommands
settle(auth, command_envelope)
# {:ok, bounded_ack_map} | {:error, reason}

# Backplane.Memory.Service; read side of extended memory_call
call_shared(tool_name, arguments, auth, access_claim)
# access_claim = %{access_id: uuid, authority_version: positive_integer}
# {:ok, %{access: access_claim, partition: P, result: result}} | {:error, reason}
```

`call_shared/4` accepts only recall/list/stats. Extended remember/forget use the
durable `memory_commands.v2` envelope and `SharedCommands.settle/2`; they cannot
bypass command identity through `memory_call`. This concerns the server transport:
all five operations remain available through the host HTTP/MCP tool interfaces.
The read adapter rejects raw authority fields, validates any scope as equality,
and performs the same-version authorization check immediately before release.
Recognized withdrawn-authority commands may return a persisted ACK with
`status: :rejected` and a bounded code in the successful transport tuple. Hosts
must treat that command outcome as permanent rejection, never provisional success.

`operator = %{kind: :trusted_operator | :system, ref: nil | string,
request_id: uuid}` is constructed inside trusted Admin/lifecycle code, never host
arguments. `opts` is a keyword list; grant requires `:reason` and `:expected_version`:
`0` means no row
exists; positive version means replace/regrant that exact existing row, returning
its original UUID. Optional lease defaults to zero. Change attrs accept only
`capabilities` and `offline_read_lease_seconds`. Revoke preserves caps/lease as
history, sets revoked, clears default capture if applicable, increments version.
Nondefault private grants can be managed explicitly; warn before revoking a default
that capture stops until deliberately restored. Shared UI cannot set default capture.

Public Elixir capability inputs are lists of the four allowlisted atoms; reject
unknown atoms, strings, and duplicates rather than silently broadening a request.
Admin/wire adapters map known strings through a fixed table (never String.to_atom).
`attrs` and `partition` are atom-keyed maps; attrs lease key is
`:offline_read_lease_seconds`. Database arrays and JSON wire capabilities use strings.
Domain results use atom-keyed descriptor maps with atom capabilities/status:
`%{access_id: uuid, host_id: uuid, partition: P, status: :active | :revoked,
default_capture: boolean, capabilities: [...], authority_version: integer,
offline_read_lease_seconds: integer}`. Mutators return one descriptor; list APIs
return a list; resolver returns one active descriptor. Only the locked wrapper adds
the validated actor to the descriptor. `fun` returns `{:ok, value} | {:error, reason}`;
the wrapper flattens the transaction result and rolls back on an error. `expected_version`
is a positive integer for explicit access; nil is permitted only for the private
default compatibility path. Explicit shared wire operations never omit it.

Admin list descriptors additionally expose `latest_audit_reason: string | nil`
from a bounded latest-per-access audit lookup. This metadata is excluded from
host resolver/locked contexts and wire inventory.

`selector = :default | {:access_id, uuid}`. Operations are the four atoms above.
The compatibility default path additionally retains its existing nonshared operation
policy; capabilities do not expand that policy. The shared selector is allowlisted
to the five methods only, even if it names the caller's own private grant.

```elixir
%{
  actor: %{host_id: uuid, credential_id: uuid, source_client_id: string | nil},
  partition: %{memory_space_id: uuid, scope: string, namespace: string},
  access_id: uuid, authority_version: positive_integer,
  capabilities: [atom], offline_read_lease_seconds: 0..300
}
```

Credential scopes intersect capabilities. Host-channel reads/delivery require the
existing recall permission; remember/forget require the existing import/write
permission as well as their separate capability. The authenticated host token ID
must reach the transaction boundary, not be replaced with the host ID. Revalidate
its active assignment under the existing host lifecycle lock. Non-host/open/legacy
callers keep their current private-only behavior and cannot use the new selector.

The internal shared auth map constructed by the channel is
`%{kind: :host_agent, host_id: uuid, auth_token_id: uuid, scopes: [string],
source_client_id: string | nil}`. These are host-agent scopes, not mapped MCP
scopes. `Authorization.authorize_access/3` accepts this host-only shape, validates
the operation, and constructs the internal actor with `credential_id=auth_token_id`.
Its credential check queries the real token/host assignment under the registry's
host lock; an in-memory manager snapshot alone is insufficient. A map from a host
request is never used as this trusted auth context. Private calls retain their
existing auth shape. S2 supplies this adapter; S3 supplies the channel context.

Lock order: authenticated host row `FOR SHARE`, entitlement row `FOR SHARE`, then
existing command/idempotency, canonical-row/revision, cursor/delivery locks in their
established order. Grant/change/revoke and host lifecycle take host `FOR UPDATE`
before entitlement `FOR UPDATE`; all multi-host locks sort UUIDs. Inspect existing
canonical trigger ordering when integrating; do not add revision-before-memory
locks that invert canonical writes. No network/model call while holding these locks.
The `actor` argument additionally requires an internal `:credential_check` key,
an arity-1 function receiving only
`%{host_id: uuid, credential_id: uuid, source_client_id: string | nil}` and returning
`:ok | {:error, :unauthorized}`. The auth/skills adapter constructs this callback
from the real assignment/token validation path; it is never accepted from JSON or
provided by the tool caller. The system wrapper verifies actor IDs and callback
arity, locks host then entitlement, invokes the callback on this identity, checks
version/capability, then calls `fun`. Missing callback, false/nil, exception or any
non-`:ok` return fails closed before `fun`. Do not include the callback in output
descriptors, logs or stored rows. Production callers cannot install an unconditional
success callback; test callbacks may be used only in explicitly isolated tests.
This retains the system app's dependency direction while making revalidation occur
inside the authority transaction. Grant/revoke operator APIs use their separately
trusted internal operator context, not this host callback.

Mutation and receipt commit under these locks. Feed issuance/ACK uses the same
wrapper. For expensive reads, authorize once to build the query, perform retrieval,
then reauthorize the same version under locks immediately before release; discard
results on mismatch. No canonical read may trust ingress authorization alone.
Operations linearized before revoke's commit may finish; operations admitted after
it fail. Payload already transmitted cannot be recalled. Grant/audit commit together;
after commit publish only `{access_id, authority_version, status}` on the host's
existing topic. Notification loss is tolerated by request revalidation/renegotiation.
Implementation uses transactional PostgreSQL `pg_notify` on
`bpm_memory_access_changed`, with JSON `{host_id, access_id, authority_version,
status}`. PostgreSQL releases it only after the outermost transaction commits.
The existing edge notification bridge routes the host ID to the existing host
topic and removes it from the host-facing payload. S1 owns transactional issuance;
S3 additionally owns `edge_sync/notifier.ex` for this bridge integration.

Errors: `unauthorized` for unknown/foreign/revoked selectors or missing capability,
`authority_changed` for an otherwise valid old version, `invalid_request` for syntax,
`partition_mismatch` for target mismatch, `version_conflict` for operator CAS, and
existing storage errors. No content or foreign grant details in host errors.

Read queries use only the canonical triple as visibility identity. New shared
remember retains B as source host, `client_id="host:B"` for existing generator
compatibility, and actual source_client_id when known, inside A's canonical space.
Do not label A as the author. Shared forget locates by canonical ID+triple and calls
existing tombstone/governance logic; it preserves the original source fields and
records B as requesting actor separately. Keep `PartitionIdentity.validate_generator`
and derived-data source checks intact. Recall traces identify the requesting actor
separately from the source provenance of returned candidates.

## Selector and negotiated wire contracts

`memory_access_id` is an optional UUID string in the five shared tool schemas and
both local HTTP/MCP routes. Omission always resolves the existing private/default
path (including permitted existing private scope selection), even with many grants.
An invalid explicit ID never falls back. Strip the selector out of business arguments
and put it into the validated envelope below. Existing scope input can only confirm
the resolved target; do not inject the remember schema's `global` default over a
selected target. Raw memory_space_id/host_id/client_id/partition_id/namespace authority
arguments remain rejected by host interfaces. No selector for capture/import/slots.

Offer `memory_v2.extensions=["memory_access.v1", "memory_commands.v2"]` on join.
Server echoes supported extensions in the selected `host_memory.v2` response.
Both are required for shared command admission; `memory_access.v1` suffices for
shared reads/delivery. No implicit fallback to V1 for explicit shared requests.
A nonextended peer receives only alias-backed private inventory and original shapes.

Extended join response adds `accesses` (the authenticated host's bounded inventory,
including nonread grants) and `default_access_id`. Each entry is:

```json
{"access_id":"uuid","authority_version":2,"status":"active",
 "partition":{"memory_space_id":"uuid","scope":"proj_local","namespace":"private"},
 "capabilities":["read","deliver"],"offline_read_lease_seconds":0}
```

An extended peer may join with `default_access_id: null` when its original private
entitlement is absent or revoked. Explicit shared access remains available through
its independent grant. Omitted-selector reads and canonical private operations
fail closed; no shared grant becomes a substitute default. Existing durable private
intent capture may stay provisional, subject to canonical rejection. Legacy peers
still require their alias-backed private entitlement to join.

`partitions` retains base V2 revision/status fields but contains only read+deliver
entitlements and adds `access_id`/`authority_version`. Access inventory contains no
memory content or counts. Extend the existing bounds (1000 offered partitions,
negotiated frame cap); overflow fails closed, never truncates into an apparently
complete inventory. Missing previously known access IDs in a complete authenticated
inventory fence them. Revoked tombstones need not be enumerated to all clients.

Wire `capabilities` are the effective intersection of the registered grant and
the current authenticated credential's operation scopes: recall permits
read/deliver, import permits remember/forget. Registry/Admin continue to show the
granted capabilities. Include an otherwise eligible descriptor even when its
effective capabilities are empty; never choose a different default.
Wire `offline_read_lease_seconds` is the registered lease only when effective
capabilities include both read and deliver; otherwise it is zero. A lease change
accompanying a same-version credential-capability transition follows the same
credential-policy fence rules; a lease-only mismatch remains an authority change.
Credential replacement may change effective capabilities without changing the grant version.
The host accepts this same-version transition only on fresh authenticated
connection negotiation, hides the prior mirror, requires fresh synchronization,
and rejects pending commands for removed operations. A same-generation mismatch
closes admission with a credential-policy fence recoverable on fresh negotiation;
it cannot clear a true target revoke/version fence. Ordinary versioned grant
changes still apply through authenticated inventory refresh on the current channel.

An extended feed's target-scoped authorization denial uses `{"code":"unauthorized"}`
without `retryable`; the request ticket binds the target fence. The exact marker
`{"code":"unauthorized","retryable":false}` is reserved for a revalidated
credential-wide ingress failure and closes all grants. Storage/conflict errors
retain their retryability metadata. Existing target-scoped `memory_call` string
denials remain compatible.

Extended `memory_call` carries `access:{access_id, authority_version}` alongside
`method` and sanitized `arguments`. Canonical partition is server-resolved. Reply
success echoes `access` and `partition`; the host gates release against its current
connection/request generation. Add authenticated `memory_access_refresh` (empty
request) to refresh that complete inventory without changing a default or reconnecting;
response uses the same `accesses/default_access_id/partitions` shape. The channel
requires the negotiated extension and repeats active-token validation.

For extended `memory_next`, delivery (including `current`), snapshot continuation,
and `memory_ack`, add `access:{access_id,authority_version}` to the base V2 shape;
keep exact partition P and all existing revision/hash fields. Persist access ID and
version on `bpm_host_memory_deliveries` and `bpm_host_memory_cursors` (nullable only
for pre-extension private compatibility). On an authority-version change, expire
old issued deliveries and reset that host's cursor/snapshot association for a fresh
snapshot before granting mirror readability. Canonical changes/snapshots remain
partition-wide; only delivery authorization is host-specific. A canonical snapshot
may be reused only via a newly authorized delivery, never an old host continuation.
ACK binding includes authenticated host, access ID/version, P, issued batch and
existing hashes/revision; a late old-version ACK cannot advance the new cursor.
Extended ACK success preserves base status `advanced|progress|duplicate` and
current-cursor `applied_revision/next_chunk_index`; it additionally echoes validated
`access`, `partition`, `batch_id`, `snapshot_id`, `chunk_hash`, and `integrity_hash`.
The host binds these identities to its ACK ticket. Advanced/progress revisions must
match the expected request; a duplicate may report a newer cursor, but cannot
advance an uncommitted local mirror. ACKs never renew an offline read lease.

`memory_access_changed` is a content-free push with access ID/version/status; host
immediately fences that access, then requests a complete inventory. A push alone
cannot grant authority or renew a lease. Old connection generations cannot update
inventory, release replies, apply delivery or extend leases.

## Durable shared commands and receipts

Keep private `memory_sync` with `host_memory.v1` unchanged. An extended `memory_sync`
uses `protocol="memory_commands.v2"`, max 50 items and existing 512 KiB batch cap:

```json
{"command_id":"uuid","op":"remember",
 "access":{"access_id":"uuid","authority_version":2},
 "partition":{"memory_space_id":"uuid","scope":"proj_local","namespace":"private"},
 "arguments":{"content":"synthetic fixture","type":"episodic"}}
```

Forget uses `op="forget"`, `arguments={"id":"canonical_uuid"}`. The partition is
an equality claim against server-derived authority, not an authorization source.
Each local command persists immutable command ID, operation, access ID/version,
exact target, normalized arguments and payload digest before returning a local
provisional ACK. The caller's idempotency_key maps durably to one command ID under
local agent+access ID+operation; different payload/target for that key is a conflict.
Do not retarget pending commands after default changes, regrant, restart, or discovery.
Unknown/unnegotiated targets cannot create shared provisional work.

A previously authenticated, unfenced target can accept offline command *intent*
after a transport failure, independently of the read lease; this releases only the
caller's command ID/status, never protected content or proof of a remote effect.
Settlement always reauthorizes the captured version. Cold start requires fresh
negotiation before new shared intent; durable already-pending work stays queued.
Known permanent denial blocks new intent and marks affected pending commands
permanently rejected; it must never return provisional-only success. Regrant does
not automatically replay old-version rejected commands. User retry is a new command.

Add `bpm_memory_access_commands` owned by memory (migration in system): composite
unique `(host_id, access_id, command_id)`; exact tuple, `authority_version`, `operation`,
`payload_digest` (SHA-256 canonical normalized JSON, including target/version/op),
`status=committed|rejected`, nullable canonical ID/revision, nullable bounded error
code, inserted/updated UTC microsecond timestamps. No server pending row is needed:
insert final receipt atomically with mutation; rejected status is durable for a
recognized actor/target whose version/capability was withdrawn. Invalid/foreign
requests do not create attacker-selected receipts.

Acquire idempotency lock and check the digest before effect. Same key/digest returns
the saved outcome; different digest/version/op/target is `idempotency_conflict`.
Use a separate remember idempotency scope derived from authenticated host+access ID,
with command ID as key, retaining the existing RememberRequest mechanism. Do not
reuse V1 host/local-ID mappings for shared authorization. Deletion locks canonical
ID under the selected triple and uses canonical tombstones, including existing
mapping invalidation and derived-data governance so no private retry resurrects it.
A delete-only grant does not require a local prior-read receipt; server returns the
same bounded not-found result for an absent or wrong-partition ID.

ACK item: command_id, `status=committed|duplicate|rejected`, access, partition,
canonical_id and revision when committed, or a bounded code when rejected. No
memory body, facets, source metadata, counts, or fetched record in receipts. A
still-authenticated actor may reconcile its own already committed duplicate receipt
after grant revoke, using exact command identity+digest; this exception cannot
execute a new mutation or expose other command IDs. Revoked credentials cannot use
it. Host may record such a late receipt as settled but cannot expose its cached
content/overlay or mark the grant active. Lost ACK retry never duplicates effect.

## Host authority owner, persistent fences, and lease

Introduce `Backplane.HostAgent.Memory.Access`, supervised after the command-store
migrator and before Syncer. It serializes bounded local access admission, invalidation,
command enqueue/settlement and mirror application. It is infrastructure coordination,
not a second canonical registry. Persist its fence/version metadata in the existing
command DB through its owning Turso connection; keep command, capture and edge DBs
separate. Never transfer a checked-out connection into a spawned task.

Frozen host interfaces (explicit server argument may be added for test isolation):

```elixir
Access.install_inventory(connection_generation, inventory)
Access.fence(selector_or_all, reason, connection_generation)
Access.begin_request(selector, operation) # returns immutable target + request ticket
Access.finish_request(ticket, reply)     # gate online response and lease refresh
Access.run_local(target, operation, fun) # serialized, bounded local DB work only
```

`run_local` owns all relevant pool transactions in its own process; its callback
receives the validated target. Never run network/model calls inside it. Mirror read
plus provisional/acknowledged overlay composition occurs within this admission,
not after returning a reusable `read_context`. Deliveries, snapshot activation,
canonical receipt recording, command draining and ACK settlement use the same gate.
No other public path may call a shared store directly with only a cached context.
Mirror-disabled hosts still have the owner and can perform online shared operations.
Owner unavailable or fence persistence failure fails closed for affected shared
operations; it cannot degrade to a bare store read.

Command DB migration V5 adds `memory_access_state`: access_id primary key, exact
partition, authority_version, status (`active|fenced|needs_sync`), capabilities JSON,
lease seconds, nullable fence_reason and updated_at; a singleton global fence row
for credential/protocol-wide rejection; immutable access ID/version/target/op/digest
columns on shared outbox records (nullable for legacy private rows). Mirror migration
V4 adds access ID/version to partition generation metadata. Each active/staging
snapshot belongs to that authority generation; all relevant overlay/receipt/mapping
lookups must match access ID/version as well as P. Existing private rows remain
private and are not guessed into shared grants.

Fence processing first closes admission in the owner, durably persists the fence,
then hides the matching mirror/staging generation and rejects unsent old-version
commands. The primary fence gates all stores, so a crash between the two DB commits
cannot expose the unchanged mirror. No cross-DB atomicity claim. Startup begins
closed for shared data regardless of persisted active status and requires fresh
authenticated negotiation. The existing private offline behavior remains separate.

Newer authenticated authority after revoke/change enters `needs_sync`; obtaining a
complete fresh snapshot for that version makes its mirror readable. Online read can
return freshly authorized canonical data before mirror activation. A same-version
transport reconnect may resume an unfenced generation after negotiation; a persisted
revocation fence cannot be cleared by a same-version stale success. Rejected malformed
individual requests deny that call without revoking unrelated accesses. A genuine
authorization/partition/protocol failure for an issued target fences that target;
credential-wide denial fences all. No cache, pending overlay, ACK overlay, canonical
receipt mapping, lifecycle cache or late network callback bypasses the gate.
Shared lifecycle-context selection remains unsupported; private lifecycle caches
must still clear on credential-wide denial.

**Lease policy is fixed: default 0 seconds, configurable integer 0..300 per grant.**
It governs shared offline protected reads only, requiring read+deliver and a complete
current mirror generation. Zero means no shared offline read even when mirror exists.
Private transport-only fallback remains as already qualified. After a successful
authenticated inventory or version-matched read/feed response, deadline is request
send monotonic time + granted duration (not response arrival). For join use join-send
time; for lease zero no offline deadline. This bounds delayed replies and network
transit without trusting wall clocks. Only a current connection/request ticket may
renew; renewal never increases the negotiated duration. Poll/read failure, invalid
response, ACK receipt, notification, or wall-clock change never renews authority.

Owner checks the monotonic deadline at read admission and before releasing composed
results; expiry fails with `access_lease_expired`, never an empty success or protected
provisional-only fallback. Do not persist monotonic deadlines across VM boots.
Disconnected revocation can remain unknown only until this bounded lease expires;
content already delivered to a client is not remotely erased. Report bounded-stale
metadata honestly. Cold start closes shared reads even if the wall clock moved back.

## Admin, rollout, and rollback

Add an Access section to the existing exact-partition `MemoryMemoriesLive` view
(`memory_memories_live.ex`); preserve its five selection parameters, filters,
pagination, source-summary links, and refresh behavior. No new navigation/router
or hook needed. List registered host name/ID, access ID, active/revoked status,
independent capability checkboxes, lease, current version, and latest audit reason.
Grant/change/revoke call the frozen domain APIs; retain expected_version in forms
and show a conflict with freshly loaded state instead of overwriting. Require a
reason; clearly show the exact tuple and warning when sharing existing private
content or revoking default capture. Revoke never deletes host/data. Use DuskMoon
components and stable `memory-access-*` IDs for local browser/LiveView acceptance.
The trusted-network Admin boundary is unchanged; audit `trusted_operator`, ref nil
unless an actual operator identity exists. Do not add fictitious login identity.

Deploy additive schema before extended readers, then server support, then updated
hosts, then enable grants through Admin. Do not grant shared access while any serving
process still uses unrestricted old entitlement inventory. Unextended clients remain
private-only. Preserve all previous routing, source-link, processing and tombstone
repairs; this feature does not reset their repair budgets.

Private-only operational rollback: stop new shared grants, revoke existing shared
access with audits, wait the maximum issued lease (300 seconds upper bound), and
keep new authority-aware server/host readers until fences are confirmed. Retain
schema/receipts/audit. After shared writes, an old host-private binary cannot represent
all canonical provenance: use a canonical-aware rollback build or forward fix.
No destructive down migration, alias rewriting, or dropping shared data. The
production edge-protection guard and upstream concord#91 limitation remain intact;
this assignment qualifies only supported local dev plaintext mode.

## Sol implementation packages and exact ownership

Prefixes below are repository-relative. Each package has one owner. Unlisted file
changes require coordinator allocation, not silent scope expansion. All new migration
filenames are reserved here; coordinator checks collisions before delegation. Existing
uncommitted work is the baseline to preserve. Tests named below are scoped targets,
not claims they were run. Interfaces above permit parallel coding with stubs, but
integration proceeds in the dependency order shown.

1. **S1 registry/audit/lifecycle** owns
   `apps/backplane_system/lib/backplane/memory_spaces.ex`,
   `apps/backplane_system/lib/backplane/memory_spaces/entitlement.ex`, new
   `apps/backplane_system/lib/backplane/memory_spaces/access_audit.ex`,
   `apps/backplane_system/priv/repo/migrations/20261020000004_add_memory_host_access.exs`,
   `apps/backplane_skills/lib/backplane/skills/hosts.ex`,
   `apps/backplane_system/test/backplane/memory_spaces_test.exs`, new
   `apps/backplane_system/test/backplane/memory_host_access_test.exs`, and
   `apps/backplane_skills/test/backplane/skills/hosts_test.exs`.
   Implement frozen APIs, conservative backfill, CAS/locks/audit, lifecycle version
   increments, and no automatic reactivation. Tests: caps independence/dependency,
   migration preservation, revoked/private/default paths, audit rollback, CAS races.
2. **S2 canonical shared operations** depends on S1 interfaces; owns
   `apps/backplane_memory/lib/backplane/memory/authorization.ex`,
   `apps/backplane_memory/lib/backplane/memory/service.ex`,
   `apps/backplane_memory/lib/backplane/memory/memories.ex`, new
   `apps/backplane_memory/lib/backplane/memory/shared_commands.ex`, new
   `apps/backplane_memory/lib/backplane/memory/shared_commands/receipt.ex`,
   `apps/backplane_system/priv/repo/migrations/20261020000005_create_memory_access_commands.exs`,
   new `apps/backplane_memory/test/backplane/memory/authorization_test.exs`,
   `apps/backplane_memory/test/backplane/memory/service_test.exs`,
   new `apps/backplane_memory/test/backplane/memory/memories_test.exs`, and new
   `apps/backplane_memory/test/backplane/memory/shared_commands_test.exs`.
   Tests: canonical target/source distinction, cross-source forget/tombstones,
   remember-only/forget-only/no-read receipts, lost ACK/digest conflicts, concurrent
   revoke versus settlement, shared reads and unchanged default tool behavior.
3. **S3 schemas/channel/feed** depends on S1/S2; owns
   `apps/backplane_memory_contract/lib/backplane/memory_tool_contract.ex`,
   `apps/backplane_memory_contract/test/backplane/memory_tool_contract_test.exs`,
   `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex`,
   `apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex`,
   `apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs`,
   `apps/backplane_api/test/backplane/api/host_agent_memory_sync_test.exs`,
   `apps/backplane_api/test/backplane/api/memory_v2_edge_qualification_test.exs`,
   `apps/backplane_memory/lib/backplane/memory/edge_sync.ex`,
   `apps/backplane_memory/lib/backplane/memory/edge_sync/postgres_store.ex`,
   `apps/backplane_memory/lib/backplane/memory/edge_sync/cursor.ex`,
   `apps/backplane_memory/lib/backplane/memory/edge_sync/delivery.ex`,
   `apps/backplane_memory/lib/backplane/memory/edge_sync/snapshot_builder.ex`,
   `apps/backplane_system/priv/repo/migrations/20261020000006_bind_memory_delivery_access.exs`,
   new `apps/backplane_memory/test/backplane/memory/shared_delivery_test.exs`.
   Tests: negotiated versus old clients, denied raw authority, complete inventory,
   token recheck, command dispatch, stale batch/ACK/snapshot and regrant generation.
4. **S4 host owner/outbox/mirror** depends on frozen S3 wire; owns new
   `apps/backplane_host_agent/lib/backplane/host_agent/memory/access.ex`,
   `apps/backplane_host_agent/lib/backplane/host_agent/memory.ex`,
   `apps/backplane_host_agent/lib/backplane/host_agent/memory/{supervisor,migrator,syncer,recall_cache}.ex`,
   `apps/backplane_host_agent/lib/backplane/host_agent/memory/migrations/v5.ex`,
   `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/{migrator,syncer}.ex`,
   `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/migrations/v4.ex`,
   `apps/backplane_host_agent/lib/backplane/host_agent/memory/mirror.ex`,
   `apps/backplane_host_agent/lib/backplane/host_agent/memory/mirror/store.ex`,
   `apps/backplane_host_agent/lib/backplane/host_agent/{memory_facade,memory_proxy,memory_router,worker}.ex`,
   `apps/backplane_host_agent/lib/backplane/host_agent/services/memory.ex`,
   `apps/backplane_host_agent/lib/mix/tasks/agent.run.ex`, corresponding existing
   test files under `apps/backplane_host_agent/test/backplane/host_agent/` with
   matching module paths, and new `memory/access_test.exs` there.
   Test persistent fences, separate-store crash points, monotonic expiry, cold-start,
   in-flight reply gates, unnegotiated/foreign selectors, bounded owner work,
   immutable command targets, late ACK settlement without visibility and private
   offline/read-your-writes preservation. Do not reopen Connector/Channel recovery.
   Coordinator allocation during Task64: the new-feature join offer helpers
   `Channel.join_payload/0` / `edge_offer/0` may add extensions even when the mirror
   is disabled. `AgentChannel` may add only access-change event forwarding, with
   corresponding `channel_test.exs` / `agent_channel_test.exs` coverage. Socket
   start/connect/retirement/retry, duplicate registration and child restart policy
   remain outside this allocation; mirror protection is unchanged.
5. **S5 Admin** depends on S1; owns only
   `apps/backplane_admin/lib/backplane/admin/live/memory_memories_live.ex` and
   `apps/backplane_admin/test/backplane/admin/live/memory_memories_live_test.exs`.
   Tests: grant/change/revoke/regrant, independent checkboxes, invalid deliver-only,
   version conflict, exact selector retention, unknown host, reason and failure UI.
6. **S6 coordinator integration/live/docs** after relevant packages pass; owns
   `scripts/memory_local_acceptance.py`, new `scripts/memory_local_shared_access.py`,
   new `scripts/tests/test_memory_local_shared_access.py`,
   `docs/memory/{host-memory-v2-protocol,local-dev-runbook,local-dev-checklist,local-e2e-acceptance,local-implementation-notes}.md`.
   Coordinator exclusively owns services/DB/browser/provider settings and new local
   host process, integration/restarts and evidence. This architecture document is
   handed back to the coordinator on Task58 completion.

S1 and S5 scaffolding can proceed independently of S2/S3/S4 within those files;
S3 and S4 can code against frozen contracts in parallel. Only the coordinator runs
Mix/dev lifecycle at integration gates. Sharing work in routing modules is new
feature work, not a reset of routing04 Sol2/Astra13, stages04, UI05, or other budgets.

## Required acceptance and evidence boundaries

Focused tests must cover the matrices below; no full unrelated suite is required
by this document. Run scoped format and compile checks for touched apps, then scoped
module/contract suites. If a check outside scope fails, report and stop that gate.
Preserve the existing routing 177-test regression set and parent's actual 30-case
revocation plus positive-outage evidence by rerunning the affected subset after
integration; historical passes alone do not qualify newly changed paths.

Live L13 requires **two real local registered hosts A and B**, separate command,
capture and mirror DBs, normal authenticated channels, direct HTTP and local MCP,
actual negotiated delivery, and supported Admin/domain grants (no SQL grants):

| Step | Required observation |
| --- | --- |
| Isolated baseline | A fixture and B private sentinel; B cannot read, remember, forget, derive, capture into, or receive A; raw authority rejection unchanged. |
| Read-only | Grant B read; canonical A IDs visible through direct and MCP; no delivery/remember/forget. Omitted target still B. |
| Read+deliver | Actual delta/snapshot populates B mirror; source stays A; default lease 0 rejects transport-only shared read while B private outage fallback works. |
| Independent remember | Remember-only allows provisional command and canonical settlement in A with source B; forget/read/delivery denied; ACK contains no protected content. |
| Independent forget | Forget-only rejects remember/read/delivery but deletes a supplied A canonical fixture ID through tombstones; no creator impersonation or prerequisite read grant. |
| Combined subset | Read+deliver+remember still denies delete; read+deliver+forget still denies write. Full four allows both; duplicate/lost ACK gives one canonical effect. |
| Capability change | Remove read/deliver while preserving remember; populated caches no longer readable; old versions rejected, current write remains permitted without disclosure. |
| Online revoke then outage | Revoke populated grant; both interfaces fail closed across mirror, pending/ACK overlays and lifecycle cache; induce transport failure afterward, restart host, verify no resurrection. A and B private paths remain usable. |
| Disconnected revoke | Set a short explicit lease, disconnect before revoke; stale read possible only within measured bound; expiry denies, wall-clock/cold-start cannot extend. Record default0 and max300 validation. |
| Regrant | Same access ID, strictly newer version; old queued commands remain rejected, old snapshot/upsert/ACK cannot activate; fresh snapshot exposes only current canonical state/tombstones. |
| Audit and preservation | Durable change history matches versions/reasons; token-free evidence; capture/default aliases unchanged; canonical data retained on revoke and governed records remain deleted. |

Supplement live evidence with deterministic races: revoke vs mutation commit/read
release/delivery/ACK; fence vs owner read/overlay; lease expiry during read; delayed
old-channel inventory; interrupted multi-chunk snapshot; crash after primary fence
before mirror cleanup; committed receipt arriving after revoke; same command ID in
two targets; digest conflict; rejected old version after regrant. Classify these as
focused fault tests, not live execution. No content in denied results or diagnostics.

Only after all L13 positive/negative/capability/revoke/regrant cases pass, run L18:
repeat using retained canonical/host state, restart gateway and both local hosts,
reconcile queues/fences, verify no duplicates/loss/orphan processes, and leave the
owned dev stack healthy. Update acceptance evidence and runbook with actual commands
and results. Architecture Task58 completion alone does not complete L13 or L18.
