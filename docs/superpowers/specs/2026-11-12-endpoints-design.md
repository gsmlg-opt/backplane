# Endpoints: Named, Restricted LLM + MCP Surfaces

Status: design, awaiting approval (builder-checked)
Date: 2026-11-12

## Intent

Operators want to hand Backplane to specific agents without exposing everything.
Examples from the operator:

- **ChatGPT web plugin (connector)**: only a few MCP services.
- **Claude Code**: a few MCP services (skills come later, via HTTP, not MCP).
- **openclaw**: a few models plus a few MCP services.

An **endpoint** is a named, DB-managed slice of the gateway served under
`/endpoints/{name}/`. It re-exposes the LLM proxy and MCP hub exactly as they
behave at the root (`/v1/*`, `/mcp`), but limited to the features, models, MCP
services, and clients the operator selected. The point is to give an agent one URL
that exposes exactly the configured slice.

Credentials are **not bound** to endpoints (operator's decision). A `bp2_` client
keeps working at the root and at any endpoint that allows it; isolation, when
wanted, comes from giving that agent a narrowly scoped client.

The existing OAuth implementation was built for this purpose and is unfinished;
this work completes the parts endpoints need.

## Goals

1. Admin can create, edit, enable/disable, and delete endpoints.
2. Each endpoint exposes, independently toggled:
   - **MCP** at `/endpoints/{name}/mcp` (POST, plus legacy GET SSE / DELETE), same
     protocol behavior as `/mcp` for both downstream eras (legacy `2025-11-25` etc.
     and modern stateless `2026-07-28`).
   - **LLM** at `/endpoints/{name}/v1/*`, including `/v1/messages`, same behavior as
     root `/v1/*`.
3. Per-endpoint allowlists:
   - **MCP services**, by tool namespace prefix (`day`, `web`, an upstream prefix,
     ...). Only those tools appear in `tools/list` and may be called.
   - **Models**. Only those appear in `/v1/models` and may be requested.
   - **Clients**: optional restriction. **By default every client may use the
     endpoint** (all `bp2_` clients and all enabled OAuth clients that are allowed
     the matching base resource); the operator may instead select specific OAuth
     and `bp2_` clients, and then only those may use it.
4. Effective permission is the **intersection** of the endpoint allowlist and the
   caller's own scopes. An endpoint never grants a client more than it already has.
5. Each endpoint feature is its own OAuth protected resource with its own RFC 9728
   metadata and token audience. A token issued for root `/mcp` is rejected at an
   endpoint, a token for one endpoint is rejected at another endpoint and at the
   root. (OAuth tokens are resource-bound by audience; `bp2_` tokens are not.)

## Non-goals (this round)

- Skills on endpoints (they will be delivered over HTTP later, never via MCP).
- OAuth Dynamic Client Registration / CIMD. ChatGPT is connected by creating an
  OAuth client manually in admin and entering its client_id/secret in ChatGPT.
- Changing behavior of root `/mcp`, `/v1/*`, or existing OAuth resources.
- Google `/v1beta/*`, `/antigravity/*`, and provider passthrough
  `/v1/providers/:provider/*` on endpoints (they cannot be model-gated cleanly).
- Per-endpoint rate limits, quotas, usage dashboards, or endpoint columns in logs.
- Per-tool (rather than per-prefix) MCP allowlists.

## Anti-goals (failure even if it "works")

- Any path where an endpoint exposes a tool or model outside its allowlist,
  including through hub meta tools (`hub::discover` etc.), prompts, ETag-cached
  lists, the modern MCP server path, or alias/auto-model resolution.
- An OAuth token bound to the root or another endpoint being accepted at an
  endpoint.
- A client excluded by an endpoint's client restriction being accepted there.
- Endpoints falling into "open access" development mode.
- A disabled or deleted endpoint still serving requests or validating tokens.

## Decided by the operator

- Path shape `/endpoints/{name}/` with `mcp` and `v1/*` underneath, behaving like
  the root routes.
- Configurable: which features are on, which models, which clients.
- Only LLM and MCP this round; no DCR this round.
- Credentials are not bound to endpoints; by default all clients may use an
  endpoint, optionally restricted to selected clients.
- Admin UI management page is required this round.
- The overall direction in this document (endpoint record, intersection rule,
  per-feature OAuth resources, allowed-client list) was approved in conversation.

## Design (the designer's calls, approved as a direction)

### Data model

New table `endpoints` (migration in `apps/backplane_system`), schema and context
`Backplane.Endpoints` in `backplane_system` because `backplane_auth`,
`backplane_mcp`, and `backplane_llama` all need to read it and all already depend
on `backplane_system`.

Fields:

| Field | Notes |
|---|---|
| `id` | UUID |
| `name` | Unique, URL-safe slug `^[a-z0-9][a-z0-9-]{0,62}$`. **Immutable after creation** (it is part of token audiences). |
| `description` | Optional text |
| `enabled` | Default true (DB + schema default, per DESIGN.md §6) |
| `mcp_enabled` / `llm_enabled` | Feature toggles |
| `mcp_prefixes` | `text[]` of allowed tool namespace prefixes |
| `models` | `text[]` of allowed model names, as clients send them and as `/v1/models` lists them (`provider/model`, aliases, auto-models) |
| `restrict_clients` | Boolean, default false. False = all clients allowed; true = only the lists below |
| `oauth_client_ids` | `text[]` of allowed Boruta OAuth client ids (used when restricted) |
| `client_ids` | Allowed `bp2_` client ids (used when restricted; array or join table — builder's choice) |
| timestamps | |

Reads go through an ETS cache invalidated on change (same pattern as
`Backplane.Clients` / Settings), since every endpoint request consults it.

### Resource identity (OAuth)

`Backplane.Auth.Resources` gains dynamic keys `{:endpoint, name, :mcp | :v1}`
alongside the fixed atoms.

- Path / canonical URI: `api_url("/endpoints/{name}/mcp")` and
  `api_url("/endpoints/{name}/v1")`.
- RFC 9728 metadata: `/.well-known/oauth-protected-resource/endpoints/{name}/mcp`
  and `.../endpoints/{name}/v1` (path-inserted form matching the resource path).
  `WWW-Authenticate` challenges on endpoint paths point there.
- Scope vocabulary is the same as the corresponding base resource (`:mcp` or
  `:v1`).
- `from_uri` resolves endpoint URIs via the endpoints cache; unknown, disabled, or
  feature-off endpoints do not resolve.
- An OAuth client may be authorized and issued tokens for an endpoint resource if
  it is enabled and allowed the matching base resource (`mcp` / `v1` in its
  `backplane_resources`), and, when the endpoint restricts clients, it is listed in
  `oauth_client_ids` (designer's call for how "all clients" maps to OAuth).
- Token verification at an endpoint re-checks at request time: endpoint exists,
  is enabled, the feature is on, and the client is still allowed. Removing a client
  or disabling an endpoint takes effect immediately for existing tokens.
- Deleting an endpoint revokes every access and refresh token bound to its
  resources in the same transaction (designer's call), so a later endpoint with
  the same name never revives old tokens.
- Prefix stripping must rewrite both `path_info` and `request_path`
  (`ResourceAuthorization.required_scope` matches on `request_path`).
- `completion/complete` and legacy SSE list-changed notifications get the same
  prefix filter as `tools/list`.
- User RBAC scopes still apply as today.

### Request authentication on endpoints

- OAuth access token: must be bound to exactly this endpoint resource (audience).
- `bp2_` client token: any active client, unless the endpoint restricts clients,
  in which case it must be listed. Its own scopes still apply. The same token keeps
  working at the root as today.
- **No open access** (designer's call). Endpoints always require a credential,
  even when no clients exist at all. A restricted endpoint with empty lists serves
  nobody.
- Invalid or disallowed credentials: 401 with challenge (unknown credential) or
  403 (known but not allowed), consistent with existing `ResourceAuthPlug`
  semantics.

### Routing

- Unknown endpoint name, disabled endpoint, or disabled feature: 404 (do not
  reveal existence).
- LLM: endpoint-level interception before `Plug.Parsers` (the LLM proxy needs the
  raw body), analogous to `Backplane.LLM.ProxyPlug`. It strips the
  `endpoints/{name}` prefix so downstream `path_info`-based logic
  (`ResourceAuthorization.required_scope`, route matching) sees `v1/...`, and
  carries the endpoint in `conn` assigns / private.
- MCP: `/endpoints/{name}/mcp` reaches `McpPlug` with the endpoint resource
  instead of hardcoded `:mcp`. HEAD short-circuit applies here too.
- MCP sessions carry only the negotiated protocol version; authorization and
  scopes are evaluated per request, so a session id reused on another endpoint or
  at root gains nothing. No session isolation work is needed.

### MCP restriction

Prefixes `admin`, `hub`, `skill`, and `system` cannot be allowlisted on an
endpoint (validation rejects them; pickers omit them), and no hub/admin
management tool is reachable on an endpoint. Rationale (designer's call):
`admin::*` could mint credentials that escape the endpoint, `hub::*` acts on
gateway-wide state, and skills are out of scope.

Effective tool scopes = caller scopes ∩ `{prefix}::*` for each allowed prefix.
Apply it once where the request context is built so every consumer sees it:
`tools/list` (and its ETag), `tools/call`, `tasks/create`, managed prompts,
hub meta tools that enumerate or describe tools, and the modern server path
(`Backplane.MCP.ModernServer`). Skill prompts from `SkillsRegistry` are not exposed
on endpoints. Admin-only methods (`logging/setLevel`) remain governed by existing
rules on the caller's scopes and are not widened.

### LLM restriction

- `/v1/models` on an endpoint lists only allowlisted models that are currently
  available (enabled provider/model, existing alias).
- Every model-bearing request checks the requested model string against the
  allowlist **before** resolution. Disallowed: an OpenAI/Anthropic-shaped 403 or
  404 error (builder's choice of exact shape, consistent with existing proxy
  errors).
- Routes under `/v1` that carry no gateable model and are not `/v1/models` are
  not served on endpoints (404), unless the builder confirms they cannot reach a
  model outside the allowlist.
- Operation scopes (`llm::models` / `llm::invoke`) apply as at root.

### Admin UI

New page **System → Endpoints** at `/system/endpoints` (next to Clients),
following DESIGN.md: table with Name, Features, MCP services, Models, Clients,
Status, and icon Actions (edit, enable/disable, delete); Add/Edit modal; new
endpoints enabled by default with no enable control in the form; name read-only
in Edit. The page shows each enabled feature's full URL and its RFC 9728 metadata
URL so the operator can paste them into ChatGPT / Claude Code / openclaw.

Pickers source options from: MCP prefixes in the tool registry (managed +
upstream), models from the same catalog as `/v1/models`, OAuth clients, and `bp2_`
clients. Allowlist entries whose target no longer exists are kept and shown as
unavailable, not silently dropped.

## Constraints

- Root routes and existing tokens behave exactly as before (regression-tested).
- Both MCP downstream eras work on endpoints; both upstream eras unaffected.
- No secrets in logs, audit records, or UI. Endpoint CRUD is audited (action,
  entity type, id).
- Tests follow AGENTS.md conventions (owning app's test support, no cross-app test
  helpers, `async: true` only when safe).

## Left to the builder

- Exact module names and file layout within the owning apps.
- Array columns vs join tables for client allowlists.
- Exact error bodies for disallowed models, within existing proxy conventions.
- How the endpoint is threaded through `conn` (assigns vs private) and the MCP
  context.
- Cache implementation details.
- Whether to fix incidental OAuth issues found on the way (e.g. per-request load of
  all clients in `enabled_client_for_resource?`) — only where endpoint code paths
  require it; otherwise record them.

## Acceptance

- Create endpoint `chatgpt` (MCP only, prefixes `day`, `web`, one OAuth client):
  OAuth flow with `resource=…/endpoints/chatgpt/mcp` yields a token;
  `tools/list` shows only `day::*`/`web::*`; calling another prefix is rejected;
  that token is rejected at `/mcp`, `/v1`, and other endpoints.
- Create endpoint `openclaw` (MCP + LLM, two models, restricted to one `bp2_`
  client):
  `/endpoints/openclaw/v1/models` lists only those two; a third model is rejected;
  `/v1/messages` and `/v1/chat/completions` work for allowed models; a different
  `bp2_` client is rejected.
- An unrestricted endpoint accepts any active `bp2_` client; that client still
  works at root `/mcp` / `/v1` unchanged.
- Disabling the endpoint or removing a client takes effect on the next request.
- Unknown name / feature off → 404. No credential → 401 even with zero clients
  configured.
- Root `/mcp` and `/v1` regressions pass unchanged.
