# Native provider selection adoption and raw search envelopes

Addresses internal requests #154 and #155. Implementation follows the user's
standing instruction to fix on main and release without repeated approval.

## Scope and ownership

Conversation remains the only live execution owner. Kernel validates durable
transitions, Execution commits effect intents, and the existing Store persists
portable run records. Hosts retain provider resolution, pending-intent storage,
credentials and compaction content. No new controller, Store callback or migration
is introduced. Restored nonterminal Conversations remain inspection-only.

Web search admission remains in Codex.Web. Provider adapters own parsing; the
runtime preserves successful portable envelopes without manufacturing results.

## Provider selection contract (#154)

Add `Conversation.stage_provider_selection/2` for trusted-host requests containing
run/incarnation/turn identity, a unique request ID, `:select` or `:reset`, and
bounded portable intent. Return a checkpointed staging receipt with generation,
revision and Store mode. Staging is not adoption. Exact retries are idempotent;
conflicting reuse fails. A bounded receipt ledger rejects overflow rather than
forgetting identities. Optional initial provider/model selection preserves fixed
consumers and binds ordinary continuations to their existing selection.

An adapter can opt into live recovery by ending its current enumerable with
`%{type: :response_failed, error: error, recovery: :retry | :compaction}`.
Classification requests consideration; it does not establish eligibility. Ordinary
failure events, crashes, missing terminals and timeouts retain existing behavior.

The native owner opens a boundary only after the exact failed worker has settled,
with no active provider/tool/wait/interaction/nested work or uncertain cleanup,
remaining allowances, and a pending selection. The failed attempt must have
published no text, thinking, tool-call or hosted-effect output. Informational
start and usage events do not block replay. For opted-in runs, the first
replay-blocking event is checkpointed before emission, including when there are
no subscribers. Canonical messages alone are not evidence of replay safety.

At an eligible boundary, optional bounded host
`prepare_provider_selection(snapshot, context)` resolves the exact observed
request B. The immutable snapshot contains the boundary and failed-attempt
identities, canonical history and revision, selection, reason and pinned catalog.
The result supplies provider/model IDs, ephemeral provider context, and unchanged
or prepared provider messages. The callback has no dispatch, interaction,
feedback or catalog publication authority. Credentials/context are not persisted.

After preparation, revalidate liveness, boundary identity, deadlines, eligibility
and canonical-prefix consistency. Commit adoption and the new `provider_started`
identity together, including selection request/generation, resolved provider/model,
provider view and consumed boundary. Execution's canonical command must preserve
these fields, and Kernel must validate them in the final Store transition.
Only after acknowledgement emit adoption and dispatch the existing provider facade.

If C was staged while B prepared or committed, adopting B clears only B's
generation; C remains pending. Every subsequent recovery requires a distinct
pending request and consumes ordinary provider work. Preparation failure neither
consumes B nor produces an adoption receipt. Cancellation, storage failure, stale
callbacks and restored runs cannot dispatch replacements.

Canonical history, settled tool results and usage remain intact. A compacted
provider view is separately persisted with source-prefix count/digest, and future
requests append the new canonical suffix. Explicit context reset invalidates the
view; mismatched prefixes fail closed. Failed-attempt usage, Goal accounting,
root deadlines and work reservations are retained.

Public requests, trusted contexts, status and committed observations expose the
adopted request/generation, resolved provider/model and actual
run/incarnation/turn/step/attempt identity. Returned-model provenance is separate.

### Alternatives and limits

Resolving the latest model in every stream callback would lose native eligibility
and ordinary-continuation semantics. An unrestricted host retry/compact API would
create a second execution controller. The classified-failure route is selected
because the native owner can prove sequencing and replay eligibility. Arbitrary
active interruption and crash restoration are not eligible live boundaries.

## Raw search contract (#155)

Admit a third search success form with unambiguous atom/string aliases for
`kind`, `provider`, and `data`: kind is `:raw` or `"raw"`, provider is nonempty
UTF-8 text, and data is a plain portable JSON map. Nested JSON maps have string
keys; values may be text, numbers, booleans, null, proper lists or plain maps.
Reject structs, unsupported nested values and ambiguous aliases.

Return the entire original envelope unchanged. No outer query/timing/cache fields
are required. Preserve protocol-relative URLs and nested `data.cached: true`
literally. Existing results-list and answer forms retain their precedence and
behavior. Both search and x_search reuse the same admission, whole-result
external-size limit and lifecycle. No provider, URL or transport rewrite is added.

## Verification and delivery

Focused tests must prove ordinary continuation remains A; eligible failure adopts
B in the same turn; settled tools/history are not replayed; actual request/context
identity matches committed binding; C survives B preparation; reset resolves the
default; compaction view preserves canonical history and appends its suffix;
storage acknowledgement gates dispatch; published effects reject replay; stale,
cancelled, timed-out or restored work cannot dispatch; usage/work remain accounted.
Retain existing fixed-provider and failure compatibility tests.

Raw tests use the exact full #155 fixture and nested-cache variant, both key styles,
x_search, full-map budget checks, invalid aliases/payloads, existing forms, and
native Conversation/Code Mode propagation where supported by the existing harness.

Run focused Runtime verification, review the integrated diff, then required
release contracts and CI before GitHub Actions publication of the next patch.
Unrelated API-usage work is preserved. Current main has independent audio
Dialyzer errors (File.stream! argument order and unreachable header patterns) and
an HTTP/2 audio termination-test failure; record these as release blockers rather
than silently expanding these two issue fixes.

No OpenClaw reference runtime execution or real-provider compatibility is claimed.
