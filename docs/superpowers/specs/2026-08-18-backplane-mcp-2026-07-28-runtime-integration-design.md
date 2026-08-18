# Backplane MCP 2026-07-28 Runtime Integration Design

**Date:** 2026-08-18
**Status:** Approved design, pending written-spec review
**Scope:** Backplane public MCP endpoint, upstream MCP proxy, upstream configuration UI, and the minimal reusable protocol-package seams they require

## Objective

Add end-to-end MCP `2026-07-28` support to Backplane's public `/mcp` endpoint and upstream proxy while preserving the existing legacy behavior and keeping `2025-11-25` as the default.

The integration must reuse the conformant client, server, negotiation, metadata, header, result, error, and transport primitives already implemented in `apps/backplane_mcp_protocol`. Backplane must not grow a second handwritten implementation of the modern wire protocol.

## Decisions

- The endpoint default remains `2025-11-25`.
- Every currently supported legacy endpoint version remains supported:
  - `2024-11-05`
  - `2025-03-26`
  - `2025-06-18`
  - `2025-11-25`
- `2026-07-28` is additionally supported through explicit modern protocol markers.
- Legacy versions continue to negotiate through `initialize`. A request for an exact supported legacy version receives that version and creates a version-aware legacy session.
- Modern `server/discover` reports modern profiles only, currently `2026-07-28`. Legacy versions remain supported but are intentionally absent from modern discovery.
- Each upstream persists one protocol preference:
  - `2025-11-25` — default legacy preference;
  - `2026-07-28` — strict modern preference;
  - `auto` — modern discovery with the protocol package's classified legacy fallback.
- A successful legacy upstream initialization may return an older transport-compatible legacy version. That returned version becomes authoritative client state.
- The modern endpoint advertises only the capabilities Backplane implements end-to-end in this milestone: tools, resources, prompts, and completion.
- Modern MRTR, `subscriptions/listen`, Tasks, logging configuration, and optional authorization extensions are not advertised or implemented in this milestone.
- Release and deployment are separate follow-up actions.

## Non-goals

- Replacing Backplane's legacy session transport with the protocol package's legacy server implementation.
- Adding modern MRTR callbacks for roots, sampling, or elicitation.
- Adding modern long-lived subscriptions or list-change notifications.
- Adding the optional modern Tasks extension.
- Adding legacy HTTP+SSE as a new upstream transport. Existing upstream transport compatibility remains unchanged: stdio supports `2024-11-05`; Streamable HTTP supports `2025-03-26` and newer.
- Changing LLM proxy behavior or any non-MCP public route.
- Releasing or deploying the implementation.

## Architecture

The integration is a hybrid adapter. Backplane retains ownership of authentication, authorization, registries, namespaces, caching, idempotency, rate limiting, audit behavior, and operational configuration. The protocol package retains ownership of protocol-era routing rules, modern metadata and headers, stateless execution, response normalization, negotiation, transport behavior, and conformance-sensitive errors.

### Public endpoint

The existing `Backplane.Transport.McpPlug` pipeline remains in front of both protocol eras:

```text
CORS
  -> request logging
  -> rate limiting
  -> resource authentication
  -> idempotency
  -> JSON parsing
  -> era routing
       -> legacy McpHandler and Session
       -> modern protocol-package dispatcher and ModernServer adapter
```

A new plain-function era router classifies the parsed request and transport headers. It creates no process and retains no state.

- `initialize`, an existing `Mcp-Session-Id`, or an unmarked request selects the legacy path.
- `server/discover`, modern body `_meta`, or a modern/unknown MCP protocol header selects the modern path.
- Simultaneous hard legacy and modern markers return an invalid-request error rather than guessing.
- Legacy `initialize` with `protocolVersion: "2026-07-28"` remains legacy and negotiates to the default legacy version instead of creating a modern session.

The legacy route continues through the current `McpHandler` and `Backplane.Transport.Session` without changing GET, POST, DELETE, SSE, task, or version-shaped response behavior.

The modern route uses a reusable pre-authorized Streamable HTTP dispatch seam extracted from the protocol package's existing Plug. That seam accepts the already authenticated and parsed connection, request message, transport context, server adapter, task supervisor, and timeout. It owns modern profile selection, header validation, HTTP status mapping, request-scoped SSE formatting, and response encoding. The package's standalone Plug also uses this seam so the two integrations cannot drift.

### Modern server adapter

`Backplane.MCP.ModernServer` is a module implementing the protocol package server contract; it is not a process.

It reports:

- server identity and instructions from Backplane;
- supported modern profile `2026-07-28`;
- tools, resources, prompts, and completions capabilities without list-change or subscription flags.

`init_request/2` copies only trusted request-local Backplane assignments into the frame: normalized resource auth, client record, granted scopes, and request identity. It also projects the currently visible tool definitions and raw schemas into that request frame so the protocol package can validate named and custom parameter headers before application dispatch. The frame is discarded after every request.

The adapter delegates application work to a shared `Backplane.MCP.Dispatch` boundary extracted from `McpHandler`. Both legacy and modern transports use this boundary for:

- tool listing, schema projection, validation, scope filtering, and calls;
- resource listing, template listing, and reads;
- skill and managed-prompt listing and retrieval;
- completion calculation;
- upstream forwarding, result formatting, caching, and audit side effects.

This extraction must preserve legacy response behavior. Protocol-specific envelope shaping remains in the legacy handler or modern protocol package, not in the shared application dispatcher.

### Supervision

Normal modern requests require callback fault isolation and deadlines but no persistent session state. `BackplaneMcp.Application` therefore adds only a named `Task.Supervisor` for modern request execution. It does not start a modern session registry, subscription hub, or HTTP listener.

### Upstream proxy

`Backplane.Proxy.Upstream` remains the public coordinator and ToolRegistry-facing PID. Existing callers, Pool behavior, registry ownership, admin start/stop actions, refresh scheduling, and reconnect backoff retain their contracts.

Wire communication moves to `Backplane.McpProtocol.Client` for every configured upstream protocol preference. Backplane does not retain a separate handwritten modern request path.

The application adds:

- `Backplane.Proxy.ProcessRegistry`, keyed with terms such as `{prefix, :client}` and `{prefix, :transport}` so no dynamic atoms are created;
- `Backplane.Proxy.ClientPool`, a `DynamicSupervisor` for protocol-client supervision trees.

Each protocol client tree is temporary from the pool's perspective because `Upstream` owns terminal reconnect and exponential-backoff policy. The protocol client's internal one-for-all supervision still restarts its client and transport together for recoverable failures. `Upstream` monitors the client tree, removes registered tools on loss, and starts a replacement only through its existing reconnect path.

### Minimal protocol-package additions

The Streamable HTTP client transport gains two generic options:

- an exact endpoint `:url`, mutually exclusive with `:base_url` plus `:mcp_path`;
- a zero-arity `:headers_provider` returning `{:ok, headers}` or `{:error, reason}`.

The provider runs for every outbound HTTP request, including POST, legacy GET, session DELETE, and request-scoped streams. Static headers and provider headers are merged deterministically. Provider failures are sanitized transport errors. The protocol package does not depend on Backplane's credential store.

Backplane supplies a provider that resolves the configured credential through `Backplane.Proxy.AuthInjector` on every request. Credential rotation therefore takes effect without restarting an upstream, and decrypted credentials never become long-lived protocol-client state.

## Endpoint data flow

1. The common Plug pipeline authenticates the request and assigns normalized auth and scopes.
2. JSON is decoded once with the existing body-size limit and raw-body support.
3. The era router evaluates the method, body metadata, protocol header, and session header.
4. Legacy traffic enters `McpHandler`; modern traffic enters the package's pre-authorized modern HTTP seam.
5. The modern executor validates required metadata and header/body agreement, then creates a fresh request frame.
6. `ModernServer` invokes `Backplane.MCP.Dispatch` with request-local auth and scopes.
7. The package adds `resultType`, server identity metadata, conservative cache hints, and the modern error mapping.
8. The HTTP seam sends JSON or request-scoped SSE without creating or returning a session ID.

Modern requests are POST-only. An explicitly modern GET or DELETE returns HTTP `405` with `Allow: POST`. Modern batches are rejected. Removed modern operations—including `initialize`, `ping`, `logging/setLevel`, legacy resource subscribe/unsubscribe, and Tasks methods—return the modern method-not-found response.

## Upstream data flow

1. Load the persisted upstream and map `"auto"` to `:auto` only at the runtime boundary.
2. Build a protocol client with empty outbound capabilities. Backplane does not claim roots, sampling, or elicitation callbacks.
3. Build HTTP or stdio transport options and start the client tree under `ClientPool`.
4. Wait for protocol readiness.
5. Read and retain negotiated preference, version, era, peer identity, and peer capabilities.
6. Fetch every `tools/list` page with duplicate-cursor and maximum-page protection.
7. Validate and atomically register the complete tool catalog.
8. Forward calls through `Client.call_tool/4`, unwrap the protocol response, and preserve the raw result for downstream shaping.
9. Refresh periodically. Legacy health may use `ping`; modern health uses successful discovery, catalog refreshes, and ordinary request activity because `2026-07-28` removed `ping`.

Explicit version preferences never fall back across eras. `auto` relies exclusively on the package's classified fallback rules. Network failures, authentication errors, HTTP `5xx`, malformed responses, header-validation errors, and arbitrary application errors are terminal negotiation failures rather than evidence of a legacy peer.

Downstream and upstream eras are independent. A modern downstream client can call a tool hosted by a legacy upstream, and a legacy downstream client can call a tool hosted by a modern upstream. Backplane translates at its registry and dispatch boundary rather than forcing both connections to use the same version.

## Tool and result preservation

Upstream tool normalization is a plain function. It requires a binary name and preserves:

- raw JSON Schema 2020-12 input and output schemas;
- title, description, annotations, icons, and `_meta`;
- modern custom-header declarations;
- execution metadata when present.

Only genuinely absent description and input-schema fields receive compatibility defaults. Invalid tools are excluded with sanitized diagnostics; a malformed catalog never partially replaces the last known complete catalog.

Tool results preserve all content blocks, `isError`, and every JSON shape of `structuredContent`, including arrays, strings, numbers, booleans, and explicit `null`. Presence is tested with key membership rather than truthiness.

## Authentication, authorization, and isolation

`Backplane.Auth.ResourceAuthPlug` continues to run before era selection. Existing OAuth, client token, legacy token, and open-mode behavior stays unchanged.

The modern adapter receives only trusted `conn.assigns` created by that Plug. Each modern request independently:

- filters tool lists by granted scopes;
- rechecks the named tool during calls;
- passes normalized auth to memory resources and managed prompts;
- avoids retaining identity in a session or global process.

Authentication failures retain the current HTTP challenge behavior. Application-level scope failures retain the existing Backplane semantics while being encoded in a valid modern JSON-RPC response.

Idempotency and cache identities include the authenticated principal, client, era, method, named operation, and request digest. Request-scoped SSE is never stored as an idempotent response. Private result caching must never cross client or authorization identities.

Secrets, authorization codes, bearer tokens, dynamic headers, and opaque upstream error details are excluded from logs and telemetry.

## CORS and headers

Browser preflight support is extended for:

- `MCP-Protocol-Version`;
- `Mcp-Method`;
- `Mcp-Name`;
- `Idempotency-Key`;
- validated `Mcp-Param-*` declarations.

Dynamic parameter headers are allowed only after safe name validation. The server rejects duplicates, CR/LF injection, invalid encoded sentinels, and disagreement between body and header values.

The response version header reflects the actual request era and negotiated version. Legacy session, ETag, and CORS response headers remain available to legacy clients.

## Error behavior

| Condition | Behavior |
| --- | --- |
| Unmarked request | Legacy route, defaulting to `2025-11-25` when initialization omits a version |
| Supported legacy version | Exact legacy version and version-aware session |
| Legacy initialization requesting modern version | Legacy negotiation to `2025-11-25` |
| Conflicting hard legacy and modern markers | HTTP `400`, invalid request |
| Missing or invalid modern `_meta` | HTTP `400`, `-32602` |
| Header/body mismatch | HTTP `400`, `-32020` |
| Missing required client capability | HTTP `400`, `-32021` |
| Unsupported modern version | HTTP `400`, `-32022` with requested and supported versions |
| Unknown or removed modern method | HTTP `404`, `-32601` |
| Modern GET or DELETE | HTTP `405`, `Allow: POST` |
| Expected application failure | Sanitized version-aware protocol error without crashing the request pipeline |
| Unexpected callback failure | Contained by the request task and translated to `-32603` |

Modern success responses never include `Mcp-Session-Id`. A request carrying both a modern marker and `Mcp-Session-Id` is rejected as conflicting; an accepted modern request never reads or mutates a legacy session.

## Persistence and administration

Add a non-null `protocol_version` column to `mcp_upstreams` with database and schema default `"2025-11-25"`. Existing rows are backfilled by the migration default.

The upstream changeset accepts only `"2025-11-25"`, `"2026-07-28"`, and `"auto"`. Older legacy upstreams remain supported through authoritative legacy downgrade rather than additional selector values.

The upstream admin form exposes the three preferences with `2025-11-25` selected for new records. List and detail views show:

- configured preference;
- negotiated version;
- negotiated era;
- negotiation or connection status.

Changing the preference restarts that upstream through the existing configuration-change lifecycle. No secret value is displayed.

## Testing strategy

Implementation follows test-driven development. Each production change begins with a focused failing test that proves the missing behavior.

### Endpoint tests

- No-version initialization defaults to `2025-11-25`.
- `2024-11-05`, `2025-03-26`, `2025-06-18`, and `2025-11-25` initialize exactly and retain their version-specific capabilities and response fields.
- Legacy initialization requesting `2026-07-28` negotiates to `2025-11-25` and never creates a modern session.
- Modern `server/discover` reports `2026-07-28` and only implemented capabilities.
- Two independent modern requests create zero legacy sessions and return no session header.
- Modern tools/list and a real namespaced tools/call use the Backplane registry, validation, scope filtering, and upstream dispatch.
- Modern resources, prompts, and completion exercise their real application services.
- Required metadata, method/name/custom headers, encoded values, duplicates, mismatch, and CR/LF rejection are covered.
- Modern GET, DELETE, batches, unknown methods, and removed methods return their designed statuses and codes.
- Authentication, list filtering, call reauthorization, identity-isolated idempotency, and private caching are covered.
- JSON Schema 2020-12 and every structured-content JSON shape are preserved.
- CORS preflight permits only the required safe modern headers.
- Request timeout and callback crash tests prove fault containment.

### Proxy tests

- Migration, schema, changeset, and new-record defaults are `2025-11-25`.
- Admin create, edit, list, and runtime status round-trip all three preferences.
- Default HTTP and stdio clients begin on the legacy path without a modern probe.
- A legacy peer's older returned version becomes authoritative, including `2024-11-05` over stdio.
- Explicit modern HTTP and stdio clients use discovery, required metadata and headers, tools/list, and tools/call without initialize, sessions, or ping.
- `auto` covers modern success, recognized legacy fallback, one supported-version retry, and terminal non-fallback cases.
- Credential rotation between discovery and a later tool call uses the new secret without a restart.
- Modern health never sends ping.
- Client-tree loss removes tools, observes backoff, and recovers through one replacement tree.
- Pagination detects repeated cursors and excessive pages before replacing the catalog.
- Tool normalization preserves schemas and optional metadata.
- Results preserve structured content when the value is `false` or `null`.
- The protocol transport header provider is covered across POST, legacy GET, session DELETE, and request-scoped stream paths.

### Verification gates

1. Focused Backplane MCP endpoint and proxy suites pass.
2. Focused authentication, migration/schema, and admin LiveView suites pass.
3. The complete `apps/backplane_mcp_protocol` unit, integration, and doctest suite passes.
4. Frozen official `2026-07-28` server conformance passes unchanged.
5. Frozen official `2026-07-28` client conformance passes unchanged.
6. Local live HTTP probes prove legacy-default initialization and explicit stateless modern discovery/list/call.
7. A real modern upstream fixture proves downstream → Backplane → upstream tool execution.

## Compatibility and rollout order

Implementation proceeds in dependency order without activating partial support:

1. Add reusable exact-URL, dynamic-header, and pre-authorized modern HTTP seams to the protocol package with package tests.
2. Add shared Backplane application dispatch while keeping legacy tests green.
3. Add and test the modern endpoint adapter and era router.
4. Add the persisted upstream preference and admin controls.
5. Move upstream wire communication to the protocol client behind the existing coordinator contract.
6. Run full package conformance and app-level integration gates.
7. Restart the local application and prove both eras against the real endpoint.

Registry activation and public modern routing are added only when the adapter and live tests are ready. The database default makes existing upstream rows deterministic. No release or deployment follows automatically.

## Risks and mitigations

- **Legacy regression:** preserve the current legacy route and gate every supported legacy version before and after extraction.
- **Protocol drift:** delegate modern routing, metadata, headers, result normalization, negotiation, and errors to the conformant package.
- **Authorization drift:** keep the existing auth Plug ahead of both eras and share application dispatch.
- **Identity leakage:** use request-local frames and identity-aware idempotency/cache keys.
- **Credential staleness:** resolve credentials through a per-request header provider.
- **Duplicate client ownership:** keep `Upstream` as the single reconnect owner and make protocol client trees temporary children.
- **Dynamic atom growth:** name client and transport processes through a Registry with term keys.
- **Partial tool catalogs:** validate and paginate completely before atomic replacement.
- **False legacy fallback:** rely only on the package's classified fallback rules.
- **Modern health failure:** never use removed ping; use discovery, refresh, and request activity.
- **Over-advertised behavior:** omit MRTR, subscriptions, logging configuration, Tasks, and optional auth extensions.

GitNexus could not resolve the affected Elixir symbols and reported unknown impact. Direct-source tracing classifies the implementation as high risk because it touches the public authenticated MCP endpoint and every upstream connection. The staged rollout and verification gates are mandatory mitigations.

## Acceptance criteria

The implementation is complete when all of the following are true:

- An unmarked client still initializes at `2025-11-25`.
- Every existing legacy endpoint version remains operational and version-shaped.
- An explicitly modern client completes discovery and all advertised Backplane operations at `2026-07-28` without creating a session.
- Modern and legacy clients enforce identical Backplane authentication and authorization decisions.
- Existing upstream records continue using the legacy default.
- A configured modern upstream works over HTTP and stdio.
- An `auto` upstream uses only safe classified fallback.
- Older negotiated legacy upstream versions remain supported where transport-compatible.
- Downstream and upstream protocol eras can differ without changing tool behavior.
- Credentials rotate without reconnect and are never retained or logged.
- Tool schemas, metadata, content, and structured output survive both proxy directions.
- All scoped tests, package tests, frozen conformance roles, and live endpoint/proxy probes pass.
- No modern MRTR, subscriptions, Tasks, logging configuration, or optional auth extension is advertised.
- No release or deployment occurs without a separate request.
