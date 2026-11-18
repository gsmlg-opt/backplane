# OpenAI Platform local qualification — 2026-11-17

Tested the existing `openai` Provider through public `http://127.0.0.1:4220` in the local devenv, with the admin UI on port 4221. Changes are uncommitted on `main`, based on `5e412d32bd9cafed23ae66206bd7de6b50228147`; nothing was released or deployed.

**All 15 configured operation types now have two successful checks each.** The initial 13 HTTP/WebRTC checks were followed by successful Responses and Realtime WebSocket checks on 2026-11-18, after adopting the upstream proxy fix in `1.0.0-rc.19`. Earlier failures are preserved below and in the JSON evidence.

## Configuration and scope

Providers now contains connection/authentication settings. `/llama/llm` independently configures conversation protocols, Responses WebSocket/lifecycle, discovery and model management. Decisions, Images, Embeddings, TTS, Transcription and Realtime independently reference a Provider. Existing enablement, policies, credentials and model associations were preserved.

The tested OpenAI connection enabled Chat Completions, Responses HTTP and Responses WebSocket. Its six native services were enabled; Decisions allowed/defaulted to `gpt-6-luna`, and the others used client-model passthrough. Both image operations were enabled. Responses lifecycle was disabled, so retrieve/delete/cancel were excluded. Anthropic Messages was not configured for this Provider. Tests cover configured API operations using small fixed models, rather than every model in the discovered catalog.

Each execution issued a temporary scoped Backplane client with `llm::invoke` and `llm::models`. Every run confirmed token revocation, HTTP 401 rejection and deletion of that temporary client. Provider secrets stayed server-side. No automatic POST or WebSocket replay was used. Generated audio/images stayed in memory; evidence contains statuses and numeric usage only.

## Two-pass results

The table reports post-fix qualification where a fix was possible. Original failures and every subsequent attempt are retained in the [sanitized evidence](openai-platform-live-2026-11-17.json).

| Operation | Model | Pass 1 | Pass 2 | Semantic check |
| --- | --- | --- | --- | --- |
| `GET /v1/models` | — | 200 | 200 | Catalog includes the fixed text model |
| Chat Completions JSON | `gpt-6-luna` | 200 | 200 | Nonempty text, `finish_reason=stop` |
| Chat Completions SSE | `gpt-6-luna` | 200 | 200 | Text, stop, `[DONE]`, numeric usage |
| Responses JSON | `gpt-6-luna` | 200 | 200 | Completed response with text |
| Responses SSE | `gpt-6-luna` | 200 | 200 | Text delta and `response.completed` |
| Responses WebSocket | `gpt-6-luna` | 101 + completed | 101 + completed | Text delta and `response.completed`, rc.19 retest |
| Decisions | `gpt-6-luna` | 200 | 200 | Typed probability in [0, 1] |
| Embeddings | `text-embedding-3-small` | 200 | 200 | One numeric embedding vector |
| Speech | `tts-1` | 200 | 200 | Valid bounded WAV, 43,844 / 44,444 bytes |
| Transcription | `whisper-1` | 200 | 200 | Nonempty transcription of generated WAV |
| Image generation | `gpt-image-1-mini` | 200 | 200 | Decodable PNG, low quality, one 1024 square image |
| Image editing | `gpt-image-1-mini` | 200 | 200 | Multipart input PNG, decodable edited PNG |
| Realtime WebSocket | `gpt-realtime-2.1-mini` | 101 + completed | 101 + completed | Session initialized, text and completed `response.done`, rc.19 retest |
| Realtime client secret | `gpt-realtime-2.1-mini` | 200 | 200 | Nonempty ephemeral secret and expiry; value discarded |
| Realtime WebRTC calls | `gpt-realtime-2.1-mini` | 201 + completed | 201 + completed | Browser connected, data channel open, completed text response |

WebRTC checks negotiated receive-only audio without microphone capture and generated text only. A 201 SDP answer was not treated as full success: both successful browser checks received `response.done` with completed text, and then closed their peers. Usage was 10 input / 22 output tokens and 10 input / 21 output tokens, including reasoning tokens.

## Problems and disposition

1. **Fixed: native HTTP routes ignored environment proxy configuration.** Initial Decisions, Embeddings, Speech, image generation and Realtime secret requests returned 504; dependent ASR/edit checks could not run. Ordinary conversation routes already worked. An unauthenticated diagnostic GET timed out over direct egress and returned 401 through the configured proxy. `OpenAI.Dispatch` constructed a Relayixir upstream with `proxy=nil`. It now uses `proxy: :environment`, matching the existing conversation and lifecycle routes, including `NO_PROXY`. Regression coverage proves proxy admission and bypass behavior; all seven affected operation types then passed twice.
2. **Resolved in the rc.19 retest: WebSocket forward-proxy transport.** Both WebSocket operations failed on two independent attempts. Installed `http_web_socket` / `http_runtime` 1.0.0-rc.18 rejects non-nil proxy options with `:proxy_not_supported` in `HTTP.Runtime.Options.protocol_selection/2`; changing application options alone cannot resolve it. Filed [gsmlg-dev/http_fetch#172](https://github.com/gsmlg-dev/http_fetch/issues/172), Feature, `internal request`, severity blocker; both callsites initially carried TODO references. No local transport workaround was made. The upstream fix was subsequently published in rc.19, adopted with its coordinated dependency family, and verified through loopback regressions and four completed OpenAI WebSocket responses; the obsolete TODOs were removed.
3. **Fixed: API Usage timestamps stayed stale after refresh.** Usage totals changed, but ignored `<local-time>` elements kept their original `datetime` and displayed time until a page reload. LiveView now sends `data-datetime` / `data-format` on those ignored elements; the custom element observes them and synchronizes its semantic datetime and localized text. The dashboard regression checks updated timestamp data on an existing view. A live browser refresh advanced both attributes and visible local time without reload, from 19:09:54 to 19:11:39.
4. **Recorded: one WebRTC signaling connection timeout.** The proxy logged `:upstream_timeout` after 5,003 ms during connection establishment. Another independent call succeeded. No automatic replay occurred; a fresh session was used for the additional qualification check.
5. **Corrected test procedure: delayed SDP application.** One successful signaling response was applied to the browser after roughly 44 seconds; its data channel failed to open. A fresh offer with immediate answer application connected and completed. This was a harness timing failure, not counted as a gateway pass. All browser peers were closed.

The preparation runner also needed local script corrections (PubSub startup, Ecto options and client scopes) before actual requests; these were test-harness issues and did not change repository API behavior.

## Usage and budget

The requested budget remained **USD 30**. All executions, including the later WebSocket retests, together reserved a conservative **USD 1.450**, including failed and ambiguous attempts. This is a request-size/model-based reservation, not a measured invoice or an account-level spending limit. Text output was capped at 64 tokens; image generation/editing used one low-quality square output each; ASR inputs were verified below one minute; Realtime generated bounded text without audio input.

Official pricing used for planning: [OpenAI pricing](https://developers.openai.com/api/docs/pricing), checked 2026-11-17. Per million units: `gpt-6-luna` text input/output $0.10/$0.50; embedding input $0.02; TTS characters $15; image text/image input/output $2/$2.50/$8; Realtime text input/output $0.60/$2.40. Whisper was $0.006/minute. Decisions used input-only billing. Successful response usage indicates a few cents; delayed organization costs must not be represented as a finalized zero charge.

| API Usage observation | Before | After, latest captured successful refresh |
| --- | --- | --- |
| Success time, Asia/Shanghai | 18:39:51 | 19:11:39 |
| Today UTC input tokens | 0 | 2,170 |
| Today UTC output tokens | 0 | 873 |
| Today UTC requests | 0 | 12 |
| Today UTC organization costs | 0 USD | 0 USD, reporting delayed |
| Month-to-date organization costs | 0.00080984 USD | 0.00080984 USD, reporting delayed |

API Usage is organization-wide and can include concurrent traffic. Its completions totals and delayed costs are not an exact sum of this multi-API suite. The per-operation numeric usage in the evidence is the more immediate record; no final bill is claimed.

## Verification and limits

Focused domain, migration, provider, LLM/native configuration, navigation and API Usage regressions passed: **153 tests, 0 failures** (81 domain and 72 admin). `mix compile --warnings-as-errors`, changed-file `mix format --check-formatted`, JavaScript module syntax and `git diff --check` passed. The running dev watcher served the updated JavaScript to the browser; no production asset build is claimed. Browser verification used real dev assets and connected LiveView at 1440px and 390px, sunshine/moonlight: separate Provider settings, independent LLM/native forms, initial focus, keyboard navigation, Escape/focus return and no page overflow. API Usage refresh was verified without reloading.

The devenv gateway and PostgreSQL remain running for operator use. Host Agent is independently blocked by the installed ex_turso NIF requiring GLIBC_2.44 on a GLIBC_2.42 environment; direct OpenAI testing did not depend on it. Full-repository tests, Credo, Dialyzer, production load and deployment were not performed. Existing model-form ID warnings remain outside these changes.


## Responses WebSocket retest — 2026-11-18

Retested the existing enabled `openai` Responses WebSocket configuration through public port 4220 with `gpt-6-luna`, at most 64 output tokens and no automatic replay. **Both independent attempts returned HTTP 502 before upgrade; neither reached HTTP 101 or a response completion event. The current gateway WebSocket connection is still unusable in this environment.**

The installed transport remains `http_web_socket` / `http_runtime` 1.0.0-rc.18. Direct unauthenticated OpenAI HTTPS egress also timed out after six seconds; the installed runtime still rejects non-nil proxy options with `:proxy_not_supported`. The previously recorded upstream blocker therefore remains applicable; no configuration, dependency or application-code changes were made for this retest.

The temporary client was revoked, its public token rejection confirmed, and the client deleted. This retest reserved an additional $0.002; it did not reach generation and returned no usage. This is not a measured billing statement. Safe statuses and cleanup evidence are in the JSON `retests` field. The gateway and PostgreSQL remain running.


## WebSocket qualification after upstream fix — 2026-11-18

The requested one-hour wait ended at approximately 03:05 Asia/Shanghai (19:05 UTC on November 17). Upstream issue #172 was closed with a published `1.0.0-rc.19` fix. Updated the twelve installed HTTP-family packages together, with no unrelated lockfile upgrades, and raised the root and Llama WebSocket minimum to rc.19. Both sessions now resolve the existing environment proxy policy through `Relayixir.Proxy.EnvironmentProxy`: WS uses HTTP proxy routing, WSS uses CONNECT with verified target TLS, proxy authorization stays in transport options, and NO_PROXY selects direct transport. The dependency owns proxy transport and cleanup; no local CONNECT implementation was added.

Restarted the gateway after a successful warnings-as-errors compile. The public endpoint returned 200 and the admin endpoint responded with its normal redirect. Through the public port 4220 and existing `openai` configuration, both independent passes succeeded:

| WebSocket operation | Pass 1 | Pass 2 | Numeric usage (input / output) |
| --- | --- | --- | --- |
| Responses, `gpt-6-luna` | 101, text and completed response | 101, text and completed response | 9 / 5; 9 / 5 |
| Realtime, `gpt-realtime-2.1-mini` | 101, initialized session and completed text response | 101, initialized session and completed text response | 10 / 24; 10 / 34 |

Each connection created exactly one bounded text response, with no replay, microphone, audio output or tools. All four reached native terminal events, rather than treating HTTP 101 as sufficient. The temporary scoped client was revoked, public rejection returned 401, and the client was deleted. Additional conservative reservation was **USD 0.102**, not a measured bill; no billing refresh was performed for this retest. Total reservation, including earlier attempts, is USD 1.450 against the unchanged USD 30 limit.

Focused regression results: **45 tests, 0 failures** (8 Relayixir environment-policy tests and 37 Llama WebSocket session/configuration/route tests). New regressions exercise both session implementations through a real loopback proxy, authenticated proxy routing, NO_PROXY bypass and failure without direct-origin fallback. The upstream release supplies the proxy transport; actual WSS CONNECT was exercised by the four OpenAI responses. Warnings-as-errors compile, changed-file formatting and diff whitespace checks passed. No full-repository suite, Credo, Dialyzer or deployment was performed. Gateway and PostgreSQL remain running.

These successful connections use **HTTP/1 WebSocket over CONNECT**, not RFC 8441. rc.19 explicitly rejects proxy routing with HTTP/2/auto/HTTP/3; OpenAI RFC 8441 support was not tested and is not claimed.
