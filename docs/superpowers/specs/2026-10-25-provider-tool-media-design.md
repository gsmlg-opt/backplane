# Provider tool-result media: native PDF references

Status: proposed for issue #108; implementation awaits approval.

## Problem and acceptance boundary

The canonical AI Protocol contract already retains ordered `audio`, `resource`,
and `resource_link` content, including namespaced metadata and JSON reload. The
current codecs reject these kinds in tool-result messages. Add a useful native
representation where the provider can preserve the complete requested form.

This proposal supports Anthropic PDF URL resources and named PDF URL links in
tool results. Audio and other unrepresentable combinations remain explicit
`incompatible` errors with `upstream_outcome: :not_submitted`. Canonical content
is never moved into user history, flattened into text, fetched by Backplane, or
rewritten to another canonical kind.

Local codec fixtures establish the emitted request contract. They do not prove
that a real provider or selected model accepts a request, nor complete Synapsis's
separate package-upgrade, durable-reload, and model-readiness acceptance.

## Provider evidence and alternatives

Official sources checked on 2026-10-25:

| Protocol | Native tool-result capability | Consequence |
| --- | --- | --- |
| OpenAI Chat | Tool content is text | Keep typed media incompatible. |
| OpenAI Responses | Function output can contain `input_text`, `input_image`, and `input_file`; no audio member | File inputs lack an explicit MIME field and a native effect-error flag. Do not assume arbitrary resources can be encoded losslessly. |
| Gemini | Gemini 3 multimodal function responses support selected images and PDF/plain-text documents in nested `inlineData` | Outer `Part.fileData` does not establish URI support in nested function responses. No tool-role audio route was established. |
| Anthropic | `tool_result.content` supports native image and document blocks; `is_error` carries result status | URL-PDF documents preserve an exact reference and PDF semantics within the existing tool-result envelope. |

References:

- https://developers.openai.com/api/docs/guides/function-calling
- https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_function_call_output_item_param.py
- https://github.com/openai/openai-python/blob/main/src/openai/types/chat/chat_completion_tool_message_param.py
- https://ai.google.dev/gemini-api/docs/generate-content/function-calling.md
- https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls
- https://platform.claude.com/docs/en/build-with-claude/pdf-support

Two viable delivery choices are:

1. **Recommended: ship the bounded Anthropic PDF-reference subset.** This adds
   native resource/link consumption without inventing provider fields. Its
   restrictions are explicit, and unsupported audio remains blocked.
2. **Defer #108 until a broader native route is available.** This avoids a partial
   capability release, but leaves currently representable PDF references blocked.

Expanding all four codecs is not part of the first option: it requires independent
proof for each MIME, source representation, metadata field, status, and model
restriction. Serializing media as ordinary tool-output text does not satisfy the
requested contract.

## Exact supported forms

Only Anthropic tool-result messages gain the following new routes. Their canonical
tool-message extensions and media-block extensions must both be empty.

| Canonical block | Exact data keys | Native content block |
| --- | --- | --- |
| `:resource` | `uri`, `mime_type`; MIME exactly `application/pdf`; an absolute HTTPS URI | `{"type":"document","source":{"type":"url","url":URI}}` |
| `:resource_link` | `uri`, `mime_type`, `name`; same PDF/HTTPS restrictions | The same document source, with `title` equal to the exact canonical `name` |

The PDF URL source itself supplies the native PDF semantics. The original URI is
copied without normalization or retrieval. Canonical persistence retains the
original resource/link kind and data; encoding a provider document does not mutate
that object. `resource_link.name` is the document's display title in this declared
mapping; there is no implicit default or truncation.

Reject additional inline `text`/`data`, optional link `title`/`description`/`size`,
namespaced extensions, other MIME types, unsupported URI schemes, and unsupported
message roles before submission. Even redundant extra metadata is rejected rather
than silently discarded. Existing validation continues to reject malformed data.

Existing text/image encoding and existing user-role audio/resource support retain
their current behavior. No audio block is admitted in a tool role by this change.
Support is documented for Anthropic models that accept PDF URL documents; local
encoding does not add a remote capability probe or infer model acceptance from an
arbitrary model name.

## Implementation and data flow

Keep canonical validation, Serialization, and Message ownership unchanged. Add a
role-aware internal media encoding path so preflight and Anthropic tool-result
encoding apply the same exact-form checks. Other protocols retain their current
explicit incompatibilities.

Anthropic's existing `tool_result` envelope retains `tool_use_id`, `is_error`, and
the original block order. Only the two new media forms are mapped to native
document blocks. A tool message containing new media and unrepresentable
message-level metadata fails preflight; it does not lose that metadata.

Expected source scope:

- `apps/backplane_ai_protocol/lib/backplane/ai_protocol/media.ex`
- `apps/backplane_ai_protocol/lib/backplane/ai_protocol/codec/anthropic.ex`
- `apps/backplane_ai_protocol/test/backplane/media_content_test.exs`
- An independently documented native Anthropic request fixture under this app's
  existing test-fixture convention, with source URL and capture date.
- `apps/backplane_ai_protocol/README.md` and `SOURCE_NOTES.md`.

No runtime dependency, lockfile, public transport, provider-selection policy,
database schema, or consumer-repository change is planned.

## Verification and publication

Start with failing functional tests for both exact forms and both success/error
tool statuses. Serialize and reload canonical messages before encoding. Assert
exact URI, MIME semantics, link name/title, tool call ID, status, and mixed
text/image/document ordering. Check that the canonical objects remain unchanged.

Cover every rejected field and source combination above, message/block metadata,
all other codecs, unsupported roles, malformed inputs, and existing text/image
fixtures. Round-trip here means canonical JSON reload followed by native request
encoding; no provider request-decoding API is invented.

Run the owning AI Protocol suite and required compile/format/static/workflow
checks. After official publication, use a fresh Hex-only consumer to repeat the
contract and JSON-reload checks. A task-local loopback HTTP fixture can capture
the exact serialized request from `Codec.encode_rest_request/3`; it must not add
an HTTP dependency to this pure codec package or contact a real provider. This
proves local wire delivery only.

The release remains 1.10.38, with #106's native-image regression qualification and
#107's explicit-empty stopped presentation. Require green CI at the final exact
source SHA, canonical publication, and independent package/artifact verification.
Report the resource/link subset and the unsupported audio boundary explicitly in
the issue response; do not claim general media or live model-consumption support.
