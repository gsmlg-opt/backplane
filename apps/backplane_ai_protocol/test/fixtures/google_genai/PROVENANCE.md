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
