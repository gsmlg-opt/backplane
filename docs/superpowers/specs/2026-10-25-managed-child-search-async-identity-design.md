# Managed child Sessions, deferred metadata search, and async call identity

Status: proposed; implementation awaits user review.

Repository: `gsmlg-opt/backplane`, `main` at
`ab8f2f5d9a581bdf5168a3670ffd2c858a226b0e` (`1.10.35`).
Target release: `1.10.36`.

The release scope is the initial internal-request snapshot:

| Request | Required behavior |
| --- | --- |
| [#86](https://github.com/gsmlg-opt/backplane/issues/86) | Give managed children independent native resource Sessions while preserving the root's shared collaboration manager |
| [#87](https://github.com/gsmlg-opt/backplane/issues/87) | Search deferred tools using the pinned Codex metadata and English BM25 contract |
| [#88](https://github.com/gsmlg-opt/backplane/issues/88) | Reuse one DynamicRuntime across independent run owners with overlapping candidate names |
| [#89](https://github.com/gsmlg-opt/backplane/issues/89) | Identify direct and nested native async events by their actual tool invocation |

This design has three implementation packages: child resource ownership (#86),
owner-local search (#88 followed by #87), and async event identity (#89). They
retain the current Store, Session, MultiAgent, Dynamic, and Conversation
boundaries. No host application changes, new inbox service, database migration,
automatic effect replay, or production Rust dependency is required.

## Existing behavior and constraints

`Codex.Session` owns a ResourceRegistry across successful bounded Conversation
runs. A new run reserves a fresh binding; successful completion checks resource
readiness, acknowledges durable finish, then detaches. Failure, cancellation,
owner loss, and uncertain settlement fence and close resources. Binding tokens
are process-local capabilities; restored journals cannot recreate them.

`Session.attach/2` currently treats every collaboration descriptor as a manager
owned by that Session and calls `MultiAgent.rebind_parent/3`. A real child's
Session therefore fails against a root-owned manager. Skipping rebind alone
would leave the manager's bound invocation owner checks unsatisfied.

MultiAgent currently starts a child Conversation synchronously while processing
its reserved admission. Session attachment, detachment, and cleanup must never
synchronously call back into that manager from the child path: this would make
the manager wait for the child while the child waits for the manager.

DynamicRuntime discovers candidates once per run ID, but stores all candidates
in one Dynamic whose names are globally unique. The second run collides with
the first. Dynamic search also only matches case-sensitive tool names, accepts
empty queries as list-all, and can crash on a non-string runtime query.

Conversation already assigns distinct invocation and tool-call IDs before
direct and nested dispatch. Its async native events currently carry only the
enclosing run/step metadata. Ordered root events cannot identify nested calls.

## #86: managed child resource ownership

### Selected approach and alternatives

| Approach | Benefit | Cost or limitation |
| --- | --- | --- |
| Automatic pre-start adoption by MultiAgent | Keeps existing child_options callbacks and admitted descriptors; Session attach can validate locally | Requires explicit child association and cleanup obligations |
| Explicit bind_child with a manager-issued permit | Makes host intent explicit | Adds permit issuance, callback adoption and abandoned-permit states |
| Asynchronous manager startup/attach handshake | Allows manager validation during attach | Reworks child birth and admission acknowledgement sequencing |

Use automatic pre-start adoption. Root manager ownership and child resource
ownership are separate relationships. Adoption grants no tools or authority.

### Public integration and trust boundary

Keep `Session.bind/3` and `child_options/3` unchanged. The host creates or retains
one Session infrastructure process for each stable managed child, binds it using
the callback's fresh run ID and incarnation, and returns that binding together
with the normally admitted child registry, tools and authority. Root and child
Session infrastructure may have different host owner PIDs.

Add `Session.adopt_managed_child(binding, admission, authority)`. MultiAgent
invokes it automatically after validating returned options and child authority,
and before starting the Conversation. The manager supplies this admission from
its own reserved attempt:

```elixir
%{
  manager: manager_pid,
  manager_id: manager_id,
  agent_id: stable_agent_id,
  attempt_id: attempt_id,
  run_id: run_id,
  incarnation: incarnation
}
```

The Session checks that the calling process is `admission.manager`, the complete
binding is its exact current reserved binding, and run/incarnation match the
admission. Validate authority using the supported Policy representation: nonempty
binary caller, exact run, list-valued grants, valid global/per-tool revisions and
binding maps. Adoption must not expand the Session's reserved authority, and
records the manager-validated child authority. Compare capabilities by tool name,
revision and binding rather than raw map equality or grant-list order. Subsequent
catalog admission may narrow those capabilities, never expand them. Malformed
admission or authority returns a structured error without crashing Session.

Record the stable manager/agent association and the current attempt and binding.
Repeating the same adoption is idempotent;
a conflicting active adoption is refused. A Session already used as the root
owner cannot become a child, and a child's stable manager/agent association
cannot be reassigned to a different child or manager.

The manager records the exact prospective binding as an obligation before
requesting adoption, distinguishing pending, accepted, explicitly rejected and
uncertain outcomes. It independently matches that association to its reserved
agent/attempt/run/incarnation. Caller-supplied admission metadata alone cannot
authorize a manager operation. The manager must have recorded the same live
association; Session adoption is not a way to join another manager.

For an adopted child, `Session.attach/2` verifies the local adoption, fresh
binding, admitted authority and collaboration descriptors. It permits the
adopted shared manager without rebinding its parent. A descriptor targeting an
unrelated manager is refused in this initial feature. Omitting collaboration
tools does not remove the recorded lifecycle association. Root attachment keeps
the existing owned-manager rebind protocol.

Do not reconstruct collaboration descriptors, remove grants, strip their
`family` metadata, or use private child process lookup. Existing strict schema
admission and parent/ancestor capability intersection remain authoritative.

### Manager invocation authentication

Extend the existing native/bound authentication path to recognize the current
managed child's recorded Session binding. Match the stable child, current
attempt, run, incarnation, validated Session owner and exact binding. Retain the
current caller, grants, revision, immutable collaboration binding and ancestor
authority checks. Re-evaluate parent/ancestor policy on each invocation.

The root continues to require its root Session owner. Legacy children without
a Session retain their current process-owner path. A stale binding, forged
owner, completed attempt or previous incarnation cannot invoke child tools.

### Session relationship and lifecycle rules

Split Session relationships into owned root managers and an adopted shared
manager. Only owned managers participate in `rebind_parent`, `transfer_ready`,
`detach_parent` and whole-manager `close_session`. The child path validates local
Registry readiness and never waits on a synchronous manager callback.

| Event | Required resource behavior |
| --- | --- |
| Successful child finish | Local readiness, durable finish acknowledgement, then detach; retain commands, plan and Code Mode resources in the idle child Session |
| Successful follow-up | Same stable Session, fresh run and token, incremented child incarnation, newly checked authority; all previous bindings fail |
| Child failure, cancellation or explicit local Session close | Fence and close that child's resources; preserve root and sibling resources |
| V2 target-only interrupt | Settle only the target and its local Session; preserve independently running descendants |
| V1 recursive close or root Session close | Reach all targeted adopted child Sessions, including completed/unloaded children with retained idle resources |
| Child Session host owner loss | Begin local fencing/cleanup and notify the manager; settle the affected child conservatively |
| Manager process loss | Each adopted Session observes manager DOWN and closes its own local resources |
| Lost adoption, finish or cleanup acknowledgement | Retain the exact obligation and execution reservation; report unknown outcome and refuse replacement/retry |

Successful detachment releases the execution reservation under the existing
rules; retained idle resources remain a tracked ownership obligation rather than
consuming an execution slot. The manager requires the same Session PID and owner
identity for a follow-up while that ownership obligation remains open; it cannot
accept a second Session and abandon the first one's retained resources. After
confirmed closure, a replacement for the same stable child may use a new Session
infrastructure process. A closed Session itself cannot be rebound. Unconfirmed
prior closure prohibits replacement.

Track associations independently of live Conversation PIDs so root cleanup also
reaches idle retained Sessions. Extend existing off-manager settlement workers
to close these Sessions and collect exact evidence. A completed Conversation's
`resource_cleanup: :confirmed` may describe successful retention, so local or
recursive close also requires an independent confirmed Session-close receipt.
An old successful snapshot cannot override an unknown Session-close outcome.
V1 recursive close and root close fence all targets and attempt every tracked
Session obligation under bounded deadlines, aggregating uncertainty even when
an earlier child fails. Do not infer resource closure from a terminated
Conversation, or successful termination of a waiter.

The Session monitors its adopted manager, and the manager monitors adopted
Session infrastructure. Session lifecycle notifications to the manager are
asynchronous and carry the complete private association identity. Fence before
notification; accept a run-level result only if its manager/agent/attempt/run/
incarnation and binding still match. Infrastructure DOWN instead matches the
currently associated Session PID and owner incarnation: a monitor created in
run A remains valid during run B. Old run notifications cannot close or release
a newer activation. Private binding tokens and PIDs do not enter public
checkpoints or JSON-facing collaboration records.

Once adoption was accepted or may have been accepted, the manager owns cleanup
on startup, prompt, admission-receipt or settlement failure. Do not close an
explicitly rejected foreign/root binding. Host allocations rejected before
adoption, and allocations made by a callback that raises before returning its
options, remain the host's responsibility under the callback contract. Document
this boundary in the public child_options example.

Closing resources does not terminate host-owned Session infrastructure. Preserve
the existing normal-stop teardown of the Session's own Registry/supervisors and
the independence of externally owned managers and host services.

## #88: owner-local deferred candidate state

Keep independent Dynamic instances inside DynamicRuntime:

```elixir
owner_key = {caller_identity, run_id, incarnation}
discovery_owners = %{owner_key => dynamic}
```

Each partition uses its binary run ID with the existing low-level Dynamic API.
Do not change Dynamic's public global-name collision and snapshot semantics
inside one instance. Keep plugin request/receipt state separate and unchanged.

Require a nonempty binary run ID and positive integer incarnation. When `caller`
is absent, use a private `:host_direct` sentinel to preserve the documented direct
Runtime API. A present caller must be a nonempty binary; preserve its exact value,
matching current Policy identity semantics. Nil, empty and nonbinary supplied
callers fail validation instead of falling back to the sentinel. The sentinel
grants no execution or publication authority.

Same candidate names are legal across distinct caller/run/incarnation partitions.
Within-owner duplicates and active catalog collisions continue to fail. Fit and
mutate only the current owner's candidate state. Another owner's discovery or
publication cannot alter its ranking, consume candidates or grant tools.

Preserve exact run/incarnation/revision checks and the live producer-bound
Conversation staging callback. Ordinary failed staging leaves the previous
partition unchanged. Search results remain unavailable to another tool call in
the same provider batch; publication becomes visible at the existing next-model
boundary. Accepted staging followed by cancellation may discard the pending
catalog while candidates remain consumed for that owner, as today. No automatic
reset or replay is introduced.

The existing candidate/result bound applies per owner (`max_results`, default
50). Partitions live until Runtime shutdown. This change adds no eviction API,
candidate refresh or implicit expiry. A long-lived host must account for retained
owner state and can rotate the Runtime at its chosen resource boundary.

Alternatives were composite `{owner, name}` keys throughout Dynamic, which would
change its public semantics, or enforcing one run per Runtime, which would force
consumer resource-lifetime changes. Runtime-level partitioning is the narrower
compatible repair. Implement it before metadata search because both use the
same state and publication path.

## #87: pinned metadata and BM25 search

### Compatibility target and implementation choice

Use Codex revision `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`:

- `codex-rs/tools/src/tool_search.rs`: generic metadata text construction.
- `codex-rs/core/src/tools/handlers/dynamic.rs`: namespace default mapping.
- `codex-rs/core/src/tools/handlers/tool_search.rs`: English BM25 query semantics.
- Its Cargo.lock: bm25 2.3.2, deunicode 1.6.2, rust-stemmers 1.2.0,
  stop-words 0.9.0 with NLTK data, and unicode-segmentation 1.12.0.

Implement the required tokenizer and scorer in pure Elixir with pinned data.
Vendor the exact deunicode mapping (476,399 bytes), English stopwords and their
source/license notices under the Runtime's `priv/codex/tool_search/` directory.
Port the required English Snowball, ASCII word-boundary and FxHash32 behavior
with attribution. Rust is a development differential oracle only. The published
Hex package must work in a fresh consumer without Rust, Cargo, a native library
or an external helper process.

A Rust wrapper would directly reuse the implementation but add native build and
distribution requirements. Existing Hex bm25/unidecode implementations use
different algorithms/data; a standalone Porter2 dependency is not proven equal
to the pinned Snowball implementation. Neither is sufficient parity evidence.

The compatibility claim is the pinned generic metadata/token/scoring algorithm
over Backplane's individually admitted, currently discoverable owner-local
candidates. Codex's specialized MCP indexing, namespace grouping and provider
output aggregation have different metadata and are outside this request.

### Search text

Build one document per normalized Contract in this order:

1. For a named namespace: namespace name and namespace description. Optional
   `metadata: %{namespace_description: text}` supplies the latter; support atom
   or string keys inside this map. Absent/nil/blank description defaults to
   `Tools in the <name> namespace.`, except namespace `functions`, whose default
   description is empty. This matches the pinned DynamicToolHandler mapping.
2. For a function: `contract.name`, its underscore-expanded words, description,
   then recursive input-schema text. Do not substitute the canonical
   `namespace::name`, which would change token weighting.
3. For a custom tool: name, description and optional `contract.format.syntax`
   (atom or string key). Do not add underscore-expanded custom-name words.

Unnamespaced tools do not gain an implicit `functions` token. Return existing
canonical names in public result summaries. Missing optional syntax contributes
nothing; existing text-format custom tools remain valid. Explicitly malformed
optional text fails with a structured validation error rather than crashing.

Schema text visits descriptions, sorted property names and their child schemas,
`items`, and `anyOf` in the pinned order. Do not index output schemas, enum values,
grammar definitions, `$defs`, backend context, credentials or arbitrary metadata.
Retain existing strict schema and candidate admission bounds.

### Tokenization and ranking

Match this pipeline exactly: deunicode transliteration with unknown characters
mapped to `[?]`, lowercase, Unicode word segmentation, NLTK English stopword
removal, then English Snowball stemming. Since pinned transliteration produces
ASCII, only the segmentation library's ASCII boundary behavior is needed after
transliteration. Contractions, underscores, decimals and punctuation still need
the actual boundary rules; a general word regex is insufficient.

Match the pinned FxHash32 token identity, including Rust string hashing and
32-bit overflow, rather than silently replacing it with token strings. Match
the source's f32 arithmetic and operation order, with `k1 = 1.2` and `b = 0.75`:

```text
idf(t) = ln(1 + (N - df(t) + 0.5) / (df(t) + 0.5))
tf_weight(t,d) = tf(t,d) * (k1 + 1) /
                (tf(t,d) + k1 * (1 - b + b * (len(d) / avgdl)))
score(d,q) = sum(idf(t) * tf_weight(t,d), for each query token occurrence)
```

Repeated query tokens contribute repeatedly. Corpus lengths count tokens after
stopword removal and stemming. Follow the pinned average-length conversion to
f32 and per-operation rounding, rather than relying on BEAM double precision.
When fitted average length is nonpositive, use the source's fallback of 256;
an empty or entirely zero-token corpus still yields no matching documents.
Return positive matching scores in descending order. Upstream equal-score order
is unspecified; Backplane uses canonical tool name ascending as a deterministic
secondary order. Public summary fields remain unchanged; scores are internal.

Fit only the current owner's `:discovered` candidates. Successfully staged
published entries leave both eligibility and corpus statistics. Failed staging
preserves the old corpus. This published-state filtering is an explicit
Backplane lifetime rule, rather than a claim about Codex's deferred registry.

### Query and limit validation

Require valid UTF-8 string query input, trim it, and reject missing, non-string
or trimmed-empty queries. Empty query no longer means list-all. A nonblank
query reduced entirely to stopwords is valid and returns no matches. Preserve
the existing no-match result and publication status.

Runtime defaults an omitted limit to 8. Explicit limits must be positive
integers no greater than configured `max_results`; zero, negative, noninteger
and over-bound limits fail validation. Validate the effective default against
the same bound: preserving current behavior, `max_results < 8` requires the
caller to supply a smaller explicit limit. The public low-level search API keeps
its configured bound. Malformed input must not terminate DynamicRuntime.

### Differential evidence

Create a development oracle locked to the exact crates above and record source
revision, crate checksums and fixture generation instructions. Compare document
text/token sequences and FxHash32 identities exactly. Compare finite BM25 scores
within four f32 ULPs, allowing an absolute floor of `1e-7` near zero. Require exact
non-tied result order; compare upstream ties as sets, then assert Backplane's
documented canonical-name order. Fixture scores are test evidence, not new public
API fields. Keep Rust out of normal Mix tests and the consumer package.

Cover description/property-only queries, nested schemas/items/anyOf, namespace
defaults, custom syntax, underscore handling, accents/CJK/emoji/unknown Unicode,
contractions and punctuation, Snowball exceptions and a broad word corpus,
stopwords, repeated terms, rare-term IDF, length normalization, zero-token
documents, empty corpus, and hash-collision behavior. Check that another owner
and excluded schema/backend fields cannot change results.

## #89: authoritative async invocation identity

Add top-level `invocation_id` and `tool_call_id` to both public event types:
`:async_user_input_requested` and `:async_user_message`. Preserve questions or
message, run ID, incarnation, step, attempt and turn metadata.

Enrich at Conversation's producer-token-checked `{:chunk, token, event}` boundary
from the current direct tool invocation or the current nested invocation. A
nested event carries the nested invocation/call IDs, rather than its enclosing
Code Mode call. Do not add a second async item ID or infer identity from text,
event order, subscriber state or private process lookup.

Authoritative identity overwrites payload-supplied IDs. Accept these native
async event types only from an executing live tool producer; provider and
preparation callbacks cannot manufacture native call identity. Stale, cancelled,
finished and replaced producers retain the existing conflict behavior. Generic
tool metadata events remain supported. No tool schema or descriptor recreation
is required.

Both IDs are strings already assigned before the durable tool invocation
checkpoint. Direct provider call IDs remain unchanged; nested calls retain their
generated IDs. Verify correspondence to the existing canonical tool-invoked
records, execution intents and checkpointed tool history where present. Public
event serialization and projection preserve these fields unchanged.

This does not add durable notification replay. A host persists its own async
cards/events and admits replies as new user messages. `accepted: true` continues
to mean immediate Runtime acceptance, including with no subscriber or before a
subscriber processes the event; it is not a durable user-receipt acknowledgement.

An alternative is to add identity in each backend or host descriptor adapter.
That duplicates trusted-context logic and permits direct/nested identity drift.
A new async request registry would add an unrelated lifecycle and persistence
service. Use the existing Conversation invocation boundary instead.

## Verification and delivery

Use issue-scoped worktrees under `.trees/` and separate Conventional Commits,
then integrate the approved changes into main. Serialize local Mix/BEAM/devenv
builds. Parallel read-only work and disjoint implementations can proceed, but
#88 precedes #87; shared Conversation edits require coordination.

| Area | Required acceptance evidence |
| --- | --- |
| Managed child public path | Two real Sessions and Conversations with unchanged native manager contracts and update_plan; distinct host owner wrappers; root binding unchanged |
| Retention | Real command, Plan and Code Mode state survives successful child completion and fresh follow-up; previous run bindings fail; a second Session cannot replace an open retained one |
| Ownership and policy | Native/bound calls, duplicate/forged/wrong-manager/agent/attempt/run/incarnation rejection; ancestor grant/revision changes; mailbox and nested spawn/follow-up |
| Cleanup | Child/root/sibling isolation, idle retained child cleanup, owner/manager/Session loss after follow-up, V2 target-only interrupt, V1 recursive close, normal infrastructure teardown; an uncertain first target does not skip a second retained Session |
| Uncertainty | Startup/prompt/receipt failure, failed Store finish, lost adoption/cleanup acknowledgement and stale lifecycle notifications preserve fencing and reservations |
| Dynamic ownership | Exact successive-run public reproduction; same names across caller/run/incarnation partitions; within-owner duplicates; failed stage rollback and next-turn executable publication |
| Search | Pinned differential fixtures above; malformed query/limit does not crash; empty query fails; stopword-only query returns no matches; owner-local corpus changes |
| Async identity | Identical calls in one step have different IDs; both event types; direct/nested IDs match canonical records and serializable public projection; spoof/stale callbacks; subscriber:nil acceptance |

Run focused tests first, then the complete Runtime suite and required repository
formatting, warnings-as-errors compilation, strict Credo, Dialyzer, release/CI
workflow contracts and standalone package checks as applicable. Report the
pre-existing unrelated Credo finding at
`apps/backplane_memory/lib/backplane/memory/operations/inventory.ex:280`
separately; do not repair it within these requests or claim that check passed.

Update the Runtime changelog, CODEX/EMBEDDING documentation, Session resource
guide and compatibility evidence. Include a public child_options example and
the exact metadata-search scope, invalid-input behavior and async receipt limits.
Ensure vendored data and notices ship in the existing package `priv` inclusion.

After accepted implementation, use `scripts/set-version.sh 1.10.36 all` and the
canonical release workflow. Verify exact main/tag/remote convergence, terminal
workflow status, archives/checksums and packaged BuildInfo provenance, Hex source
and HexDocs, GHCR metadata, and a fresh consumer installed from published
1.10.36. Exercise the four public reproductions there, including actual selected
tool execution. Repository tests alone do not establish published-consumer proof.
Production deployment is outside this release request.

## Design review checklist

- [x] Initial issue scope and current source baseline recorded.
- [x] Alternatives and selected ownership/search/event boundaries specified.
- [x] Failure, deadlock, identity, retention and unknown-outcome rules explicit.
- [x] Pinned algorithm scope, data, licensing and differential evidence defined.
- [x] Public API compatibility changes and receipt limits identified.
- [x] Verification, package contents and release proof separated.
- [x] Source review corrections applied: authority narrowing, stable Session
  identity, monitor lifetime, complete cleanup receipts, f32 grouping and limits.
- [ ] User has approved implementation of this written design.
