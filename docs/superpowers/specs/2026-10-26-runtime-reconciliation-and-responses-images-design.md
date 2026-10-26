# Runtime reconciliation and Responses image results — 1.10.40

Date: 2026-10-26

Status: approved by the user on 2026-10-26; implemented. Final integration and
published-package acceptance remain release gates.

Baseline: `main` at `77721c0e674996c81b7f0a0b824a748a641420a6`, published as
1.10.39. Release scope is the fixed internal-request snapshot
[#109](https://github.com/gsmlg-opt/backplane/issues/109),
[#110](https://github.com/gsmlg-opt/backplane/issues/110),
[#111](https://github.com/gsmlg-opt/backplane/issues/111),
[#112](https://github.com/gsmlg-opt/backplane/issues/112), and
[#113](https://github.com/gsmlg-opt/backplane/issues/113).

## Outcome and boundaries

Allow hosts to acknowledge retained Goal receipts on terminal runs, expire
unconsumed notifications with their accepting turn, deliver settled native errors
to Code Mode as structured values, encode supported Responses image tool results,
and expose the complete pinned catalog to provider and preparation adapters.

Keep implementation in `backplane_agent_runtime` and `backplane_ai_protocol`.
The gateway, downstream Sigma/Synapsis applications, deployment configuration,
database schemas and dependency versions are outside the implementation scope.
The existing unrelated `devenv.lock` modification must be preserved. Work proceeds
on the current `main`, without creating a branch or worktree.

Release delivery includes scoped commits/push, required CI, the unified 1.10.40
release workflow and published-artifact acceptance. Issues arriving after the
snapshot require a separate scope decision. No production deployment is included.

## Approach and alternatives

Use the existing ownership boundaries: a narrow Kernel command for terminal ACK,
Conversation/MultiAgent lifecycle filtering, a Code Mode wire projection, a
Responses codec extension and two additions to ephemeral adapter contexts.
This keeps durable state and native settlement authoritative while changing only
the boundaries that currently lose information.

A separate durable notification queue and a general public error/media framework
would provide more abstraction, but require migration and compatibility work
beyond these issues. Broad terminal conversation updates, generic struct
flattening and mutable latest-catalog lookups are smaller shortcuts with incorrect
semantics: they respectively permit unrelated terminal mutation, erase type
boundaries and lose revision pinning. They are excluded.

## #109: terminal Goal outbox ACK

Add this public Kernel command, usable through the existing Store paths:

```elixir
{:goal_outbox_acknowledged, occurred_at_ms,
 %{
   run_id: current_run_id,
   incarnation: current_incarnation,
   receipts: exact_delivered_receipts
 }}
```

The command is valid only in the five existing terminal states: `:completed`,
`:failed`, `:cancelled`, `:timed_out` and `:unknown_outcome`. Validate the current
run/incarnation with the existing identity checks. The receipts must be a
nonempty list of maps with nonempty receipt IDs and no repeated IDs. Every
supplied receipt must exactly equal one retained outbox entry, including its
payload; changed, ambiguous or unknown receipts fail without changing the run.
No caller-supplied conversation/context replacement is accepted.

Remove precisely the supplied subset from
`run.context.conversation.goal_outbox`, retaining the remaining entries in their
original order. Preserve every other run/context field, terminal state, outcome,
tool result, execution intent, budget and unresolved-effect evidence. Increment
the revision and emit the dedicated `run.goal_outbox_acknowledged` transition
event through the normal Kernel commit; emit no effects. Existing Store staging,
transaction acknowledgement and revision CAS remain the persistence boundary.
No new Store adapter callback is required.

The current command incarnation fences the operation. A retained receipt can
legitimately originate in an older incarnation after recovery; compare its full
contents with the retained entry rather than requiring its incarnation to equal
the current run's incarnation.

Only the trusted host can establish delivery. It loads/fences/reconciles the
ordinary run, restores Goal and fresh bindings, redelivers the committed receipts,
then ACKs the exact successfully delivered set. A definitively rejected ACK
write leaves the original outbox authoritative. An uncertain write or lost ACK
reply may follow a successful commit: reload and reconcile the outbox before
deciding what remains; an already-removed receipt is not
silently accepted as a new ACK. Goal's existing duplicate-delivery accounting is
unchanged. No provider or tool is replayed and no terminal Conversation is reopened.

Document the command and recovery sequence in `PERSISTENCE.md` and the package API
documentation. Add Kernel, Store and file-backed cold-reopen coverage.

## #110: notification lifetime

Keep the existing mailbox and public notification acceptance API. A pending
mailbox entry whose `collaboration.kind` is `:notification` is active-only. Such
an entry may enter history at the next provider boundary of its accepting turn.
If the turn ends first, expire it in the acknowledged checkpoint that ends the
turn, before a queued followup or terminal settlement can carry it onward.
Cancellation, failed completion and suspension apply the same expiry rule.
Notifications already consumed into `messages` remain ordinary history.

Filter pending notifications at root settlement/rebind, child replacement,
fresh Conversation mailbox initialization, manager input binding and new-turn
admission. These boundaries also prevent an older retained snapshot from
delivering an active-only intent to a later turn. Do not filter ordinary queued
messages or result messages. Preserve the existing accepted/checkpointed,
skipped, conflict and uncertain responses and the accepted-notification ledger.

Queued conversation checkpoints currently append mailbox suffixes and can
resurrect a deletion. Give mailbox rebasing removal-aware semantics relative to
the queued command's base: remove only unchanged base entries removed by that
command, preserve concurrent ordinary additions, append each new entry once and
never reintroduce an unchanged base entry that another committed checkpoint
already removed. Use existing stable message identity and exact payload checks.
Apply lifecycle expiry at the final boundary as well as to the initially computed
checkpoint so a queued acceptance cannot escape the accepting turn. Keep other
conversation merge rules unchanged.

Cover actual provider inputs for child followup, root later turns, same-run
queued followup, cancellation/failure, old retained snapshots and settlement/
checkpoint races. A notification accepted after the current provider request was
built and unconsumed when that turn ends must appear zero times in later-turn,
replacement-run or recovery inputs. Also verify the positive case: a subsequent
provider boundary within the accepting turn consumes the notification once.
A consumed one remains once in history. An ordinary queued message accepted
alongside it still appears exactly once. Preserve existing stale/inactive and
duplicate tests.

## #111: settled errors at the Code Mode JSON boundary

Keep the native `%Backplane.AgentRuntime.Error{}` and Store/Conversation results
unchanged. Immediately before host-to-Deno tool-result encoding, traverse
ordinary maps/lists and project known native Error values with the existing
public fields `class`, `message` and `details`. Recursively project known Error
values in details; omit private `cause`, consistently with `Error.to_map/1`.

For example, a settled native rejection remains a resolved JavaScript value:

```json
{"type":"tool_result","id":"call_1","ok":true,"value":{"is_error":true,"error":{"class":"not_found","message":"command session is unknown","details":{}}}}
```

Preserve the existing NDJSON record type/correlation fields, both dispatcher
success tuple forms, result ordering/nesting and the returned context.
JavaScript can inspect the result and perform another tool call. This presentation
step must never rerun the original settled effect.

Preflight JSON encoding under controlled error handling before writing the
record. Clear the already-settled active-tool marker and retain the updated
context before handling an encoding failure; otherwise cleanup can incorrectly
upgrade a known result to `unknown_outcome`. Unsupported values become explicit
`malformed_result` failures after confirmed cleanup. Preserve existing encoder
behavior for other structs; do not generically flatten, stringify or drop opaque
values, unsupported keys or invalid UTF-8. Do not expose inspected terms or
encoder exception internals. Apply equivalent validation to the existing
transport-error envelope's details.

Preserve the 1,048,576-byte NDJSON record limit, measured as UTF-8 bytes excluding
the newline. An oversized result remains `budget_exceeded`. Genuine explicit
`unknown_outcome` and unconfirmed OS cleanup remain terminal and block later
effects. The JavaScript resolve/reject contract and native settlement policy do
not change. No new dependency or global JSON encoder is needed.

Use real Deno tests for the known Error projection, nested details, unsupported
values, context propagation, subsequent calls, explicit uncertainty and framing.
Exercise both dispatcher success tuple forms; the context-returning form must
prove that the next callback receives the updated context. Also cover the public
Session/Conversation completed-command-handle reproduction with a scripted
provider and a real command, rather than only an injected dispatcher: preserve
the original exit code 0 and output, retain the original native Error settlement
and identity in Store/history, run the following command exactly once and
complete the Conversation. Document the wire projection beside existing Code
Mode semantics.

## #112: Responses image tool results

Publish this supported image data form, using string keys and existing portable
size/depth limits:

```elixir
%{type: :image, data: %{
  "data" => bare_base64_or_complete_data_uri,
  "mime_type" => "image/png",
  "detail" => "original"
}}
```

`data` and `mime_type` are required. Support PNG, JPEG, WebP and GIF MIME types
(`image/png`, `image/jpeg`, `image/webp`, `image/gif`); the selected provider/model
still owns actual image decoding and restrictions such as animation. Require
valid nonempty base64. A complete supported URI has the form
`data:<matching-image-mime>;base64,<payload>`: validate its MIME against the
explicit MIME, retain the original URI bytes and do not add a second prefix.
Bare base64 becomes exactly one data URI. Other URI forms, remote URLs, file IDs,
additional data fields and unsupported MIME types fail explicitly.

`detail` is optional and accepts exactly `auto`, `low`, `high` and `original`.
When absent, encode explicit `auto`, matching the API default. Codex-aligned
consumers that require `high` must specify it. Preserve supplied detail verbatim;
do not downgrade `original` based on guessed model capability. Document that
detail/model support differs and local encoding does not establish remote
acceptance. Keep existing bounded opaque image construction and legacy provider
image representations compatible; Responses validates this newly documented
subset during encoding.

For a tool result containing an image, emit an ordered content array in the
associated `function_call_output.output` or `custom_tool_call_output.output`.
Map text blocks to native `input_text` and images to native `input_image` with
`image_url` and `detail`. Preserve each text block and image's order and the
original `call_id`. Continue requiring the preceding typed call to select the
output kind. Text-only outputs retain the existing string representation.
Do not promote images to user messages or flatten their bytes into text.

Canonical `Message.status` survives JSON persistence. Native Responses outputs
do not have Anthropic's semantic `is_error` marker: the function item's lifecycle
`status` values are not an error flag, and the custom output has no such status
field. Treat `nil` and `:success` as ordinary completed tool outputs. Reject
`:error` tool-result messages before transport for both output kinds, including
text-only results, instead of silently discarding that semantic distinction.
This intentionally tightens the existing lossy text-error edge. Do not invent
an unsupported status property, prefix text or conflate an error with incomplete
execution. Explain this limit in the public codec documentation.

The new multimodal route also rejects block/message extensions and image reason
metadata that the selected native schema cannot preserve. Other content kinds
and image message roles remain explicitly unsupported by Responses. Other codecs
gain no new media routes or cross-protocol capability claims.

Add independently authored native fixtures for both output kinds, all detail
values/default, both data forms, mixed order and explicit unsupported cases.
Round-trip canonical JSON, restore through public constructors, send through
the public codec with an OTP HTTP host client to a loopback server and assert the exact captured
JSON. The protocol package owns pure codecs and has no HTTP client; transport
remains host-owned. Preserve status, call identity and detail before/after reload. Include
legacy image-codec compatibility coverage. No real-provider acceptance is claimed.

Official source evidence retrieved on 2026-10-26:

- [Responses create reference](https://developers.openai.com/api/reference/resources/responses/methods/create):
  `FunctionCallOutput.output` and `CustomToolCallOutput.output` both admit text/
  image/file arrays. `ResponseInputImageContent`/`ResponseInputImage` define the
  data-URL `image_url` and detail values. The complete rendered reference was
  fetched because the documentation MCP Markdown endpoint returns a schema stub.
- [Function calling guide](https://developers.openai.com/api/docs/guides/function-calling):
  documents image/file arrays as function output.
- [Images and vision guide](https://developers.openai.com/api/docs/guides/images-vision):
  defines the default `auto`, supported detail values and model restrictions.

## #113: pinned host catalog snapshots

Add `context.catalog_snapshot` to provider `stream/2` using the catalog captured
when its request was built. Add the same field to direct and supported nested
`prepare_tool/2` contexts using the catalog already passed to preparation.
Its revision must match `request.catalog_revision` or
`invocation.catalog_revision` respectively. Runtime-owned fields override any
same-named value supplied through `provider_context`.

Pass the complete existing native catalog value: registry, authority, provider
definitions, revision and native metadata, including registry-only admitted tools
and descriptor backend/revision/exposure data. Keep provider-visible tools
filtered exactly as today. Older captured contexts retain their old immutable
catalog after a later successful publication. Provide no latest-catalog getter.

The snapshot is trusted host-only ephemeral context, just as it already is for
executing backends. Do not place it in provider requests, history, event logs,
execution intents or public JSON. This addition grants no stage/dispatch
callbacks to providers or preparation hooks. Existing callbacks keep their
existing behavior.

Extend dynamic publication tests to capture provider/preparation/backend
contexts across revisions, including nested preparation and a registry-only
tool. Verify matching snapshots, old-context retention, supplied-value override,
unchanged provider definitions and absence from persisted/public records.
Document the field in `ConversationAdapter` and the package documentation.

## Verification and delivery

| Boundary | Required evidence |
| --- | --- |
| Terminal ACK | All terminal states, subset/full ACK, exact receipt matching, malformed/duplicate inputs, wrong identity/stale revision, older receipt incarnation, failed persistence, durable reopen and deduplicated redelivery; unchanged outcome/effects and zero dispatch. |
| Notifications | Actual later provider inputs for child/root/same-run/recovery and races; missed notifications expire, consumed history and ordinary queued messages remain. |
| Code Mode | Real Deno and public command lifecycle; structured Error fields, context and next-call behavior; explicit malformed/oversized/uncertain outcomes without a worker crash or replay. |
| Images | Function/custom native fixtures, detail/default/data-URI fidelity, canonical JSON reload and exact loopback HTTP capture, explicit metadata/status incompatibility, legacy compatibility. |
| Catalog | Exact complete snapshots across publication and nested preparation, pinned revision and ephemeral exclusion. |
| Integration | Relevant owning-app suites first; warnings-as-errors compilation, formatting, strict Credo, Dialyzer and CI workflow contract checks required by the live CI; release configuration contracts. |
| Published release | Workflow completes all jobs; tag/source convergence, GitHub archives/checksums and packaged BuildInfo provenance, configured Hex/HexDocs cohort, GHCR image and final publication checks. Repeat public functional probes against fresh official 1.10.40 packages. |

Serialize shared BEAM/devenv builds and use CI-pinned Deno 2.8.3. Do not reset or
clean the existing local test database; use task-owned database resources for
checks requiring a fresh database. Out-of-scope failures are recorded and only
the affected work stops. Do not change unrelated code or weaken release gates.

Before dispatch, re-read the current release workflow: 1.10.39 changed asset
qualification/artifact handling and PostgreSQL setup. Use its declared inputs
and configured publication set. Verify the target version is still free and
the released immutable source contains only the approved scope on top of the
already-published baseline. If concurrent unpublished commits enter `main`,
reconcile the authorized release boundary before publishing them.

Implementation and independent spec/code-quality reviews cover all five requests.
Focused Conversation coverage passes 93 tests and the AI protocol suite passes 178.
The original full runtime suite passes 1044 tests; the earlier two native cleanup
failures and diagnostic rerun are retained as verification evidence. Scoped
formatting, strict compilation and Credo pass. Local Elixir 1.18 Dialyzer has no
new Kernel warnings after using a private ID map; eight warnings in unchanged
files and one unchanged root formatting difference remain for the required
Elixir 1.19.5 CI. Release/CI/Hex contracts pass 34/8/8 tests; the Hermes oracle
passes 74. Exact-source CI, published-package acceptance and 1.10.40 publication
remain release gates; no real-provider acceptance or deployment is claimed.
