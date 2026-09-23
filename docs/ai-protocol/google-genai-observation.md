# Google GenerateContent observation

## Status

On 2026-09-23 the user explicitly reopened W3-observer for coordinator repair.
The prior Sol repair counter remains exhausted at `2/2`; it was not reset.
The coordinator fixed JSON-body cancellation/transport-failure precedence in
`UsageAccumulator.snapshot/3`, including countTokens. Completed JSON bytes no
longer imply request success after cancellation or transport failure. Normal EOF
is recorded explicitly. Parsed usage is retained as evidence but not marked complete
on failed transport. Repeated final snapshots retain the first terminal decision.

Focused validation: 13 pure observer tests and 9 Google integration tests passed,
including four new JSON cancellation/error cases. Broader validation is recorded
in `google-genai-repair-handoff.md`. This does not establish native forwarding.

Historical blocker: a complete JSON body followed by `snapshot(pid, 200, :cancelled)`
previously returned `protocol_terminal: :completed`, `partial: false`, and
`transport_terminal: nil`. The prior 13 observer / 32 integration-regression /
110 protocol tests did not cover that case.

`Backplane.AiProtocol.GoogleGenerateContentObserver` is a pure, bounded observer for native Google GenerateContent response bytes. It extracts operational facts without rewriting, validating, or buffering the response for forwarding.

## Integration boundary

The observer supports JSON response bodies and Google GenerateContent SSE events. `Backplane.LLM.UsageAccumulator` exposes these modes:

- `:google_generate_content` for SSE
- `:google_generate_content_body` for a GenerateContent JSON body
- `:google_count_tokens_body` for a countTokens JSON body

`Backplane.LLM.AccessEvent` selects these modes when `api_surface` is `google_generate_content`; `count_tokens` selects the countTokens body mode. The future native router is expected to use operation names `generate`, `stream_generate`, and `count_tokens`.

This integration does **not** add a Google route, listener dispatch, provider transport, or native forwarding path. Those remain W2 work. These tests therefore establish observer and access-event selection behavior only, not end-to-end Google provider support.

## Usage projection

GenerateContent usage snapshots replace earlier snapshots. Counters are never added across events, so repeated snapshots are idempotent.

| Backplane field | Google field | Meaning |
| --- | --- | --- |
| `input_tokens` | `promptTokenCount` | Prompt total, including any cached-content subset |
| `output_tokens` | `candidatesTokenCount` | Generated candidate tokens, excluding thought tokens |
| `cached_tokens` | `cachedContentTokenCount` | Cached subset of the prompt total |
| `reasoning_tokens` | `thoughtsTokenCount` | Generated thought tokens |
| metadata `native_total` | `totalTokenCount` | Google's total, retained unchanged |

Missing counters remain `nil`; the observer does not fabricate zero. Sanitized native usage metadata retains only known non-negative counters and modality/token-count pairs. It drops arbitrary strings and unknown fields.

For countTokens, `totalTokens` is stored only under `metadata.operation` with operation name `count_tokens`. It never populates generation input, output, reasoning, cached, or native-total billing counters.

## Lifecycle

Candidate `finishReason`, content completion, protocol terminal state, and transport termination are separate facts.

- A finish reason marks candidate content finished but does not stop SSE observation. Later usage events are still consumed.
- Streaming success requires transport EOF and verified `STOP` finishes for all observed candidates.
- EOF without a verified finish is incomplete.
- Unknown finish reasons are retained verbatim and never imply success.
- Known partial or safety finish reasons are incomplete/partial, not successful completion.
- For both SSE and JSON-body observation, transport failure and cancellation remain partial even when a candidate previously reported `STOP`. Cancellation is recorded separately from transport failure.
- Google-native errors retain only bounded code/status fields. Safety blocking retains the bounded native block reason, not messages or response bodies.
- Multiple candidates retain aggregate native usage and per-index finish reasons, while marking the observation ambiguous/incomplete.

## Bounds and isolation

The observer defaults to an 8 MiB total-byte limit, 1 MiB SSE frame limit, 2 MiB pending SSE buffer limit, 10,000 parsed events, 250 ms cumulative parse-time budget, 64 candidates, 32 modality rows per usage detail field, and 32 diagnostics. Transport chunks are processed in bounded slices.

The parse-time budget uses monotonic elapsed time around each bounded JSON document parse and semantic extraction. Enforcement is cooperative at document boundaries: a single parse cannot be preempted, but its frame/body size is independently bounded. Once cumulative time exceeds the budget, semantic parsing stops and the observation is incomplete; native response handling is unaffected.

`UsageAccumulator` adds its existing one-MiB chunk limit, bounded owner queue, eight-MiB JSON-body accumulation limit, and snapshot timeout. Overflow, malformed input, parser exceptions, queue saturation, and snapshot timeout produce incomplete or unavailable observation facts. They do not raise into response forwarding.

## Timing

The existing accumulator records:

- `ttft_ms`: time from accumulator creation to the first observed response chunk, which is first-byte timing, not guaranteed first-content timing
- `metadata.timing.first_content_ms`: time from accumulator creation until candidate content is first detected; `nil` when no content is observed
- `stream_duration_ms`: time from the first observed chunk to the last observed chunk
- `stream_chunks`: number of chunks accepted by the accumulator owner

First-content timing is measured in the accumulator owner when the pure observer reports `content_seen`; it is not inferred from finish or usage. Completion timing remains the surrounding access event's request/upstream duration; protocol terminal facts describe semantics, not a new clock measurement.

## Sensitive data

Observation does not retain response text, arbitrary error messages/details, complete native bodies, API keys, or opaque thought signatures. Provider request IDs and bounded protocol enum/status values are retained for correlation. Native bytes remain the responsibility of the forwarding path and are not reconstructed from observer facts.
