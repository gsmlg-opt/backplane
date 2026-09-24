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

`Backplane.AiProtocol.Codec` is a pure facade with three supported selectors:

- `:anthropic` for Anthropic Messages
- `:openai` for OpenAI Chat Completions and compatible APIs
- `:google` for Google Gemini GenerateContent

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

The OpenAI Responses observer remains an observation helper for Backplane's
native proxy path. It is not an OpenAI Responses client codec, and `:responses`
is not a supported `Codec` selector.

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
