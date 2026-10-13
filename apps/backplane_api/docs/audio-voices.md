# Audio voice discovery API

`GET /v1/audio/voices` lists speech voices advertised by Backplane's enabled audio providers. It is served on the **public API** endpoint, alongside `/v1/audio/speech`. The development origin is `http://localhost:4220`; use the deployment's public API origin in production. A client can populate its voice selector from this response and send the selected `id` in a speech request.

This is a **Backplane extension**, not an official OpenAI voice-list API. OpenAI's `POST /v1/audio/voices` creates custom voices; it is a different operation. The standard OpenAI SDK has no built-in method for this GET. Use an HTTP client for discovery, then the speech API or its compatible SDK method for synthesis.

The served public guide is available at `/docs/llm`. For audio installation, provider setup, media formats, and operational limits, see [Audio API operations](../../../docs/audio.md).

## Authentication

Send `Authorization: Bearer <BACKPLANE_TOKEN>`. Use a Backplane client bearer token or an OAuth access token issued for the `/v1` resource. Do not send a MiniMax API key to this endpoint; provider credentials stay inside Backplane.

DB clients and OAuth clients need `llm::models` for voice discovery. Speech synthesis separately requires `llm::invoke`. Legacy bearer tokens retain the existing unrestricted compatibility policy. Requests without credentials follow the existing local-development policy: open access is allowed only when the resource has no enabled OAuth client, no DB clients exist, and no legacy token is configured. Invalid supplied credentials are rejected even in an otherwise open deployment.

## Request

```http
GET /v1/audio/voices?model=minimax-audio%2Fspeech-2.8-turbo
Authorization: Bearer <BACKPLANE_TOKEN>
```

| Query parameter | Required | Meaning |
| --- | --- | --- |
| `model` | No | A nonempty public speech model alias or `provider/model` identifier. Backplane resolves it using the same speech-model rules as synthesis and returns voices for that provider. |

Omitting `model` lists voices for providers with an enabled speech binding, an enabled model, and an enabled, non-deleted provider. Providers with only transcription bindings are excluded. A provider with several eligible speech models contributes its voices once. Results do not enumerate models; use `/v1/models` to discover public model identifiers.

Use query encoding instead of constructing a URL from an unescaped model value:

```sh
curl --get 'http://localhost:4220/v1/audio/voices' \
  -H 'Authorization: Bearer <BACKPLANE_TOKEN>' \
  --data-urlencode 'model=minimax-audio/speech-2.8-turbo'
```

To list all eligible speech providers:

```sh
curl 'http://localhost:4220/v1/audio/voices' \
  -H 'Authorization: Bearer <BACKPLANE_TOKEN>'
```

## Response

A successful request returns HTTP 200 and a JSON list envelope:

```json
{
  "object": "list",
  "data": [
    {
      "id": "alloy",
      "object": "audio.voice",
      "name": "甜美女性音色",
      "language": "中文 (普通话)",
      "provider": "minimax-audio",
      "native_id": "female-tianmei",
      "type": "alias"
    },
    {
      "id": "female-tianmei",
      "object": "audio.voice",
      "name": "甜美女性音色",
      "language": "中文 (普通话)",
      "provider": "minimax-audio",
      "native_id": "female-tianmei",
      "type": "system"
    }
  ]
}
```

This shortened example assumes native voices are allowed and the operator explicitly configured `alloy` as an alias for `female-tianmei`. The default MiniMax setup does not create that alias. Additional system voices may appear in an actual response.

| Field | Type | Meaning |
| --- | --- | --- |
| `object` (envelope) | string | Always `list`. |
| `data` | array | Voice rows sorted by `provider`, then `id`. An empty list is valid. |
| `id` | string | Public voice identifier to send as `voice` to `/v1/audio/speech`. |
| `object` (row) | string | Always `audio.voice`. |
| `name` | string | Display name from the system catalog for the native voice or known alias target; otherwise the public alias name. |
| `language` | string or null | Human-readable catalog language label, not a guaranteed ISO language code. Null when catalog metadata is unavailable. |
| `provider` | string | Backplane provider name. Use a speech model that resolves to this provider. |
| `native_id` | string | Provider-native voice identifier, including an alias's configured target. |
| `type` | string | `system` for a catalog voice or `alias` for a configured public voice alias. |

The same `id` can occur under different providers. Treat `(provider, id)` as the identity when showing an unfiltered list; filtering by the selected speech model avoids provider ambiguity.

## Voice policy and synthesis

Native system rows are listed only when the provider's voice policy has `allow_native: true`. Configured aliases are listed regardless of that setting. An alias overrides a system row with the same public `id` for the same provider. An alias targeting an account-specific or otherwise unknown native voice can still appear with its alias name and `language: null`; this does not enumerate the account's custom voices.

Speech resolves a configured alias first. If no alias matches and `allow_native` is true, it forwards any nonempty native voice ID, including one outside the local discovery catalog. When native voices are disallowed, an unknown public voice fails with `400 unknown_voice`. Discovery is therefore a list of advertised and configured choices, not an exhaustive list of every native ID the provider could accept.

There is no automatic mapping from OpenAI voices such as `alloy` to MiniMax voices. Configure a voice alias explicitly or use a returned native system `id`.

After choosing `female-tianmei` for a model belonging to `minimax-audio`, send:

```sh
curl 'http://localhost:4220/v1/audio/speech' \
  -H 'Authorization: Bearer <BACKPLANE_TOKEN>' \
  -H 'Content-Type: application/json' \
  -d '{"model":"minimax-audio/speech-2.8-turbo","input":"Hello from Backplane","voice":"female-tianmei","response_format":"mp3"}' \
  --output speech.mp3
```

This POST performs synthesis and may incur provider charges. The preceding discovery GET does not.

## Errors and empty results

Discovery uses the existing `/v1` authentication and scope enforcement. Missing or invalid credentials return HTTP 401 when authentication is required; insufficient scope returns HTTP 403. Once authorized, audio discovery uses the existing audio error envelope:

```json
{
  "error": {
    "message": "Model not found",
    "type": "invalid_request_error",
    "param": "model",
    "code": "model_not_found"
  }
}
```

| HTTP status | Error code | Condition |
| --- | --- | --- |
| 400 | `invalid_parameter` | A supplied `model` is empty or is not a string, for example `model[]=...`. |
| 400 | `operation_mismatch` | The resolved model does not support speech, for example a transcription-only model. |
| 400 | `alias_loop` | Model alias resolution encounters a loop. |
| 404 | `model_not_found` | The supplied model is unknown, its provider/model is disabled or deleted, or its speech binding is disabled. |
| 503 | `audio_disabled` | The global Audio feature is disabled. |

When Audio is enabled and no eligible speech providers or advertised voices exist, the result is HTTP 200 with `{"object":"list","data":[]}`. A provider without a voice policy contributes no voices. These empty results are distinct from requesting an unknown or disabled model.

## Catalog source and limits

The current system catalog is a local snapshot of the [official MiniMax system voices](https://platform.minimaxi.com/docs/faq/system-voice-id.md), dated **2026-10-06**, shared with the admin speech preview. Configured voice aliases come from Backplane's provider voice policies.

Discovery makes no upstream provider requests, reads no vault secrets, and incurs no provider usage charges. It does not call MiniMax's per-credential voice-management API, discover account-specific cloned or generated voices, or verify a credential's entitlement to a voice. A listed voice does not guarantee provider availability, region compatibility, model entitlement, or synthesis readiness. The chosen speech operation still performs its normal validation and provider call.
