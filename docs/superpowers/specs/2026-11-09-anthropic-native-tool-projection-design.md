# Anthropic native tool projection (#160)

## Scope and rationale

Codex profiles contain freeform calls and canonical namespace separators that
Anthropic Messages cannot represent directly. Implement an explicit reversible
projection inside AI Protocol, without changing Runtime ownership or introducing
provider transport, model calls, global registries or private consumer mappings.

Keep default codecs strict. Add `Codec.Anthropic.prepare_request/2`, returning
`{:ok, %{body: wire_body, codec_options: decoding_options}}`. The host retains the
returned options for non-streaming and streaming response decoding. The existing
encode_request return shape and ordinary JSON function stream events stay intact.
A direct automatic projection would lose its reverse table at the HTTP boundary;
a stateless escaping scheme cannot fit every 256-byte name into 64 characters.
An explicit request context avoids both problems.

## Mapping and replay

Build an immutable mapping from the request's definitions and historical calls.
Preserve already legal names and map other names to a deterministic bounded hash
alias. Collision-check the entire table, including collisions with legal names.
Reject tool-kind conflicts, malformed contexts and unknown projected identities.
Historical calls contribute their canonical identity and argument kind even when
the current tool catalog no longer includes their definition. Forced tool-choice
names use the same mapping; unknown names fail before submission.

Custom tools become JSON functions accepting exactly one required string field,
`input`, with no additional properties. Reverse decoding restores `{:custom,text}`
without trimming or line-ending normalization. Replay uses the same wrapper and
preserves call IDs and tool-result IDs/status. Functions keep ordinary object input.

Preserve original descriptions as a prefix and append documented metadata JSON
containing canonical identity, kind, custom format and extensions. Consumers map
Codex output_schema to `extensions["codex::output_schema"]`. These schemas and
custom grammar remain advisory description metadata; Anthropic does not enforce
them. Unsupported native provider state and other media restrictions stay strict.

## Streaming and verification

Canonical names appear on start/delta/done events. Buffer custom input_json_delta
bytes until the complete wrapper is available. Never expose partial JSON wrapping
as raw freeform input. Completed custom calls carry a canonical ContentBlock;
ordinary function completion content remains its existing input map. Validate
malformed, truncated and unknown streams explicitly.

Regression coverage must exercise Unicode, LF/CRLF and edge whitespace, history
replay, forced choice, tool-name order independence, alias collisions, kind
conflicts, malformed wrappers/context and every byte boundary of SSE input.
Verify a real exported Codex profile in addition to pure protocol tests. Run
strict compile, formatting, Credo, Dialyzer and the protocol suites, then verify
GitHub CI on the pushed main commit. Next patch target is 1.10.62. Existing
LLama sandbox and Admin frozen asset lockfile failures remain outside this scope.
