# LLM Provider Redesign Implementation Plan

> **For implementation workers:** this is a breaking refactor. Do not preserve the old
> one-provider-one-api-type design. Delete or replace old LLM provider, alias, and usage
> logging code where it conflicts with this plan.

**Goal:** Redesign Backplane's LLM provider system so one provider can configure both
OpenAI-compatible and Anthropic Messages API surfaces, discover upstream models, expose
Backplane-owned auto models (`fast`, `smart`, `expert`) per API surface, and persist LLM
logs through `Backplane.Telemetry.LLM`.

**Canonical client base URLs:**

- OpenAI-compatible: `/llm/v1`
- Anthropic Messages: `/llm/anthropic`

**Key decisions:**

- No backward compatibility with `llm_providers.api_type`, provider-level `models`, old
  `llm_model_aliases`, or `llm_usage_logs`.
- Provider configuration lives in PostgreSQL and is managed through `/admin/providers`.
- Provider creation happens on a full-page create flow, not an inline modal/form.
- The create flow starts from provider presets. The first shipped presets are DeepSeek,
  Z.ai, and MiniMax; users only need to provide an API key and may override the default
  base URLs.
- The request path only emits `:telemetry`; persistence is handled by
  `Backplane.Telemetry.LLM`.
- No GenServer per provider. Providers and models are database state; processes are used
  only for cache, rate limit, health checks, and async persistence.
- Public model names are Backplane auto models: `fast`, `smart`, `expert`. Each auto model
  has independent OpenAI-compatible and Anthropic Messages routing.

---

## Target Domain Model

### `llm_providers`

Represents an upstream LLM service/vendor.

Fields:

- `id`
- `preset_key`
- `name`
- `credential`
- `enabled`
- `default_headers`
- `rpm_limit`
- `deleted_at`
- timestamps

Notes:

- Remove `api_type`.
- Remove provider-level `models`.
- Keep credentials as references to `Backplane.Settings.Credentials`.
- `preset_key` is nullable. Use it for providers created from built-in presets, not as
  routing logic.

### `llm_provider_apis`

Represents one API surface configured for a provider.

Fields:

- `id`
- `provider_id`
- `api_surface`: `openai` or `anthropic`
- `base_url`
- `enabled`
- `default_headers`
- `model_discovery_enabled`
- `model_discovery_path`
- `last_discovered_at`
- timestamps

Constraints:

- Unique `{provider_id, api_surface}`.
- `base_url` must be `https://` except localhost and `127.0.0.1`.

Default discovery paths:

- OpenAI-compatible: `/models`
- Anthropic Messages: `/v1/models`

Discovery path must be configurable because compatible services differ.

### `llm_provider_models`

Represents a model known for a provider.

Fields:

- `id`
- `provider_id`
- `model`
- `display_name`
- `source`: `discovered` or `manual`
- `enabled`
- `metadata`
- timestamps

Constraints:

- Unique `{provider_id, model}`.

### `llm_provider_model_surfaces`

Represents whether a provider model is available and enabled for a specific configured API
surface.

Fields:

- `id`
- `provider_model_id`
- `provider_api_id`
- `enabled`
- `last_seen_at`
- `metadata`
- timestamps

Constraints:

- Unique `{provider_model_id, provider_api_id}`.

This table prevents an OpenAI request from accidentally routing to an Anthropic-only
target.

### `llm_auto_models`

Backplane-owned public model names.

Seed exactly:

- `fast`
- `smart`
- `expert`

Fields:

- `id`
- `name`
- `description`
- `enabled`
- timestamps

Admins can enable/disable and configure these records, but should not create arbitrary
public names in this phase.

### `llm_auto_model_routes`

One route group per auto model and API surface.

Fields:

- `id`
- `auto_model_id`
- `api_surface`: `openai` or `anthropic`
- `strategy`: initially `first_available`
- `enabled`
- timestamps

Constraints:

- Unique `{auto_model_id, api_surface}`.

### `llm_auto_model_targets`

Ordered target list for one auto model route.

Fields:

- `id`
- `auto_model_route_id`
- `provider_model_surface_id`
- `priority`
- `enabled`
- timestamps

Constraints:

- Unique `{auto_model_route_id, provider_model_surface_id}`.

Example:

```text
fast / openai
  1. openai / gpt-5.3-codex

fast / anthropic
  1. anthropic / claude-haiku

smart / openai
  1. openai / gpt-5.5

smart / anthropic
  1. anthropic / claude-sonnet

expert / openai
  1. openai / gpt-5.5-pro

expert / anthropic
  1. anthropic / claude-opus
```

### `llm_logs`

Persisted by `Backplane.Telemetry.LLM`.

Fields:

- `id`
- `request_id`
- `client_id`
- `client_ip`
- `api_surface`
- `provider_id`
- `provider_name`
- `provider_api_id`
- `provider_model_id`
- `provider_model_surface_id`
- `requested_model`
- `resolved_model`
- `status`
- `error_reason`
- `stream`
- `duration_ms`
- `request_bytes`
- `response_bytes`
- `input_tokens`
- `output_tokens`
- `total_tokens`
- `raw_request`
- `raw_response`
- `raw_request_truncated`
- `raw_response_truncated`
- `metadata`
- `inserted_at`

Indexes:

- `inserted_at`
- `{provider_id, inserted_at}`
- `{requested_model, inserted_at}`
- `{resolved_model, inserted_at}`
- `{api_surface, inserted_at}`
- `{status, inserted_at}`

Raw request/response fields are nullable and only populated when debug logging is enabled.

---

## Provider Presets

Create:

```text
Backplane.LLM.ProviderPreset
```

This is a static catalog, not a database table. It provides defaults for the full-page
provider creation flow.

Preset fields:

- `key`
- `name`
- `default_name`
- `credential_kind`: always `llm`
- `default_base_url`
- `openai_enabled`
- `openai_base_url`
- `openai_discovery_path`
- `anthropic_enabled`
- `anthropic_base_url`
- `anthropic_discovery_path`
- `notes`
- `docs_urls`

The create page should allow users to override base URLs before saving. The saved provider
stores the final per-surface base URLs in `llm_provider_apis`.

Keep the basic create form small:

- API key
- provider base URL, defaulted from preset

Show per-surface base URLs under advanced settings. For presets where both API surfaces
derive cleanly from one root, changing the provider base URL should update the OpenAI and
Anthropic base URL previews. For presets where surfaces use different hosts or products,
advanced per-surface overrides are required.

### Researched Built-In Presets

Use these defaults:

```text
deepseek
  default_base_url: https://api.deepseek.com
  docs_urls:
    - https://api-docs.deepseek.com/
    - https://api-docs.deepseek.com/guides/anthropic_api
    - https://api-docs.deepseek.com/api/list-models
  OpenAI-compatible:
    enabled: true
    base_url: https://api.deepseek.com
    discovery_path: /models
  Anthropic Messages:
    enabled: true
    base_url: https://api.deepseek.com/anthropic
    discovery_path: /v1/models
  notes:
    DeepSeek documents both OpenAI and Anthropic API formats. Current documented models
    include deepseek-v4-flash and deepseek-v4-pro; older deepseek-chat and
    deepseek-reasoner names are documented as compatibility names with deprecation dates.

z-ai
  default_base_url: https://open.bigmodel.cn/api
  docs_urls:
    - https://docs.bigmodel.cn/cn/guide/develop/openai/introduction
    - https://docs.z.ai/api-reference/llm/chat-completion
    - https://docs.z.ai/devpack/tool/claude
  OpenAI-compatible:
    enabled: true
    base_url: https://open.bigmodel.cn/api/paas/v4
    discovery_path: nil
  Anthropic Messages:
    enabled: false
    base_url: https://api.z.ai/api/anthropic
    discovery_path: nil
  notes:
    Z.ai/BigModel general API documents an OpenAI-compatible chat completions endpoint
    under /api/paas/v4. Z.ai also documents an Anthropic-compatible endpoint for GLM Coding
    Plan tooling at https://api.z.ai/api/anthropic, but that is plan/tool specific, so do
    not enable it by default for the general provider preset.

minimax
  default_base_url: https://api.minimaxi.com
  docs_urls:
    - https://platform.minimax.io/docs/token-plan/other-tools
    - https://platform.minimax.io/docs/api-reference/models/openai/list-models
    - https://platform.minimax.io/docs/api-reference/models/anthropic/list-models
    - https://platform.minimax.io/docs/solutions/mini-agent
  OpenAI-compatible:
    enabled: true
    base_url: https://api.minimaxi.com/v1
    discovery_path: /models
  Anthropic Messages:
    enabled: true
    base_url: https://api.minimaxi.com/anthropic
    discovery_path: /v1/models
  notes:
    MiniMax official international docs use https://api.minimax.io. The docs also state
    China users can use https://api.minimaxi.com. This Backplane preset uses the China
    base requested for this deployment; the create page must allow overriding to
    https://api.minimax.io.
```

Provider-specific discovery behavior:

- `nil` discovery path means the UI should not run auto detection by default; admins can
  still add models manually or enable discovery after setting an explicit path.
- OpenAI-compatible discovery normalizes OpenAI model-list responses shaped as
  `%{"object" => "list", "data" => [%{"id" => model_id}]}`.
- Anthropic-compatible discovery normalizes Anthropic model-list responses shaped as
  `%{"data" => [%{"id" => model_id, "display_name" => display_name}]}`.

---

## Module Map

### Replace Existing LLM Provider Modules

New or rewritten modules:

```text
Backplane.LLM.Provider
Backplane.LLM.ProviderPreset
Backplane.LLM.ProviderApi
Backplane.LLM.ProviderModel
Backplane.LLM.ProviderModelSurface
Backplane.LLM.AutoModel
Backplane.LLM.AutoModelRoute
Backplane.LLM.AutoModelTarget
Backplane.LLM.ModelDiscovery
Backplane.LLM.ModelResolver
Backplane.LLM.ResolvedRoute
Backplane.LLM.ProviderAdapter
Backplane.LLM.ProviderAdapters.OpenAI
Backplane.LLM.ProviderAdapters.Anthropic
Backplane.LLM.Router
Backplane.LLM.HealthChecker
Backplane.LLM.RateLimiter
```

Delete or replace:

```text
Backplane.LLM.ModelAlias
Backplane.LLM.CredentialPlug
Backplane.LLM.UsageCollector
Backplane.LLM.UsageLog
Backplane.LLM.UsageQuery
Backplane.Jobs.UsageWriter
```

`CredentialPlug` can be deleted because credential header construction belongs in provider
adapters.

### New Telemetry Logging Modules

```text
Backplane.Telemetry.LLM
Backplane.Telemetry.LLM.Log
Backplane.Telemetry.LLM.Writer
Backplane.Telemetry.LLM.Query
```

Responsibilities:

- `Backplane.Telemetry.LLM`: attach/detach telemetry handlers, normalize metadata,
  enqueue persistence.
- `Backplane.Telemetry.LLM.Log`: Ecto schema for `llm_logs`.
- `Backplane.Telemetry.LLM.Writer`: Oban worker.
- `Backplane.Telemetry.LLM.Query`: admin filtering and aggregates.

The router, discovery, and health checker only emit telemetry events.

---

## Public API Behavior

### OpenAI-compatible Surface

Routes under `/llm/v1`:

```text
GET  /models
POST /chat/completions
POST /* fallback to OpenAI-compatible proxy rules where useful
```

`GET /llm/v1/models` returns auto models that have at least one enabled OpenAI-compatible
target.

### Anthropic Messages Surface

Routes under `/llm/anthropic`:

```text
GET  /v1/models
POST /v1/messages
```

`GET /llm/anthropic/v1/models` returns auto models that have at least one enabled
Anthropic Messages target.

### Resolution

Resolve with the current API surface:

```text
resolve(:openai, "fast")
resolve(:anthropic, "fast")
```

Valid target requirements:

- auto model enabled
- auto model route enabled for the requested API surface
- target enabled
- provider enabled and not deleted
- provider API enabled for the requested API surface
- provider model enabled
- provider model surface enabled

The resolver returns `%Backplane.LLM.ResolvedRoute{}`:

```text
api_surface
requested_model
resolved_model
provider
provider_api
provider_model
provider_model_surface
adapter
```

The router rewrites the request model to `resolved_model` before proxying upstream.

---

## Provider Adapter Contract

Create a behavior:

```text
Backplane.LLM.ProviderAdapter
```

Callbacks:

- `api_surface/0`
- `build_auth_headers(provider, provider_api)`
- `merge_default_headers(provider, provider_api)`
- `models_response(auto_models)`
- `extract_model(raw_body)`
- `replace_model(raw_body, resolved_model)`
- `streaming?(raw_body)`
- `extract_usage(response_body)`
- `scan_stream_chunk(acc, chunk)`
- `error_response(reason)`
- `health_request(provider, provider_api)`
- `normalize_discovered_models(response_body)`

Implementation modules:

- `Backplane.LLM.ProviderAdapters.OpenAI`
- `Backplane.LLM.ProviderAdapters.Anthropic`

Keep the existing `Backplane.LLM.ModelExtractor` if it stays useful, but call it from
adapters instead of from router conditionals.

---

## Telemetry Events

Runtime code emits:

```text
[:backplane, :llm, :request, :stop]
[:backplane, :llm, :request, :exception]
[:backplane, :llm, :provider, :health]
[:backplane, :llm, :model, :discovery]
```

Request stop measurements:

```text
duration_ms
request_bytes
response_bytes
input_tokens
output_tokens
total_tokens
```

Request stop metadata:

```text
request_id
client_id
client_ip
api_surface
provider_id
provider_name
provider_api_id
provider_model_id
provider_model_surface_id
requested_model
resolved_model
status
stream
error_reason
raw_request
raw_response
raw_request_truncated
raw_response_truncated
```

Raw bodies are present only when debug logging is enabled. Apply redaction and byte caps
before emitting telemetry so handlers never see secrets or oversized data.

Settings:

```text
llm.log_debug_enabled
llm.log_raw_body_max_bytes
llm.log_retention_days
```

---

## Admin UI

### `/admin/providers`

Refactor provider administration into an index plus a full-page create flow.

Routes:

```text
/admin/providers
/admin/providers/new
```

The Add Provider button on `/admin/providers` navigates to `/admin/providers/new`.

`/admin/providers/new` flow:

1. Show preset cards for DeepSeek, Z.ai, and MiniMax.
2. After selecting a preset, show a full-page form with:
   - provider name, defaulted from preset
   - API key
   - provider base URL, defaulted from preset and overridable
   - enable/disable each API surface
   - advanced fields collapsed by default, including per-surface base URLs and discovery
     paths
3. On save:
   - create or update a `llm` credential from the supplied API key
   - create the provider with `preset_key`
   - create enabled `llm_provider_apis` from the selected preset
   - run model discovery only for API surfaces with a configured discovery path

Implementation options:

- Use `BackplaneWeb.ProvidersLive` for the index.
- Use `BackplaneWeb.ProviderNewLive` for the full-page create flow, or route
  `ProvidersLive` with `live_action == :new` if keeping one LiveView is simpler. The UI
  must still render as a full page, not an inline card inside the provider list.

Refactor `BackplaneWeb.ProvidersLive` index into three logical areas:

1. Providers
2. Provider Models
3. Auto Models

Provider edit form:

- Name
- Credential
- Enabled
- RPM limit
- Provider default headers
- OpenAI-compatible API section:
  - enabled
  - base URL
  - default headers
  - discovery enabled
  - discovery path
- Anthropic Messages API section:
  - enabled
  - base URL
  - default headers
  - discovery enabled
  - discovery path

Provider detail:

- health per API surface
- discovered/manual models
- enable/disable model surface
- trigger model detection
- last discovered time

Auto Models area:

- fixed rows: `fast`, `smart`, `expert`
- per row, configure:
  - OpenAI-compatible target list
  - Anthropic Messages target list
  - target priority
  - route enabled/disabled

### `/admin/logs`

Add an `LLM Logs` tab to `BackplaneWeb.LogsLive`.

Filters:

- time range
- provider
- requested model
- resolved model
- API surface
- status
- client
- debug logs only

Table columns:

- time
- status
- API
- provider
- requested model
- resolved model
- tokens
- data sent / received
- latency
- client

Row detail:

- request summary
- provider and model resolution
- timing
- token usage
- data sent / received
- error reason
- raw request, if debug captured
- raw response, if debug captured

---

## Implementation Phases

### Phase 1: Destructive Schema Rewrite

Files:

- `apps/backplane/priv/repo/migrations/*llm*.exs`
- `apps/backplane/lib/backplane/llm/provider.ex`
- `apps/backplane/lib/backplane/llm/provider_preset.ex`
- new Ecto schema/context modules listed above

Tasks:

- Replace old LLM migrations with the new tables.
- Add nullable `preset_key` to `llm_providers`.
- Add `Backplane.LLM.ProviderPreset` with DeepSeek, Z.ai, and MiniMax defaults.
- Seed `fast`, `smart`, `expert` auto models and their two route rows.
- Delete old model alias and usage log schemas.
- Rewrite provider tests around provider APIs and provider model surfaces.

Validation:

```bash
mix format
MIX_ENV=test mix ecto.reset
mix test apps/backplane/test/backplane/llm/provider_test.exs
```

### Phase 2: Provider Adapters and Discovery

Files:

- `apps/backplane/lib/backplane/llm/provider_adapter.ex`
- `apps/backplane/lib/backplane/llm/provider_adapters/openai.ex`
- `apps/backplane/lib/backplane/llm/provider_adapters/anthropic.ex`
- `apps/backplane/lib/backplane/llm/model_discovery.ex`

Tasks:

- Move credential header construction into adapters.
- Implement model discovery per provider API.
- Upsert discovered models and model surfaces.
- Emit `[:backplane, :llm, :model, :discovery]` telemetry.

Validation:

```bash
mix test apps/backplane/test/backplane/llm/model_discovery_test.exs
mix test apps/backplane/test/backplane/llm/provider_adapter_test.exs
```

### Phase 3: Auto Model Resolution and Router Paths

Files:

- `apps/backplane/lib/backplane/llm/model_resolver.ex`
- `apps/backplane/lib/backplane/llm/resolved_route.ex`
- `apps/backplane/lib/backplane/llm/router.ex`
- `apps/backplane/lib/backplane/llm/proxy_plug.ex`
- `apps/backplane_web/lib/backplane_web/endpoint.ex`

Tasks:

- Split canonical public routes:
  - `/llm/v1/*`
  - `/llm/anthropic/*`
- Resolve `fast`, `smart`, `expert` by API surface.
- Return model lists per API surface.
- Rewrite upstream model through adapter.
- Keep Relayixir path rewriting visible in logs for proxy debugging.

Validation:

```bash
mix test apps/backplane/test/backplane/llm/model_resolver_test.exs
mix test apps/backplane/test/backplane/llm/router_test.exs
mix test apps/backplane/test/backplane/llm/streaming_integration_test.exs
```

### Phase 4: Telemetry LLM Logging

Files:

- `apps/backplane/lib/backplane/telemetry/llm.ex`
- `apps/backplane/lib/backplane/telemetry/llm/log.ex`
- `apps/backplane/lib/backplane/telemetry/llm/writer.ex`
- `apps/backplane/lib/backplane/telemetry/llm/query.ex`
- `apps/backplane/lib/backplane/application.ex`
- `apps/backplane/lib/backplane/jobs/usage_retention.ex`

Tasks:

- Replace `Backplane.LLM.UsageCollector.attach()` with `Backplane.Telemetry.LLM.attach()`.
- Replace `Backplane.Jobs.UsageWriter` with `Backplane.Telemetry.LLM.Writer`.
- Store request/response sizes and optional debug raw bodies.
- Preserve retention behavior under the new `llm_logs` table.
- Ensure telemetry handlers do not block request execution.

Validation:

```bash
mix test apps/backplane/test/backplane/telemetry/llm_test.exs
mix test apps/backplane/test/backplane/telemetry/llm/query_test.exs
```

### Phase 5: Admin Providers UI

Files:

- `apps/backplane_web/lib/backplane_web/live/providers_live.ex`
- `apps/backplane_web/lib/backplane_web/live/provider_new_live.ex`
- `apps/backplane_web/lib/backplane_web/router.ex`
- `apps/backplane_web/test/backplane_web/live/providers_live_test.exs`

Tasks:

- Add full-page `/admin/providers/new` create flow.
- Add preset selection for DeepSeek, Z.ai, and MiniMax.
- Let users provide API key and override preset base URLs before save.
- Store the supplied API key through `Backplane.Settings.Credentials`.
- Replace single `api_type` select with OpenAI and Anthropic API setup sections.
- Replace comma-separated provider model field with discovered/manual model management.
- Add detect models action.
- Add auto model configuration for `fast`, `smart`, `expert`.

Validation:

```bash
mix test apps/backplane_web/test/backplane_web/live/providers_live_test.exs
mix test apps/backplane_web/test/backplane_web/live/provider_new_live_test.exs
```

### Phase 6: Admin LLM Logs UI

Files:

- `apps/backplane_web/lib/backplane_web/live/logs_live.ex`
- `apps/backplane_web/test/backplane_web/live/logs_live_test.exs`

Tasks:

- Add `LLM Logs` tab.
- Add filters for time range, provider, models, API surface, status, client, and debug.
- Add row detail for raw request/response when captured.

Validation:

```bash
mix test apps/backplane_web/test/backplane_web/live/logs_live_test.exs
```

### Phase 7: Cleanup and End-to-End Verification

Tasks:

- Remove dead references to `api_type`, provider-level `models`, `ModelAlias`,
  `CredentialPlug`, `UsageCollector`, `UsageLog`, and `UsageQuery`.
- Update docs and home page examples to use:
  - `openai_base_url = ".../llm/v1"`
  - `ANTHROPIC_BASE_URL = ".../llm/anthropic"`
- Run focused LLM and LiveView tests.
- Run `mix assets.deploy` if UI changed CSS or templates enough to affect assets.

Validation:

```bash
rg "api_type|llm_model_aliases|llm_usage_logs|UsageCollector|UsageWriter|CredentialPlug" apps config
mix format
mix test apps/backplane/test/backplane/llm
mix test apps/backplane_web/test/backplane_web/live/providers_live_test.exs apps/backplane_web/test/backplane_web/live/logs_live_test.exs
```

---

## Risk Notes

- Raw request/response logging can leak secrets. Debug logging must default off, redact
  auth headers and known credential fields, and cap body size.
- Streaming responses may not have a complete raw response body. Store sizes and token
  usage even when raw response capture is unavailable.
- Model discovery is not standardized for every Anthropic-compatible provider. Manual
  model creation must remain available.
- The old MiniMax failure involved Relayixir/Mint HTTP/2 request window behavior. Keep
  upstream path and raw proxy transport reason visible in operational logs while changing
  route surfaces.
- Full umbrella tests may include unrelated stale failures. Use focused LLM and LiveView
  tests while iterating, then broaden when the feature slice is stable.
