# Response fixture provenance

Verified on 2026-09-23 during coordinator takeover:

- REST reference: https://ai.google.dev/api/generate-content
- Retrieved HTML SHA-256: `734a0c675abfb76ce7b88d662b6843af45e7460b2a9df06065ee474888de8044`
- `generate-content-schema.txt` is a verbatim text extraction of the official
  GenerateContentResponse and UsageMetadata JSON representations, not executable JSON.
- Official Python SDK tag `v2.25.0` resolved through the GitHub tree API to
  `2faba3c07bcabaa662d8bc4804d2f3f1994648d9`.
  `google/genai/tests/models/test_generate_content.py` was retrieved from that tag;
  its response tests assert candidates, usageMetadata, and streaming finish fields.

`generate-content-response.json` remains manually authored synthetic data with
local text, model version, and response ID. It is not an official response capture.
The harness responses are also synthetic. The official schema corroborates their
field structure; it does not prove real-provider behavior.

All three pinned SDK recording-server tests now pass and export actual sanitized
request records under `../requests/*.captured.json`. Earlier handoff evidence
reported only failed TypeScript execution and Python/Go setup failures; those
historical failures are retained in the SDK contract document.

## Independently recorded official response

`generate-content-recorded-response.json` is extracted from the official
TypeScript SDK's checked-in system-test recording, fetched on 2026-09-23:

- Repository/tag: `googleapis/js-genai`, `v2.24.0`.
- Immutable source commit: `5c4fc4e8c0aad4dab85e63e238aaf81b1295575d`.
- Source: https://github.com/googleapis/js-genai/blob/5c4fc4e8c0aad4dab85e63e238aaf81b1295575d/test/system/recordings/Client_Tests_generateContent_ML_Dev_should_generate_content_with_specified_parameters.json
- Original source SHA-256: `c92d4130307e506e2b7e75ebf77bc7515598c873b83af3247f292f2ad0050afe`.
- Extraction: `interactions[0].response.bodySegments[0]`, recorded HTTP status 200.
- Attribution: Google LLC, official `js-genai` repository; source license
  https://github.com/googleapis/js-genai/blob/5c4fc4e8c0aad4dab85e63e238aaf81b1295575d/LICENSE.
- Sanitization: replace candidate text with `[SANITIZED_OFFICIAL_RESPONSE_TEXT]`,
  response ID with `sanitized-official-response-id`, and `turnToken` with
  `[REDACTED_OPAQUE_TOKEN]`. Request, headers, network addresses and all other
  recording metadata are excluded. No counters, finish reason, model version,
  candidate position or usage modality fields were changed.
- Preserved facts: `MAX_TOKENS`, prompt 7, candidate 149, thought 48, total 204.
  These counts describe the upstream recording, not the sanitized text length.

This closes the independent official response-fixture provenance gap. It does not
establish current live-provider behavior. No SDK-to-Backplane forwarding or live
Google request was executed here; all E2E testing is deferred by user instruction.
