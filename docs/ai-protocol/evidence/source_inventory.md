---
project: sigma
commit: 108106b7bc255e1a11a96f17e1885d35c0ef0b9e
branch: main
path: apps/sigma_ai/lib/sigma_ai
mode: read-only
---

# AI Provider Source Inventory

## Summary

`sigma_ai` is a compact Elixir protocol/adapter package: `Req` HTTP streaming, `Jason` JSON, telemetry, SSE framing, neutral messages, provider-specific codecs, and a legacy/normalized event bridge. It has no database or Phoenix dependencies. Persistence and provider selection live outside it: `sigma_session` owns JSONL message storage, `sigma_agent` invokes adapters, and `sigma_web` resolves configured provider records into adapter modules/options. It also uses no OAuth code or WebSocket transport.

### Runtime dependencies

- `req ~> 0.5`
- `jason ~> 1.4`
- `telemetry ~> 1.0`

## Modules

| Path | Purpose | Key deps | Callers | Disposition | Risks / notes |
|---|---|---|---|---|---|
| `application.ex` | Starts `Sigma.Ai.Supervisor` and named `Sigma.Ai.ProviderTaskSupervisor` for provider streams | BEAM supervision | Umbrella application start | **adapt** | Process names are global; rename if multiple standalone instances coexist |
| `message.ex` | Neutral `user` / `assistant` / `tool_result` message shapes; content, usage, stop reason, and token-level stream event types | types only | `sigma_agent.message_transformer`, `sigma_coding.tool`, `sigma_protocol.pi_agent.message`, provider adapters, agent/web layers | **extract** | Stable map-based types and role names are an integration contract, not persisted storage |
| `provider.ex` | Provider behavior and public seam; bridges legacy stream events into `ProviderEvent`s; cooperative cancellation bridge | `Sigma.Ai` protocol structs | `sigma_agent`, `sigma_web`, mock/release providers implementing `Sigma.Ai.Provider` | **extract** | Legacy/normalized dual events must be preserved until callers migrate; bridge processes are runtime-coupled |
| `provider_auth.ex` | Builds bearer / `x-api-key` / custom-header authentication; omits blank credentials | none | All three provider adapters | **extract** | Low risk; custom header name and credential presence are runtime options |
| `provider_capabilities.ex` | Struct for tools, thinking, image input, context/output windows, supported options | none | `Provider`, adapters, capability consumers | **extract** | Low risk |
| `provider_error.ex` | Closes over HTTP/transport/parse failures into classified exception with retry metadata and bounded raw message | exception + message parsing | Agent/UI/protocol error paths; adapters | **extract** | Message-based fallback classification is heuristic |
| `provider_event.ex` | Neutral lifecycle event struct | none | `Provider` seam, adapters | **extract** | Low risk |
| `provider_model.ex` | Empty model placeholder/type | none | Currently not referenced in source | **keep** | Unneeded for minimal standalone extraction |
| `provider_request.ex` | Neutral request, lifecycle timestamps, usage fact, retry identity, and legacy-map conversion | `Sigma.Ai.ProviderUsage` | `Provider` and adapters; agent/web providers and tests | **extract** | Session/turn identity is opaque metadata, not persistence |
| `provider_stop_reason.ex` | Normalizes provider stop values to neutral reasons while retaining raw value | none | Provider event normalization, agent/web consumers | **extract** | Low risk |
| `provider_usage.ex` | Normalizes token/cache/reasoning counters, status/revision/provenance, and emits metric fact shape | none | Adapters, `ProviderRequest`, session metrics | **extract** | Provenance vocabulary is intentional and must remain stable |
| `stream.ex` | Pure SSE reducer: accumulates buffer, splits `\\n\\n` events, joins `data:` lines, decodes JSON or recognizes `[DONE]` | `Jason` | Anthropic/OpenAI streaming handlers | **extract** | Assumes `\\n\\n`; tolerant on malformed events |
| `providers/anthropic.ex` | Anthropic Messages adapter: request build, auth/version/beta headers, SSE decode, message transform, event accumulation, HTTP/provider error handling, telemetry | `ProviderAuth`, capabilities/error/request, `Stream`, `Req`, `Jason`, telemetry | `Provider` via API type mapping; agent/web runtime | **adapt** | Endpoint, API version, prompt-caching beta, and thinking beta are adapter-specific but option/config driven |
| `providers/openai.ex` | OpenAI Chat Completions adapter: request build, bearer/custom auth, SSE decode, message/tool transform, usage decode, error handling, telemetry | same core deps | `Provider` via API type mapping; agent/web runtime | **adapt** | Supports `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, and `OPENAI_BASE_URL` fallbacks; no OAuth |
| `providers/openai_responses.ex` | OpenAI Responses adapter: `/responses`, Responses event decoding, function calls, reasoning deltas, usage/status mapping, error handling, telemetry | same core deps | `Provider` via API type mapping; agent/web runtime | **adapt** | Default base URL and credential env fallbacks; no OAuth |

## Runtime / call graph

```text
sigma_web provider config
  -> provider module + model + options
    -> sigma_agent runtime / session
      -> Sigma.Ai.Provider.stream(provider, ProviderRequest)
        -> adapter stream_normalized
          -> adapter stream
            -> Req HTTP/SSE -> Stream.decode -> legacy events
            -> Provider normalize_legacy_event -> ProviderEvent stream
      -> agent messages/events -> sigma_session JSONL persistence
```

- `sigma_web` maps configured API types: `anthropic` → `Providers.Anthropic`; `openai` and `openai-responses` → `Providers.OpenAIResponses`; `openai-completions` → `Providers.OpenAI`. Test/mock providers can substitute through `Application.get_env`.
- `sigma_agent` owns request runtime and consumes `Sigma.Ai.ProviderRequest`, `ProviderEvent`, `ProviderError`, `ProviderUsage`, `ProviderStopReason`, and `Sigma.Ai.Message`.
- `sigma_session` persists messages, provider/model selection, and provider/model changes as JSONL journal/log entries. This is outside `sigma_ai`.
- `sigma_protocol.pi_agent.message` mirrors `Sigma.Ai.Message`; `sigma_coding.tool` accepts its text/image tool-result content types.

## Model catalogs / capabilities

- There is no provider model catalog in `sigma_ai`.
- Current model is a runtime map with `id`, provider/API identifiers, optional `context_window`, and output-token limits.
- Adapters advertise coarse capability booleans/options and pass context/output values through from that model map.
- `sigma_web` stores and edits configured provider/model data; no model IDs are hardcoded in `sigma_ai`.

## Transports and auth

- HTTP-only streaming via `Req.post!(..., into: :self)` plus `Req.parse_message/2`.
- Endpoints used: Anthropic `/v1/messages`; OpenAI Chat Completions `/chat/completions`; OpenAI Responses `/responses`.
- `Sigma.Ai.Stream` decodes generic SSE `data:` blocks and `[DONE]`.
- No WebSocket transport exists in `sigma_ai`.
- Authentication is static API keys only: bearer, `x-api-key`, or custom header. No OAuth or token refresh code exists.

## Standalone package constraints

- **Elixir module names:** `Sigma.Ai.*` and adapter modules are embedded in callers and mock behavior contracts.
- **Named process:** `Sigma.Ai.ProviderTaskSupervisor` is a globally registered name.
- **Credential fallbacks:** adapter credentials come from explicit options first, then provider-specific env fallbacks (`ANTHROPIC_AUTH_TOKEN`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`); OpenAI-family adapters also use `OPENAI_BASE_URL`. No credential files or OAuth files are referenced.
- **Hard-coded defaults:** provider default base URLs, Anthropic API version, and beta identifiers are defaults in adapter code. No user-filesystem paths are read by `sigma_ai`.
- **Database / Phoenix:** no Ecto, Postgrex, Phoenix, or session-storage dependency in `sigma_ai`.
- **Provider mapping:** API-type strings remain in `sigma_web` (`anthropic`, `openai`, `openai-responses`, `openai-completions`).
- **Legacy protocol:** `Sigma.Ai.Message` map shape and legacy stream event tuples are part of the existing public behavior contract.

## Disposition rationale

- **Extract:** neutral request/event/error/usage/auth/SSE types and runtime behavior form the reusable protocol core.
- **Adapt:** concrete provider adapters should be retained but likely renamed/reorganized if the standalone package abandons the `Sigma` namespace or introduces a broader provider registry.
- **Keep:** `ProviderModel` remains as-is because it is not load-bearing; remove it from a minimal extraction rather than expand it speculatively.

---

# Backplane Source Inventory

## Scope

Inventory of protocol, authentication, model routing, and transport code relevant to extracting a shared AI protocol library. Focus paths: `apps/backplane/lib/backplane/llm/*`, `apps/backplane/lib/backplane/proxy/*`, `apps/backplane/lib/backplane/config.ex`, `apps/backplane/lib/backplane/settings/credentials.ex`, `apps/backplane/lib/backplane/clients/*`, `apps/backplane/lib/backplane/transport/*`, `apps/backplane/lib/backplane/services/*`, `apps/relayixir`, and host-agent/Codex transport code. Note: much of this has already been split across umbrella child apps (`backplane_mcp`, `backplane_llama`, `backplane_system`, `backplane_mcp_protocol`, `backplane_auth`); the `backplane` app itself is now a thin orchestrator (`apps/backplane/lib/backplane/application.ex` only).

## Shared Protocol Library

| Path | Purpose | Deps | Callers | Extract? | Risks |
|---|---|---|---|---|---|
| `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/protocol.ex` | Protocol version registry, negotiation, transport compatibility across MCP 2024-11-05 → 2026-07-28 | backplane_mcp_protocol internal | `McpEraRouter`, `Upstream`, `Dispatch` | **Keep** — already extracted, LGPL-3.0 | Version coupling; profile registry is app-scoped |
| `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client.ex` (~1600 lines) | Full MCP client GenServer: request routing, streaming, sampling, elicitation, roots, subscriptions, catalog | Finch, Peri, Finch redirects, optional Redix/Gun | `Proxy.ClientPool`, `Proxy.ProtocolClient`, `Upstream` | **Keep** — protocol library | Large; auth callback (`CredentialStore`) seam needed for request-scoped auth forwarding |
| `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server.ex` | MCP server macro + ProfileRouter for modern era | Peri schema, profile registry | `McpPlug` (via `ModernServer` macro) | **Keep** | Server behaviours are tightly coupled to MCP spec shapes |
| `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex` | Streamable HTTP client transport | Finch | `Client` | **Keep** | Header provider is zero-arity (no request context) — flagged as deferred seam |
| `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/stdio.ex` | Stdio client transport | Port | `Client` | **Keep** | Process lifecycle owned by parent supervisor |
| `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/sse.ex` | SSE client transport | Finch | `Client` | **Keep** | Legacy; Streamable HTTP supersedes |

## MCP Transport Layer (`apps/backplane_mcp/lib/backplane/transport/*`)

| Module | Purpose | Deps | Callers | Extract? | Risks |
|---|---|---|---|---|---|
| `mcp_plug.ex` | HTTP entry point for `/mcp` — Plug.Router with compression, rate-limit, auth, idempotency chain | Backplane.Auth.ResourceAuthPlug, CacheBodyReader, CORS, McpEraRouter, McpHandler, ModernServer, Session, VersionHeader, McpProtocol | `Backplane.Api.Router` (`forward("/mcp", ...)`), admin `McpInspectorLive` | **Adapt** — transport plumbing is reusable but auth/scope hooks are Backplane-specific | Coupled to `Backplane.Clients` scope filtering; CORS/CacheBodyReader live in `backplane_system` |
| `mcp_handler.ex` | Legacy-era JSON-RPC dispatcher (batch, request, notification) → `Dispatch.execute` | Clients, Dispatch, Info, JsonRpc, InputValidator, ToolRegistry, Session, SSE, TaskManager, Extensions, Telemetry | `McpPlug`, admin `McpHandler`, host-agent `HostAgentChannel` | **Adapt** — dispatch layer is transport-independent but depends on Backplane registries | Version-aware response formatting is embedded; extracting requires a handler-behaviour interface |
| `mcp_era_router.ex` | Classifies requests as legacy or modern MCP era via `ProfileRouter` | McpProtocol.ProfileRouter, Error, Profile, Registry | `McpPlug` | **Adapt** — mostly protocol logic, small Backplane-specific header normalization | Hard-coded `@modern_versions` and `@protocol_version_header` |
| `session.ex` | ETS-backed per-session state (version, capabilities, inactivity cleanup) | GenServer, ETS | `McpHandler`, `McpPlug` | **Adapt** — ETS session pattern is reusable | No shared Redis backend for multi-node; lifecycle is app-scoped |
| `sse.ex` | SSE streaming for MCP tool-call responses | Plug.Conn, JsonRpc, McpSSE | `McpHandler` | **Adapt** — encoding is in protocol lib already; this is the Plug adapter | Tied to Plug.Conn chunked responses |
| `task_manager.ex` | ETS-backed async tool tasks (2025-11-25 experimental) | Task, Repo, Skills.Host, ETS | `McpHandler` | **Keep** — app-specific async execution | Depends on `Backplane.Repo` and `Backplane.Skills.Host` |
| `compression.ex`, `rate_limiter.ex`, `idempotency.ex`, `version_header.ex` | HTTP middleware (gzip, ETS sliding-window rate limit, identity-bound replay, version headers) | Plug, ETS, Backplane.MCP.Info, ModernServer | `McpPlug` chain | **Extract** — generic plugs with minimal Backplane coupling | `Idempotency` depends on `ModernServer` for key derivation; `RateLimiter` config is app-scoped |
| `metrics_plug.ex`, `health_plug.ex`, `health_check.ex` | Health and metrics endpoints | Plug, Pool, ToolRegistry, SkillsRegistry, Metrics.Prometheus | API router (via admin), admin LiveViews | **Keep** — Backplane hub introspection | Depends on full hub state |
| `request_logger.ex` | Deprecated alias → `McpObservability` | — | Tests only | **Remove** — dead code | None (test-only) |

## MCP Proxy (`apps/backplane_mcp/lib/backplane/proxy/*`)

| Module | Purpose | Deps | Callers | Extract? | Risks |
|---|---|---|---|---|---|
| `pool.ex` | DynamicSupervisor managing upstream MCP connections (one-for-one) | ClientLeaseManager, Upstream, Namespace | `Application.start_upstream`, `Tools.Hub`, admin Dashboard | **Keep** — lifecycle orchestration | Not a protocol library candidate |
| `upstream.ex` | GenServer per upstream: connect, catalog registration, health ping, tool refresh, reconnect, call forwarding | McpProtocol.Client, Observability, ClientPool/LeaseManager, ToolRegistry, PubSub, ProtocolClient, ToolCatalog | `Pool`, `Dispatch`, admin | **Keep** — Backplane lifecycle orchestration | Complex reconnect/backoff; monitoring of external `McpProtocol.Client` trees |
| `protocol_client.ex` | Builds `McpProtocol.Client.child_spec/1` options from config; protocol preference normalization; headers provider | McpProtocol.Client, Error, Headers, AuthInjector | `Upstream`, `ClientPool` | **Adapt** — client construction is config normalization; could generalize | Zero-arity headers_provider limitation (no request-context auth forwarding) documented |
| `auth_injector.ex` | Resolves named credential → auth header (bearer, x_api_key, custom_header) | Settings.Credentials | `ProtocolClient` | **Extract** — small, generic credential-to-header injection | Similar but distinct from `LLM.CredentialPlug`; unification opportunity |
| `client_pool.ex` | DynamicSupervisor for reusable `McpProtocol.Client` trees with ETS lease tracking | McpProtocol.Client, ETS | `ClientLeaseManager`, `Upstream` | **Keep** — lifecycle management | ETS lease table is app-scoped |
| `client_lease_manager.ex` | GenServer for owned client lifecycle (attach/detach, monitoring) | ClientPool, Pool, ToolRegistry, DynamicSupervisor | `Upstream` | **Keep** | Complex PID-ownership tracking |
| `tool_catalog.ex` | Normalizes raw upstream tool defs into registry `Tool` structs | McpProtocol.Response, Registry.Tool | `Upstream` | **Keep** — Backplane registry format | Schema is app-specific |
| `mcp_upstream.ex` | Ecto schema for `mcp_upstreams` table (name, prefix, transport, url, protocol_version, auth) | Ecto, Changeset, Namespace | `Upstreams` context, admin CRUD | **Keep** — DB schema is app-specific | Protocol version allowlist is duplicated with `ProtocolClient` |
| `upstreams.ex` | Context for `mcp_upstreams` (CRUD, list_enabled, runtime_config) | Repo, McpUpstream | Application boot, admin | **Keep** | Standard Ecto context |
| `namespace.ex` | Tool name prefixing/stripping (`prefix::tool_name` using `::` separator) | — | ToolRegistry, Dispatch, Config, admin | **Extract** — pure function, zero deps | Simple; low risk |
| `sse_parser.ex`, `sse_client.ex` | SSE chunk parsing for legacy upstream connections | Req/WebSocket | Legacy `Upstream` path (deprecated) | **Keep** — legacy compat | Deprecated code path; should not extract |

## LLM Proxy (`apps/backplane_llama/lib/backplane/llm/*`)

| Module | Purpose | Deps | Callers | Extract? | Risks |
|---|---|---|---|---|---|
| `router.ex` | Plug.Router for `/v1/*` — model listing, chat completions, messages, embeddings, responses; catch-all forwards | Relayixir.Proxy.HttpPlug/Upstream, ModelResolver, CredentialPlug, ModelAlias, AutoModel, ModelExtractor, RateLimiter, AccessEvent, Embedding, CacheBodyReader | `Backplane.Api.Endpoint` (`plug Backplane.LLM.ProxyPlug`) | **Adapt** — routing is protocol surface but depends on full Backplane LLM context | Heavy; streaming, model extraction, auto-model routing all inline |
| `openai_codex.ex` | Detects/enables OpenAI Codex backend proxying; base URL and header rules | Provider, ProviderApi, Settings.Credentials | CredentialPlug, WebLiveSearch, RouteLoader, CodexProxyPlug | **Adapt** — Codex-specific auth/header logic; has a plugin-like contract | Hard-coded `@default_backend_base_url` and provider-owned headers list |
| `openai_codex_proxy_plug.ex` | Plug that rewrites OpenAI requests to Codex backend | Relayixir.Proxy.HttpPlug/Upstream, OpenAICodex, CredentialPlug, RateLimiter | `Api.Endpoint` (via LLM.ProxyPlug) | **Keep** — app-specific proxy surface | Depends on Relayixir upstream registration |
| `credential_plug.ex` | Strips client auth headers, injects provider credentials based on `api_type` + `auth_type` | OpenAICodex, Provider, Settings.Credentials, Plug.Conn | Router, WebLiveSearch, CodexProxyPlug | **Adapt** — LLM credential injection; parallel to MCP `AuthInjector` | Multiple auth_type branches (api_key, oauth2_client_credentials, anthropic_oauth, openai_oauth) |
| `model_resolver.ex` | ETS-cached model string → provider/model resolution (aliases, auto models, provider/model) | AutoModel, AutoModelRoute, ModelAlias, ProviderApi, ProviderModel, ProviderModelSurface, Provider, PubSub, Repo | Router, WebLiveSearch | **Adapt** — model resolution logic is protocol-level; could generalize | Depends on Ecto schemas and ETS cache lifecycle |
| `route_loader.ex` | GenServer syncing active LLM provider APIs into Relayixir UpstreamConfig | ProviderApi, PubSub, Relayixir.Config.UpstreamConfig | Application supervision | **Keep** — Backplane-specific sync to Relayixir | Depends on `Relayixir.Config.UpstreamConfig` global state |
| `provider.ex` | LLM provider Ecto schema + context (CRUD, soft delete) | ProviderApi, ProviderModel, ProviderPreset, Repo, Credentials | Router, admin CRUD, WebLiveSearch | **Keep** — app data model | Standard Ecto context |
| `provider_api.ex`, `provider_model.ex`, `provider_model_surface.ex`, `provider_preset.ex` | Sub-schemas for provider API surfaces, models, model surfaces, presets | Repo, Provider | Provider, ModelResolver, admin | **Keep** | Deep schema graph |
| `model_alias.ex`, `auto_model.ex`, `auto_model_route.ex`, `auto_model_target.ex`, `auto_model_target.ex` | Model alias and auto-model routing schemas | Repo, ProviderModelSurface | ModelResolver, admin | **Keep** | Multi-table resolution complexity |
| `model_discovery.ex` | Fetches model list from provider API | Req, ProviderApi, CredentialPlug | Router | **Keep** | HTTP call to external provider |
| `model_extractor.ex` | Extracts model string from request body based on API surface | Plug.Conn | Router | **Adapt** — small pure function | API surface detection logic |
| `rate_limiter.ex` | ETS-based sliding-window rate limiter for LLM requests | GenServer, ETS | Router, WebLiveSearch | **Extract** — generic rate limiter | Config is app-scoped |
| `access_event.ex` | Builds access event struct for LLM observability v2 | Observability Context/Error/Event/Id, Provider, ProviderApi, UsageAccumulator | Router, CodexProxyPlug | **Keep** — Backplane telemetry contract | Heavy observability coupling |
| `log_writer.ex` | Buffered ETS writer flushing LLM access events to `llm_logs` | Repo, ProxyRequest, Observability.Buffer | Application supervision, admin logs | **Keep** | Retention policy is app-scoped |
| `log_query.ex` | Query helpers for `llm_logs` | Repo, ProxyRequest | Admin logs, UsageQuery | **Keep** | Standard query module |
| `usage_accumulator.ex` | Agent process accumulating token usage and streaming metrics from SSE chunks | Agent | Router (during streaming) | **Adapt** — could be useful for any SSE-streaming proxy | Pure utility with no Backplane deps |
| `usage_collector.ex`, `usage_log.ex`, `usage_query.ex`, `usage_writer.ex`, `usage_retention.ex` | Legacy telemetry → Oban → Ecto pipeline (deprecated when Observability v2 is on) | Observability, Repo | Application (conditional attach) | **Keep** — legacy compat, extraction not useful | Will be removed; don't invest |
| `proxy_request.ex` | Observability v2 durable write schema for `llm_proxy_requests` | Repo, Ecto | LogWriter, LogQuery | **Keep** | App-specific schema |

## LLM Transport (Relayixir)

| Module | Purpose | Deps | Callers | Extract? | Risks |
|---|---|---|---|---|---|
| `apps/relayixir/lib/relayixir.ex` | Application entry, starts Router | — | Parent app | **Keep** — MIT-licensed standalone proxy library | Protocol-agnostic HTTP/WS reverse proxy |
| `relayixir/proxy/http_plug.ex` | Core HTTP proxy Plug: resolve upstream, prepare headers, connect, stream response | Headers, HttpClient, ErrorMapper, Upstream, Request, Response, ConnPool | LLM.Router, CodexProxyPlug | **Keep** — generic HTTP proxy | Well-isolated |
| `relayixir/proxy/upstream.ex` | Struct + route resolution (`%Upstream{}` from conn + config) | RouteConfig, UpstreamConfig | HttpPlug, Router, ConnPool | **Keep** | Route matching is simple |
| `relayixir/config/upstream_config.ex` | Global upstream config registry (ETS-backed) | ETS, PubSub | RouteLoader (LLM), Router | **Keep** | Shared mutable ETS config |
| `relayixir/proxy/conn_pool.ex` | GenServer-based connection pool for Mint connections | Upstream, Mint | HttpPlug | **Keep** | Generic pooling |
| `relayixir/proxy/http_client.ex` | Mint HTTP client: connect, send, stream, close | Mint, Upstream, EnvironmentProxy | HttpPlug, ConnPool | **Keep** | Streaming support good |
| `relayixir/proxy/headers.ex` | Header prep/merge for upstream and response | Plug | HttpPlug, Router | **Keep** | Small utility |
| `relayixir/proxy/error_mapper.ex` | Maps internal errors to HTTP responses | Plug.Conn | HttpPlug | **Keep** | — |
| `relayixir/proxy/request.ex`, `response.ex` | Request/Response structs and `from_conn/2` normalization | Plug.Conn | HttpPlug | **Keep** | — |
| `relayixir/proxy/environment_proxy.ex` | Detects HTTP proxy env vars for Mint connect options | System.get_env | HttpClient | **Keep** | Generic |
| `relayixir/proxy/websocket/*` (plug, bridge, adapter, frame, close, upstream_client) | WebSocket bridge: client ↔ upstream bidirectional frame bridging via Mint.WebSocket | Mint.WebSocket, Websock | HttpPlug (WS upgrade path) | **Keep** | Protocol-agnostic WS bridging |
| `relayixir/router.ex` | Default Plug.Router (starts as library, not mounted externally) | Plug.Router, Upstream, ErrorMapper | Library default (config `start_server: false`) | **Keep** | Unused in Backplane — library consumer defines own router |

## Auth / Credentials (`apps/backplane_system/lib/backplane/settings/*`, `apps/backplane_system/lib/backplane/clients/*`)

| Module | Purpose | Deps | Callers | Extract? | Risks |
|---|---|---|---|---|---|
| `settings/credentials.ex` | Central encrypted credential store: store/fetch/delete/rotate; OAuth device-flow and CLI import (Anthropic, OpenAI, Google, xAI, Figma); token refresh; status | Repo, Credential, Vault, Encryption, Ecto.Query | CredentialPlug (LLM), AuthInjector (MCP), admin, WebSearch, WebXSearch, WebLiveSearch, Embedding, OpenAICodex, CodexAuth | **Keep** — deeply coupled to app data model and OAuth flows; not protocol-library material | ~936 lines; multiple vendor-specific OAuth formats; TokenCache ETS dependency |
| `settings/credentials/vault.ex` | ETS-backed GenServer for credential metadata caching (no plaintext) | Repo, Credential, Phoenix PubSub, GenServer | Credentials, admin | **Keep** — app-scoped cache | Cache invalidation via PubSub |
| `settings/encryption.ex` | AES-256-GCM encrypt/decrypt helpers | :crypto | Credentials, CodexAuth | **Extract** — pure crypto utility, zero external deps beyond `:crypto` | Simple; safe to extract |
| `settings/openai_codex_auth.ex` | Device-flow OAuth for OpenAI Codex (start, poll, exchange, refresh, revoke, read, logout) | Repo, Credential, Credentials, Encryption | Admin UI, CLI | **Keep** — vendor-specific flow | Tied to Backplane credential storage |
| `clients.ex` | MCP client bearer-token verification (BCrypt), scope matching, ETS cache, `filter_tools` | Repo, Client, Bcrypt, Ecto.Query | AuthPlug, McpHandler, Dispatch, Tools.Admin, admin CRUD, HostAgentChannel | **Keep** — app access-control context | BCrypt token hashing; ETS + `:persistent_term` dual cache; fail-closed semantics |
| `clients/client.ex` | Ecto schema for `clients` table (name, token_hash, scopes, active, metadata) | Ecto.Schema, Changeset | Clients | **Keep** | Scope regex and permission lists are app-domain-specific |

## Managed Services (`apps/backplane_mcp/lib/backplane/services/*`)

| Module | Purpose | Deps | Callers | Extract? | Risks |
|---|---|---|---|---|---|
| `day.ex` | Date/time tools via `day_ex` (`day::now`, `day::format`, `day::parse`, `day::diff`) | day_ex, Settings, ManagedService behaviour | Application reconcile, ToolRegistry | **Keep** — thin adapter, already delegates to standalone library | Trivial |
| `math.ex` | Math expression evaluation via `math_ex` (`math::evaluate`) | math_ex, Math.Router, Math.Config, ManagedService behaviour | Application reconcile, ToolRegistry | **Keep** | Delegates to standalone library |
| `skills.ex` | Archive-backed skill toolset (`skill::list`, `skill::load`) delegating to `Backplane.Tools.Skill` | Settings, ToolRegistry, Tools.Skill, ManagedService behaviour | Application reconcile, ToolRegistry | **Keep** | App-specific skill registry |
| `web.ex` | Unified `web::fetch`, `web::search`, `web::live_search`, `web::x_search` | WebFetch, WebSearch, WebLiveSearch, WebXSearch, ManagedService behaviour | Application reconcile, ToolRegistry | **Keep** | Composes multiple search backends |
| `web_fetch.ex` | Fetches URL → Markdown (Req, HTML→Markdown conversion) | Req | Web service | **Keep** | Standalone logic, but no extraction signal |
| `web_search.ex` | Ollama/MiniMax web search backends | Settings, Credentials, Req | Web service | **Keep** | Credential-dependent |
| `web_live_search.ex` | LLM provider-hosted web_search via OpenAI Responses API | LLM.CredentialPlug, ModelResolver, OpenAICodex, Provider, ProviderApi, ProviderModel, RateLimiter, Settings.OAuthRefresher, Req | Web service | **Keep** | Cross-domain (MCP service → LLM proxy); coupling risk for extraction |
| `web_x_search.ex` | xAI X Search via Responses API | Settings, Credentials, OAuthRefresher, Req | Web service | **Keep** | Vendor-specific |

## Config

| Module | Purpose | Deps | Callers | Extract? | Risks |
|---|---|---|---|---|---|
| `apps/backplane_system/lib/backplane/config.ex` | Loads and parses `backplane.toml` (sections: backplane, database, upstream, clients, cache, audit, telemetry) | Toml, Registry.Namespace | `runtime.exs` (prod boot), `Validator` | **Keep** — TOML format is Backplane-specific | No runtime concerns; only boot |
| `apps/backplane_system/lib/backplane/config/validator.ex` | Validates app-env config (port, upstreams) at boot | Registry.Namespace | Application.start | **Keep** | Boot-only |

## Host Agent / Codex Native Transport

| Module | Purpose | Deps | Callers | Extract? | Risks |
|---|---|---|---|---|---|
| `apps/backplane_host_agent/lib/backplane/host_agent/hub_proxy.ex` | Proxies local MCP requests to hub over Phoenix channel (`mcp_tools_list`, `mcp_tool_call` events) | Channel, MemoryProxy, Trace | MemoryRouter, services | **Adapt** — MCP-over-channel is a transport variant; could use a transport-behaviour interface | Phoenix channel-specific; coupled to hub connection lifecycle |
| `apps/backplane_host_agent/lib/backplane/host_agent/services/*.ex` | Local MCP services (Memory, Plugins, Day, Math) implementing same `prefix/tools/call` pattern | HostAgent.Memory, Math.Engine, day_ex | Services registry | **Keep** — local services are agent-runtime specific | Duplicates managed-service pattern but not same module namespace |
| `apps/backplane_host_agent/lib/backplane/host_agent/channel.ex` | Thin wrapper around `phoenix_socket_client` for channel operations | Phoenix.SocketClient | Connector, Worker, HubProxy | **Keep** | TODO(upstream): gsmlg-dev/phoenix_socket_client#98 |
| `apps/backplane_host_agent/lib/backplane/host_agent/http_server.ex` | Bandit HTTP server for MemoryRouter (optional, `http_port`-gated) | Bandit, MemoryRouter | Worker supervision | **Keep** | Simple optional server |
| `apps/backplane_mcp/lib/backplane/mcp/modern_server.ex` | Uses `Backplane.McpProtocol.Server` macro; implements `init_request/2` and `handle_request/2` for modern-era MCP | McpProtocol.Server, Error, Schema, Frame, Dispatch | McpPlug | **Keep** — already uses protocol library macro | Protocol version coupling |

## Dependency Constraints

From `.github/workflows/ci.yml` and umbrella `mix.exs`:

- **Elixir**: `~> 1.18` (all apps); CI pins `1.18.4`
- **OTP**: `28` (BEAM 28+); CI pins `28.5.0.5`
- **warnings-as-errors**: `mix compile --warnings-as-errors` in CI
- **Credo strict**: `mix credo --strict`
- **Dialyzer**: umbrella-level with `plt_local_path: "priv/plts"`; ignore list at `.dialyzer_ignore.exs` (line-agnostic file-based entries)
- **Formatting**: `mix format --check-formatted`
- **Adding a new umbrella child**: Must set `build_path: "../../_build"`, `config_path: "../../config/config.exs"`, `deps_path: "../../deps"`, `lockfile: "../../mix.lock"`, `elixir: "~> 1.18"`. Root `mix.exs` has no explicit `apps` list (Mix auto-discovers). Adding to a release requires updating `releases()` in root `mix.exs`. No `overrides` needed unless a new dep conflicts.

## Key Risks for Library Extraction

1. **Auth coupling**: `McpPlug` chain includes `Backplane.Auth.ResourceAuthPlug` (from `backplane_auth`), which validates OAuth-protected-resource tokens. A protocol library cannot assume this — needs a plug-in auth behaviour.
2. **Credential-to-header injection split**: MCP upstreams use `Proxy.AuthInjector` (bearer/x_api_key/custom_header); LLM providers use `LLM.CredentialPlug` (api_key, oauth2_client_credentials, anthropic_oauth, openai_oauth). Both read from `Settings.Credentials` but format differently. Unification requires a shared "CredentialProvider" behaviour.
3. **Cross-domain service coupling**: `WebLiveSearch` (MCP managed service) depends on `Backplane.LLM.*` modules, creating a dependency from `backplane_mcp` → `backplane_llama`. This is acceptable in the umbrella but blocks clean library boundary.
4. **MCP protocol library already extracted**: `backplane_mcp_protocol` is a standalone app with LGPL-3.0 licensing, standalone Burrito release, and documentation pages. Further extraction should extend this library, not create a parallel one.
5. **Dialyzer ignore list is file-based**: Moving modules to a new app requires updating `.dialyzer_ignore.exs` entries (file paths change).
6. **Observability v2 flags**: `Observability.Flags` controls which writers/buffers are active. Extracted modules must not silently bypass this policy.
7. **Codex auth is credential-store-specific**: `Settings.OpenAICodexAuth` implements device-flow OAuth against OpenAI's CLI-compatible endpoints, storing tokens in the encrypted credential vault. Not extractable without also extracting the vault.
---

# Synapsis Source Inventory

Evidence snapshot: `/Users/gao/Workspace/gsmlg-opt/Synapsis`, branch `main`, commit `fe4ebf7d70d58ec46c1055f22e7c13cb455d8700`. Read-only inspection; no files were checked out or edited. Source tree contains untracked local runtime artifacts (`apps/synapsis_agent/.synapsis/`, `apps/synapsis_agent/global/`), which do not alter committed code.

## Scope and architecture

`apps/synapsis_provider` is a small, protocol-oriented Elixir app in the Synapsis umbrella. It contains request codecs for Anthropic, OpenAI-compatible, and Google APIs, event normalization, SSE parsing, stream guarding, tool-name encoding, OpenAI device OAuth, model metadata, provider configuration persistence, and the HTTP transport/adapter runtime. It depends on `synapsis_data` (umbrella), `req`, `finch`, and `jason`; runtime configuration management is file/TOML-backed through `Synapsis.Config.Store`, not Phoenix.

Agent consumers live in `apps/synapsis_agent`, with shared message/accumulator and tool code in `synapsis_core`. The provider app exposes a caller-neutral, wire-focused API; agent ownership (tool execution, approval, daemon/background work, persistence, fallbacks, and UI) remains host-owned.

## Protocol types and formats

- **Canonical message envelope:** `Synapsis.Message` (`apps/synapsis_data/lib/synapsis/message.ex`) holds `role` (`user`, `assistant`, `system`), ordered polymorphic `parts`, token count, session ID, and timestamp. It is an embedded Ecto schema, not a database record.
- **Part vocabulary:** `Synapsis.Part.Text`, `ToolUse`, `ToolResult`, `Reasoning`, `Image`, `File`, `Snapshot`, and `Agent` (`apps/synapsis_data/lib/synapsis/part/*`). Tool-use status is `:pending | :approved | :denied | :completed | :error`; tool results are plain content plus `is_error`; reasoning carries both text and a provider signature. File/snapshot/agent parts are host-ownership and workspace-domain concepts, not pure provider types.
- **Message serializer:** `%Message{}` encodes to a Concord turn map using `type: "text" | "tool_use" | "tool_result" | "reasoning" | ...` and atom-keyed fields; loader tolerates string keys. Durable message storage is node-local Concord via `Session.Store`, not a database table.
- **Provider runtime configs:** `Synapsis.ProviderConfig` (`apps/synapsis_data/lib/synapsis/provider_config.ex`) validates provider `name`, `type`, `base_url`, encrypted API key, JSON-style config, and enabled state. Valid types: `anthropic`, `openai`, `openai_compat`, `google`, `local`, `openrouter`, `groq`, `deepseek`.
- **Raw stream events:** each transport parses provider JSON and delegates to `EventMapper`; mapper output is a provider-neutral streaming event vocabulary, not the persisted message format.
- **Host-facing telemetry:** provider requests/responses emit `[:synapsis, :provider, :request]` / `[:synapsis, :provider, :response]` telemetry. `SynapsisProvider.Sanitizer` implements header allowlist redaction and debug sanitization.

## Modules and disposition

| Path | Purpose | Key deps | Callers | Disposition | Risks / notes |
|---|---|---|---|---|---|
| `apps/synapsis_provider/lib/synapsis/providers.ex` | Provider configuration CRUD, registry sync, runtime config build, model cache/discovery, presets, default URLs/models/tiers, env-variable resolution, and OAuth token persistence | `Synapsis.Config.Store`, `Synapsis.ProviderConfig`, `Synapsis.Provider.Registry`, `Adapter`, `OAuth.OpenAI` | `SynapsisCore.Application`, `Synapsis.MessageBuilder`, `Synapsis.LLM`, `Synapsis.Session.Worker.Config`, `Synapsis.Session.Worker.Auditor`, web/server UI/controllers | **adapt** | Encodes provider preset names, URLs, tier defaults, and base-URL heuristics directly. Reads/writes `~/.config/synapsis/providers.toml`; falls back to numerous provider env vars. OAuth persistence needs `Synapsis.Encrypted.Binary` and `synapsis_data` app config. |
| `apps/synapsis_provider/lib/synapsis/provider/adapter.ex` | Unified provider facade: streaming, synchronous completion, cancellation, request formatting, model resolution, OAuth 401 retry, telemetry, stream guarding | `Transport.*`, `EventMapper`, `MessageMapper`, `ModelRegistry`, `StreamGuard`, `Sanitizer`, `Req`, `Jason`, BEAM tasks | `Synapsis.Session.Stream`, `Synapsis.MessageBuilder`, `Synapsis.LLM`, `Synapsis.Session.Worker.Auditor`, web provider tests | **extract/adapt** | Core reusable seam. Emits caller messages directly; expects `Synapsis.Provider.TaskSupervisor`, `Synapsis.Providers.refresh_oauth/1`, and UUID generation. Hardcoded 300 s/60 s timeouts and provider default model fallbacks. Anthropic sends both `x-api-key` and bearer headers. |
| `apps/synapsis_provider/lib/synapsis/provider/event_mapper.ex` | Converts provider JSON chunks into neutral stream tuples/events: text/tool/reasoning/done/error lifecycle | `Synapsis.Provider.ToolName`, `Jason` | `Adapter` | **extract** | Canonical neutral stream contract. OpenAI branch recognizes `reasoning_details` / `reasoning_content` and nonstandard tool-call shape; Google supports function calls but no reasoning deltas. |
| `apps/synapsis_provider/lib/synapsis/provider/message_mapper.ex` | Builds provider-specific request bodies from canonical `Synapsis.Part.*` messages/tools | `Synapsis.Part.*`, `ToolName`, `Synapsis.Providers` defaults, `Jason` | `Adapter.format_request/3`, agent/session request builders | **adapt** | Core codec, but module hardcodes default model/tier selection and MiniMax reasoning split heuristics. Anthropic/OpenAI/Google codecs should become explicit adapters. |
| `apps/synapsis_provider/lib/synapsis/provider/transport/sse.ex` | SSE parser with accumulation across HTTP chunks; JSON and `[DONE]` handling | `Jason` | Adapter streaming paths; low-level transports | **extract** | Small, high-value, host-independent. Splits on `\n\n`; other line-ending shapes are not handled. |
| `apps/synapsis_provider/lib/synapsis/provider/stream_guard.ex` | Pure scanner holding back bytes that might complete forbidden substrings; violation redaction | none | `Adapter` streaming path | **extract** | Security-adjacent, pure, and reusable. Violation payloads intentionally expose only matched-byte length. |
| `apps/synapsis_provider/lib/synapsis/provider/tool_name.ex` | Encodes unsafe tool names for OpenAI-safe function names via `syn_` + base64url | none | `MessageMapper`, `EventMapper` | **extract** | Encoded tool-name scheme is a wire contract; must be versioned/shared consistently with any agent/tool registry migration. |
| `apps/synapsis_provider/lib/synapsis/provider/registry.ex` | ETS-backed provider runtime registry: provider name → config, and type/name → unified adapter | ETS, `GenServer` | Core/session/stream tooling, UI, health checks, tests | **adapt** | Uses named `:synapsis_providers` ETS table and GenServer process. Runtime config authority; must be made injectable or namespaced. |
| `apps/synapsis_provider/lib/synapsis/provider/model_registry.ex` | Static model metadata and capabilities for Anthropic, OpenAI, Google, Moonshot, Zhipu, and MiniMax model sets | none | `Adapter.models/1`, web model pickers, context compactor | **adapt** | Fully hardcoded model IDs, context/output windows, and capability flags; duplicate keys appear in OpenAI data. Ideally replaced with dynamic catalog/cache or data-driven source. |
| `apps/synapsis_provider/lib/synapsis/provider/retry.ex` | Exponential backoff helper for 429/5xx/transport errors | none | Not referenced in current source | **keep** | Small standalone utility; unused, so extract only if needed. |
| `apps/synapsis_provider/lib/synapsis/provider/sanitizer.ex` | HTTP debug redaction and sanitized telemetry/request/response projection | allowlist map, `DateTime` | `Adapter`, `Synapsis.Session.DebugTelemetry` | **extract** | Security-sensitive but low coupling. Allowlist and last-4 redaction policy should be preserved. |
| `apps/synapsis_provider/lib/synapsis/provider/oauth/openai.ex` | OpenAI device-code + PKCE OAuth flow: user-code, poll, token exchange, refresh, storage shape | `Req`, fixed OpenAI auth endpoints/client ID | Web and server provider OAuth flows; provider refresh; adapter 401 retry | **adapt** | Hardcoded client ID, base/verification/callback URLs, 15-minute poll cap, 7-day refresh policy. Token storage shape (`oauth_tokens`, `last_refresh`, `auth_mode`) is a compatibility contract. |
| `apps/synapsis_provider/lib/synapsis/provider/transport/anthropic.ex` | Legacy direct Anthropic transport: model fetch, streaming, auth headers, default base URL | `Req`, `SSE` | Superseded by `Adapter`; module remains public | **adapt/keep** | Endpoint and API version are adapter-specific. Sends both Anthropic and bearer auth. Duplicative with Adapter's direct implementation; avoid extracting both versions blindly. |
| `apps/synapsis_provider/lib/synapsis/provider/transport/google.ex` | Legacy direct Gemini transport with model URL construction and streaming | `Req`, `SSE` | Superseded by `Adapter`; not observed in active runtime | **adapt/keep** | Gemini endpoint shape and API-key auth are adapter-specific. |
| `apps/synapsis_provider/lib/synapsis/provider/transport/openai.ex` | Legacy OpenAI-compatible transport including Azure deployment support and model listing | `Req`, `SSE` | Superseded by `Adapter`; not observed in active runtime | **adapt/keep** | Azure URL/auth shape and `openai_compat` model URL rule are adapter details. |
| `apps/synapsis_data/lib/synapsis/part/*.ex` | Canonical message part structs: text, tool use/result, reasoning, image, file, snapshot, agent | Ecto types / structs | Message serialization, mappers, agent persistence | **extract** | `File`, `Snapshot`, and `Agent` are workspace/host concepts; split into host-owned workspace types versus pure provider protocol types before sharing. |
| `apps/synapsis_data/lib/synapsis/message.ex` | Canonical message envelope and Concord persistence codec | `Synapsis.Part`, `Synapsis.Session.Store` | Agent/session persistence, message mappers | **adapt** | Message shape is protocol-relevant, but persistence is host-owned Concord and must not move into a shared provider library. |
| `apps/synapsis_data/lib/synapsis/provider_config.ex` | Provider configuration schema/changeset | Ecto changeset, `Synapsis.Encrypted.Binary` | `Synapsis.Providers`, web/server serialization | **adapt** | Embedded schema plus encrypted field depends on host data app/encryption key; separate config abstraction from protocol package. |

## Agent-side integration points

| Path | Purpose | Key deps | Callers | Disposition | Risks / notes |
|---|---|---|---|---|---|
| `apps/synapsis_agent/lib/synapsis/agent/query_loop.ex` | CCB-style tail-recursive agent loop: user message → provider stream → tool dispatch → tool results → repeat until terminal | `QueryLoop.State`, `Context`, `Executor`, `StreamingExecutor`, `Synapsis.Provider.Adapter`, `Synapsis.Tool.Registry`, `Jason` | Agent runtime/session path | **keep (host)** | MUST stay host-owned. Consumes provider stream and formats provider requests, but owns tool dispatch, result ordering, loop terminal states, max depth/turns, subscriber notification, and stream timeout. Request builders normalize `Synapsis.Part.*` into provider shapes; message/loop boundary is host responsibility. |
| `apps/synapsis_agent/lib/synapsis/agent/streaming_executor.ex` | Eagerly dispatches tool calls during provider stream; concurrent-safe/serial partitioning with ordered result flushing | `Synapsis.Tool.TaskSupervisor`, `QueryLoop.Executor` | `QueryLoop` streaming-tools mode | **keep (host)** | MUST stay host-owned. Tool permission classification, safety, timeouts, and task lifecycle are agent concerns. Uses `Synapsis.Tool.TaskSupervisor`. |
| `apps/synapsis_agent/lib/synapsis/agent/query_loop/executor.ex` | Batch tool executor with concurrency partitioning, retries, and timeout/error normalization | `Synapsis.Tool.TaskSupervisor`, `Synapsis.Tool.Executor` | `QueryLoop` batch mode, `StreamingExecutor` | **keep (host)** | MUST stay host-owned. Tool-level semantics, permission levels, retry policy, and result shape are host/agent domain. |
| `apps/synapsis_agent/lib/synapsis/agent/nodes/llm_stream.ex` | Conversational-loop stream request/fallback node; waits on Worker-owned stream accumulation | `Synapsis.Agent.Runtime.Node`, `Synapsis.Session.Worker` | Agent graph runtime | **keep (host)** | MUST stay host-owned. Owns provider/model fallback list parsing, request rebuild, node routing, and wait/resume against Worker process. |
| `apps/synapsis_agent/lib/synapsis/session/worker/auditor.ex` | Async single-shot escalation/analysis call using provider fast tier | `Synapsis.Provider.Registry`, `Adapter.complete`, `Synapsis.Providers` | `Session.Worker` escalation flow | **adapt (thin caller)** | Can become a standalone-library caller once config/model resolution moves behind a provider-facing facade. Complete() response is text-only today. |
| `apps/synapsis_agent/lib/synapsis/session/worker/config.ex` | Provider/agent/model/tier resolution, session defaults, mode/permission switching | `Synapsis.Provider.Registry`, `Synapsis.Providers`, `Synapsis.Config.load_auth`, `Phoenix.PubSub`, `Synapsis.Session.Store` | Worker boot, stream start, mode/agent switching | **keep/adapt** | MUST stay host-owned for auth/config resolution and persistence. Only the provider-config lookup seam should be exposed to a shared package. |
| `apps/synapsis_agent/lib/synapsis/session/worker/io_handler.ex` | Worker I/O event routing: stream start/cancel/chunk/error, tool dispatch, auditor, debug attachment | `Synapsis.Session.Stream`, `StreamAccumulator`, `ResponseFlusher`, provider registry/config, `Synapsis.Tool.*`, `Phoenix.PubSub` | `Session.Worker`, `GlobalAgent` | **keep (host)** | MUST stay host-owned. All stream event forwarding, tool execution, idempotency/fencing, checkpoints, PubSub, and checkpoint rollback on stream-guard violation are process/host responsibilities. |
| `apps/synapsis_agent/lib/synapsis/session/worker/persistence.ex` | Persists user messages and updates session status; broadcasts session events | `Synapsis.Message`, `Session.Store`, `Phoenix.PubSub` | Session.Worker | **keep (host)** | MUST stay host-owned. Message durability is Concord-based host storage, not provider protocol. |
| `apps/synapsis_agent/lib/synapsis/session/debug_telemetry.ex` | Attaches per-turn provider telemetry handlers; sanitizes and broadcasts/Persists debug payloads | `SynapsisProvider.Sanitizer`, `Phoenix.PubSub`, `SynapsisServer.DebugStore` | Worker stream lifecycle | **keep/adapt** | Event names are a shared convention; handler/store/broadcast belong to host. DebugStore cross-app reference is soft via `@compile {:no_warn_undefined, ...}`. |

## Shared/adjacent runtime dependencies

- `Synapsis.Session.Stream` (`apps/synapsis_core/lib/synapsis/session/stream.ex`) wraps adapter stream/cancel with a named proxy task and fenced `Ref` forwarding to the Worker. It is host-owned process orchestration, not protocol logic.
- `Synapsis.MessageBuilder` (`apps/synapsis_core/lib/synapsis/message_builder.ex`) resolves provider registry/adapter and builds formatted requests; candidate to collapse into the provider package's request-format seam.
- `Synapsis.Agent.StreamAccumulator` (`apps/synapsis_core/lib/synapsis/agent/stream_accumulator.ex`) converts neutral stream events into pending text/tool/reasoning state and PubSub broadcast tuples. Protocol-adjacent but intertwined with host event names.
- `Synapsis.Agent.ResponseFlusher` (`apps/synapsis_core/lib/synapsis/agent/response_flusher.ex`) persists assistant parts/tool results and repairs tool-result adjacency. Host-owned persistence logic; MUST NOT move into provider package.
- `Synapsis.Tool.Registry` / `Synapsis.Tool.Executor` / `Synapsis.Tool.Gateway` / `Synapsis.Tool.TaskSupervisor` provide tool discovery, permissions, execution, and supervision. All MUST remain host-owned; a shared package must accept tool descriptions, never resolve/execute them.
- `Synapsis.Agent.Daemon`, `RunSupervisor`, heartbeat/routine schedulers, and `Session.Worker` handle daemon/background work and process lifecycle. These MUST stay host-owned.

## Model catalogs / capabilities

- `ModelRegistry` hardcodes ~26 model records across Anthropic, OpenAI, Google, Moonshot, Zhipu, and MiniMax, including IDs, display names, context/output windows, and coarse capability flags. This is a rapidly stale, release-coupled source of truth.
- `Synapsis.Providers` separately hardcodes preset provider names, URLs, API type mapping, default/fast/expert model IDs, and base-URL string heuristics for custom providers. Tier model selection is duplicated between preset logic and registry inference.
- `enabled_models` / `available_models` provider config supports cache and allowlist behavior; `refresh_models` calls provider `/models` endpoints where available and normalizes only id/name/context-window.
- No universal capability record exists: model registry entries have `supports_tools`, `supports_thinking`, `supports_images`, `supports_streaming`, while discovered/cache records only retain id/name/context. A shared library should define a stable capability contract without adopting hardcoded IDs.

## Transports, auth, and OAuth

- **HTTP transports:** all provider calls use `Req` over HTTP/SSE. Anthropic uses `/v1/messages`; OpenAI uses `/chat/completions` (plus Azure deployment URL form); Google uses `v1beta/models/<model>:streamGenerateContent?alt=sse` and `:generateContent`. OpenAI-compatible providers route through `/v1/chat/completions` or `/chat/completions` depending on base-URL suffix.
- **SSE:** `Synapsis.Provider.Transport.SSE` is a reusable pure parser; adapter-level streaming consumes it inline with `Req` callbacks and buffer preservation.
- **Auth:** static API keys only. Anthropic sends `x-api-key`, `anthropic-version`, and `Authorization: Bearer`; OpenAI-compatible sends `Authorization: Bearer`; Google uses `x-goog-api-key`; Azure uses `api-key`. Credentials come from provider TOML config, encrypted field, or env fallbacks.
- **OpenAI OAuth:** `Synapsis.Provider.OAuth.OpenAI` implements device-code + PKCE against fixed OpenAI auth URLs, returning access/refresh/id tokens and a config storage shape. `Synapsis.Providers.save_oauth_tokens/2` stores refresh tokens in plaintext TOML config and access token through encrypted field; `Synapsis.Encrypted.Binary` derives key from `synapsis_data` app env. Adapter retries 401 once after refresh.
- **No WebSocket transport exists.** No other OAuth provider flows exist.

## Persisted message / log formats

- Durable conversation storage uses `Synapsis.Message.encode/1`: atom-keyed turn maps containing `id`, `role`, `token_count`, `inserted_at`, and `parts`. Stored as ordered `turns/<n>` entries in node-local Concord via `Synapsis.Session.Store`, not a SQL database.
- `Synapsis.Part` custom Ecto type supports a parallel JSONB string-key codec with `type` discriminators; durable Concord turns use atom-keyed maps with `type` plus type-specific field names. Tool-use status persists as a string; reasoning stores content and signature; unknown parts inspect to text rather than round-tripping losslessly.
- Tool-result repair (`Synapsis.Agent.ResponseFlusher`) preserves adjacency of assistant `tool_use` and user `tool_result` messages and updates `ToolUse` status in the persisted assistant message.
- Provider telemetry metadata (URL, sanitized headers, body, status, duration, provider, model) and provider errors are streamed to optional debug handlers, ETS `SynapsisServer.DebugStore`, and Phoenix PubSub; this is host-owned observability, not provider package persistence.
- Provider credentials/token configuration persists to `~/.config/synapsis/providers.toml` (or `$SYNAPSIS_CONFIG_DIR`): provider record fields, encrypted API key binary, and OAuth token map.

## QueryLoop / tools / daemon / background work boundaries

- **Host-owned:** `QueryLoop`, `StreamingExecutor`, `Executor`, `Session.Worker`, `IOHandler`, checkpoints, stream fallbacks, tool registries/executors, approval/permission flows, daemon/background schedulers, PubSub, persistence, and telemetry handlers.
- **Provider-owned or extractable:** wire request formatting, transport calls, SSE parsing, event normalization, auth header construction, stream cancellation, stream guard, and model fetch.
- **Boundary contract:** the shared library should expose a stable `stream/2`, `complete/2`, `cancel/1`, `format_request/3`, and capability/model listing seam. It must not own tool execution, approval, workspace paths, checkpointing, process supervision, or durable session/message storage.
- **Process boundaries:** adapter stream tasks send messages directly to the caller. A shared package should define the task-supervisor seam and event envelope explicitly rather than assume `Synapsis.Provider.TaskSupervisor` or Synapsis message tuples.

## Standalone package constraints

- **Hardcoded paths:** `Synapsis.Config.Store` resolves `~/.config/synapsis` or `$SYNAPSIS_CONFIG_DIR`; provider configs use `providers.toml`. Do not replicate this inside the shared protocol package; accept provider/config from caller.
- **Named processes / ETS:** `Synapsis.Provider.TaskSupervisor`, `Synapsis.Provider.Registry` GenServer, and `:synapsis_providers` ETS table are global. The tool side also relies on `Synapsis.Tool.TaskSupervisor`. Rename, inject, or namespace these for standalone use.
- **Credential files / encryption:** OAuth tokens and provider API keys are persisted via TOML plus `Synapsis.Encrypted.Binary`; encryption requires `Application.get_env(:synapsis_data, :encryption_key)`. A standalone package must not assume this store.
- **Database/Phoenix:** provider app itself has no direct DB/Phoenix dependency, but is currently umbrella-coupled to `synapsis_data` embedded schemas and Ecto changesets. Host paths use Phoenix PubSub, Concord, Ecto schemas, and DebugStore. A shared library should depend only on pure protocol/runtime code and accept external config/session interfaces.
- **Model hardcoding:** default model, fast/expert tiers, provider presets, and capability metadata are hardcoded in code. Migration must replace these with explicit config/data or a versioned catalog source.
- **Module naming:** `Synapsis.Provider.*`, `SynapsisProvider.Sanitizer`, `Synapsis.Part.*`, and `Synapsis.Providers` are part of existing callers/tests and provider serialization shape; extraction needs either an alias/adaptation layer or deliberate API migration.

## Summary

Synapsis already separates provider wire/adapter logic into `synapsis_provider`, but it remains umbrella-coupled through provider config persistence, data schemas, task supervision, and agent/host runtime assumptions. The strongest shared-library candidates are message/part type vocabulary, SSE parsing, event/message codecs, tool-name encoding, sanitizer, stream guard, adapter dispatch, and model capability listing. Keep host ownership of agent loops, tools, approval/permission, checkpoints, daemon/background scheduling, persistence, PubSub, and provider/config/credential management. A standalone package should define injectable runtime supervision and config seams, replace hardcoded model/catalog data with caller-provided data, and preserve existing neutral stream event contracts to avoid breaking agent and web callers.
