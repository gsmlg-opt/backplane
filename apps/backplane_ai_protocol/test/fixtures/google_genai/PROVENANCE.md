# Google GenAI fixture provenance

`generate_content_tool_continuation.json` is the request body captured on
2026-09-23 from pinned official TypeScript SDK `@google/genai` 2.24.0 under
`integrations/google-genai/node_modules/@google/genai`.

The capture replaced `globalThis.fetch` in memory, invoked
`GoogleGenAI.models.generateContent`, parsed `RequestInit.body`, and removed
transport headers and the API key. The source invocation used model
`gemini-2.5-flash`, two same-name signed function calls with native IDs, two
structured function responses, and generation config for temperature, maximum
output tokens, and text modality. The fixture was not produced by the Elixir
codec under test.

## Inline user PDFs

`inline_pdf_user.json` was independently authored on 2026-10-27 from Google
GenerateContent REST schemas, separately from the older SDK tool fixture:

- https://ai.google.dev/gemini-api/docs/document-processing
- https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta
  — retrieved version `v1beta`, revision `20261026`, SHA-256
  `c85efb5279458100eb8eb1f323db17f7b155dfd3ac1dc219bbf5a510f9222735`.

The refreshed discovery schema defines ordered `Content.parts`, `Part.inlineData`
and `Blob` fields `mimeType` and base64-encoded `data`. The expected native body
was authored directly from those schemas without invoking the Elixir encoder.
It omits transport model/operation/stream fields and optional native metadata.

The two local PDF documents, their authorship and SHA-256 values are documented
in [Anthropic fixture provenance](../anthropic/PROVENANCE.md#inline-user-pdfs).
Both native fixtures use exactly the same two documents and prompt order.

Local ExUnit checks compare the complete REST body and historical compatibility
envelope, decode each PDF to its original bytes, and submit actual public REST
codec JSON through OTP `:httpc` to loopback
`/v1beta/models/fixture-model:generateContent`. This fixture is schema-authored,
not captured SDK output or an authenticated Gemini response. It proves local
persistence, wire encoding and host HTTP composition; it does not establish
model capability, provider body/page/context limits or document analysis.
