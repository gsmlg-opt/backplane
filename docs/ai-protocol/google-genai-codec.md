# Google GenerateContent codec

## Scope

`Backplane.AiProtocol.Codec.Google` is a pure codec for the canonical subset of
Google GenerateContent. It owns request body construction, response decoding,
bounded SSE framing, canonical tool values, opaque signed-part replay, usage
snapshots, and protocol lifecycle facts.

It does not own HTTP routing, URL construction, authentication, retries,
cancellation, persistence, agent tool execution, or provider selection. At this
revision there is no production Backplane runtime branch that dispatches through
this codec. Native Google proxy support and SDK-to-Backplane integration remain
separate integration work. Native same-protocol passthrough is unaffected by the
canonical subset restrictions described here.

## Request APIs

The explicit API is:

```elixir
Codec.encode_rest_request(:google, request, opts)
```

It returns:

```elixir
{:ok,
 %{
   target: %{operation: :generate_content, model: model, stream: boolean},
   body: google_generate_content_body
 }}
```

`target` is transport metadata. The REST body never contains `model`,
`operation`, or `stream`. The historical `Codec.encode_request(:google, ...)`
selector remains supported as a compatibility wrapper and returns the previous
internal envelope with string keys `model` and `stream` merged into the body.

## Canonical Configuration

Canonical settings map explicitly to these Google `generationConfig` fields:

| Canonical settings field | Google field |
| --- | --- |
| `temperature` | `temperature` |
| `top_p` | `topP` |
| `top_k` | `topK` |
| `max_output_tokens` | `maxOutputTokens` |
| `stop_sequences` | `stopSequences` |
| `presence_penalty` | `presencePenalty` |
| `frequency_penalty` | `frequencyPenalty` |
| `seed` | `seed` |

Canonical output constraints map explicitly:

| Canonical output field | Google field |
| --- | --- |
| `candidate_count` | `candidateCount` |
| `response_mime_type` | `responseMimeType` |
| `response_schema` | `responseSchema` |
| `response_json_schema` | `responseJsonSchema` |
| `response_modalities` | `responseModalities` |

Unknown fields return an `:incompatible` error with a field path and reason.
Canonical decoding supports one candidate only. When specified,
`candidate_count` must be `1` and `response_modalities` must be `["TEXT"]`.
Thinking budget and thinking level are intentionally not mapped. These limits do
not apply to native passthrough.

## Tools And Signed Parts

Tool call order, canonical ID, native ID, name, and structured arguments are
preserved. A tool result uses its canonical `tool_call_id` to recover the exact
call and emits the original native ID only when Google supplied one. Generated
canonical IDs remain internal correlation values and are never inserted into an
exact signed Google part. Structured Google results are supplied through the tool
message extension:

```elixir
%{
  role: :tool,
  tool_call_id: call.id,
  status: :success,
  content: [%{type: :text, text: "structured result"}],
  extensions: %{"google::function_response" => structured_map}
}
```

The text content remains a portable fallback for consumers that do not use the
Google extension. Consecutive Google function results are emitted as ordered
parts in one user content, so repeated function names remain associated by ID.

`thoughtSignature` is opaque part state. Decoding retains the complete original
part and its candidate/part position in `ProviderState.payload`; encoding only
reattaches that exact part immediately after its canonical content block. The
codec does not move a signature, create synthetic thought text, infer a missing
signature, or silently discard it.

Legacy Google signature payloads containing only `thinking` and `signature` are
not replayable because they cannot prove the original part or position. The
compatibility request envelope remains supported, but such unbound opaque state
is deterministically rejected.

Signed replay requires matching protocol, profile, endpoint, account, model,
credential scope, and credential version. Scope and version are public binding
labels, not credential identifiers or secrets. Missing bindings and cross-origin
replay return an affinity diagnostic before a request body is produced.

## Streaming Lifecycle

Google `finishReason` marks content as finished but does not emit the canonical
terminal event. Later usage-only frames remain valid, and repeated identical
usage snapshots emit once. `stream_finish(..., :eof)` records transport EOF and
emits the terminal event only after a known finish reason. State therefore keeps
content-finished, protocol-complete, and transport-EOF facts separately.

Per-candidate part positions advance across SSE frames, so signed calls delivered
in separate fragments retain distinct replay positions when reconstructed into a
single assistant turn.

An unknown future `finishReason` is retained as an incompatibility and is never
promoted to success. `[DONE]` is accepted as a framing marker for compatibility,
but it cannot create a successful terminal without a known Google finish reason.

## Evidence And Integration Boundary

The checked-in GenerateContent fixture was captured from the outbound
`RequestInit.body` produced by the pinned official TypeScript package
`@google/genai` 2.24.0. Fetch was intercepted in memory, so no Google service was
called and no credential was sent. The capture independently checks the wire
body for same-name signed calls, native IDs, structured results, and generation
config; it does not prove a live Google request or SDK-to-Backplane route.

`scripts/verify_ai_protocol_package.sh` builds one real Hex archive, extracts
`contents.tar.gz` from that exact archive, verifies the archive hash is unchanged,
compiles an independent consumer against the extracted artifact, runs a signed
tool-call to structured-result to continuation loop, and rejects Ecto, Postgrex,
Phoenix, or Backplane host dependencies in the consumer tree.
