# Native OpenAI API proxy

Backplane's **Llama** admin section provides separate configuration menus for Decisions, Images, Embeddings, Text to Speech, Transcription, Realtime and MiniMax Audio, alongside providers, model aliases and Codex. Opening or saving a configuration page does not run generation, synthesis, transcription or other paid probes.

## Configuration

Apply the `20261110000006_create_llm_openai_services` migration and restart after upgrading supervision. Store the OpenAI Platform API key in **System → Credentials** as kind `llm` or `service`, with `auth_type` absent or `api_key`. Configure an existing provider and its OpenAI API surface with the intended endpoint (usually `https://api.openai.com/v1`) and credential reference. Codex/OAuth credentials and host-linked services are not eligible for these new native routes.

Each capability page under Llama has its own route configuration:

| Menu | Admin route | Public operation |
| --- | --- | --- |
| Decisions | `/llama/openai/decisions` | `POST /v1/decisions` |
| Images | `/llama/openai/images` | `POST /v1/images/generations`, `POST /v1/images/edits` |
| Embeddings | `/llama/embedding` | Existing `POST /v1/embeddings` |
| Text to Speech | `/llama/openai/speech` | `POST /v1/audio/speech` |
| Transcription | `/llama/openai/transcription` | `POST /v1/audio/transcriptions` |
| Realtime | `/llama/openai/realtime` | WebSocket `GET /v1/realtime`, `POST /v1/realtime/client_secrets`, `POST /v1/realtime/calls` |
| MiniMax Audio | `/llama/audio` | Existing adapted speech/transcription and previews |

Temporary `/api-proxy/*` admin addresses redirect to the corresponding Llama pages. Existing `/llama/embedding` and `/llama/audio` addresses remain canonical. Embeddings retains its existing provider/model configuration and can reference the same vault credential. MiniMax keeps its existing bindings and media pipeline; its global audio switch does not control native OpenAI services.

For each new capability, click **Add** to open its modal form (or the **Edit** icon on an existing route), then select the provider, enter the raw upstream model IDs (one per line), optionally choose a default from that list and set limits. New configurations are enabled by default. The form has no enable/disable field; use the table's Enable/Disable icon after saving. Editing preserves the existing enabled state. All table actions use icon buttons with accessible labels and tooltips. Saving closes the modal after success; validation errors preserve the form. Cancel, the close button and Escape dismiss it without saving. Configure the model IDs actually available to the account; discovery of a chat model does not grant image, audio or Realtime capability. These models do not enter the chat/Codex catalog.

Apply migration `20261111000000_enable_new_openai_services_by_default.exs` to update the database default. Existing configurations retain their enabled/disabled state.

Clients use `provider/model` to select a route. A bare model must match exactly one enabled eligible configuration for that capability. If an operation omits the model, an explicit default must resolve unambiguously. The gateway removes the provider prefix before forwarding; other native fields remain upstream-owned. Configure OpenAI project/organization defaults on the provider API when needed. A compatible provider can be explicitly configured only for capabilities it actually supports; an OpenAI-compatible name or URL alone is not capability evidence.

## HTTP behavior

All public operations require existing Backplane `/v1` resource authentication and `llm::invoke` for scoped clients. The OpenAI key stays server-side. Decisions and image generation use JSON; image editing accepts JSON or multipart. Transcription accepts multipart, preserving repeated fields and files. Speech returns the upstream audio or SSE format. Native parameters such as speech instructions and transcription options are not restricted to the MiniMax subset.

Native status codes, error bodies, content types, response bytes and streaming events pass through. Requests are submitted once. The gateway never retries a possibly accepted POST, normalizes audio/image output into chat messages or fabricates usage. Configure SDK clients with `max_retries=0` when the caller must also avoid automatic replay.

Upload and output limits are local proxy policy, independent of upstream per-model limits. The native HTTP parser buffers a bounded request body to select and rewrite model fields; it does not transcode, inspect audio duration or validate media containers. Keep ingress body/concurrency limits appropriate for available memory. MiniMax media conversion and sandbox limits are separate. Payloads and API keys are not saved in configuration or CRUD audit events; access records contain safe routing and outcome metadata.

## Realtime

Connect to `/v1/realtime?model=provider/model` using a Backplane bearer credential. Each WebSocket pins one provider/model and relays native JSON audio, session, response and cancellation events. Session model identifiers must remain consistent with that route. Frames, queues, cumulative input/output bytes and session lifetime are bounded. Disconnects close the upstream; the gateway does not reconnect, replay events or promise cancellation/refunds for work the provider accepted.

Browser WebRTC setup can use `POST /v1/realtime/calls`, or obtain an ephemeral secret through `POST /v1/realtime/client_secrets`. Backplane proxies setup; audio/media then travels directly between the browser and OpenAI. The ephemeral secret is an intentional sensitive API response, not the long-lived Platform key, and must not be logged by clients. Direct WebRTC traffic is outside Backplane's byte/usage/session observation. SIP and later call-management operations are outside this implementation.

Realtime access observation covers connection metadata; provider token totals are currently unavailable locally. Native usage/rate-limit events still pass to the client. Explicit `response.create` events consume the provider's configured local RPM budget; upstream automatic VAD turns are outside this local admission counter. Client events revalidate configuration and credentials at most once per second for audio traffic, immediately for `session.update` and `response.create`; an idle client receiving only upstream events is not proactively polled. HTTP JSON usage observation is best effort and depends on the native result shape; missing values stay unavailable. HTTP SSE observation records transport outcomes only: it does not establish semantic completion or extract token totals from streamed events.

## Model lifecycle and evidence

Official documentation checked on 2026-11-10 lists `tts-1`, `tts-1-hd` and `gpt-4o-mini-tts` for shutdown on 2027-01-06. Their replacement uses Realtime and is a different workflow, so a model-name substitution in `/audio/speech` is insufficient. File transcription currently recommends `gpt-transcribe`; older transcription models and `/audio/translations` are listed for shutdown on 2027-02-26.

- [Decisions](https://developers.openai.com/api/reference/resources/decisions/methods/create)
- [Images](https://developers.openai.com/api/docs/guides/image-generation)
- [Speech](https://developers.openai.com/api/docs/guides/text-to-speech)
- [File transcription](https://developers.openai.com/api/docs/guides/speech-to-text)
- [Realtime](https://developers.openai.com/api/docs/guides/realtime)

Local controlled-upstream tests establish proxy behavior. They do not establish account entitlement, live OpenAI compatibility, production capacity, release or deployment. No real OpenAI calls are part of these tests.
