# Backplane.AiProtocol

`backplane_ai_protocol` is a standalone production package for provider-neutral AI protocol
contracts and bounded native protocol observation.

It contains canonical contracts, validation/serialization boundaries, pure translation and wire
preflight, SSE framing, and an OpenAI Responses observer. It intentionally contains no provider
transport, credential handling, database, Phoenix, Backplane host process, or network startup.

## Backplane proxy boundary

Same-protocol traffic uses native passthrough. Cross-protocol traffic uses
backplane_ai_protocol translation. Logging and usage collection are isolated observations.

Native selection is based on the concrete client wire protocol and the selected provider API's
declared `native_protocols`, not its provider name or broad compatibility family. Native requests,
responses, streaming events, and upstream errors bypass canonical conversion. Model alias mapping
is the sole routing exception: when needed, only the semantic `model` value changes; otherwise the
original request bytes are forwarded.

A cross-protocol route may be enabled only when the package has complete request, non-streaming
response, streaming-event lifecycle, tool, usage, and error codecs for that directed pair. The
current package provides compatibility preflight but no complete cross-protocol HTTP codec pair,
so the host rejects mismatches with `unsupported_protocol_translation` before submission.

## Source notices

See [`SOURCE_NOTES.md`](SOURCE_NOTES.md) for the pinned extraction candidates and current non-extraction boundary.
