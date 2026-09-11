# Backplane.AiProtocol

`backplane_ai_protocol` is a standalone production package for provider-neutral AI protocol
contracts and bounded native protocol observation.

It contains canonical contracts, validation/serialization boundaries, pure translation and wire
preflight, SSE framing, and an OpenAI Responses observer. It intentionally contains no provider
transport, credential handling, database, Phoenix, Backplane host process, or network startup.

## Source notices

See [`SOURCE_NOTES.md`](SOURCE_NOTES.md) for the pinned extraction candidates and current non-extraction boundary.
