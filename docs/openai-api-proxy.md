# Native OpenAI API proxy

Backplane separates provider connections from API configuration under **Llama**. **Providers** stores one default Base URL and credential references. **LLM** configures protocol-specific URLs, headers, backend parameters and conversation APIs; Decisions, Images, Embeddings, Text to Speech, Transcription and Realtime have their own configuration pages. Every API configuration references an existing Provider. Opening or saving configuration does not run paid API probes.

## Configuration

1. In **Providers**, choose **OpenAI Platform**, select its vault API-key credential and save the connection. OpenAI Codex remains a separate OAuth preset.
2. In **LLM**, select the Provider connection and configure its conversation protocols: OpenAI Chat Completions, Responses HTTP and optional Responses WebSocket, or Anthropic Messages and other supported protocols on compatible connections. Manage discovery and conversation models from LLM.
3. In each other capability menu, click **Add**, select the Provider, and save. New configurations default to enabled and accept client model IDs. Advanced settings optionally restrict models, set a default, or change resource limits. Images has independent generation and edit selections.

Provider edits do not change conversation protocols or any other API policy. Credentials and the default Base URL are entered once in Providers; shared headers and protocol-specific URL overrides and headers are configured in LLM. Conversation model catalogs remain independent of image, audio and embedding model policies.

| Capability | Configuration page | Public operation |
| --- | --- | --- |
| Conversation | `/llama/llm` | `/v1/messages`, `/v1/chat/completions`, `/v1/responses` (HTTP and WebSocket) |
| Decisions | `/llama/openai/decisions` | `POST /v1/decisions` |
| Images | `/llama/openai/images` | `POST /v1/images/generations`, `POST /v1/images/edits` |
| Embeddings | `/llama/embedding` | `POST /v1/embeddings` |
| Text to Speech | `/llama/openai/speech` | `POST /v1/audio/speech` |
| Transcription | `/llama/openai/transcription` | `POST /v1/audio/transcriptions` |
| Realtime | `/llama/openai/realtime` | WebSocket `GET /v1/realtime`, `POST /v1/realtime/client_secrets`, `POST /v1/realtime/calls` |
| MiniMax Audio | `/llama/audio` | Existing adapted speech/transcription and previews |

### Model selection and status

New native API configurations accept the client's model without requiring a local model list. An optional allowlist restricts admission. Decisions supports the documented `gpt-6-luna` model. Existing Platform Decisions defaults are retained; new configurations can set an explicit default in advanced settings. Missing models are accepted only when an explicit default resolves unambiguously; the gateway does not invent defaults for other capabilities.

Clients use `provider/model` for explicit routing. A bare model must resolve to a single eligible enabled configuration; ambiguous routes fail without contacting an upstream. A prefixed request cannot fall through to another configured provider when its target is disabled. Account entitlement and model/API compatibility are decided by the upstream, and its error is preserved.

For `/v1/audio/speech` and `/v1/audio/transcriptions`, declared aliases and explicit MiniMax audio bindings take precedence over generic native OpenAI `:passthrough` services, while explicit native `provider/model` requests, allowlisted native models, and unclaimed raw/non-provider-slash models route directly to OpenAI without probing or post-error fallback. For `POST /v1/embeddings`, omitting `"model"` resolves a single eligible native default model and enforces named-endpoint model authorization against the resolved model before dispatch; explicit `null`, empty, or malformed `"model"` values fail validation instead of substituting the default.

Shared Provider Default Headers and API-specific Default Headers are merged case-insensitively across HTTP, Responses lifecycle, Codex direct, native services, and Responses WebSocket routes, with API-specific defaults overriding Provider defaults for ordinary headers while server-owned credentials remain protected.

Status pages report configured enablement separately from unavailable connections or credentials. `Configured` is local configuration readiness, not proof of a successful upstream call. Native routes require direct HTTP and a vault credential of kind `llm` or `service` with absent/`api_key` auth type. OAuth/Codex credentials are ineligible.

### Upgrade and compatibility

Apply the `20261117` Provider-capability migrations before starting the new code. Existing capability rows remain the canonical source of enablement, limits and model policy. Existing nonempty lists remain allowlists; empty lists become client-model passthrough. Empty OpenAI Decisions configurations receive the documented model/default. Existing disabled states, custom defaults, headers and resource limits are preserved. Apply `20261119000000_add_provider_base_url` before using the single-URL Provider form. This migration copies a retained API URL as the Provider default without changing API rows. Saving Provider settings preserves existing API URLs, headers and policy.

Existing direct embedding definitions are linked to Provider-owned connections and API policy during migration. Their original client names and per-model activation remain compatible, including name collisions; changing the linked Provider's credentials or disabling Embeddings affects the old names too. Use **Manage embedding connections** on the Embeddings page to configure Host Agent connections and manage unlinked definitions. Configure native direct connections in Providers and set their policy in Embeddings.

Temporary `/api-proxy/*` admin addresses retain their redirects. MiniMax's adapted audio workflow remains separate; its global switch does not control native OpenAI audio. Files, Batches, Vector Stores, Fine-tuning, SIP and later Realtime call-management operations are outside the implemented API set.

## HTTP behavior

All public operations require existing Backplane `/v1` resource authentication and `llm::invoke` for scoped clients. The OpenAI key stays server-side. Decisions and image generation use JSON; image editing accepts JSON or multipart. Transcription accepts multipart, preserving repeated fields and files. Speech returns the upstream audio or SSE format. Native parameters such as speech instructions and transcription options are not restricted to the MiniMax subset.

Native status codes, error bodies, content types, response bytes and streaming events pass through. Requests are submitted once. The gateway never retries a possibly accepted POST, normalizes audio/image output into chat messages or fabricates usage. Configure SDK clients with `max_retries=0` when the caller must also avoid automatic replay.

Upload and output limits are local proxy policy, independent of upstream per-model limits. The native HTTP parser buffers a bounded request body to select and rewrite model fields; it does not transcode, inspect audio duration or validate media containers. Keep ingress body/concurrency limits appropriate for available memory. MiniMax media conversion and sandbox limits are separate. Payloads and API keys are not saved in configuration or CRUD audit events; access records contain safe routing and outcome metadata.

## Realtime

Use `GET /v1/realtime/models` with a Backplane bearer credential and
`llm::models` to find provider-qualified Realtime model IDs. The response lists
locally eligible allowlisted models and explicit passthrough defaults. A
passthrough service without a default accepts explicit model requests and has
no configured model to list. Discovery checks configuration without contacting
the upstream. The upstream account still determines model availability.

`GET /v1/models` is the general model catalog. An ID present there can return
`404 model_unavailable` from Realtime before Backplane contacts the provider.
In **Llama → Realtime** (`/llama/openai/realtime`), verify the service,
its provider, and the provider's OpenAI API surface are enabled. Check that the
provider has a direct API URL and an eligible Platform API-key credential. When
using an allowlist, enter the raw upstream model ID, then connect with the
qualified ID returned by Realtime discovery. The connecting client needs
`llm::invoke`.

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

Controlled-upstream tests establish proxy behavior without paid calls. The separate [local qualification report](testing/openai-platform-live-2026-11-17.md), updated on 2026-11-18, records two successful checks for all 15 configured OpenAI operation types, numeric usage and fixes, including completed Responses and Realtime WebSocket responses. That qualification uses one development account and does not establish production capacity, release or deployment.

Native HTTP and Responses/Realtime WebSocket requests honor environment proxy settings and `NO_PROXY`. WebSocket proxy dialing requires `http_web_socket` 1.0.0-rc.19 or later, adopting the fix for [http_fetch#172](https://github.com/gsmlg-dev/http_fetch/issues/172). WSS uses HTTP CONNECT with verified target TLS; proxy authentication stays in transport options. Failed proxy connections do not fall back to direct dialing. Current proxy connections use HTTP/1 WebSocket; HTTP/2 Extended CONNECT is not qualified.

### Provider and LLM configuration ownership

Providers expose one default Base URL together with identity and credentials.
LLM owns protocol paths relative to that URL, Default Headers, backend parameters,
conversation protocols and discovery. Existing API URLs are preserved when the
Provider default changes. Known presets seed unconfigured API connections from
the Provider default; protocol-specific paths remain editable in LLM. Saving or
cancelling either form never probes the upstream.
