# LLM model metadata

`GET /v1/models` returns the OpenAI-compatible top-level `object: "list"` and
`data` fields. Authentication and the `llm::models` scope are unchanged.
Listing reads persisted discovery data; it does not poll providers during the
public request.

## OpenAI-compatible listing

Every `data` entry has a `metadata` object. Known fields are normalized to:

| Field | Type | Meaning |
| --- | --- | --- |
| `context_window` | Positive integer | Advertised context/input token limit |
| `max_output_tokens` | Positive integer | Advertised output token limit |
| `input_modalities` | String array | Advertised input modalities |
| `output_modalities` | String array | Advertised output modalities |
| `supports_tool_calling` | Boolean | Explicit tool support or lack of support |
| `supports_reasoning` | Boolean | Explicit reasoning support or lack of support |
| `supported_reasoning_levels` | Object array | Advertised efforts with `effort` and `description` |
| `default_reasoning_level` | String | Upstream-advertised default effort |
| `display_name`, `description` | String | Upstream model presentation metadata |
| `raw` | Object | Original persisted model/surface discovery metadata |

Unknown fields are omitted, not replaced by zero or a guessed capability.
Canonical fields supplied in stored model metadata take precedence over
provider-specific mappings. Surface metadata takes precedence over model
metadata for that surface. Aliases inherit the metadata of their currently
resolved target, not the capabilities of an arbitrary fallback.

## Provider-specific mappings

- **OpenRouter:** `context_length`, `top_provider.max_completion_tokens`,
  `architecture` modalities, and `supported_parameters`.
- **vLLM:** `max_model_len` from its OpenAI-compatible model listing.
- **SGLang:** `max_model_len` from the model list and explicit image/audio flags
  from supplemental `/model_info` discovery. Legacy servers can use `/get_model_info`.
- **Ollama:** supplemental `/api/show` model info, parameters, and capabilities.
  An explicit `num_ctx` takes precedence over architecture context capacity.
  Architecture capacity alone does not guarantee the server's runtime allocation.
- **Anthropic:** `max_input_tokens`, `max_tokens`, and advertised thinking,
  image-input, and effort capabilities. Zero-valued unavailable limits remain unknown.
- **Google AI Studio:** `inputTokenLimit`, `outputTokenLimit`, and `displayName`
  when supplied in discovery metadata.
- **Codex and other presets:** canonical advertised fields are retained;
  model names are never used to infer context, vision, tools, or effort levels.

Supplemental discovery is best-effort. A missing or failed metadata endpoint
does not invalidate a successful model listing or erase last-known supplemental
metadata. Existing generic and provider-scoped Codex discovery remain independent.

## Codex catalog

Codex descriptors are served separately by `GET /v1/codex/models`; they are not
part of the OpenAI-compatible `/v1/models` response. In the admin catalog,
select an enabled OpenAI Codex provider to import its complete upstream model
list. Each entry retains the exact upstream descriptor, including unknown fields,
and uses the upstream slug as its public ID. Refresh Models updates every saved
model from that provider's current snapshot while preserving enabled states; the
admin Preview JSON dialog shows the effective response. This endpoint publishes enabled
entries only while their Codex Responses routes remain available. See
[OpenAI Codex Responses proxy](llm-proxy-openai-codex.md) for its catalog and
provider-scoped route details.

## Local serving presets

All OpenAI-compatible provider presets default to both Chat Completions and
Responses, except `openai-codex`, which remains Responses-only. These defaults
apply when creating an API surface; saved protocol selections are not overwritten,
and operators can still disable Responses explicitly.

The provider creation catalog includes `vllm` and `sglang`. Their default
OpenAI bases are `http://localhost:8000/v1` and
`http://localhost:30000/v1`, respectively, with `/models` discovery. Their
Anthropic Messages bases use the corresponding root URL. Both are configurable;
enable only the native protocols supported by the deployed server version and
model. Backplane's existing vault-credential requirement is unchanged, even
when the local server itself does not require an API key.

## Verification

Run focused tests for `model_metadata_test.exs`,
`model_discovery_metadata_test.exs`, `router_models_metadata_test.exs`, and
`provider_preset_test.exs` under `apps/backplane_llama/test/backplane/llm/`.
Existing discovery, router, provider, and provider-scoped Codex tests cover the
compatibility boundaries.
