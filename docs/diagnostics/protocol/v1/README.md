# Diagnostics protocol v1

The application sends `diagnostics.v1` to its Host Agent. The Host sends `host_diagnostics.v1` to Backplane through `diagnostics_sync` on its authenticated Channel. A Host probes `diagnostics_capabilities` before uploading. Capability replies return the protocol name and the maximum batch/item counts and bytes. Legacy Memory and trace protocols retain their own request and acknowledgement formats.

## Event identity and encoding

[event.schema.json](event.schema.json) defines the envelope. String bounds are measured in UTF-8 bytes and strings cannot contain U+0000. Dates must be real timestamps with an offset. Unknown fields and arbitrary atom keys are rejected on the wire. The app SDK allowlists fields and redacts evidence before sealing. JSON objects contain unique member names. Repeated keys make the canonical representation ambiguous and are invalid.

Canonicalization v1 recursively orders object keys by raw UTF-8 byte order and preserves array order. Encode strings as JSON UTF-8 with required JSON escapes. Do not normalize Unicode or add whitespace or a final newline. Encode integers in base 10 and restrict them to ±9,007,199,254,740,991. Fractional measurements are decimal strings. The depth limit is 12 edges below the root and the event byte limit is 65,536. Compute SHA-256 over the canonical bytes and transmit 64 lowercase hexadecimal characters.

The worked fixture has [input JSON](event.json), [canonical bytes](event.canonical.json), and the [expected digest](event.sha256). Source identity is `(source_id, event_id)` and a sequence is allocated within `(source_id, producer_epoch)`. A resend keeps all original identifiers and bytes. Business IDs, trace links and local or central receive timestamps have separate semantics. Omit missing optional evidence or use the corresponding documented quality field.

Both hops retain deduplication records after body expiry. They retain `(source_id, event_id, digest, disposition)` and a unique key for `(source_id, producer_epoch, source_sequence)`. A new epoch permits restarting the sequence. The Host compares the ingress digest before applying a new policy to new records. It independently freezes a forward representation and its digest before acknowledging local storage. Central verifies the forward digest and can store a more restrictive view. Receiving metadata never changes either hop's digest.

## Batch and acknowledgement

The batch object has `protocol`, `batch_id`, and `events`. Each entry has `event` and `digest`. Use at most 100 entries and 524,288 bytes including the encoded batch fields. A sender uses one source per batch or otherwise ensures every `event_id` is unique in a batch. Hosts respect lower negotiated limits and may split a retry. Receivers verify source authorization from the authenticated transport and process valid entries independently of their invalid neighbors.

The response object has `batch_id`, `level`, and `receipts`. The level is `local_durable` after the Host spool commit or `remote_durable` after Backplane commits the event and outbox. Each receipt uses `event_id`, `digest`, `status` and optional `reason` and `retry_after_ms`. When a malformed entry cannot carry a valid identity or digest, its rejection can use `null` for the invalid field. Such a receipt cannot acknowledge a sender record.

| Status | Sender disposition |
| --- | --- |
| `stored`, `duplicate` | Release the exact item after a unique receipt matches the batch, level, ID and digest. |
| `retryable_rejection` | Retain the original and retry after backoff or the bounded delay hint. |
| `permanent_rejection` | Apply bounded dead-letter handling with the reason, including `invalid_event`, `digest_mismatch` or `epoch_sealed`. |
| `identity_conflict` | Quarantine the item. The reason distinguishes `identity_conflict` and `source_sequence_conflict`. |
| `unsupported_schema` | Retain the item and pause that version until capability or configuration changes. |

Review all receipt entries before updating any pending item. A missing ID, mismatched digest, unknown status or contradictory/duplicate receipt is unknown for that item. Unknown IDs do not acknowledge any sender item. The other unique matching successes can still acknowledge their items. For invalid batches use `invalid_batch`, `batch_too_large`, or `unsupported_schema`. An unauthorized batch receives no durable acknowledgement. The sender pauses until authorization is restored.

Epoch closure is a separate controlled operation after the producer has stopped using the epoch, the retry window and gaps have been settled, and pending work has finished. Previously stored receipt keys continue to return their recorded disposition. An unrecognized entry in a sealed epoch is rejected with `epoch_sealed`. Historical import uses its own operation and never silently creates a new live occurrence.
