# User-message inline PDF encoding — proposed 1.10.43

Date: 2026-10-27

Status: approved by the user on 2026-10-27. Implementation and verification are
in progress; this document does not claim completed feature tests.

Issue: [#116](https://github.com/gsmlg-opt/backplane/issues/116).
Source baseline: `main` at `793cd3cf5780f6c003653191275a1c42e920d37b`.
The inspected `backplane_ai_protocol` source matches published 1.10.42 source
`2b7a3318a5fbb31b5a49824b01a3343dac043d0b`. The unrelated Memory commit and
concurrent parent-owned Runtime #118 edits are outside this design.

## Outcome and ownership

Allow a host to construct ordered user content containing prompt text and inline
PDF resources, persist/reload that canonical content, and encode the same PDF
bytes as Anthropic Messages documents or Google GenerateContent inline parts.
The host continues to use `Backplane.AiProtocol.Codec`; downstream applications
do not construct provider-specific PDF request maps.

Keep implementation inside `apps/backplane_ai_protocol`. The package remains a
pure codec: the host owns PDF acquisition, model capability selection, HTTP,
authentication, request-body limits and provider failures. File/URL fetching,
PDF parsing, extraction, rasterization, password/page handling, gateway changes,
runtime tools and downstream Synapsis changes are outside scope.

## Existing behavior and the missing path

The current source establishes these boundaries:

- `lib/backplane/ai_protocol/content_block.ex` and `media.ex` already accept a
  `:resource` with string-keyed `uri`, `mime_type` and optional base64 `data`.
  URI is mandatory; `text` and `data` are mutually exclusive. The generic
  constructor permits an empty resource body and validates absolute URI identity
  without fetching it.
- `media.ex` currently emits Anthropic PDF documents only for exact HTTPS
  tool-result references. Its Google resource route accepts exact two-field
  URI-only maps. Neither supplies user-message inline PDF bytes.
- `Media.preflight/2` and `Media.encode/3` revalidate via `ContentBlock.new(block)`
  without caller options. Google contents/parts and Anthropic tool-media paths
  also omit these options, even though constructors already forward them.
- `Validation` defaults are `max_string_bytes: 262_144` and
  `max_bytes: 1_048_576`. `Serialization.from_json/2` separately defaults to
  `max_encoded_bytes: 2_097_152`. `Serialization.decode_and_validate/3` already
  forwards structural limits to its decoded-value check.
- `Request.new/2` validates nested content but does not currently impose a single
  aggregate byte budget on the entire Request. This feature must not silently
  redefine that contract.

## Chosen contract and alternatives

The proposed choice is the existing URI-bearing `:resource`, with an explicitly
documented canonical-only URI for the new inline form. This preserves existing
construction and JSON persistence while adding two narrow provider mappings.
Its tradeoff is a documented exception to README's current general statement
that encoding never discards a URI to obtain a supported form.

A URI-less inline resource would avoid that exception, but would change the
constructor contract and introduce a second resource shape. A new `:document`
content kind would make the distinction more explicit, but would expand public
types, validation and downstream reconstruction beyond the requested additive
codec change. Neither alternative is selected for this proposal.

A fixed per-document ceiling plus existing caller structural limits is selected
over raising global defaults or adding another public limits option. Hosts can
choose smaller structural envelopes; larger decoded PDFs remain incompatible.

## Exact canonical subset

The new supported block is:

```elixir
%{
  type: :resource,
  data: %{
    "uri" => "file:///fixture/report.pdf",
    "mime_type" => "application/pdf",
    "data" => Base.encode64(pdf_bytes)
  },
  extensions: %{}
}
```

The data map must have exactly those three keys. MIME must be exactly
`application/pdf`; `data` must decode as valid, nonempty base64 and contain at
most 10,485,760 decoded bytes (10 MiB). Retain the caller's exact base64 string;
do not decode/re-encode it for transmission. The library does not inspect the
PDF format or infer model acceptance from MIME alone.

Only `:user` messages gain this form, only for `:anthropic` and `:google`.
PDF block extensions and extensions on a user message containing this form must
both be empty. This narrow admission prevents portable annotations from being
silently lost by these new mappings. Do not invent title, filename, citation or
provenance fields. Additional data keys and nonempty extensions remain
incompatible at encoding even when canonical persistence can represent them.
The constructor's existing general resource contract remains unchanged.

The URI remains an exact canonical source identity through construction and JSON
reload. Any absolute URI already admitted by the resource constructor can serve
as that identity, including a `file:` URI. It is neither fetched nor transmitted
in the new inline provider block. Do not convert it into a URL source, filename,
title or prompt. This omission is an explicit feature contract, not a fallback
that strips unsupported metadata. All other submitted fields must be represented
exactly or cause incompatibility.

Assistant, system, developer and tool messages do not gain inline PDF encoding.
OpenAI Chat and OpenAI Responses remain incompatible with this form. Existing
Anthropic HTTPS tool-result PDF references/named links, Google URI-only resources,
text, images and supported audio retain their current mappings and role rules.

## Exact provider output

For each admitted block, Anthropic user `content` contains:

```json
{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":"<same base64>"}}
```

Google user `contents[].parts` contains:

```json
{"inlineData":{"mimeType":"application/pdf","data":"<same base64>"}}
```

Preserve every prompt/document position, including text before, between and after
multiple distinct PDFs. Do not join documents, synthesize labels or flatten them
into text. The encoded maps contain no URI or additional document metadata.

Google's public `Codec.encode_rest_request(:google, request, opts)` continues to
return `%{target: target, body: body}`; transport model/operation/stream targeting
stays outside the REST body. The historical `Codec.encode_request(:google, ...)`
wrapper must produce the same PDF parts in its existing compatibility envelope.
No response/stream PDF decoder is added.

## Limits and API data flow

Preserve every existing global default. Add option propagation through these
internal boundaries while retaining their existing arities:

```elixir
Media.preflight(request, protocol)              # existing, default opts []
Media.preflight(request, protocol, opts)        # added
Media.encode(block, protocol)                  # existing user-context wrapper
Media.encode(block, protocol, message)         # existing, default opts []
Media.encode(block, protocol, message, opts)   # added
```

`Media.encode/4` revalidates using `ContentBlock.new(block, opts)` and applies the
same role, metadata and PDF checks used by preflight. All four provider codec
entry paths pass their original options into media preflight. Anthropic ordinary
user media and existing tool media carry those options into final media encoding;
retain actual message context for role/extension checks. Google carries options
through contents, message, parts and media encoding. Adapt its private helper
calls consistently, including system-part callsites, without admitting media in
additional roles or changing thought-signature part-position handling.

The fixed decoded ceiling is an encoding subset rule, independent of caller
structural limits. Validate the existing bounded portable map/base64 contract
before emitting a wire block, then require decoded size in `1..10_485_760`.
The ceiling applies to each document on every public codec path.

After successful per-block media preflight, validate one ordered list containing
the canonical `data` maps of all newly admitted inline PDFs across the request:

```elixir
Validation.term(inline_pdf_data_maps, Keyword.get(opts, :limits, %{}))
```

Apply this only when that collection is nonempty and only to the new supported
Anthropic/Google user-PDF subset. It counts URI, MIME and base64 strings plus map
keys under the existing byte accounting, and uses the existing depth, node, map
and list limits. It does not include prompt text or unrelated content. Keep
per-block validation as well. Two individually valid PDF blocks must fail when
their combined data maps exceed the caller's aggregate structural budget.
This adds a bounded PDF collection without imposing a new whole-Request budget
on old content or adding another limits option.

Malformed canonical input and structural-limit failures retain existing
`:invalid_request` validation errors. Unsupported protocol, role, metadata,
empty inline PDF body or fixed decoded-ceiling overflow use the existing media
`:incompatible` path with `upstream_outcome: :not_submitted`. No partial successful
request is returned. The host submits only a successfully encoded request.

## Canonical persistence and a supported larger profile

Use existing Serialization APIs; production Serialization changes are unnecessary.
For an explicit two-document envelope supporting up to 10 MiB per document:

```elixir
limits = %{max_string_bytes: 13_981_016, max_bytes: 33_554_432}
opts = [limits: limits]
json_opts = [limits: limits, max_encoded_bytes: 33_554_432]
```

A 10,485,760-byte PDF occupies 13,981,016 base64 bytes. Two occupy 27,962,032
base64 bytes before URI/key/JSON overhead. This profile admits ordinary prompts
and bounded source identities while retaining explicit 32 MiB structural and
encoded limits. It does not promise that arbitrary additional content fits.

Pass the same `limits` at initial ContentBlock/Message/Request construction, JSON
reload validation, the reload constructor closure, and codec encoding. The host's
HTTP/JSON boundary must separately bound the complete serialized provider body.
`Serialization.to_json/1` has no options or encoded-size enforcement; hosts must
check persisted JSON size themselves. `from_json/2` uses the encoded limit;
`decode_and_validate/3` additionally validates the entire decoded JSON projection
under `limits` before calling its validator. That whole-projection reload check
is broader than the new codec PDF-collection check and remains unchanged.

On reload, map only fixed known Message role/status values and public Request
fields into constructor attributes, as existing package examples require;
ContentBlock already recognizes its fixed string type tags. Never create atoms
from arbitrary JSON strings. The validator closure must call the public
constructors with `opts`, rather than silently reintroducing defaults.
Omitting larger options at any applicable stage must continue to expose that
stage's existing default limit. No automatic retry with larger limits is added.

## Implementation allowlist after approval

Production changes are limited to:

- `apps/backplane_ai_protocol/lib/backplane/ai_protocol/media.ex`.
- `apps/backplane_ai_protocol/lib/backplane/ai_protocol/codec/anthropic.ex`.
- `apps/backplane_ai_protocol/lib/backplane/ai_protocol/codec/google.ex`.
- `apps/backplane_ai_protocol/lib/backplane/ai_protocol/codec/openai.ex` and
  `codec/openai_responses.ex`, only their media-preflight opts propagation.
- `apps/backplane_ai_protocol/lib/backplane/ai_protocol/codec.ex` and
  `content_block.ex`, documentation only.
- `apps/backplane_ai_protocol/README.md` and `SOURCE_NOTES.md`.

Test/fixture changes are limited to:

- New `apps/backplane_ai_protocol/test/backplane/inline_pdf_test.exs`.
- Bounded regression additions to `test/backplane/media_content_test.exs`.
- New `test/fixtures/pdf/first.pdf` and `second.pdf`, ordinary finite distinct
  local documents with documented fixture provenance.
- New independently authored native request fixtures
  `test/fixtures/anthropic/inline_pdf_user.json` and
  `test/fixtures/google_genai/inline_pdf_user.json`, with updates to the adjacent
  existing `PROVENANCE.md` files. Reuse the established `google_genai` directory.

Paths in the test list are relative to `apps/backplane_ai_protocol` after the
first entry. No dependency, lockfile, Validation default, Serialization production
code, provider transport or runtime source changes are included. Any newly
necessary scope expansion must be reviewed before editing beyond this list.

## Acceptance and verification

Implementation acceptance requires these ordinary local functional checks:

1. Construct two distinct PDFs through public Request/Message/ContentBlock APIs
   with text before, between and after them. Serialize, reload using explicit
   limits and constructor closure, then encode both providers. Assert exact URI,
   MIME, base64 and content order in canonical reload; decode native base64 and
   compare it byte-for-byte with each original PDF.
2. Compare complete emitted request maps with independently authored Anthropic
   and Google fixtures. Expected maps must not be generated by the encoder under
   test. Exercise both Google public entry points and assert REST targeting is
   excluded from the native body.
3. Exercise a positive PDF larger than the current 262,144-byte string default
   through construction, JSON reload and both encoders with explicit options.
   Exercise exactly 10,485,760 decoded bytes successfully and one byte above the
   ceiling as incompatible, with sufficient structural limits for both cases.
   Test nonempty base64, smaller caller limits and omitted codec/reload options.
4. Exercise multiple individually valid PDFs whose data-map collection crosses
   `max_bytes`; assert aggregate failure. Check a sufficient aggregate budget
   passes, a caller list bound applies to that collection, and encoded JSON reload
   separately rejects its configured byte limit. Default limits remain unchanged.
5. Submit the actual serialized public codec output through an OTP host HTTP
   client to loopback fixtures for Anthropic `/v1/messages` and Google
   `/v1beta/models/<fixture-model>:generateContent`. Assert method, target path,
   Content-Length, complete body bytes and parsed native JSON, including PDF and
   prompt order. Use the existing `:httpc`/`:gen_tcp` pattern in
   `test/backplane/responses_image_test.exs`; add no production HTTP client.
6. Retain exact existing HTTPS PDF tool-result, Google URI-resource and supported
   text/image/audio behavior. Confirm the new subset remains incompatible for
   other roles/protocols, empty PDF data, extensions and extra metadata, without
   stripping fields or changing existing thought-signature positions.
7. Update docs with the precise URI exception, strict metadata subset, decoded
   ceiling, PDF aggregate semantics and all limits stages. Fixture provenance
   must distinguish native schema references from local execution evidence.

After implementation, the coordinator runs the focused inline-PDF and media tests,
then the owning AI protocol suite and scoped format/compile checks in the shared
serialized build environment. Actual commands and outcomes must be recorded;
this design drafting assignment runs none of them. Release acceptance separately
checks the officially published package cohort. No source-tree test result alone
unblocks the downstream dependency requirement.

## Provider evidence and completion limits

Issue #116 records the pinned OpenClaw reference
`488631c18fae7cc541ba8fc8beff6cbb0438787b` and its native PDF provider mappings.
The native schema references for fixture provenance are:

- https://platform.claude.com/docs/en/build-with-claude/pdf-support
- https://ai.google.dev/gemini-api/docs/document-processing
- https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta

These references are review inputs; this drafting assignment did not refresh
remote documentation or call providers. Implementation must record the schema
source/version used when authoring fixtures and resolve a contradictory source
before advertising a mapping.

Successful codec fixtures and loopback HTTP prove canonical persistence, exact
wire encoding and host transport composition. They do not prove remote acceptance
by every model, provider body/page/context limits, document quality, passwords,
analysis results or downstream asynchronous replay. A host must select a model
that accepts native PDF documents and satisfy its current provider limits; the
10 MiB ceiling is this codec's supported envelope, not a provider capability claim.

Approval of this document selects the URI-bearing canonical-only identity, empty
extension subset, two user-role mappings, fixed 10 MiB decoded ceiling and bounded
aggregate PDF collection described above. After user approval, implement and
verify this contract, then complete the already requested release; implementation,
publication and downstream provider acceptance remain distinct results.
