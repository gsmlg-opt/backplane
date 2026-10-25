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
