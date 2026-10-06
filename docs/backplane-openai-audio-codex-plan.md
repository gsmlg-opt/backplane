# Backplane OpenAI-Compatible Audio API
## Codex Implementation Plan

**Repository:** `gsmlg-opt/backplane`
**Prepared:** 2026-10-01
**Reviewed baseline:** `a4b5944b3d85891dfc6a42f82f6931447494778e`
**Delivery:** Implement the feature, tests, admin configuration, and deployment support.
**Status:** Implementation instructions only. No repository changes or live MiniMax calls were made while preparing this plan.

## 1. Mission and fixed scope

Implement OpenAI-compatible standalone TTS and file-transcription endpoints in Backplane, using MiniMax as the initial upstream provider. Backplane owns audio-format conversion so clients do not need MiniMax-specific audio handling.

The user has already decided the following requirements. Do not reopen these decisions or reduce the format matrix to an MP3-only milestone.

| Area | Required delivery |
| --- | --- |
| TTS endpoint | `POST /v1/audio/speech` |
| Transcription endpoint | `POST /v1/audio/transcriptions` |
| TTS output formats | `mp3`, `opus`, `aac`, `flac`, `wav`, `pcm`; default `mp3` |
| Transcription upload formats | `flac`, `mp3`, `mp4`, `mpeg`, `mpga`, `m4a`, `ogg`, `wav`, `webm` |
| Transcription result formats | `json` and `text`; default `json` |
| Initial provider | MiniMax, using a configured credential from Backplane's existing vault |
| Conversion | Server-side FFmpeg/ffprobe, with passthrough and remuxing when appropriate |
| Streaming | Ordinary HTTP binary TTS streaming where the complete processing path supports it |
| Configuration | Existing PostgreSQL-backed operational configuration and DuskMoon admin UI |

The format lists match the OpenAI references reviewed for this plan. Raw TTS PCM is 24 kHz, signed 16-bit little-endian without a container header; this implementation will emit one channel. The mono choice is an explicit Backplane output profile, not a claim that every OpenAI audio operation uses mono. [OAI-SPEECH] [OAI-TTS-GUIDE] [OAI-ASR]

**Compatibility means the stated HTTP contract and media formats, not OpenAI model behavior, identical voices, every optional parameter, every codec ever embedded in a named container, or identical provider limits.** Publish the tested container/codec combinations and remaining semantic differences.

### Explicit non-goals

Do not implement Realtime API, WebRTC, WebSocket audio sessions, continuous microphone ingestion, VAD, barge-in, conversational state, or tool calling. Do not add `/v1/audio/translations`, voice cloning, voice enrollment, diarization, subtitle export, ASR SSE, or TTS SSE events in this delivery. Ordinary binary HTTP streaming remains in scope and is not Realtime API.

Do not introduce a new authentication system, admin login layer, standalone gateway product, agent-runtime subsystem, generic job platform, or broad `backplane_ai_protocol` refactor. Do not add an MCP audio tool unless separately requested.

## 2. Repository baseline and working rules

The reviewed endpoint runs `Backplane.LLM.ProxyPlug` before the general Phoenix parsers. That plug intercepts `/v1/*`. `Backplane.LLM.Router` performs resource authentication and authorization before its JSON-only parser. Audio routes are absent. Adding routes only to the ordinary Phoenix router would therefore miss the current request path. [REPO-ENTRY] [REPO-ROUTER]

The reviewed provider API configuration and native-protocol enums are conversational, not a general declaration that every OpenAI-shaped endpoint can be forwarded to any provider. The Docker runtime package list does not include FFmpeg. [REPO-PROVIDERS] [REPO-DOCKER]

Read `AGENTS.md` and any applicable local instructions before editing. Recheck the current checkout against this baseline; preserve newer implementations instead of replacing them with this plan's proposed names.

Repository rules to preserve:

- Keep domain implementation in `apps/backplane_llama`; public endpoint integration belongs in `backplane_api`, UI in `backplane_admin`, migrations in `apps/backplane_system/priv/repo/migrations`.
- Store operational settings in PostgreSQL, not new boot-only TOML fields. Reuse vault credential references, client scopes, provider identities, aliases, and observability facilities.
- Use `phoenix_duskmoon` and the existing DuskMoon design system. Do not introduce DaisyUI or a replacement component library.
- Preserve unrelated worktree edits. Do not create branches, commit, or push unless separately authorized.
- Run focused verification first. Report unrelated baseline failures rather than fixing unrelated subsystems. Do not claim unexecuted checks passed.
- Keep gateway-only dependencies out of the independent `host_agent` release. Follow repository issue-escalation and agent-note conventions when applicable. [REPO-AGENTS]

The baseline commit message reports existing agent-runtime test failures. That is historical context, not a substitute for running scoped checks or proof of the current test status. Do not make audio delivery depend on an unrelated runtime repair. [REPO-BASELINE]

## 3. Architecture and ownership

### 3.1 Request pipeline

Keep the existing `/v1` authentication boundary. Use route-aware parsing after authentication and authorization:

`request → authentication → authorization → admission/size policy → route-specific parsing → validation → capability-aware model resolution → audio execution → response → cleanup/usage finalization`

TTS uses a bounded JSON parser. Transcription uses bounded multipart parsing. Preserve the existing raw-body behavior of conversational routes; do not run audio uploads through a JSON model extractor or cache a multipart body as one large BEAM binary.

Prefer Plug's multipart machinery instead of writing a new multipart parser. Its file uploads are spooled to temporary files, and its multipart parser does not use the ordinary `body_reader` callback. Inspect the pinned Plug version before implementing parser options and ownership transfer. [PLUG-PARSERS]

Authentication must precede application-level upload spooling and all ffprobe/FFmpeg/upstream activity. Transport-level buffering is separate: configure ingress and server limits too, and do not claim the application can prevent every byte from reaching the socket before authentication.

### 3.2 Suggested module boundaries

Names below are proposals, not assertions that these files exist:

| Namespace under `Backplane.Audio` | Responsibility |
| --- | --- |
| `Speech`, `Transcription` | Operation orchestration; no controller-sized provider implementation |
| `Request`, `Error` | Pure request normalization, validation, and consistent public errors |
| `Resolver`, `Config` | Operation-specific routing and validated operational configuration |
| `Adapters.MiniMax` | Native request construction, upstream response normalization, provider errors |
| `Media.Probe`, `Media.Plan` | Bounded probing and pure passthrough/remux/transcode planning |
| `Media.Runner`, `Media.TempFiles` | External process lifecycle, quotas, cancellation, temporary files |
| `Stream` | Incremental provider decoding and binary output coordination |

Separate pure decisions from effects. Pass normalized maps/structs and explicit capability records between layers. Use OTP processes for ownership and concurrency, not an object hierarchy. A single GenServer must not serialize every audio request.

Reuse a suitable existing HTTP or subprocess primitive only after verifying its streaming, bounded buffering, cancellation, and ownership semantics. Do not add a dependency on `backplane_agent_runtime` just to launch FFmpeg. Avoid new codec NIFs.

### 3.3 Provider configuration and routing

Reuse existing Provider and ProviderModel identities. Add a focused audio binding for a provider/model/operation where existing storage cannot express native audio capabilities. Prefer this small domain-owned extension over widening all shared conversational protocol enums.

The binding must express: provider/model references, operation (`speech` or `transcription`), adapter/native protocol, explicitly configured API origin, enabled state, supported media/parameter capabilities, and an optional vault credential override. An omitted override may inherit the provider credential, but the effective credential reference must be visible to the operator. No secret values belong in binding rows.

Use foreign keys and uniqueness constraints, validate that a referenced model belongs to its provider, and require provider, model, and binding to be enabled. Store related voice mappings and policy in the existing settings system or the audio domain's validated configuration, not unvalidated arbitrary backend options.

Keep these concepts separate:

- Client operation and format: OpenAI-shaped speech/transcription.
- Upstream wire protocol: MiniMax native speech/transcription.
- Model identity and credential: selected by persisted configuration.

Do not mark MiniMax native audio as native OpenAI merely because Backplane exposes OpenAI-shaped routes. Do not reuse a chat-only `ProviderApi` record as proof of audio support.

Implement an operation-aware resolver. Reuse alias expansion where it is genuinely operation-neutral; do not route audio through checks that require a conversational API surface. Detect alias loops and operation mismatches. Invalidate caches on relevant provider, model, binding, alias, and credential-reference updates, and include the operation in cache keys.

Support explicit `provider/model` identifiers and configured public aliases. Suggested aliases are `backplane-tts` and `backplane-asr`; create them only through explicit setup, not an automatic migration. Include enabled public audio models in `/v1/models` without breaking its existing response envelope. Keep audio-only models out of Codex catalogs and chat auto-model candidates. Do not invent OpenAI-compatible capability fields unless clearly documented as Backplane extensions.

## 4. Public HTTP contract

### 4.1 Speech

Require JSON `model`, nonempty `input`, and `voice`. A string such as `default` is a configured voice alias, not permission to silently omit a required parameter. Support `response_format` and `speed`; accept an absent `stream_format` or `stream_format=audio`.

Use the OpenAI reference's 4,096-character input ceiling for this public route. Define and test Unicode character counting separately from the JSON byte limit. `speed` defaults to 1.0; validate the OpenAI range first and then the verified provider range. For values without a supported mapping, return a parameter-specific error rather than clamping or introducing undisclosed time-stretch processing. [OAI-SPEECH]

Resolve voice aliases per configured provider. Unknown aliases are errors. A direct native voice ID is allowed only through an explicit permitted-native-voice policy. An administrator may map an OpenAI-style name to a MiniMax voice for client convenience, but documentation and UI must not claim they are the same voice.

Nonempty unsupported `instructions`, custom-voice objects, or `stream_format=sse` receive clear 400 errors. Do not silently drop requested behavior. Do not require a nonstandard `stream=true` JSON field for ordinary SDK binary streaming.

Return actual audio bytes, not a JSON envelope, hex string, base64 blob, or upstream download URL. Preserve a request ID. Select truthful `Content-Type`, length when known, and an appropriate safe filename. Do not apply a text charset or gzip transformation to encoded audio.

Use this explicit output-profile matrix. Container choices not dictated by the cited OpenAI format list are Backplane implementation choices and must be tested with normal decoders:

| Format | Required bytes/container | Response MIME policy |
| --- | --- | --- |
| `mp3` | Decodable MP3 audio | `audio/mpeg` |
| `opus` | Ogg container carrying Opus | `audio/ogg` |
| `aac` | ADTS-framed AAC-LC, not an MP4 file renamed `.aac` | `audio/aac` |
| `flac` | Native FLAC container | `audio/flac` |
| `wav` | Finalized RIFF/WAVE containing signed 16-bit PCM | `audio/wav` |
| `pcm` | Headerless signed 16-bit little-endian PCM, 24,000 Hz, mono | `application/octet-stream` |

Do not label little-endian PCM as an incompatible sample representation. Document PCM geometry because the payload has no self-describing header. Other output profiles must record their sample rate, channel policy, and codec settings explicitly rather than rely on varying FFmpeg defaults.

### 4.2 File transcription

Require multipart `model` and one `file`. Support the nine upload formats in Section 1. `response_format=json` returns a minimal object with a string `text`; `response_format=text` returns UTF-8 plain text. Keep provider duration/trace metadata in internal observations unless explicitly part of a documented public extension.

Support optional `language` only where the selected provider supports it. MiniMax's reviewed contract places the hint in a `language` request header, whereas the public API takes a multipart field. Validate the value and translate it explicitly. Omit the header for automatic recognition. [MM-ASR]

Reject unsupported meaningful `prompt`, `temperature`, timestamp, speaker, chunking, and log-probability options with parameter-specific errors. Accept absent or false `stream`; reject true rather than pretending to implement ASR SSE. Reject `verbose_json`, `srt`, `vtt`, and `diarized_json` in this delivery. Null/empty-as-absence behavior must be consistent and documented; do not use it to silently ignore a real instruction.

Use content inspection, container structure, codec metadata, and decoding results together. File extensions and uploaded MIME types are hints, not security controls. Detect video-only files, corrupt/truncated media, encrypted/DRM media, ambiguous multiple audio tracks, and files that only pretend to be an allowed format.

For multiple audio tracks, reject ambiguity in this release rather than silently picking the wrong language. Extract only audio from video containers. Raw `.pcm` uploads are not in the public ASR format list; reject them with an explanation to wrap samples in WAV. No implicit raw-PCM geometry guessing.

### 4.3 Resource policy

Implement independently configurable, validated limits. These are proposed starting defaults, not claims about universal provider behavior:

| Limit | Initial policy |
| --- | --- |
| Public uploaded file bytes | 25,000,000; enforce on the file part, not just `Content-Length` |
| Multipart envelope overhead | Separate bounded allowance, initially 64 KiB |
| Speech JSON request bytes | 64 KiB, in addition to input-character validation |
| Media probe deadline | 10 seconds |
| ASR input duration | At most 500 seconds for the reviewed MiniMax binding |
| Transformed upstream upload | At most the configured verified MiniMax limit, initially 50,000,000 bytes |
| Media conversion deadline | 120 seconds |
| Overall audio request deadline | 600 seconds, coordinated with ingress/upstream deadlines |
| Active media subprocesses | Two per node initially; no unbounded wait queue |

Also configure maximum decoded samples, sample rate, channel count, provider response/event sizes, output bytes, concurrent uploads, temporary storage, and total audio operations. Pick conservative defaults, justify them in the implementation notes, and test their enforcement. Per-node limits are not cluster-wide quotas: document their scope, and do not advertise a global limit unless it is actually coordinated.

MiniMax currently documents a 500-second file duration limit, a 50 MB upload limit, and no containerless PCM ingestion. Backplane must retain effective upstream bounds even when its public file-byte policy changes. Transcoding cannot remove duration limits. Never truncate, silently split into multiple paid calls, or retry with degraded audio to hide a limit error. [MM-ASR] [MM-ASR-GUIDE]

Probe metadata is not sufficient proof of safe duration or decompressed size. Enforce runtime sample/output/time bounds while decoding, and reject uncertain or inconsistent media rather than trusting a forged header. If needed, run bounded validation decoding before any billable ASR call.

## 5. MiniMax adapter

### 5.1 Verified API starting points

The official references reviewed on 2026-10-01 document `POST /v1/t2a_v2` for speech and `POST /v1/speech_to_text` for transcription. Listed model identifiers include `speech-2.8-turbo`, `speech-2.8-hd`, and `asr-1.0`. Treat these as configurable starting points, not guarantees of account entitlement or permanent defaults. [MM-SPEECH] [MM-ASR]

Verify the selected region's official origin and current capabilities before enabling an account. Do not overwrite an existing MiniMax chat origin, invent a China/global URL by string substitution, add legacy group parameters without evidence, or send a key across regions as an automatic fallback. Build paths exactly once, with tests for existing `/v1` prefixes.

### 5.2 Speech translation and decoding

Map normalized `input` to native `text`, resolved voice to `voice_setting.voice_id`, and validated speed to `voice_setting.speed`. Select native `audio_setting` from the conversion plan. Prefer inline hex output over provider-hosted URLs. This avoids an unnecessary remote-file retrieval path.

Check HTTP status and native business status. MiniMax speech responses carry `base_resp`, audio data, and optional usage/audio metadata; successful HTTP transport alone is not successful synthesis. Strictly decode hex and reject missing, empty, invalid, or inconsistent required audio. [MM-SPEECH]

For streamed upstream responses, implement a bounded incremental event parser. Network chunks are not event boundaries. Test split JSON, split delimiters, CRLF, multiple events per chunk, large events, premature EOF, and late business errors.

Verify whether the deployed API's final event contains only final metadata, a final delta, or a complete aggregated audio copy. Use a documented option to suppress aggregate duplication when available, or classify events according to the verified protocol. Do not append the same complete audio twice. Do not use generic byte-equality deduplication, which could delete legitimate repeated audio. Pin fixtures to the verified behavior and record the evidence.

Metadata names and units must be normalized explicitly. Preserve missing usage as unknown; do not infer paid consumption solely from a successful HTTP status.

### 5.3 Transcription translation

Build a fresh multipart request using the prepared file, resolved native model, validated language header, and native `response_format=json`. Derive the filename and content type from the actual prepared media. Use a real multipart encoder; do not concatenate file contents into one large binary.

Enforce the upload limit on the transformed file as well as the original upload. Preserve authorization isolation: only the selected upstream credential may leave Backplane, never the client's bearer token or unrelated default headers.

Validate that a successful upstream response contains a string transcript. Map it to the selected public result format. Do not fabricate timestamps, detected language, confidence, token counts, or speakers.

### 5.4 Credentials, billing, and retries

Expose separate labels for subscription credentials and pay-as-you-go credentials, while storing only vault references. The user's subscription does not prove that this particular key, region, or model is authorized. Provide separate explicit TTS and ASR test actions; never synthesize/transcribe automatically during startup or routine health polling.

Do not automatically switch credentials, regions, providers, or billing modes. MiniMax documents that Subscription Keys and ordinary API Keys differ, and that eligible overflow can consume purchased Credits under the same Subscription Key. A local no-fallback rule cannot guarantee zero Credits usage. Explain this in the admin UI and operational documentation. [MM-BILLING]

Disable automatic retries for billable audio POST requests by default, including HTTP-library retries. A timeout after dispatch can represent uncertain execution. Record that uncertainty rather than retrying and possibly charging twice. Cancellation is best effort after the upstream accepted work; do not promise a refund or zero usage.

Reuse existing quota monitoring only where its source actually supports the selected subscription. Show unavailable/stale data accurately. Do not rebuild subscription billing dashboards or turn a legacy Coding Plan balance into a claim about audio entitlement as part of this task.

## 6. Media conversion engine

### 6.1 Pure planning

Produce a deterministic plan from source media metadata, target profile, provider capabilities, and policy. The possible strategies are passthrough, remux, or transcode. Keep executable invocation separate from this decision.

Prefer passthrough when bytes already satisfy the target. Prefer remuxing when the encoded audio is compatible and only its container must change. FFmpeg streamcopy can change packaging without a decode/encode cycle. [FFMPEG-MAIN]

Do not force every TTS response through MP3. For a required conversion, request a documented lossless upstream format when available, then encode the target once. Do not assume every native format is available with every model, streaming mode, or voice option; encode those combinations as capabilities.

For ASR, use a conservative provider-compatible lossless container such as FLAC or PCM WAV when direct delivery/remuxing is not verified. Example: test WebM/Opus to Ogg/Opus remuxing only for a provider binding verified to accept that combination; otherwise decode to the conservative target. Do not guess that every `.m4a` codec is supported because one M4A variant is listed upstream.

Preserve sample rate, channel information, duration, and silence unless a documented configured policy requires a transformation. Never change playback speed, trim silence, concatenate tracks, or normalize loudness as a hidden side effect. Channel mixing or resampling must be an explicit recorded plan step. If a preserving conversion cannot meet upstream bounds, return a clear error rather than quietly degrade or truncate.

### 6.2 External process ownership and safety

Use administrator-controlled, validated executable paths and argument arrays, never shell interpolation or caller-supplied FFmpeg flags. Launch ffprobe and FFmpeg with minimal environments and no API keys. Keep stderr separate from audio stdout; bound diagnostic capture and redact local paths in public errors.

Restrict protocol and demuxer access to the required formats. For media probing/conversion, reject playlists, concat scripts, network references, and nested external-resource formats. FFmpeg's protocol whitelist is one tool, not a complete sandbox. Restrict filesystem visibility and deny network access with platform-appropriate confinement where available; document what the deployment actually enforces. Test both probing and conversion against local-file and network-reference attacks. [FFMPEG-PROTOCOLS]

Run as a non-root user. Bound process concurrency, threads, input/output, elapsed time, and diagnostic buffers. Keep media-process admission separate from billable upstream concurrency. Reject excess work promptly with a retryable capacity error rather than retaining unlimited uploaded files in a queue.

A request owns its upstream operation, conversion process, handles, and temporary paths. Monitor the request owner. On cancellation, timeout, crash, or shutdown, cancel the upstream, terminate and reap the media process and any children, close handles, and release reservations exactly once. Prove this behavior; do not assume `Port.close` necessarily implements every required OS-process cleanup guarantee.

### 6.3 Temporary storage

Use a private temporary root with server-generated names, restrictive permissions, disk reservations, and per-request directories. Never use an uploaded filename as a filesystem path. Do not serve these directories as static assets.

Handle Plug upload ownership explicitly before passing a file to a process that may outlive the upload owner. Avoid gratuitous copies, but prefer correctness over retaining a path whose owner can delete it.

Clean up after success, validation failure, upstream failure, conversion failure, cancellation, owner death, and restart. Add a bounded orphan janitor with ownership/age checks that cannot delete another active request's files. Use atomic finalization for buffered outputs. Ensure file-backed response sending has finished before unlinking a file still needed by the server adapter.

### 6.4 Binary HTTP streaming

Deliver incremental MP3 when the upstream supports it. Deliver incremental PCM when a verified native or transcoded path supports it; otherwise document buffering for that profile. Other formats may stream only when the muxer can produce a correct incremental representation. Finalize WAV on a bounded seekable file rather than returning an invalid or misleading header.

Use one persistent decoder/encoder context for a converted stream. Feed sequential chunks into it; never launch FFmpeg separately for each chunk and concatenate independent files.

Propagate bounded demand through client output, media process, and upstream reads. Draining upstream into an unlimited mailbox is not backpressure. Include a slow-reader test and explicit high-water limits.

Validate local encoder availability and the initial upstream response before committing successful audio headers. Before commitment, return structured errors. After commitment, abort the connection on failure and record a failed/incomplete stream; never append JSON to audio or attempt to change an already-sent status. Incomplete finalization is not a successful operation.

## 7. Errors, authorization, and observability

Preserve `ResourceAuthPlug`, existing `/v1` scopes, client token behavior, and the trusted admin boundary. Initially use the existing `llm::invoke` authorization for both audio operations. Do not change generic authentication behavior merely to make one audio response look different. Add endpoint tests for OAuth/client/legacy behavior and insufficient scopes. [REPO-AUTH]

Audio validation and upstream failures should use the familiar OpenAI error envelope with `message`, `type`, `param`, and `code`. Sanitize provider details. Suggested status mapping:

| Condition | Status |
| --- | --- |
| Malformed request, unsupported option, corrupt/no-audio media, duration excess | 400 |
| Invalid/insufficient client authorization | Existing 401/403 behavior |
| Unknown or disabled public model | 404 |
| Known model incompatible with the requested audio operation | 400 |
| Upload/body exceeds configured byte limit | 413 |
| Unsupported request or media type | 415 |
| Caller/provider rate limit or media admission exhausted | 429 with a safe `Retry-After` when meaningful |
| Invalid upstream response, upstream service failure | 502 |
| Disabled/unconfigured audio capability or missing encoder | 503 |
| Upstream/conversion/overall deadline exceeded | 504 |

Do not expose an upstream credential failure as though the client's Backplane token were invalid. Provider quota errors may be mapped to a documented quota-specific 429 without exposing raw responses.

Reuse `AccessEvent` and existing bounded observability sinks. Add operation labels `audio.speech` and `audio.transcriptions`. Record requested/resolved model, provider, credential reference identifier, strategy, media metadata, byte counts, queue/probe/conversion/first-byte/total timing, terminal outcome, safe error code, and upstream trace ID when available.

Keep audio seconds, usage characters, bytes, and token counts as distinct units. Do not force audio usage through a chat-token parser or show unavailable usage as zero. No raw audio, input text, transcript, authorization header, full multipart body, or provider hex payload should be logged by default. Avoid sensitive or high-cardinality metric labels.

Exactly one terminal access event must describe each accepted operation, including cancellation and late stream failure. Preserve existing persistence toggles and writer-health behavior.

## 8. Admin, packaging, and deployment

Add a **Llama → Audio** page in the existing admin navigation, reusing DuskMoon patterns. It must configure the enabled state, provider/model bindings, credential references and billing labels, voice aliases, media limits, and allowed operations. Public model aliases remain compatible with the existing alias management approach.

Show a capability/readiness panel for ffprobe, FFmpeg, required decoders/encoders/muxers, temporary-directory permissions, and audio binding validity. Checking only `ffmpeg -version` is insufficient. Missing a required codec must prevent this feature from being reported as fully ready, not silently remove a promised format.

Provide explicitly initiated TTS and ASR test actions with cost warnings and separate results. Playback/upload examples must use the same domain orchestration and media policies as public traffic, not a second ad hoc MiniMax implementation. Keep secrets and temporary paths out of the rendered UI and audit payloads.

Add FFmpeg/ffprobe to the runtime Docker stage and the repository's current Nix/devenv development configuration. Ensure the selected package builds include the required capabilities, including Opus and AAC. Verify supported release architectures rather than assuming one local binary represents all images. Keep versions reproducible within the existing packaging approach.

A missing media dependency should disable audio readiness, not crash unrelated LLM/MCP services. Do not add media-process requirements to `host_agent`. Document binary-path overrides as boot/environment concerns, and operational audio settings as database-managed concerns.

Document reverse-proxy body/time limits, buffering behavior for binary streaming, writable temporary storage, cleanup after restart, and feature-disable rollback. Do not replace the user's existing Caddy/mTLS configuration. Do not store media as permanent application data.

## 9. Implementation sequence and gates

These are dependent implementation checkpoints, not separate releases that permit dropping formats.

| Step | Work | Gate before proceeding |
| --- | --- | --- |
| 0. Inspect | Read repository instructions; inspect routing, provider schemas, settings, process/HTTP primitives, and test layout; verify official native contracts | Record the actual checkout, reused modules, and any contract differences without changing fixed scope |
| 1. Contract and configuration | Request/error types, route-aware parsers, audio bindings, migrations, aliases, operation checks, voice policy | Pure validation/resolution tests; auth-before-upload integration test; chat parser behavior unchanged |
| 2. Media engine | Probe, deterministic plans, bounded runner, temporary-file ownership, packaging capability checks | Real local media tests for all target codecs and representative inputs; cancellation and quota tests |
| 3. MiniMax and public endpoints | Both native adapters, both public endpoints, binary response generation, transcription normalization | Local mock-upstream tests through the actual public endpoint; no client/provider credential leakage |
| 4. Streaming and failures | Incremental MP3, additional verified streaming paths, backpressure, late errors, uncertain execution handling | Slow-reader, split-event, duplicate-final-payload, disconnect, timeout, and no-orphan tests |
| 5. UI and observability | Audio admin page, readiness, explicit test actions, usage dimensions, secret/content redaction | LiveView/config/audit tests, exactly-once terminal events, no fabricated usage |
| 6. Release verification | Complete format matrix, SDK conformance, runtime image verification, documentation, rollback | Section 10 passes; distinguish offline verification from any unperformed live-account verification |

After contracts are stable, media, adapter, and UI work can proceed in parallel with disjoint ownership. Serialize shared schema/router edits and final integration. Do not parallelize by duplicating providers, configuration stores, or media runners.

## 10. Required test matrix and definition of done

### A. Real codec tests

Use deterministic generated media fixtures and a small legally usable speech sample for optional recognition checks. Local FFmpeg/ffprobe tests must run in the designated integration CI job; do not skip them silently when binaries are absent.

Test every TTS format with actual media bytes: correct MIME/container/codec, nonempty decode, expected duration within encoding tolerance, and no duplicated/truncated tail. For raw PCM, assert mono 24 kHz s16le geometry and frame alignment using explicit decoder parameters. For WAV, verify finalized header/data sizes. Decode Opus and AAC, not merely inspect their filenames.

Test every ASR extension with representative valid combinations, including WebM/Opus, Ogg/Opus, Ogg/Vorbis, MP4/AAC, M4A/AAC, M4A/ALAC, FLAC, MP3, MPGA audio, MPEG program-stream audio, and PCM WAV. The declared input contract requires actual handling of all nine format families, not renamed copies of one fixture.

Validate passthrough, remux, and transcode plans separately. Include a case where transcoding increases byte size beyond the upstream bound. Include forged-duration/size metadata, truncated files, no audio track, ambiguous tracks, and wrong or generic upload MIME types.

### B. Provider and HTTP conformance

Use a local HTTP mock provider that checks real request methods, paths, multipart headers/boundaries, field values, and actual prepared file bytes. Cover native errors under HTTP 200, ordinary error statuses, invalid JSON, invalid hex, empty audio, missing transcript, and bounded event parsing.

Run smoke tests with a pinned official OpenAI SDK against the real Backplane endpoint and mock provider. Exercise `audio.speech.create`, binary streaming response consumption, and `audio.transcriptions.create` with both result formats. These are test/documentation dependencies, not a Python service in production.

Verify missing/wrong authorization, insufficient scope, wrong content type, malformed multipart, duplicate critical fields/files, unsupported parameters, all model/voice error cases, and request IDs. Assert that unauthorized uploads do not create application upload files, launch media processes, or contact the upstream.

### C. Lifecycle and resource behavior

Test a slow reader, client disconnect before and after response commitment, stalled upstream, stalled media process, worker crash, owner death, timeout, subprocess failure, disk exhaustion, and application restart cleanup. Assert bounded queues/storage, no surviving processes or leaked files/reservations, and a single correct terminal event.

Add negative fixtures attempting remote-resource resolution and local-file references; both probe and conversion must reject them without reading unintended resources. Test filenames and parameter values that would be dangerous under shell interpolation.

### D. Regression and delivery checks

Verify existing chat, responses, embeddings, model listing, Codex catalogs, provider settings, authentication, and multipart-unrelated routes remain intact. Use each app's own test helpers. Check migrations against existing data and feature-disabled startup.

Run applicable scoped tests, warnings-as-errors compilation, formatting, strict linting, type checks, CI workflow contracts, asset build, and gateway release/image verification following repository guidance. Record exact commands and results. Report environment limitations and unrelated baseline failures without misrepresenting them as audio regressions or passing tests.

A live MiniMax smoke test is opt-in and requires an explicitly supplied/selected authorized credential and permission to spend quota. Never extract an arbitrary production secret or run paid tests automatically. Without that access, finish the implementation and offline conformance tests, provide the exact operator-run validation procedure, and label live account entitlement/end-to-end verification as not performed.

**Done means:** both endpoints work through the real public entrypoint; all six TTS outputs and nine ASR input families are covered; media conversion and lifecycle tests are real; configuration and image dependencies are shipped; unsupported semantics are explicit; no Realtime API was introduced; existing gateway behavior is preserved.

## 11. Expected Codex handoff

Implement the work rather than responding with another plan. Deliver a final report with the changed areas, migrations and operator configuration, tested format/codec matrix, exact verification results, streaming versus buffered profiles, remaining compatibility limits, any unperformed live validation, and rollback steps.

Do not call the feature fully OpenAI-compatible, production-verified, or subscription-authorized beyond the evidence. Do not leave any required format as a TODO while reporting completion. A missing optional ASR subtitle/SSE feature is outside scope; a missing AAC encoder, broken WebM upload, or absent process cleanup is not.

## 12. Reference register

External API facts above were checked on 2026-10-01. Revalidate mutable vendor details during implementation. The remainder of this document specifies Backplane engineering requirements and proposed defaults, not vendor guarantees.

| Reference | Source |
| --- | --- |
| OAI-SPEECH | `https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create` |
| OAI-TTS-GUIDE | `https://developers.openai.com/api/docs/guides/text-to-speech` |
| OAI-ASR | `https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create` |
| OAI-ASR-GUIDE | `https://developers.openai.com/api/docs/guides/speech-to-text` |
| MM-SPEECH | `https://platform.minimax.io/docs/api-reference/speech-t2a-http` |
| MM-ASR | `https://platform.minimax.io/docs/api-reference/speech-to-text` |
| MM-ASR-GUIDE | `https://platform.minimax.io/docs/guides/speech-to-text` |
| MM-BILLING | `https://platform.minimax.io/docs/token-plan/faq` |
| FFMPEG-MAIN | `https://ffmpeg.org/ffmpeg.html` |
| FFMPEG-PROTOCOLS | `https://ffmpeg.org/ffmpeg-protocols.html` |
| PLUG-PARSERS | `https://plug.hexdocs.pm/Plug.Parsers.html` — consult the repository-pinned version |

Repository references are pinned to `a4b5944b3d85891dfc6a42f82f6931447494778e`:

| Reference | Repository path |
| --- | --- |
| REPO-BASELINE | Commit metadata for the reviewed baseline |
| REPO-AGENTS | `AGENTS.md` |
| REPO-ENTRY | `apps/backplane_api/lib/backplane/api/endpoint.ex`; `apps/backplane_llama/lib/backplane/llm/proxy_plug.ex` |
| REPO-ROUTER | `apps/backplane_llama/lib/backplane/llm/router.ex` |
| REPO-PROVIDERS | `apps/backplane_llama/lib/backplane/llm/provider_api.ex`; `provider_model.ex`; `model_resolver.ex` in the same directory |
| REPO-AUTH | `apps/backplane_llama/lib/backplane/llm/resource_authorization.ex`; `credential_plug.ex` in the same directory |
| REPO-DOCKER | `Dockerfile` |

Repository: `https://github.com/gsmlg-opt/backplane`
