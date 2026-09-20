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
Missing or changed origin metadata is rejected as incompatible. Google content
that carries a thought signature without `thought: true` is also rejected
because the package cannot preserve it faithfully.

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

Synapsis currently consumes this application from a local sibling checkout path.
The package is published independently, but this integration does not imply a
standalone-package or independent-CI portability guarantee.

## Source notices

See [`SOURCE_NOTES.md`](SOURCE_NOTES.md) for the pinned extraction candidates
and current non-extraction boundary.
