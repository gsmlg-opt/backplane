# Native readable Web fetch

Issue: #157. Scope: `backplane_agent_runtime` native service factory, host adapter
boundary, documentation, and ordinary fixture acceptance.

## Decision

Retain the existing revision-1 `web::fetch` raw transport contract. A host that
sets `web_fetch_adapter: MyReadableFetch` explicitly selects revision 2 while
building `Services.contracts/1` or `Services.definitions/1`. The factory captures
the selected adapter in its backend context before catalog admission. Neither
invocation arguments nor adapter responses can replace that admitted descriptor.
`Services.definitions/0` remains revision 1.

Revision 2 adds optional `extract_mode` (`markdown` or `text`) and positive
`max_chars` to `url` and `instructions`. Arguments pass the existing schema
validation without defaults or rewriting. The adapter implements
`Codex.Web.ReadableFetch.fetch/2` and receives the complete input plus host options.

## Execution and results

`Web.fetch_readable/3` validates the original absolute HTTP(S) URL and host
allowlist before calling the trusted host adapter. The adapter owns verified
acquisition, per-hop redirect authorization, transfer decoding (including
chunked responses), extraction, content-type dispatch and caching. It returns
extracted content as a rich result, never as invented raw transport bytes.

Success is a bounded plain JSON map with string keys. Required fields are `url`
(the exact requested URL), `final_url` (the final authorized HTTP(S) URL), `text`
(UTF-8, including an empty document), and `content_type` (nonempty UTF-8).
Additional portable fields such as `title`, `extractor`, extraction mode,
length/timing/cache metadata and exact JSON-number text are preserved unchanged.
The runtime does not normalize text, round numbers, truncate metadata, strip
headers, or silently fall back to raw fetch. The entire result is bounded by
`web_result_limit` using `:erlang.external_size/1`.

Native Backend supplies reserved `runtime_context` with exact invocation and
catalog identity, resource/effect ownership and the live ToolEffects deadline
accessor. Service input cannot override it. Timeout is clamped to configured
`web_timeout` and the current remaining effect allowance; bounded execution does
not renew the deadline. Adapters receive the same accessor and must apply the
remaining allowance throughout acquisition/extraction and clean up their own
resources. Process-local context cannot appear in the portable result.

Private host pipeline configuration uses `web_fetch_options`, a keyword list.
Canonical allowlist, timeout, result limit, transport and runtime context always
win over those private options. Invalid option containers return a validation
error. The factory API also includes
`Services.admitted_definitions(context, authority)`.

## Alternatives

Widening revision 1 globally would change admitted schema identity and raw
semantics for existing hosts. Replacing transport responses with extracted text
would misrepresent data origin and still lose metadata. The explicit revision-2
factory retains native classification, authorization, ToolEffects execution and
result persistence while letting hosts supply their extraction pipeline.

## Verification and limits

Fixture tests cover versioned factory admission, complete extraction input,
original/final URL and rich metadata preservation, exact text, deadline/context
propagation and complete native Conversation/Store result delivery. Existing raw
fetch tests retain redirect/chunked refusal. Focused validation covers portable
result and size bounds, adapter failure and exhausted allowance.

This change supplies the host boundary; it does not implement or qualify
Readability, a specific HTTP client, local decoding/cache correctness, a real
provider, or consumer reopen behavior. Synapsis must update the released package
and qualify its own acquisition/extraction pipeline.
