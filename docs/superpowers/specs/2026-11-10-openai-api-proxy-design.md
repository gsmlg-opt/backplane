# OpenAI API proxy capabilities

Capability scope approved in chat on 2026-11-10. Navigation corrected by the user on 2026-11-11: all configuration menus belong under Llama, with no separate API Proxy top-level menu.

## Behavior and ownership

Extend `backplane_llama`, with migrations in `backplane_system` and configuration pages in `backplane_admin`. Reuse existing provider records, their enabled OpenAI API surface, credential references, authentication, rate limits and observability. Keep models for non-chat operations separate from chat discovery/catalogs.

Persist explicit, enabled-by-default service configurations for Decisions, Images, Speech, Transcription and Realtime. Each configuration references an existing provider and defines an allowed model list, optional default model, request timeout, upload/output bounds and session lifetime. Add and Edit open modal forms without an enablement field; existing configurations are enabled/disabled through table icon actions. Embeddings retains its existing provider/model configuration.

Expose native `POST /v1/decisions`, image generations/edits, speech and transcriptions; add Realtime WebSocket, client-secret creation and WebRTC call establishment. Preserve native parameters, status, errors, JSON, multipart, audio and SSE. Rewrite only model identifiers needed for routing. Do not retry submissions or reconnect/replay WebSocket events automatically.

Existing MiniMax adapters remain distinct and functional. Their restricted request validation must not reject OpenAI-native options. OpenAI audio configuration does not require enabling MiniMax audio. Authenticate before parsing uploads, bound resources and clean up after success, error, timeout and disconnect.

## Administration

Add Decisions, Images, Embeddings, TTS, ASR, Realtime and MiniMax Audio menu entries under the existing Llama section. Provide separate CRUD configuration pages for the five new OpenAI capability kinds. Each page opens its create form in a modal through an Add button; Edit uses the same modal. Successful saves close it, validation failures preserve it, and Cancel/close/Escape dismiss without saving. Show existing provider, credential reference and API endpoint; never expose secret values. Persist only identifiers in CRUD audit events. Keep existing embedding and MiniMax audio pages at `/llama/embedding` and `/llama/audio`; redirect the temporary `/api-proxy/*` addresses into Llama.

## Verification

Use deterministic local upstreams for native request/response preservation, disabled/ambiguous routing, authentication, credential isolation, multipart repeats, binary/SSE errors, bidirectional Realtime events, disconnect cleanup and no replay. Exercise admin CRUD, validation, per-kind isolation, menu placement, legacy redirects and MiniMax/embedding regressions. Run focused checks serially, inspect integrated diff, and report real-provider/browser checks separately.

No branch/worktree creation, commits, publication, deployment, dependency changes, automatic paid health checks, or migration of live configuration is authorized. Files/batches/vector stores/fine-tuning/SIP are outside this approved first set. WebRTC media travels directly between the client and OpenAI; Backplane handles authenticated setup, not media relay.

## Official references checked 2026-11-10

- https://developers.openai.com/api/reference/resources/decisions/methods/create
- https://developers.openai.com/api/docs/guides/image-generation
- https://developers.openai.com/api/docs/guides/text-to-speech
- https://developers.openai.com/api/docs/guides/speech-to-text
- https://developers.openai.com/api/docs/guides/realtime
- https://developers.openai.com/api/docs/guides/voice-websockets?api=realtime
- https://developers.openai.com/api/docs/guides/voice-webrtc?api=realtime

The speech guide currently documents old TTS model shutdown on 2027-01-06. File transcription recommends `gpt-transcribe`; older transcription models and audio translations shut down on 2027-02-26. Model choices remain operator-configured rather than hard-coded assumptions about account entitlement.
