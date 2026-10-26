# Source notes

This package is being prepared from the pinned inventory in
`docs/ai-protocol/evidence/source_inventory.md` at the Backplane, Sigma, and Synapsis commits
recorded there. No Sigma or Synapsis implementation code has been copied yet.

## Disposition

Sigma `sigma_ai` is the initial extraction source for neutral request, event, message, usage,
error, and SSE primitives. Synapsis provider codecs are compatibility evidence and may inform
translation in later work packages.

The package must not absorb Backplane credential storage, production routing, native Codex
transport, or host-owned persistence. Sigma agent loops, Synapsis agent topology, tools,
approvals, daemon/background work, persistence, PubSub, and credential/config ownership remain
host-owned.

## Antigravity native evidence

The Antigravity native facade is based on behavioral evidence from the
MIT-licensed `antigravity-claude-proxy` repository at commit
`daa39d6c6239ac078a4e69de85094dde35558ef6`. The relevant source files are
`src/cloudcode/model-api.js`, `src/account-manager/onboarding.js`,
`src/cloudcode/request-builder.js`, `src/cloudcode/message-handler.js`, and
`src/cloudcode/streaming-handler.js`.

Only the five evidenced Cloud Code RPC shapes are represented. The package does
not copy OAuth client credentials, fallback project IDs, endpoint failover,
machine-derived user agents, Node client fingerprints, prompt injection or
scrubbing, signature caches, model curation, account pooling, or retry policy.
The fixture under `test/fixtures/antigravity` is handcrafted from those source
shapes and is explicitly not a captured upstream response.

## Anthropic PDF tool-result evidence

The PDF URL document mapping and the fixture under `test/fixtures/anthropic`
were independently authored on 2026-10-25 from the official Anthropic Messages
documentation and SDK schema:

- https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls
- https://platform.claude.com/docs/en/build-with-claude/pdf-support
- https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/tool_result_block_param.py
- https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/document_block_param.py
- https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/url_pdf_source_param.py

The native `tool_result.content` schema admits document blocks, while the URL
PDF source supplies PDF semantics and `tool_result.is_error` preserves result
status. A canonical PDF resource link's exact `name` maps to the native document
`title`. Only the exact HTTPS PDF reference forms documented in `README.md` are
supported; this evidence does not establish tool audio or arbitrary resource
support.

The fixture is hand-authored schema evidence, not captured codec output, an SDK
execution, or a provider/model response. The tested round trip is canonical
message JSON serialization and reload followed by native request encoding;
there is no provider request-decoding API or remote model-capability assertion.

## OpenAI Responses image tool-result evidence

The Responses image mapping and fixtures under `test/fixtures/openai_responses`
were independently authored on 2026-10-26 from these official sources:

- https://developers.openai.com/api/reference/resources/responses/methods/create
- https://developers.openai.com/api/docs/guides/function-calling
- https://developers.openai.com/api/docs/guides/images-vision

The rendered create reference defines both `FunctionCallOutput.output` and
`CustomToolCallOutput.output` as strings or arrays admitting native input
text/image/file content. `ResponseInputImageContent` / `ResponseInputImage`
defines `image_url` and the `auto`, `low`, `high`, `original` detail values.
The function-calling guide confirms image arrays in function output; the image
guide defines the default `auto` and model-dependent detail restrictions. The
complete rendered reference was used because the documentation MCP Markdown
result exposes only a schema stub.

The public subset is restricted to inline base64/data-URI image tool results,
with exact order, call identity and detail retention. Canonical success/nil
status encodes an ordinary completed output; semantic error status is rejected
because neither output kind provides an equivalent `is_error` marker. Native
function lifecycle status is not an error substitute.

Fixtures are schema-based examples, not captured codec output, SDK executions
or real provider responses. Tests compare the codec to independently authored
native JSON, preserve canonical messages across JSON reload, and capture the
actual JSON sent by OTP's HTTP host client to a task-owned loopback listener.
The protocol package remains transport-free. This establishes local functional
encoding and legacy-codec compatibility, without provider/model acceptance.
