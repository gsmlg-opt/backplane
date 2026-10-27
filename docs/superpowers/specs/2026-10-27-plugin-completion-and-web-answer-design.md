# Verified plugin completion and synthesized Web answers

Date: 2026-10-27

Status: proposed; implementation has not started. This design covers internal
requests [#124](https://github.com/gsmlg-opt/backplane/issues/124) and
[#125](https://github.com/gsmlg-opt/backplane/issues/125), against main at
`fd31834b178e40a0ee335fc9c2872fa6dd8182ce` (published as 1.10.43).
The coordinating release design owns batch scope, approval, CI and publication.

## Problem and boundaries

`Codex.DynamicRuntime` always describes a successful plugin installation adapter
response as `requested`, even when a trusted adapter has already installed and
verified the package. The pure `Codex.Dynamic.complete_plugin/3` operation exists,
but the native dispatcher never uses it. A saved request and a verified completed
installation therefore have no distinct native result representation.

`Codex.Web` currently requires every successful search result to contain a
`results` list. An answer with citations, such as a Perplexity Sonar result, cannot
cross this public boundary without inventing rows or replacing the dispatcher.

Both changes extend existing result contracts. Runtime remains the native effect
and settlement owner; the host still owns installation, provider HTTP, projection
and any cache. Neither change starts plugin MCP components, grants tools, adds an
installation scheduler, changes permission policy or introduces a search provider.
Plugin Session cleanup and MCP ownership remain the separate #122 contract.

## Current source evidence

- `codex/dynamic_runtime.ex:124–130` creates a request receipt, invokes
  `request_install/2`, and unconditionally returns the requested wrapper.
- `codex/dynamic_runtime.ex:329–351` accepts ordinary adapter success maps/lists
  and propagates structured Runtime errors. Plugin completion needs a dedicated
  result branch rather than changing every adapter's success contract.
- `codex/dynamic.ex:154–180` records a requested receipt and provides a pure
  completion update. Completion does not publish tools.
- `codex/backend.ex:56–57` sends native dynamic operations through the same public
  DynamicRuntime dispatch. The install descriptor remains non-read-only and
  non-retry-safe (`dynamic_runtime.ex:362–371`).
- `codex/web.ex:144–180` handles both public search adapters through one normalizer,
  requires `results`, and bounds the complete result with `:erlang.external_size`.
- `codex/services.ex:91–104` uses that public boundary for `web::search` and
  `web::x_search`. The separate `web::run` adapter is not part of this change.

All paths above are relative to
`apps/backplane_agent_runtime/lib/backplane/agent_runtime/`.

## Plugin adapter outcome contract

The existing callback remains `request_install(arguments, operation)`. Its legacy
success contract is unchanged:

```elixir
{:ok, host_result} # host_result is an ordinary map or list
```

Runtime continues to return exactly the requested wrapper:

```elixir
%{request_id: receipt.id, status: :requested, host: host_result}
```

In particular, a legacy map containing a `completed` key does not silently opt into
the new contract. Existing durable-request adapters keep their current behavior.

A trusted host that finishes installation and verifies the installed artifact
before returning opts into the following tagged result:

```elixir
{:ok,
 {:completed,
  %{
    completed: true,
    user_confirmed: true,
    tool_type: "plugin",
    action_type: "install",
    tool_id: "example",
    tool_name: "Example"
  }}}
```

The fields map uses atom keys. Required keys are `completed`, `user_confirmed`,
`tool_type`, `action_type` and `tool_id`; `tool_name` is optional. No other fields
are part of this variant. `completed` must be the boolean `true` and
`user_confirmed` must be a boolean whose actual value is retained. The three
identity strings must be nonempty valid UTF-8 and equal the corresponding final
request arguments. An optional `tool_name` is a nonempty valid UTF-8 display name
reported by the verified host installation; it is not substituted for `tool_id`.

Runtime creates the receipt once for this native invocation and passes its ID to
the adapter as the additive, Runtime-owned `operation.plugin_request_id` field.
The adapter receives the original arguments and all original operation identity
fields unchanged. This host context field does not alter the canonical argument
digest, model schema or committed invocation identity. It allows the host to bind
its installation evidence to the same request returned by the native tool.

After validating the tagged outcome, Runtime completes that same receipt through
the existing pure Dynamic state update and returns:

```elixir
%{
  request_id: receipt.id,
  status: :completed,
  completed: true,
  user_confirmed: fields.user_confirmed,
  tool_type: fields.tool_type,
  action_type: fields.action_type,
  tool_id: fields.tool_id
  # tool_name is present only when the host supplied it
}
```

There is no nested completion tuple at the native JSON boundary. The public result
is an ordinary map, so direct native execution and real Deno Code Mode serialize
the same fields through their existing result and journal paths. Runtime does not
infer user confirmation, perform a second installation, activate components or
publish a tool catalog when completing the receipt.

### Failure, cancellation and replay

`{:error, %Backplane.AgentRuntime.Error{}}` remains the adapter failure result and
is propagated unchanged, including `:unknown_outcome`. An adapter that has not
completed installation uses the legacy requested outcome when it saved a pending
request, or a structured error when the operation failed, was cancelled or cannot
be confirmed. `completed: false` is not a completed variant and is not converted
into a queued request.

A recognized completed variant with malformed or mismatched verification fields
cannot confirm the installation. Return a structured `:unknown_outcome` error with
a stable malformed-completion reason; do not turn it into requested success or a
trusted assertion that no installation occurred. Other existing malformed legacy
adapter-result handling remains unchanged. The adapter may already have produced
an installation effect before returning invalid evidence.

The existing native effect deadline, cancellation and uncertain-settlement rules
continue to apply. An outcome observed after its invocation has lost admission
cannot commit a later success or rewrite an already committed requested result.
No asynchronous completion tracker, background retry or late settlement mutation
is introduced here. The host remains responsible for its owned installation work
and for truthfully returning failure or uncertainty.

Request IDs are process-local receipts, not a new durable exactly-once system.
An already settled native invocation is replayed from its authoritative journal;
that replay retains the recorded request ID and must not call the installer again.
A new explicit invocation receives a new receipt. A crash before acknowledged
settlement does not authorize automatic installation replay, even if host-side
installation might already have completed. Root and managed-child operations keep
their original run, incarnation, invocation and binding identities.

## Web search result union

Existing successful results maps retain their representation and return value.
The normalizer continues to accept an atom- or string-keyed `results` list without
reshaping its entries, changing its metadata or adding a discriminator.

An explicitly tagged answer is the additional success branch:

```elixir
%{
  "kind" => "answer",
  "provider" => "perplexity",
  "query" => "Elixir release news",
  "content" => "A synthesized fixture answer.\r\nSecond line.",
  "citations" => [
    "https://example.test/first",
    %{"url" => "https://example.test/second", "title" => "Second source"}
  ]
}
```

The answer tag accepts `:kind` or `"kind"` and the value `:answer` or `"answer"`.
Recognized answer fields accept atom or string key spellings. Providing both
spellings of the same recognized field is ambiguous and is not a supported answer
shape. This rule does not change legacy results-map lookup behavior.

`content` is required and must be a nonempty valid UTF-8 binary. `provider` and
`query` are optional valid UTF-8 binaries. `citations` is optional and, when
present, is an ordered list. Each citation is either a nonempty valid UTF-8 URL
string or an atom/string-keyed map with a required nonempty UTF-8 `url` and an
optional UTF-8 `title`. Runtime does not fetch, canonicalize, sort or deduplicate
citations. It preserves their exact values, order, key spelling and additional
adapter metadata. Additional top-level metadata is likewise retained without
Runtime-specific interpretation.

Branch precedence preserves compatibility: a map with an existing valid `results`
list takes the original results branch, even if it also contains answer-like
metadata such as `kind: :answer`. Only when no valid results list is present does
an explicit answer tag select answer validation; that branch does not require or
fabricate `results`. Other shapes retain the existing malformed-result outcome.
Accepted maps are returned unchanged. Consumers can project provider-specific
metadata into their product contract without changing Runtime's dispatcher.

Both branches use the existing positive `result_limit` option and its existing
default of 1,048,576. The limit remains `:erlang.external_size` of the entire
original result, including answer content, citations and metadata. It is not
changed into a JSON-byte or text-only limit. The adapter still receives the same
options, and no additional watchdog is started by this normalizer.

Invalid answer fields produce `:malformed_result`, invalid limits produce
`:validation`, and an oversized complete result produces `:budget_exceeded`.
Existing typed backend errors, native effect ownership, cancellation, settlement
and serialization behavior remain unchanged. `Web.search/3` and `Web.x_search/3`
share the added union. No Perplexity transport or `web::run` change is included.

## Alternatives considered

For plugin completion, promoting any legacy map with `completed: true` would be
smaller but would reinterpret previously opaque host data and allow ambiguous
outcomes. An explicit tag preserves compatibility. A separate asynchronous install
manager would require new ownership, cancellation and persistence machinery; the
reported need is already satisfied by a host that completes within the existing
native effect and returns verified evidence.

For Web answers, adding an empty `results` list changes meaning and does not meet
the requested contract. A new answer-only tool would split dispatch and require
consumers to change lifecycle paths. A tagged branch in the current normalizer
keeps the existing API and size bound with a small, explicit result union.

## Implementation ownership

Expected production edits stay in `codex/dynamic_runtime.ex` and `codex/web.ex`.
The existing `Dynamic.complete_plugin/3` helper may be reused; this design does not
require broad changes to the pure Dynamic API or other adapter families. Document
the two contracts in the owning Runtime's `CODEX.md` or `README.md`.

Regression coverage belongs in the owning Runtime tests. Existing
`codex_ct07_test.exs`, `codex_ct09_test.exs` and
`conversation_code_mode_context_test.exs` provide adjacent fixtures; focused new
plugin-completion and Web-answer test modules may keep these cases independent.
Any reusable local package-install fixture stays under the Runtime test fixture
directory. No downstream repository, provider HTTP implementation, lockfile,
permission policy or plugin Session cleanup implementation is part of these two
features. Batch-wide release integration is owned by the coordinating plan.

## Acceptance and evidence

Implementation must provide the following ordinary functional evidence:

1. A legacy map and list adapter response retains the exact requested wrapper.
   A legacy map containing completion-like keys remains requested.
2. A real local Plugin Protocol package is installed through the supported public
   installer; the trusted test host verifies the installed artifact before
   returning the tagged outcome. Keep this proof distinct from a deterministic
   adapter-shape fixture.
3. The public native dispatcher returns completed fields at the top level, with
   exactly the receipt ID delivered to the host. `user_confirmed: false` remains
   false when that is the host's actual verified result. Installation completion
   does not publish tools or activate plugin MCP components.
4. Exercise the same completed and requested outcomes through direct native
   execution and real Deno Code Mode. Verify the serialized result, authoritative
   journal and next model request, rather than only calling the normalizer.
5. Root and managed-child execution retain their own original run/incarnation,
   invocation and binding identities. An exact settled replay preserves the
   stored completion and does not increase the host installation counter.
   Independent cold-BEAM evidence must use persisted settlements, not a live
   process-local DynamicRuntime receipt map.
6. Structured host failure and unknown outcome remain failures/uncertainty. A
   cancelled or expired native effect does not acquire a late committed success,
   and no uncertain installation is automatically repeated.
7. Public Web and x_search fixtures accept answer-only maps in both key styles;
   preserve Unicode, CRLF, optional fields, URL-string/map citations and order;
   and keep ordinary results maps and typed backend errors unchanged. A formerly
   valid `%{results: [], kind: :answer}` map retains its existing success despite
   having no answer content; verify results-first precedence in both key styles.
8. Confirm the existing whole-map bound includes answer content, citations and
   metadata. Service-backed native execution must carry the accepted answer into
   the next model request and journal through the existing effect path. Where
   that admitted service is invoked by Code Mode, use real Deno and the same
   public dispatcher.

Run focused checks first, followed by the owning Runtime suite and required batch
compile/format/Credo/Dialyzer/package gates. The approved release must separately
verify the official Hex packages in a fresh consumer; a source-only fixture or
tag does not establish package availability or downstream adoption.

This design does not claim a real Perplexity request, Synapsis/Sigma acceptance,
production plugin activation or deployment. Those remain separate consumer and
operational evidence after the official release is available.
