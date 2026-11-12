# Endpoints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve named, DB-managed `/endpoints/{name}/mcp` and `/endpoints/{name}/v1/*` surfaces that behave like root `/mcp` and `/v1/*` but are restricted to configured MCP prefixes, models, and (optionally) clients, each feature being its own OAuth protected resource.

**Architecture:** An `endpoints` table and cached context live in `backplane_system`. An endpoint-level plug in `backplane_api` matches `/endpoints/:name/...`, 404s unknown/disabled/feature-off endpoints, strips the prefix, stores the endpoint in `conn.private[:backplane_endpoint]`, and hands off to the existing `McpPlug` / `LLM.Router`. `ResourceAuthPlug` turns its base resource (`:mcp`/`:v1`) into the dynamic key `{:endpoint, name, base}` when that private is present, enforces no-open-access and the client restriction, and narrows MCP scopes to the allowlist, so every existing MCP scope consumer is restricted without extra wiring. The LLM router filters `/v1/models` and gates the requested model before resolution.

**Tech Stack:** Elixir ≥ 1.18 / OTP 28, Phoenix, Plug, Ecto/Postgres, Boruta OAuth, Phoenix LiveView + phoenix_duskmoon.

**Spec:** `docs/superpowers/specs/2026-11-12-endpoints-design.md`

## Global Constraints

- Root `/mcp`, `/v1/*`, existing OAuth resources (`:mcp`, `:v1`, `:skill_protocol`), and `bp2_` behavior at root are unchanged; existing tests must pass untouched.
- Endpoint name: `^[a-z0-9][a-z0-9-]{0,62}$`, unique, immutable after creation.
- Endpoint key type: `{:endpoint, name :: String.t(), base :: :mcp | :v1}`. Persisted form in `oauth_token_resources.resource`: `"endpoint:<name>:<base>"`.
- Endpoint resource URIs: `api_url("/endpoints/<name>/mcp")`, `api_url("/endpoints/<name>/v1")`. Metadata URIs: `api_url("/.well-known/oauth-protected-resource/endpoints/<name>/<base>")`.
- Forbidden MCP prefixes on endpoints: `admin`, `hub`, `skill`, `system`.
- Endpoints never use open access; missing credentials → 401 with a Bearer challenge carrying `resource_metadata`.
- Unknown / disabled endpoint or disabled feature → 404 (no existence leak).
- LLM routes served on endpoints: `GET /v1`, `GET /v1/models`, `POST /v1/messages`, `POST /v1/chat/completions`, `POST /v1/responses`, `POST /v1/embeddings`. Every other path → 404.
- Default `restrict_clients = false` (all clients allowed); new endpoints `enabled = true` (DB + schema default); form has no enable control (DESIGN.md §6).
- No secrets in logs/audit/UI. Endpoint CRUD audited as action + entity type + id via `Backplane.Admin.Audit.record/3`.
- Tests live in the owning app; `async: true` only without shared state/DB sandbox concerns.
- No commits, branches, or worktrees unless the user explicitly authorizes them. "Checkpoint" steps mean: run the listed checks; commit only if authorized (Conventional Commits, e.g. `feat(endpoints): ...`, no generated-by/co-author trailers).

## Review Focus

1. **Caller scope narrower than the allowlist** (e.g. `bp2_` client with `day::now` only on an endpoint allowing `day`, `web`) — expect only `day::now` visible; intersection must keep the narrower scope, not widen to `day::*`. Test in Task 1.
2. **Managed prompts and `logging/setLevel` on an endpoint for a `*`-scoped caller** — expect prompts only from allowed prefixes and `setLevel` rejected, because `resource_auth.scopes` itself is narrowed. Test in Task 4.
3. **Alias / auto-model requested on an endpoint whose allowlist lists only the underlying `provider/model`** — expect rejection (match is on the requested string, before resolution). Test in Task 5.
4. **Allowlisted model that is later disabled or deleted** — expect it absent from `/v1/models` and the stored entry kept. Test in Task 5 (list) and Task 6 (shown as unavailable).
5. **OAuth token obtained for an endpoint, then the endpoint is disabled and re-enabled, or the client is removed from a restricted list** — expect rejection while disabled/removed and acceptance after re-enable (request-time checks, no cached decision). Test in Task 3.

---

### Task 1: Endpoint schema, context, cache, and policy functions

**Files:**
- Create: `apps/backplane_system/priv/repo/migrations/20261112100000_create_endpoints.exs`
- Create: `apps/backplane_system/lib/backplane/endpoints/endpoint.ex`
- Create: `apps/backplane_system/lib/backplane/endpoints/cache.ex`
- Create: `apps/backplane_system/lib/backplane/endpoints.ex`
- Modify: `apps/backplane_system/lib/backplane_system/application.ex` (start `Backplane.Endpoints.Cache` after Repo/PubSub)
- Test: `apps/backplane_system/test/backplane/endpoints_test.exs`

**Interfaces:**
- Produces:
  - `%Backplane.Endpoints.Endpoint{id, name, description, enabled, mcp_enabled, llm_enabled, mcp_prefixes :: [String.t()], models :: [String.t()], restrict_clients :: boolean, oauth_client_ids :: [String.t()], client_ids :: [Ecto.UUID.t()], inserted_at, updated_at}`
  - `Endpoints.list() :: [Endpoint.t()]` (ordered by name)
  - `Endpoints.get!(id)`, `Endpoints.get_by_name(name) :: Endpoint.t() | nil` (cache read-through)
  - `Endpoints.create(attrs) :: {:ok, Endpoint.t()} | {:error, Ecto.Changeset.t()}`
  - `Endpoints.update(endpoint, attrs)` — ignores `name` and `enabled`
  - `Endpoints.set_enabled(endpoint, boolean)`
  - `Endpoints.delete(endpoint)` — plain delete; token revocation lives in Task 2
  - `Endpoints.active(name, feature :: :mcp | :llm) :: {:ok, Endpoint.t()} | :error` — exists, enabled, and feature on
  - `Endpoints.client_allowed?(endpoint, :oauth | :client_token, client_id) :: boolean`
  - `Endpoints.restrict_tool_scopes(endpoint, caller_scopes :: [String.t()]) :: [String.t()]`
  - `Endpoints.model_allowed?(endpoint, model :: String.t()) :: boolean`
  - `Endpoints.forbidden_prefixes() :: ["admin", "hub", "skill", "system"]`

- [ ] **Step 1: Write failing tests** in `endpoints_test.exs` (DataCase, not async):
  - `create/1` with `%{name: "chatgpt", mcp_enabled: true, mcp_prefixes: ["day", "web"]}` → `enabled == true`, `restrict_clients == false`.
  - name validation: `"Chat GPT"`, `"-x"`, 64-char name rejected; duplicate `"chatgpt"` rejected.
  - `mcp_prefixes: ["hub"]` (each of the four forbidden) → changeset error on `:mcp_prefixes`.
  - `update(e, %{name: "other", enabled: false, models: ["openai/gpt-5"]})` → name and enabled unchanged, models updated.
  - `active("chatgpt", :mcp)` → `{:ok, _}`; `active("chatgpt", :llm)` → `:error`; after `set_enabled(e, false)` → `:error`; `active("nope", :mcp)` → `:error`.
  - Cache coherence: `get_by_name` returns updated struct right after `update/2`, and `nil` after `delete/1`.
  - `client_allowed?`: unrestricted → true for any id; restricted with `oauth_client_ids: ["c1"]`, `client_ids: [id]` → true only for `{:oauth, "c1"}` and `{:client_token, id}`.
  - `restrict_tool_scopes(%{mcp_prefixes: ["day", "web"]}, ...)`:
    - `["*"]` → `["day::*", "web::*"]`
    - `["day::*", "fs::*"]` → `["day::*"]`
    - `["day::now"]` → `["day::now"]` (Review Focus 1)
    - `["web::*", "web::fetch"]` → `["web::*"]` or `["web::*", "web::fetch"]` (either; assert `Clients.filter_tools` result equivalence instead if simpler)
    - `[]` → `[]`
  - `model_allowed?(%{models: ["openai/gpt-5", "fast"]}, "fast")` → true; `"openai/gpt-5-mini"` → false.

- [ ] **Step 2: Run** `mix test apps/backplane_system/test/backplane/endpoints_test.exs` — expect failures (module undefined).

- [ ] **Step 3: Implement.** Migration: `endpoints` table, UUID pk, `name text not null` + unique index, `description text`, `enabled boolean not null default true`, `mcp_enabled`/`llm_enabled boolean not null default false`, `mcp_prefixes`/`models`/`oauth_client_ids` `text[] not null default '{}'`, `client_ids uuid[] not null default '{}'`, `restrict_clients boolean not null default false`, timestamps `utc_datetime_usec`. Cache: GenServer owning a public named ETS table `:backplane_endpoints` keyed by name, read-through on miss (cache `nil` misses too), and every context write deletes the affected name key. `restrict_tool_scopes/2`: for each allowed prefix `p`, emit `"p::*"` if caller has `"*"` or `"p::*"`, else keep caller scopes `"p::<name>"`; dedupe.

- [ ] **Step 4: Run** the test file — expect PASS. Run `mix ecto.migrate` in dev only if the environment is up; tests migrate through the test alias.

- [ ] **Step 5: Checkpoint.** `mix compile --warnings-as-errors && mix format --check-formatted`.

---

### Task 2: Endpoint OAuth resources in `backplane_auth`

**Files:**
- Create: `apps/backplane_system/priv/repo/migrations/20261112100001_allow_endpoint_token_resources.exs` (replace `oauth_token_resources_resource_check` with `resource IN ('mcp','skill_protocol','v1') OR resource ~ '^endpoint:[a-z0-9][a-z0-9-]{0,62}:(mcp|v1)$'`; `down` restores the current constraint)
- Modify: `apps/backplane_auth/lib/backplane/auth/resources.ex`
- Modify: `apps/backplane_auth/lib/backplane/auth/token_resources.ex`
- Modify: `apps/backplane_auth/lib/backplane/auth/schemas/oauth_token_resource.ex`
- Modify: `apps/backplane_auth/lib/backplane/auth/oauth.ex` (`client_allows_resource?/2`, `enabled_client_for_resource?/1`)
- Modify: `apps/backplane_auth/lib/backplane/auth/metadata.ex`
- Modify: `apps/backplane_auth/lib/backplane/auth/bearer_challenge.ex`
- Create: `apps/backplane_auth/lib/backplane/auth/endpoint_access.ex`
- Test: `apps/backplane_auth/test/backplane/auth/resources_test.exs`, `token_resources_test.exs`, create `endpoint_access_test.exs`, create `bearer_challenge_test.exs` if absent

**Interfaces:**
- Consumes: `Backplane.Endpoints.active/2`, `client_allowed?/3`, `delete/1` (Task 1).
- Produces:
  - `@type key :: :mcp | :skill_protocol | :v1 | {:endpoint, String.t(), :mcp | :v1}`
  - `Resources.endpoint_key(name, base)`, `Resources.base(key) :: :mcp | :skill_protocol | :v1`, `Resources.endpoint?(key) :: boolean`
  - `Resources.path/1`, `uri/1`, `metadata_uri/1`, `documentation_uri/1` (endpoint keys use base docs), `valid_scope?/2`, `operation_scope?/2`, `default_scopes/3` accept endpoint keys by delegating to `base/1`
  - `Resources.from_uri/1` resolves `api_url("/endpoints/<name>/<mcp|v1>")` only when `Endpoints.active(name, :mcp | :llm)` succeeds
  - `Resources.to_persisted(key) :: String.t()`, `Resources.from_persisted(String.t()) :: {:ok, key} | :error`
  - `Resources.oauth_bindable?(key) :: boolean` — true for `:mcp`, `:v1`, and endpoint keys
  - `OAuth.client_allows_resource?(client, {:endpoint, name, base})` = client allows `base` AND endpoint active for that feature AND `Endpoints.client_allowed?(endpoint, :oauth, client.id)`
  - `Metadata.protected_resource({:endpoint, name, base})` — same shape as base, `resource` = endpoint URI, `resource_name` = `"Backplane endpoint <name> (MCP|LLM API)"`, base `scopes_supported` where base has them
  - `BearerChallenge.put/3` always adds `resource_metadata` for endpoint keys
  - `EndpointAccess.delete_endpoint(endpoint) :: {:ok, Endpoint.t()} | {:error, term()}` — one `Repo.transaction`: revoke every token whose binding is `"endpoint:<name>:mcp"` or `"endpoint:<name>:v1"`, then `Endpoints.delete/1`

- [ ] **Step 1: Write failing tests.**
  - `resources_test.exs`: with endpoint `"chatgpt"` (mcp only) created via `Backplane.Endpoints.create/1`: `from_uri(api_url("/endpoints/chatgpt/mcp"))` → `{:ok, {:endpoint, "chatgpt", :mcp}}`; `.../chatgpt/v1` → `:error`; after `set_enabled(false)` → `:error`; `valid_scope?({:endpoint, "chatgpt", :mcp}, "day::*")` true, `"system::x"` false; `valid_scope?({:endpoint, "x", :v1}, "llm::invoke")` true; `to_persisted`/`from_persisted` round-trip; `from_persisted("endpoint:Bad:mcp")` → `:error`; `metadata_uri({:endpoint, "chatgpt", :mcp})` == `api_url("/.well-known/oauth-protected-resource/endpoints/chatgpt/mcp")`.
  - `token_resources_test.exs`: `bind_issued("access_token", client_id, value, {:endpoint, "chatgpt", :mcp})` persists `"endpoint:chatgpt:mcp"` and `resource_for_token/1` returns the tuple.
  - `endpoint_access_test.exs`: two tokens bound to `chatgpt` endpoint resources and one bound to `:mcp`; `delete_endpoint/1` revokes the two, leaves the `:mcp` one active, and the endpoint is gone; a client allowed `:mcp` but excluded by a restricted endpoint → `OAuth.client_allows_resource?` false; disabled endpoint → false.
  - `bearer_challenge_test.exs`: endpoint key → header contains `resource_metadata="…/endpoints/chatgpt/mcp"` regardless of request path.

- [ ] **Step 2: Run** `mix test apps/backplane_auth/test/backplane/auth/` — new tests fail.

- [ ] **Step 3: Implement** per Interfaces. Replace `resource in [:mcp, :skill_protocol, :v1]` guards in `TokenResources` / schema validation with `Resources.oauth_bindable?/1` or the persisted-form regex; `persisted_resource!/1` uses `Resources.from_persisted/1` and still raises `LineageError` on corrupt values. `enabled_client_for_resource?/1` for endpoint keys returns true (endpoints always challenge).

- [ ] **Step 4: Run** `mix test apps/backplane_auth` — PASS, including all pre-existing tests.

- [ ] **Step 5: Checkpoint.** compile with warnings-as-errors, format.

---

### Task 3: OAuth HTTP flow and `ResourceAuthPlug` endpoint mode

**Files:**
- Modify: `apps/backplane_auth/lib/backplane/auth/resource_auth_plug.ex`
- Modify: `apps/backplane_api/lib/backplane/api/controllers/auth/token_controller.ex` (lines ~35, 159-216: replace `resource in [:mcp, :v1]` with `Resources.oauth_bindable?/1`)
- Modify: `apps/backplane_api/lib/backplane/api/auth/authorization_request.ex` (only if endpoint keys don't already flow through `OAuth`/`Resources` delegation)
- Modify: `apps/backplane_api/lib/backplane/api/controllers/auth/discovery_controller.ex`, `apps/backplane_api/lib/backplane/api/router.ex` (add `get "/.well-known/oauth-protected-resource/endpoints/:name/:feature"`)
- Test: `apps/backplane_auth/test/backplane/auth/resource_auth_plug_test.exs`, `apps/backplane_api/test/backplane/api/auth/{authorize_controller,token_controller,discovery_controller}_test.exs`

**Interfaces:**
- Consumes: Task 1 context, Task 2 `Resources`/`OAuth`/`BearerChallenge`.
- Produces: contract with Task 4/5. When `conn.private[:backplane_endpoint]` is a `%Endpoint{}`, `ResourceAuthPlug` (opts `resource: base`) uses `key = {:endpoint, endpoint.name, base}` and on success assigns:
  - `:resource_auth` with `resource: key`; for base `:mcp`, `scopes: Endpoints.restrict_tool_scopes(endpoint, caller_scopes)`; for `:v1`, caller scopes unchanged
  - `:tool_scopes` (for `:mcp`) equal to the narrowed scopes
  - `:client` for `bp2_` callers as today
- Endpoint mode rules: missing credential → 401 `oauth_reject` with challenge (never `:open`); invalid credential → 401 challenge; valid `bp2_` client not allowed by `Endpoints.client_allowed?/3` → 403 `{"error":"Forbidden"}`; OAuth token whose binding ≠ `key` → 401 `invalid_token`.

- [ ] **Step 1: Write failing tests.**
  - Plug unit tests (put `:backplane_endpoint` private manually):
    - no clients in DB, no credential → 401 with `www-authenticate` containing `resource_metadata` (contrast with root test that returns `:open`).
    - `bp2_` client scopes `["*"]` on endpoint prefixes `["day"]` → assigns `tool_scopes == ["day::*"]` and `resource_auth.scopes == ["day::*"]`, `resource_auth.resource == {:endpoint, "e", :mcp}`.
    - restricted endpoint, unlisted `bp2_` client → 403; listed → 200 path.
    - OAuth token bound to `:mcp` used on endpoint → 401; token bound to `{:endpoint, "e", :mcp}` used with no endpoint private (root) → 401; bound to endpoint `"e"` used on endpoint `"f"` → 401.
    - Review Focus 5: endpoint token accepted → `set_enabled(false)` → rejected → `set_enabled(true)` → accepted; restricted list removal → rejected.
  - Controller tests: full authorization-code + PKCE flow with `resource=api_url("/endpoints/chatgpt/mcp")` for a client allowed `mcp` → access token whose JWT `aud` equals that URI; refresh keeps the binding; `resource` for a restricted endpoint excluding the client → `invalid_target`/error per existing authorize conventions; `GET /.well-known/oauth-protected-resource/endpoints/chatgpt/mcp` → 200 with `resource` = endpoint URI; unknown name or disabled feature → 404.

- [ ] **Step 2: Run** `mix test apps/backplane_auth/test/backplane/auth/resource_auth_plug_test.exs apps/backplane_api/test/backplane/api/auth` — new tests fail.

- [ ] **Step 3: Implement** per Interfaces. Keep root code paths byte-for-byte in behavior: endpoint branching is entered only when the private is present.

- [ ] **Step 4: Run** the same commands — PASS, plus pre-existing tests in both directories.

- [ ] **Step 5: Checkpoint.**

---

### Task 4: `/endpoints/:name/mcp` routing and MCP restriction

**Files:**
- Create: `apps/backplane_api/lib/backplane/api/endpoints_plug.ex`
- Modify: `apps/backplane_api/lib/backplane/api/endpoint.ex` (plug `Backplane.Api.EndpointsPlug` immediately before `Backplane.LLM.ProxyPlug`)
- Modify: `apps/backplane_mcp/lib/backplane/mcp/modern_server.ex` (`normalize_auth_field(:resource, …)` accepts endpoint keys)
- Modify: `apps/backplane_mcp/lib/backplane/mcp/dispatch.ex` (skip skill prompts in `list_prompts`/`get_prompt` and skill completions when `Resources.endpoint?(context.auth.resource)`)
- Test: create `apps/backplane_api/test/backplane/api/endpoints_mcp_test.exs`; extend `apps/backplane_mcp/test/backplane/mcp/dispatch_test.exs`, `modern_server_test.exs`

**Interfaces:**
- Consumes: Task 1 `Endpoints.active/2`; Task 3 plug contract.
- Produces: `Backplane.Api.EndpointsPlug` (`@behaviour Plug`). For `path_info: ["endpoints", name, "mcp" | rest]`: `Endpoints.active(name, :mcp)` or 404 JSON `{"error":"Not found"}`; else `put_private(:backplane_endpoint, endpoint)`, set `path_info: rest`, `script_name: script_name ++ ["endpoints", name, "mcp"]`, keep `request_path`, call `Backplane.Transport.McpPlug` and halt. `["endpoints", name, "v1" | rest]` is Task 5. Any other `["endpoints" | _]` → 404. Non-matching paths pass through untouched.

- [ ] **Step 1: Write failing tests** (`endpoints_mcp_test.exs`, ConnCase through `Backplane.Api.Endpoint`, upstream/managed tools registered via existing fixtures or `ToolRegistry` test helpers):
  - endpoint `chatgpt` prefixes `["day"]`, `bp2_` client `["*"]`: legacy `initialize` + `tools/list` returns only `day::*` tools; `tools/call` `web::fetch` → JSON-RPC error `-32001`.
  - Same with header `MCP-Protocol-Version: 2026-07-28` (modern era): `tools/list` filtered identically.
  - `prompts/list` contains no skill prompts and only managed prompts of allowed prefixes; `logging/setLevel` rejected (Review Focus 2).
  - `GET` SSE and `DELETE` with session work on `/endpoints/chatgpt/mcp` as at `/mcp`; `HEAD` → 204.
  - unknown name, disabled endpoint, `mcp_enabled: false`, `/endpoints/chatgpt/other` → 404.
  - Root `/mcp` with the same client still lists all tools (regression).

- [ ] **Step 2: Run** `mix test apps/backplane_api/test/backplane/api/endpoints_mcp_test.exs apps/backplane_mcp/test/backplane/mcp/dispatch_test.exs apps/backplane_mcp/test/backplane/mcp/modern_server_test.exs` — new tests fail.

- [ ] **Step 3: Implement** per Interfaces.

- [ ] **Step 4: Run** the same, then `mix do --app backplane_mcp cmd mix test` — PASS.

- [ ] **Step 5: Checkpoint.**

---

### Task 5: `/endpoints/:name/v1/*` routing and model restriction

**Files:**
- Modify: `apps/backplane_api/lib/backplane/api/endpoints_plug.ex`
- Create: `apps/backplane_llama/lib/backplane/llm/model_catalog.ex` (move body of `Router.build_model_list/0` here unchanged)
- Modify: `apps/backplane_llama/lib/backplane/llm/router.ex` (`/v1/models`, `proxy_request/2`, `proxy_embedding_request/1`)
- Test: create `apps/backplane_api/test/backplane/api/endpoints_llm_test.exs`; existing `router_test.exs` / `router_models_metadata_test.exs` must stay green

**Interfaces:**
- Consumes: Task 1 `Endpoints.active/2`, `model_allowed?/2`; Task 3 plug contract.
- Produces:
  - `Backplane.LLM.ModelCatalog.entries() :: [map()]` — the exact list root `/v1/models` returns today (also used by Task 6).
  - `EndpointsPlug` for `["endpoints", name, "v1" | rest]`: `Endpoints.active(name, :llm)` or 404; `{method, rest}` must be one of `{"GET", []}`, `{"GET", ["models"]}`, `{"POST", ["messages"]}`, `{"POST", ["chat", "completions"]}`, `{"POST", ["responses"]}`, `{"POST", ["embeddings"]}` else 404 (Anthropic-style `not_found_error` body as `Router`'s `match _`); then `put_private(:backplane_endpoint, endpoint)`, `path_info: ["v1" | rest]`, `request_path: "/" <> Enum.join(["v1" | rest], "/")`, call `Backplane.LLM.Router`, halt.
  - Router: `GET /v1/models` filters `ModelCatalog.entries()` to `id in endpoint.models` when the private is set; `GET /v1` on an endpoint returns the endpoint resource URI; in `proxy_request/2` and the embedding path, right after `ModelExtractor.extract/1` succeeds and before `ModelResolver.resolve/2`, reject `not Endpoints.model_allowed?(endpoint, model_string)` with 403 in the client protocol's error shape (`permission_error` for Anthropic messages, `{"error":{"type":"invalid_request_error","code":"model_not_allowed"}}` for OpenAI shapes) and finalize the access event as a validation error.

- [ ] **Step 1: Write failing tests** (`endpoints_llm_test.exs`, using existing `TestLLMUpstream` / provider fixtures):
  - endpoint `openclaw` (llm on, `models: ["test/model-a", "test/model-b"]`), provider `test` with models a, b, c: `GET /endpoints/openclaw/v1/models` ids == `["test/model-a", "test/model-b"]`.
  - `POST /endpoints/openclaw/v1/chat/completions` model `test/model-a` → proxied 200; `test/model-c` → 403 `model_not_allowed`; `/v1/messages` with model a → 200, model c → 403.
  - alias `fast → test/model-a` exists but not allowlisted → 403 (Review Focus 3).
  - disable model b on the provider → `/v1/models` lists only a; endpoint still stores b (Review Focus 4).
  - `/endpoints/openclaw/v1/audio/speech`, `/v1/codex/models`, `/v1/providers/x/models` → 404; `llm_enabled: false` → 404.
  - unrestricted endpoint accepts any active `bp2_` client; that client at root `/v1/models` still sees all of a, b, c.
  - root `/v1/models` unchanged (regression).

- [ ] **Step 2: Run** `mix test apps/backplane_api/test/backplane/api/endpoints_llm_test.exs` — fails.

- [ ] **Step 3: Implement** per Interfaces.

- [ ] **Step 4: Run** it, then `mix do --app backplane_llama cmd mix test` — PASS.

- [ ] **Step 5: Checkpoint.**

---

### Task 6: Admin UI — System → Endpoints

**Files:**
- Create: `apps/backplane_admin/lib/backplane/admin/live/endpoints_live.ex`
- Modify: `apps/backplane_admin/lib/backplane/admin/router.ex` (`live("/system/endpoints", EndpointsLive, :index)`, `/system/endpoints/new` `:new`, `/system/endpoints/:id/edit` `:edit`)
- Modify: `apps/backplane_admin/lib/backplane/admin/components/layouts.ex` (System sidebar item `Endpoints`, icon `lan-connect`, after `Clients`)
- Reuse: modal hook pattern from `apps/backplane_admin/assets/js/hooks/openai_service_modal.js` (no new hook unless the existing one cannot be reused)
- Test: create `apps/backplane_admin/test/backplane/admin/live/endpoints_live_test.exs`

**Interfaces:**
- Consumes: Task 1 context; Task 2 `EndpointAccess.delete_endpoint/1`, `Resources.uri/1`, `Resources.metadata_uri/1`; Task 5 `ModelCatalog.entries/0`; `Backplane.Registry.ToolRegistry.list_all/0` (prefixes from `{:upstream, p}` / `{:managed, p}` origins, minus `Endpoints.forbidden_prefixes/0`); `Backplane.Auth.OAuth.list_clients/0`; `Backplane.Clients` list function used by `ClientsLive`; `Backplane.Admin.Audit.record/3` with actions `endpoint.create|update|enable|disable|delete`, target type `"endpoint"`.

Follow DESIGN.md §3–§8 exactly (reference: `openai_proxy_live.ex`). Table columns: Name, Features, MCP services, Models, Clients ("All clients" or count), Status, Actions (edit `pencil`, enable `play`/disable `pause`, delete `delete` with confirmation naming the endpoint and stating its tokens are revoked). Form fields: Name (read-only on Edit), Description, MCP enabled + prefix multi-select, LLM enabled + model multi-select, "Restrict clients" + OAuth client and `bp2_` client multi-selects. Row detail shows, for each enabled feature, the endpoint URL and metadata URL in monospace. Allowlisted entries missing from current options render with an "Unavailable" badge and stay selected.

- [ ] **Step 1: Write failing tests:** Add opens clean modal; create `chatgpt` → row appears enabled, audit recorded; Edit keeps enabled state and disables Name; Cancel writes nothing and next Add is clean; validation error (`hub` prefix, bad name) keeps modal and input; disable/enable icons toggle Status badge; delete requires confirmation and calls `EndpointAccess.delete_endpoint/1`; URLs shown for enabled features only; an allowlisted model not in the catalog shows "Unavailable"; icon buttons have `aria-label`s like `Edit chatgpt endpoint`.

- [ ] **Step 2: Run** `mix test apps/backplane_admin/test/backplane/admin/live/endpoints_live_test.exs` — fails.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run** it — PASS. Then browser-verify on `http://localhost:4221/system/endpoints` (desktop + ~390px, sunshine + moonlight, keyboard open/Escape/focus return, tooltips) with chrome-devtools; capture screenshots for the PR.

- [ ] **Step 5: Checkpoint.** Also `mix assets.deploy` succeeds if assets changed.

---

### Task 7: Docs and full verification

**Files:**
- Modify: `AGENTS.md` (Key Routes rows for `/endpoints/{name}/mcp` and `/endpoints/{name}/v1/*`; `endpoints` in Data Storage; System → Endpoints in admin routes; one paragraph under Authentication Boundaries: endpoints never open, OAuth audience-bound, `bp2_` unbound with optional restriction)

- [ ] **Step 1:** Update `AGENTS.md` as listed.
- [ ] **Step 2:** Run and record results: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test`, `mix run --no-start test/ci_workflow_test.exs`, `mix dialyzer`. Report any out-of-scope failure without fixing it.
- [ ] **Step 3:** Inspect the integrated diff (`git diff`) for root-path behavior changes and stray edits.
- [ ] **Step 4: Checkpoint.**
