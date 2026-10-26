# Anthropic PDF tool-result fixture provenance

`pdf_tool_result.json` was independently authored on 2026-10-25 from the official
Anthropic Messages schema and examples:

- https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls
- https://platform.claude.com/docs/en/build-with-claude/pdf-support
- https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/tool_result_block_param.py
- https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/document_block_param.py
- https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/url_pdf_source_param.py

The fixture describes a native `tool_result` containing two URL PDF documents.
The second document's display `title` represents the canonical PDF resource link's
exact `name`. URL PDF sources supply the PDF semantics without a separate MIME
field. Neither reference is fetched by the codec.

This is a hand-authored schema fixture, not output captured from the Elixir codec,
an SDK execution, or an actual provider/model request. It establishes local wire
shape only. Canonical JSON reload tests separately retain the original resource
and resource-link kinds and complete data.

## Inline user PDFs

`inline_pdf_user.json` was independently authored on 2026-10-27 from the native
Messages shape and official Python SDK schema snapshots retrieved that day:

- https://platform.claude.com/docs/en/build-with-claude/pdf-support
- https://raw.githubusercontent.com/anthropics/anthropic-sdk-python/main/src/anthropic/types/base64_pdf_source_param.py
  — SHA-256 `1b1e9cd7bc15d81abb4b954b63d875193b8cae7e3216f84e6d9932e6b284cff5`
- https://raw.githubusercontent.com/anthropics/anthropic-sdk-python/main/src/anthropic/types/document_block_param.py
  — SHA-256 `4932c772bb9e39ecccb18cac5ed4cc988c3ddb17e91efb7c3a002d3dccf3b809`

The refreshed schema requires `document.source.type = base64`, exact
`media_type = application/pdf` and base64 `data`. Optional native document fields
are deliberately absent. The complete expected request was authored directly
from that schema, without invoking or projecting output from the Elixir encoder.

The bytes in `../pdf/first.pdf` and `../pdf/second.pdf` are locally authored,
finite one-page PDF 1.4 documents using Helvetica, explicit object offsets, an
xref table and a trailer. Their text is respectively “First local PDF fixture”
and “Second distinct PDF fixture”. They contain no acquired/private documents.
SHA-256: first `a4444bdd20213c66360032bd09779299e76da4af538df1eef2802eb1982d18ae`;
second `89dbeb581f2b5087186e0d7628d34a744c4493a77ca7873f2e16e87b82ebcfd3`.
Their base64 values were inserted directly into independently authored native
fixture maps. Canonical-only `file:` identities never appear in these native maps.

Local ExUnit checks compare the complete native map, decode both PDFs to their
original bytes, and submit actual public codec JSON through OTP `:httpc` to a
loopback `/v1/messages` fixture. This proves local construction, persistence,
encoding and host transport composition. It is not SDK execution or acceptance
by an authenticated Anthropic model; model support and current provider limits
remain host-owned.
