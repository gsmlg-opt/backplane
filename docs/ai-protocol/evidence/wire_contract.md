# W1.5 Wire and Transport Contract

## Frozen V1 envelope rules

| Field | Rule |
| --- | --- |
| Protocol | `backplane.ai.v1` |
| Wire version | `{major: 1, minor: 0}` |
| Message type | Hello, welcome, command.response, event, request.finished, error |
| Terminal classification | Only `request.finished` is a business terminal; command responses and errors are control messages |
| Per-request event ordering | Enqueue order; enqueue is not proof of delivery |
| Credit unit | UTF-8 encoded data-envelope bytes |
| Credit model | Per-request; consumed when business data is sent |
| Duplicate requests | Rejected on same connection; no resubmission |
| Seen-ID set | Bounded at 32; connection retires gracefully at capacity |
| No replay on disconnect | Reconnection only establishes a transport for future requests |

## Control and terminal ordering

When business data is pending and a terminal arrives, the terminal is queued after all pending
business data for that request. It is never reordered before buffered content. A bounded
connection closes only after all queued terminals for accepted requests have been delivered,
subject to the connection outbound-buffer limit. If the buffer cannot retain the terminal, the
terminal still carries `output_completeness: :incomplete` and no content is silently skipped.

Command responses (`command.response`) are control messages and are never mixed into the
per-request event stream. A cancel acknowledgment is a local acceptance fact, not proof of
upstream spend; upstream certainty is carried only on the `request.finished` envelope.

## Backpressure rules

- Data events require sufficient per-request credit; otherwise the event is rejected with a
  structured `insufficient_credit` error rather than buffered past the credit cap.
- Individual data events that exceed the negotiated `data_event_bytes` limit fail explicitly.
- Control traffic uses a separate reserve and is not starved by data-credit exhaustion.
- Credit is replenished only when business data is consumed or a controlled buffer is released.

## Initial limit targets

The limits below are test targets inherited from design section 9.3 and are encoded in
`Backplane.AiProtocol.Wire`. They are not measured capacity claims.

| Limit | Value |
| --- | --- |
| Inbound request JSON | 8 MiB |
| Individual data event | 64 KiB |
| Initial per-request credit | 256 KiB |
| Pending per-request outbound buffer | 512 KiB |
| Pending connection outbound buffer | 8 MiB |
| Concurrent requests per connection | 8 |
| Control reserve | 64 KiB |

## Unresolved for W1.6

1. WebSocket backend selection (raw WebSocket vs HTTP adapter) remains open.
2. Exact JSON field casing and envelope key ordering require fixture confirmation.
3. Catalog query pagination limits need a concrete default before W3.
