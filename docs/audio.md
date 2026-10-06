# Audio API operations

Backplane exposes OpenAI-shaped `POST /v1/audio/speech` and `POST /v1/audio/transcriptions` on the **public** endpoint. MiniMax is the initial native provider. Audio is disabled by default. The trusted admin endpoint is separate; restrict it at the network boundary. Public OAuth and DB clients need the existing `llm::invoke` scope; legacy bearer-token compatibility follows the existing `/v1` rules.

Each accepted speech or transcription operation emits exactly one terminal access event, including cancellation and late stream failure. Preview operations measure server-side execution and collection; they do not establish browser receipt or playback. Audio seconds, bytes, characters, and token counts remain separate units; unknown token counts stay unavailable (`nil`). For multipart ASR, `request_bytes` counts uploaded file bytes read, including bytes from partial or rejected uploads, and excludes multipart framing; `upstream_bytes` records the prepared file bytes for upstream upload. Logs contain safe metadata only, never secrets or audio/text content.

## Install and configure

1. Install the gateway release with FFmpeg, ffprobe, and the `backplane-audio-launcher` built for that host architecture. The Docker runtime stage installs `ffmpeg`; `devenv.nix` provides `ffmpeg-full`. Run as a dedicated non-root user. Do not copy a macOS launcher into a Linux image or use CPU emulation as proof of native seccomp compatibility. The standalone host-agent release has no audio dependency. Run gateway image build and runtime tests on remote Linux or CI, not on this local machine.
2. Apply the database migration before enabling audio: `mix ecto.migrate` in development, or `/app/bin/backplane migrate` in the container release (adjust the path for a non-container release). The migration creates `llm_audio_bindings`; it does not create models, aliases, credentials, or enabled bindings.
3. In **System → Credentials**, store the selected MiniMax token as a vault credential of kind `llm` or `service` with API-key auth type. The Audio page uses the credential name and never asks for or displays the plaintext token.
4. Under **Llama → Audio** (`/llama/audio`), select that credential and its authorized API region, then **Save audio setup**. Region selection is required: Global uses `https://api.minimax.io`, and China uses `https://api.minimaxi.com`. The built-in preset creates the dedicated `minimax-audio` provider and its speech/transcription bindings without contacting MiniMax. It does not change chat providers, create public aliases, or enable audio. The Audio page provides no editor for custom bindings, voice policies, media limits, or public aliases; those remain backend-managed configuration. If existing audio records conflict with the preset, setup stops and the custom route configuration needs operator attention. If saving the voice policy fails after route creation, the page reports that audio voice configuration needs attention; the route change is still audited.
5. Use `minimax-audio/speech-2.8-turbo` for speech and `minimax-audio/asr-1.0` for transcription. The admin speech and transcription previews suggest enabled models and public aliases for their respective operations, including before audio is enabled; the model inputs remain editable. Speech requests must supply a `voice` containing a native MiniMax voice ID. The admin speech preview offers searchable suggestions from the official system voices and starts with no voice selected. Choosing a suggestion fills its native ID; arbitrary text is rejected before preview dispatch. The preset enables native voice IDs for its dedicated provider only when that provider has no voice policy; it preserves any existing voice policy and does not supply a default voice. Optional public aliases are managed through existing model-alias configuration.
6. Check readiness, then enable audio with the separate Audio service control. Keep the feature disabled until public endpoint, media, admin, and observability checks have passed in the target deployment. Clicking **Run speech preview** starts speech without an additional confirmation; transcription previews retain their explicit charge acknowledgment. The transcription form stays available: select a file to admit its upload, then run the preview. No capacity is reserved while the page is idle. Selected files expire within two minutes (or the configured shorter request deadline); after completion, rejection, cancellation or expiry, select another file in the same form.

Backend-managed binding capabilities are explicit. Speech bindings can constrain `native_formats`, `output_formats`, `speed_min`, `speed_max`, and `streaming`; transcription bindings can constrain `input_formats` and `languages`. An unavailable format or encoder is an error, not permission to silently change the caller's output format. Use only verified combinations for the selected model and region. There is no automatic credential, region, or provider fallback and no automatic retry of billable audio POSTs.

The native launcher path and media executable paths are **boot/environment** concerns: `BACKPLANE_AUDIO_LAUNCHER_PATH`, `BACKPLANE_AUDIO_FFMPEG_PATH`, and `BACKPLANE_AUDIO_FFPROBE_PATH` may override the packaged absolute binaries. `BACKPLANE_AUDIO_TEMP_DIR` selects the private temporary root. Restart after changing these paths or upgrading supervision/native binaries. The enable switch, policy, voice aliases, bindings, and credential references are database-backed settings managed through backend operations. Do not put plaintext keys in a binding, TOML file, command line, or logs.

## Public contract

Speech accepts JSON with required nonempty `model`, `input`, and `voice`. The input limit is **4,096 Unicode scalar values**, in addition to the JSON body-byte limit. `response_format` defaults to `mp3`; `stream_format` may be absent or `audio`. `speed` defaults to `1.0`, and the selected binding can narrow the accepted range (MiniMax binding defaults are `0.5` to `2.0`; the public parser alone accepts `0.25` to `4.0`). Nonempty `instructions`, custom voice objects, `stream_format=sse`, and unknown meaningful options are rejected. No `stream=true` field is required for ordinary binary HTTP streaming.

| `response_format` | Bytes delivered | Content type | Delivery |
| --- | --- | --- | --- |
| `mp3` | MPEG Layer III | `audio/mpeg` | Incremental binary HTTP only for a verified native streaming binding; otherwise buffered |
| `opus` | Ogg/Opus | `audio/ogg` | Buffered |
| `aac` | ADTS AAC | `audio/aac` | Buffered |
| `flac` | FLAC | `audio/flac` | Buffered |
| `wav` | PCM in a finalized RIFF/WAVE container | `audio/wav` | Buffered |
| `pcm` | Headerless signed 16-bit little-endian PCM, **24,000 Hz, mono** | `application/octet-stream` | Buffered; supply the geometry to players/importers |

The response contains actual audio bytes, never provider hex, JSON, or a hosted URL. Buffered delivery has a known length and a safe generated download name. A streamed response commits HTTP success only after initial upstream audio validation; a later failure or disconnect aborts the stream rather than appending a JSON error. Proxies must permit binary chunk delivery without response buffering or compression that defeats backpressure. PCM is not directly playable by many browsers; use the stated geometry.

Transcription accepts multipart form data with required `model` and one `file`. `response_format=json` (default) returns a minimal `{"text":"..."}` object; `response_format=text` returns UTF-8 plain text. Optional `language` is validated against the selected binding and sent as a MiniMax **header**; omit it for automatic recognition. `stream` may be absent or false; ASR SSE is unsupported. Meaningful `prompt`, `temperature`, timestamp, speaker, chunking, and log-probability options are rejected, as are `verbose_json`, `srt`, `vtt`, and `diarized_json`. Null or empty optional values are treated as absent where documented; a nonempty instruction is never silently ignored.

The public ASR extension families are `flac`, `mp3`, `mp4`, `mpeg`, `mpga`, `m4a`, `ogg`, `wav`, and `webm`. The media test matrix contains these **11 representative combinations**, which must pass on the deployment architecture before claiming the input contract:

| Extension | Representative codec/container |
| --- | --- |
| `flac` | FLAC/FLAC |
| `mp3` | MP3/MP3 |
| `mpga` | MP3/MP3 |
| `mp4` | AAC/MP4 |
| `m4a` | AAC/M4A |
| `m4a` | ALAC/M4A |
| `mpeg` | MP2/MPEG program stream |
| `ogg` | Opus/Ogg |
| `ogg` | Vorbis/Ogg |
| `webm` | Opus/WebM |
| `wav` | PCM s16le/WAV |

Uploaded MIME and filename are hints; content structure, track selection, and bounded decode decide acceptance. Video-only, ambiguous multi-audio-track, corrupt, truncated, encrypted, and external-reference media must fail before provider use. Raw `.pcm` is **not** an ASR upload type; wrap known raw samples in WAV. The current MiniMax transcription adapter prepares FLAC for upstream submission; it does not offer a configured passthrough selection. Conversion must not silently truncate, change speed, or hide an upstream size/duration limit.

## Capacity, deadlines, and storage

Defaults in `llm.audio.policy` are per node, not cluster-wide quotas. The public file part is limited to **25,000,000 bytes** plus **65,536 bytes** of multipart overhead; speech JSON is limited to **65,536 bytes**. ASR duration is at most **500 seconds** and prepared upstream upload at most **50,000,000 bytes**. Probe and conversion deadlines are **10** and **120 seconds**; the overall audio request deadline is **600 seconds**. Output and provider response caps are **100,000,000 bytes** each, provider SSE event cap **1,000,000 bytes**, and temporary storage reservation cap **500,000,000 bytes**. At most **2** uploads, **4** operations, and **2** media processes are admitted per node. The default decode ceilings are 96 kHz, 2 channels, and 96,000,000 samples. Policy validation prevents enlarging the verified 500-second/50 MB upstream limits.

Set ingress and reverse-proxy request-body limits above the intended multipart envelope, with a coordinated deadline above the gateway's configured audio deadline and time for cleanup. Disable proxy buffering for incremental MP3 where possible; otherwise clients may see a buffered response despite the gateway's incremental delivery. Keep transport/storage limits at the edge as well as in the app. Reserve writable, private space for both Plug uploads and `BACKPLANE_AUDIO_TEMP_DIR`; do not expose either as static content or permanent media storage. Monitor disk availability and per-node admission. The full readiness check covers the 11 representative ASR fixtures, not every possible codec variant. A real 16 MiB exhaustion check passed the fail-closed readiness and gateway-liveness assertions; the exercised check also verified retained temporary files, HTTP 503, rate-limiter responsiveness, and disk detachment.

The media session owns private 0700 per-request directories and keeps buffered files until synchronous HTTP delivery finishes. Cancellation, timeout, owner death, or shutdown triggers bounded native cleanup. If guardian cleanup is uncertain, the directory and capacity are **quarantined** rather than immediately reused or deleted. On restart, the janitor removes only safely identifiable old work after its age/ownership checks; an unaccounted old request tree can fail readiness closed. Investigate quarantine and disk use before re-enabling. A client cancellation is best effort after MiniMax accepted a request: it does **not** promise a refund or zero usage. A timeout after dispatch may be billed; never retry it automatically without operator review.

The native launcher enforces different confinement by platform. On Linux it requires Landlock ABI 3+, architecture-checked seccomp, an unprivileged UID, restricted executable/library/file access, denied network/process creation, and kernel address-space/CPU/file/fd/core limits; missing confinement fails closed. The guardian checks each confined worker's thread group through `/proc` every approximately 20 ms and terminates it above 64 threads; unavailable thread observation fails closed. Other processes with the same UID, including BEAM, do not consume that worker budget. On macOS it uses `sandbox-exec` with restricted file/Mach/network access and a guardian's sampled RSS/thread checks because usable `RLIMIT_AS` is unavailable. Thread sampling on both platforms, and the macOS 2 GiB RSS check, can briefly overshoot their thresholds. Run the launcher self-test and real codec tests on each release architecture; a binary existing on disk is not readiness proof.

## Charges and optional live validation

MiniMax distinguishes Subscription Keys from ordinary API Keys. An eligible Subscription Key can consume purchased **Credits under the same key** after included allowance is exhausted. Backplane does not switch keys, regions, or providers after failure. Native TTS and ASR tests are separate paid actions. Do not run them at startup or from periodic health checks. No live MiniMax call was made to prepare this guide.

For a deliberate one-call smoke check, use a verified MiniMax origin, model, voice, and small sample. The following examples keep the key out of command arguments and shell history; `curl` reads it from a transient config pipe. They write private local results and make **paid** calls only when an operator runs them. Do not add `-v` or shell tracing. Set the origin explicitly for the selected key's region; do not substitute hostnames automatically.

```sh
umask 077
MM_ORIGIN='https://<verified-MiniMax-origin>'
MM_TTS_MODEL='speech-2.8-turbo'
MM_VOICE='<verified-native-voice-id>'
printf 'Selected MiniMax key: ' >&2; read -rs MM_KEY; printf '\n' >&2
printf '{"model":"%s","text":"Audio smoke test.","stream":false,"output_format":"hex","voice_setting":{"voice_id":"%s","speed":1},"audio_setting":{"format":"mp3","sample_rate":24000,"channel":1}}' "$MM_TTS_MODEL" "$MM_VOICE" > ./minimax-tts-request.json
curl --fail-with-body --silent --show-error --max-time 120 \
  --config <(printf 'header = "Authorization: Bearer %s"\n' "$MM_KEY") \
  -H 'Content-Type: application/json' --data-binary @./minimax-tts-request.json \
  --output ./minimax-tts-response.json "$MM_ORIGIN/v1/t2a_v2"
unset MM_KEY
python3 -c 'import json; p=json.load(open("minimax-tts-response.json")); assert p["base_resp"]["status_code"] == 0; a=bytes.fromhex(p["data"]["audio"]); assert a; open("minimax-tts.mp3","wb").write(a)'
```

The ASR example uses a short verified FLAC file and asks MiniMax for native JSON. It does not send a language hint; add a validated `-H 'language: en'` only when that binding supports it. Treat the response as sensitive transcript data.

```sh
umask 077
MM_ORIGIN='https://<verified-MiniMax-origin>'
MM_ASR_MODEL='asr-1.0'
MM_SAMPLE='./short-verified-sample.flac'
printf 'Selected MiniMax key: ' >&2; read -rs MM_KEY; printf '\n' >&2
curl --fail-with-body --silent --show-error --max-time 120 \
  --config <(printf 'header = "Authorization: Bearer %s"\n' "$MM_KEY") \
  -F "model=$MM_ASR_MODEL" -F 'response_format=json' \
  -F "file=@$MM_SAMPLE;type=audio/flac" \
  --output ./minimax-asr-response.json "$MM_ORIGIN/v1/speech_to_text"
unset MM_KEY
python3 -c 'import json; p=json.load(open("minimax-asr-response.json")); assert isinstance(p["text"], str); print("ASR response shape valid")'
```

Delete the local request, audio, and response files after review. Live validation is intentionally separate from the offline mock provider and official OpenAI SDK conformance tests in CI.

To exercise the **full Backplane public endpoint** after the offline gates pass, use the pinned official SDK for exactly one speech request and one transcription request. This is a second, explicit **paid** check through Backplane; it is not part of startup or CI. The Backplane bearer token is read without echo into the Python process, never placed in shell history or command arguments. Choose a small, already verified audio sample and the public model/voice names configured above. The selected ASR result format is either JSON or text for this one call; testing both requires a separate paid call.

```sh
umask 077
python3 -m venv ./audio-sdk-venv
./audio-sdk-venv/bin/python -m pip install --disable-pip-version-check 'openai==2.26.0'
cat > ./operator-smoke.py <<'PY'
from getpass import getpass
from pathlib import Path
import subprocess
from openai import OpenAI

base = input('Configured Backplane public /v1 URL: ').strip().rstrip('/')
tts_model = input('Public speech model or alias: ').strip()
voice = input('Configured public voice or alias: ').strip()
asr_model = input('Public transcription model or alias: ').strip()
sample = Path(input('Small verified ASR sample path: ').strip())
result_format = input('ASR result format [json/text, default json]: ').strip() or 'json'
assert base.startswith(('https://', 'http://localhost:', 'http://127.0.0.1:')) and base.endswith('/v1')
assert result_format in ('json', 'text') and sample.is_file() and 0 < sample.stat().st_size < 1_000_000
token = getpass('Backplane bearer token: ')
client = OpenAI(base_url=base, api_key=token, timeout=120.0, max_retries=0)

output = Path('backplane-sdk-speech.mp3')
with client.audio.speech.with_streaming_response.create(
    model=tts_model, voice=voice, input='Audio gateway smoke test.', response_format='mp3'
) as response, output.open('wb') as target:
    for chunk in response.iter_bytes():
        target.write(chunk)
assert output.stat().st_size > 0
codec = subprocess.check_output(
    ['ffprobe', '-v', 'error', '-select_streams', 'a:0', '-show_entries',
     'stream=codec_name', '-of', 'default=noprint_wrappers=1:nokey=1', str(output)],
    text=True,
).strip()
assert codec == 'mp3', f'unexpected speech codec: {codec}'

with sample.open('rb') as source:
    result = client.audio.transcriptions.create(
        model=asr_model, file=source, response_format=result_format
    )
if result_format == 'json':
    assert isinstance(result.text, str)
else:
    assert isinstance(result, str)
print('One speech and one transcription response passed shape/codec checks.')
PY
./audio-sdk-venv/bin/python ./operator-smoke.py
```

Do not print the transcript or key during validation. Remove `operator-smoke.py`, `backplane-sdk-speech.mp3`, the sample copy if one was made, and `audio-sdk-venv` after review. A gateway timeout or cancellation after dispatch may still incur provider charges; do not auto-retry this smoke check.

## Rollback

Set `llm.audio.enabled=false` through **Llama → Audio** (or the database-backed Settings API) to stop new public audio resolution. Let in-flight requests finish or cancel them and verify cleanup/quarantine before removing writable storage. Preserve the binding migration and credential references for a reversible rollback; disabling audio does not revoke a MiniMax key, so revoke or rotate it separately if needed. Restart only when changing boot-time executable paths, packages, or supervision. Recheck ordinary chat, MCP, and host-agent health after the rollback.
