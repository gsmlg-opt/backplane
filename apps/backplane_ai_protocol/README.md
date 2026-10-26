# Backplane.AiProtocol

`backplane_ai_protocol` is the Backplane umbrella's pure protocol-contract and
provider-codec application. It contains canonical request, response, content,
tool, usage, error, provider-state, and stream-event values together with
bounded validation, serialization, SSE framing, and provider wire codecs.

It does not own HTTP transport, credentials, retries, cancellation, process
lifecycle, persistence, Phoenix, database access, or network startup. A client
such as Synapsis owns those concerns and feeds bytes to the codec. The Backplane
gateway separately owns proxy routing, authorization, native forwarding,
provider presets, and durable observation.

## Provider codec API

`Backplane.AiProtocol.Codec` is a pure facade with four supported selectors:

- `:anthropic` for Anthropic Messages
- `:openai` for OpenAI Chat Completions and compatible APIs
- `:google` for Google Gemini GenerateContent
- `:openai_responses` for Responses text, JSON functions, raw custom tools and image tool results

The facade exposes:

```elixir
Codec.encode_request(protocol, request, opts)
Codec.encode_rest_request(:google, request, opts)
Codec.decode_response(protocol, status, headers, body, opts)
Codec.decode_error(protocol, status, headers, body, opts)
Codec.stream_new(protocol, opts)
Codec.stream_feed(protocol, state, bytes)
Codec.stream_finish(protocol, state, reason)
```

Request encoding returns `{:ok, string_keyed_wire_map}` or a structured
`{:error, %Backplane.AiProtocol.Error{}}`. Response and error decoding are also
tagged. Stream state is an ordinary caller-owned value; the package starts no
processes.

For Google GenerateContent, `encode_rest_request/3` is the preferred API. It
returns separate `target` and `body` maps so model/operation/stream transport
metadata cannot leak into the REST entity. `encode_request/3` remains the
compatibility envelope used by existing consumers.

`stream_new/2` returns the initial state directly. `stream_feed/3` and
`stream_finish/3` use these tagged shapes:

```elixir
{:ok, next_state, [%Backplane.AiProtocol.StreamEvent{}]}
{:error, %Backplane.AiProtocol.Error{}, next_state}
```

Stream events can represent text/reasoning deltas, content, tool-call lifecycle,
opaque provider state, usage, terminal state, or a structured error. Hosts must
decide how those events become runtime messages and must not treat protocol
terminal observation as transport/process ownership.

The OpenAI Responses observer remains a separate observation helper for Backplane's
native proxy path. `:openai_responses` selects the client codec; `:responses` is
not an alias.

## Custom tool input and canonical namespaces

JSON tools retain the default `input_kind: :function`, `input_schema` map and
`{:json, bytes}` or `{:structured, map}` arguments. Custom definitions explicitly
use `input_kind: :custom`, optional bounded `format` metadata, and no JSON schema.
Custom calls use `raw_arguments: {:custom, text}`; patches and JavaScript remain
text and are never wrapped in a synthetic JSON object. Constructors validate
UTF-8 and existing portable-value limits (262,144 bytes per string by default).

Names may be unqualified or use a canonical `namespace::name` identity. Responses
encodes namespace tool declarations and separate native call `namespace`/`name`
fields, then reconstructs the canonical identity on decode. Chat Completions,
Anthropic and Google codecs reject custom input and canonical namespaces with
an incompatible capability and `upstream_outcome: :not_submitted` before a host
can dispatch the request.

Responses projects `custom_tool_call`, `response.custom_tool_call_input.delta`,
`response.custom_tool_call_input.done`, and `custom_tool_call_output`. Tool result
history must contain the associated typed call so the codec can choose function
or custom output. Stream deltas identify input kind in
`extensions["openai_responses::input_kind"]`; completed content retains the tagged
arguments. Duplicate call IDs, unknown/mismatched item IDs, changed completion
input, incomplete terminals and cumulative input overflow are rejected.
Only an absent tool-item status or explicit `completed` status can complete a call;
an explicit non-completed status is rejected, including in terminal output. An
incomplete response may return partial text but cannot complete tool calls. Hosts
must wait for a successful response terminal before dispatching any tool. Use
`max_tool_input_bytes` on Responses stream/response decoding to tighten the input
bound. Retained streams default to 128 calls and 1,048,576 total tool-input bytes;
`max_tool_calls` and `max_total_tool_input_bytes` can tighten these limits. SSE
framing limits also apply.

The Responses codec supports text, function/custom calls, text results, ordered
text/image tool results, usage and terminal events. It rejects images outside
tool results, reasoning, opaque provider state and unsupported events. This
subset does not establish complete provider parity or
enable cross-protocol gateway routes. All credentials, approvals and execution
authority remain host-owned.

## Responses image tool results

The supported canonical image block is:

```elixir
%{type: :image, data: %{
  "data" => bare_base64_or_complete_data_uri,
  "mime_type" => "image/png",
  "detail" => "original"
}}
```

`data` and `mime_type` are required string fields. Supported MIME values are
`image/png`, `image/jpeg`, `image/webp` and `image/gif`. Data must be valid,
nonempty base64, either bare or a complete
`data:<matching MIME>;base64,<payload>` URI. Bare data receives exactly one
prefix; an existing URI is retained byte for byte. Remote URLs, file IDs,
other URI forms, mismatched MIME, additional data fields, message/block
extensions and image `reason` metadata are explicitly incompatible.

Optional `detail` accepts exactly `auto`, `low`, `high` and `original`.
Omission encodes explicit `auto`, matching the API default. Consumers requiring
Codex's `high` preference must specify it. Detail/model support varies; the
selected provider/model owns decoding, animation and other image restrictions.
Encoding does not inspect the image format or establish remote acceptance,
and never silently downgrades a supplied detail value.

Image-bearing tool results encode an ordered array of native `input_text` and
`input_image` blocks inside `function_call_output.output` or
`custom_tool_call_output.output`. The preceding typed call selects the output
kind and retains its `call_id`. Images remain tool results; text-only results
keep their existing string output. Other image roles and other multimodal
tool-output kinds remain unsupported. Existing opaque image construction and
the three legacy codecs' image representations remain compatible; Responses
validates its supported subset during encoding.

Canonical `Message.status` survives `Serialization` JSON persistence and public
constructor reload. Status `nil` or `:success` represents ordinary completed
outputs. Responses has no semantic `is_error` marker: function lifecycle status
does not mean failure, and custom outputs have no such status field. Both
image-bearing and text-only `:error` results are therefore rejected with
`:incompatible` and `upstream_outcome: :not_submitted`. No status is invented or
silently erased. Hosts restoring JSON must map known role/status and argument
encoding tags to their public constructor atom/tuple forms, as with other
canonical messages.

The independent fixtures and tests verify canonical reload followed by exact
JSON transmission through the public codec and an OTP HTTP host client to a
loopback server. This pure package does not own an HTTP client. No remote
provider or model acceptance is claimed.

## Typed audio and resources

`ContentBlock` supports `:audio`, `:resource` and `:resource_link` as primary
content kinds. Their `data` maps have string keys:

```elixir
%{type: :audio, data: %{"mime_type" => "audio/wav", "data" => "UklGRg=="}}
%{type: :resource, data: %{"uri" => "fixture://document", "mime_type" => "text/plain", "text" => "Fixture"}}
%{type: :resource_link, data: %{"uri" => "fixture://document", "name" => "Fixture"}}
```

Audio requires an audio MIME type and exactly one base64 `data` or absolute
`uri`. Resources require `uri` and `mime_type`; they can carry one inline `text`
or base64 `data` body, or retain only the URI reference. Resource links require
`uri` and nonempty `name`, with optional `mime_type`, `title`, `description` and
nonnegative byte `size`. Unknown data fields, ambiguous bodies, malformed base64,
invalid MIME/URI identity and nonportable values fail validation. Existing
configurable structural limits apply before base64 decoding. No URI is fetched
by this library.

Namespaced block extensions retain portable annotations and provenance, for
example `"mcp::annotations"` and `"host::provenance"`. Ordered `Message.content`
retains mixed text/image/audio/resource/link tool results, their call identity
and result status. `Serialization.to_json/1` preserves that public projection;
`decode_and_validate/3` bounds decoded values before constructor validation.
`ContentBlock.new/2` also recognizes its fixed known string type tags, so media
blocks can be reconstructed from JSON without converting arbitrary strings to
atoms. Message roles and statuses retain the existing atom-based constructor API.

Codec support is explicit:

| Codec | New supported request forms |
| --- | --- |
| OpenAI Chat | User input with inline `audio/wav` or `audio/mpeg`, encoded as `input_audio` WAV/MP3 |
| Google | User inline WAV, MPEG/MP3, AIFF, AAC, OGG or FLAC audio; URI-only resources with HTTP, HTTPS or GS identities, encoded as `inlineData`/`fileData` |
| Anthropic | Tool-result HTTPS PDF resource references and named PDF resource links, encoded as URL document blocks |
| OpenAI Responses | New audio/resource/link forms return incompatibility |

Anthropic tool results accept `:resource` data with exactly `uri` and `mime_type`,
or `:resource_link` data with exactly `uri`, `mime_type` and `name`. The URI must
use HTTPS and the MIME must be exactly `application/pdf`. Both become native
`document` blocks with a `{"type":"url","url":URI}` source; the link's exact
`name` becomes the document's `title`. Canonical JSON persistence retains the
original resource/link kind and data. Encoding preserves block order, tool call
identity and success/error status without fetching or normalizing the URI.

Both block and tool-message extensions must be empty for these PDF forms. Inline
`text`/`data`, optional link `title`/`description`/`size`, other MIME types and URI
schemes remain incompatible. Other codecs and other Anthropic message roles do
not gain these tool-result routes. All codecs continue to reject tool-result
audio. Unsupported forms or media with extensions return `:incompatible` and
`upstream_outcome: :not_submitted` during encoding, including Google tool results
with a native function-response override.
Hosts must only submit successfully encoded requests. The codecs never flatten
media into explanatory text or discard URI/metadata to obtain a supported form.

The selected Anthropic model must support PDF URL documents; successful local
encoding does not prove remote model acceptance. The independently authored
[native fixture provenance](test/fixtures/anthropic/PROVENANCE.md) and
[source notes](SOURCE_NOTES.md) describe the official schema evidence and the
canonical JSON-reload/native-encoding checks, without claiming provider execution.

Google response and stream decoding preserve audio as `:audio` and file parts as
URI-only `:resource`, retaining additional media metadata under
`"google::media_metadata"`. Such metadata is preserved locally; automatic replay
is rejected until an explicit lossless encoding is supported. Other inline MIME
types are rejected instead of being labeled as images. Translation planning
requires explicit `audio`, `resource` and `resource_link` capabilities, independently
of text support. These fixtures establish codec contracts, not live-provider or
model capability support.

## Opaque provider state

Signed Anthropic thinking and Google thought signatures are represented as
opaque `%Backplane.AiProtocol.ProviderState{}` values. The host is responsible
for persisting and restoring them without interpreting the payload.

Replay is origin-bound. Encoding requires matching source protocol and profile,
plus complete matching origin/destination affinity for profile, endpoint, and
model; optional account and workspace values must also match when present.
Google signed parts additionally require account, credential scope, and
credential version bindings. Missing or changed origin metadata is rejected as
incompatible. Google stores the exact signed part and its original position, so
signatures on function calls and other supported parts are never moved into
synthetic thought content.

Unsupported response content, multiple outputs where only one can be preserved,
and other lossy conversions return structured incompatibility errors rather
than being dropped.

## Backplane proxy boundary

Same-protocol gateway traffic continues to use native passthrough. Native
selection is based on the concrete client wire protocol and the selected
provider API's declared `native_protocols`, not its provider name or broad
compatibility family. Native requests, responses, streaming events, and upstream
errors bypass canonical conversion. Model alias mapping is the sole routing
exception: when needed, only the semantic `model` value changes; otherwise the
original request bytes are forwarded.

A cross-protocol gateway route may be enabled only when the package has complete
request, non-streaming response, streaming-event lifecycle, tool, usage, and
error codecs for that directed pair. The current gateway has no complete
cross-protocol HTTP codec pair, so the host rejects mismatches with
`unsupported_protocol_translation` before submission. Adding or consuming the
client codec API does not alter native passthrough, provider presets, route
selection, or host observation behavior.

## Consumption status

The package verifier builds and unpacks a real Hex archive and runs an independent
consumer against that artifact. This portability check does not imply that the
Backplane production runtime dispatches Google traffic through the codec.

## Antigravity native protocol

`Backplane.AiProtocol.Antigravity` provides a pure native protocol facade for
the five evidenced Cloud Code RPCs: `loadCodeAssist`, `onboardUser`,
`fetchAvailableModels`, `generateContent`, and `streamGenerateContent`. It does
not perform HTTP calls, look up OAuth credentials, choose endpoints, enroll
accounts automatically, or translate OpenAI/Anthropic messages.

Hosts call `build_request/3` with a native body plus trusted bindings. Generation
requires `:project`; optional `:model`, `:session_id`, and `:request_id` bindings
must agree with caller fields. The returned descriptor contains no credentials:

```elixir
{:ok, descriptor} =
  Backplane.AiProtocol.Antigravity.build_request(
    :generate_content,
    %{"request" => %{"contents" => contents}},
    project: "configured-project",
    model: "gemini-example"
  )
```

`decode_response/5` and the stream functions preserve native envelopes and
unknown fields. `project/1`, `models/1`, and `onboarding_status/1` expose only
fields actually returned upstream. `Antigravity.Observer` extracts bounded,
sanitized Google-shaped usage facts with source `:google_antigravity`; it never
rewrites bytes forwarded by the host.

`Backplane.AiProtocol.Antigravity.Google` is the explicit, directed compatibility
boundary for Google GenerateContent clients backed by Antigravity. It wraps the
supported Google request fields unchanged inside the native `request`, unwraps
the upstream `response`, and translates SSE incrementally through the bounded
native decoder. It does not accept caller-supplied project or model bindings,
and it also exposes a separate text-only `countTokens` conversion. Count
requests reject tools, system instructions, cached content, media, and function
parts because the upstream operation does not count those fields reliably. An
empty successful response object is normalized to `totalTokens: 0`, matching the
protobuf scalar default omitted by the upstream JSON encoder.

The host owns endpoint selection, OAuth injection, authorization, retries,
polling, persistence, and transport cancellation. In particular, the package
does not contain OAuth client secrets, a fallback project, a Node client
fingerprint, prompt modifications, model-name inference, or a signature cache.

## Source notices

See [`SOURCE_NOTES.md`](SOURCE_NOTES.md) for the pinned extraction candidates
and current non-extraction boundary.
