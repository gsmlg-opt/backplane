# MCP 2026-07-28 Protocol Support Design

**Date:** 2026-08-11
**Status:** Approved for implementation
**Scope:** `apps/backplane_mcp_protocol` only

## Objective

Add complete MCP `2026-07-28` protocol support to the reusable protocol package while preserving every currently supported legacy version. The package will support both client and server roles over Streamable HTTP and stdio, automatically negotiate the modern or legacy era, and pass the frozen official `2026-07-28` client and server conformance requirements.

The optional `io.modelcontextprotocol/tasks` extension is not part of this release. Existing `2025-11-25` task behavior remains available on the legacy path.

## Scope

This change includes:

- the `2026-07-28` protocol model, schemas, metadata, methods, results, errors, and capabilities;
- modern stateless server discovery and request execution;
- dual-era client negotiation and legacy fallback;
- Streamable HTTP and stdio behavior for both eras;
- standard and custom MCP HTTP headers;
- result caching metadata, deterministic lists, subscriptions, and MRTR;
- JSON Schema 2020-12 wire preservation and safe local validation;
- authorization changes required by the revision;
- package documentation, tests, conformance adapters, and release gates.

The first implementation does not modify Backplane's public `/mcp` endpoint, upstream proxy, admin inspector, host agent, or other umbrella consumers. Those integrations require a separate follow-up plan after the protocol package is released.

## Architecture

The package exposes one client/server API while separating two protocol eras internally.

- Versions through `2025-11-25` remain on the current legacy initialization and session path.
- `2026-07-28` is an independent modern profile rather than an extension of `V2025_11_25`, because the modern revision removes inherited lifecycle operations and methods.
- The new version is added to `Protocol.Registry` and becomes the default only after its client, server, transport, and conformance gates pass.

Modern server requests follow this stateless pipeline:

```text
transport
  -> request context and header validation
  -> modern method and capability validation
  -> stateless handler dispatch
  -> result or error normalization
  -> JSON or request-scoped SSE response
```

The pipeline uses structs and plain functions. It does not create a session GenServer. A supervised process is used only when a live stream, cancellation boundary, callback fault isolation, or transport writer requires one. `Server.Session` remains exclusively responsible for legacy connections.

The existing client process remains because it owns real connection state, request correlation, pending operations, and transport lifecycle. Negotiation, metadata construction, result normalization, header projection, and MRTR transitions are plain functions.

## Protocol Model

Introduce a protocol profile contract that can describe non-monotonic revisions. It records:

- version and era;
- lifecycle and negotiation mode;
- request, notification, and result methods;
- required request and result metadata;
- result types and cache rules;
- transport constraints and HTTP header rules;
- core capabilities and extension capabilities;
- version-specific error mappings.

`Protocol.V2026_07_28` implements this contract independently. Legacy modules keep their existing callbacks and tests; legacy-only monotonic assumptions are scoped to legacy profiles.

## Modern Server Components

- `Server.Modern.RequestContext` holds the validated protocol version, client capabilities and identity, transport headers, authorization claims, log level, MRTR inputs, and request metadata.
- `Server.Modern.Executor` creates a fresh frame, invokes the existing server callback module, emits telemetry, and returns a normalized JSON-RPC result.
- `Server.Modern.Result` enforces `resultType`, cache hints, supported MRTR methods, server metadata, and modern error mappings.
- `Server.Modern.Headers` validates `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, and declared `Mcp-Param-*` mirrors.
- `Server.Modern.Discovery` implements mandatory `server/discover` with supported versions, capabilities, identity, instructions, and conservative cache hints.

`Server.Context` is extended additively with the protocol version, era, execution mode, request metadata, and MRTR data. Existing callbacks remain valid. Compile-time components are copied into each request frame. An optional request-initialization callback supports request-local dynamic registration without calling the legacy `init/2` lifecycle hook.

Streamable HTTP selects the modern executor for modern markers and the existing session path for legacy markers. Modern HTTP is POST-only and never creates or returns `Mcp-Session-Id`; legacy GET, POST, and DELETE behavior remains unchanged.

The stdio connection process owns only I/O and detected-era routing. A modern request is executed statelessly; a legacy connection continues through its singleton `Server.Session`.

## Modern Client Components

- `Client.Negotiation` implements discovery, supported-version retry, and transport-specific legacy fallback.
- `Client.Metadata` merges required modern metadata with caller-supplied `_meta`.
- `Client.Headers` derives standard and declared parameter headers for Streamable HTTP.
- `Client.Result` validates modern result envelopes and routes complete versus input-required results.
- `Client.MRTR` adapts existing roots, sampling, and elicitation callbacks and retries the original operation.
- `Client.Catalog` retains raw schemas and compiles supported output validators and custom-header projection plans.

Client state records the configured version selector, detected era, negotiated version, peer versions, capabilities, server identity, discovery data, and authorization issuer. `protocol_version` accepts `:auto | String.t()`. Explicit versions remain pins; `:auto` becomes the default only with the completed modern implementation.

Responses are correlated by pending request method, never inferred from result fields such as `serverInfo`. Existing public operation return shapes remain stable. Legacy-only operations called against a modern peer return an explicit unsupported-operation error.

## Negotiation

For `protocol_version: :auto`, a newly connected client sends a modern `server/discover` probe with required metadata.

- A valid modern result or recognized modern protocol error proves a modern peer.
- `UnsupportedProtocolVersion` selects the highest mutually supported modern version and retries.
- HTTP and stdio fall back only under the official era-detection rules.
- Network errors, 5xx responses, malformed modern responses, and arbitrary application errors are not treated as proof of a legacy peer.
- An explicitly pinned version never falls back across eras.

The server routes deterministically:

- `initialize`, a legacy session identifier, or an already-legacy stdio connection uses `Server.Session`;
- `server/discover`, modern request metadata, or a modern version header uses the stateless executor;
- conflicting modern and legacy markers return an error instead of guessing.

## Modern Requests and Headers

Every modern request carries:

- `params._meta.io.modelcontextprotocol/protocolVersion`;
- `params._meta.io.modelcontextprotocol/clientCapabilities`;
- recommended `params._meta.io.modelcontextprotocol/clientInfo`.

Every modern result includes `resultType`; server identity is placed in result metadata. Streamable HTTP sends `MCP-Protocol-Version` and `Mcp-Method` for every request and `Mcp-Name` for named operations. Parameters marked `x-mcp-header` are mirrored only when they are primitive and statically reachable. Unsafe values use the protocol's encoded representation, and CR/LF injection is rejected.

The server validates header/body agreement before application dispatch. Header mismatches return HTTP 400 and MCP error `-32020`. Unknown modern HTTP methods return HTTP 404 with JSON-RPC `-32601`.

## MRTR

Only `tools/call`, `prompts/get`, and `resources/read` may return `resultType: "input_required"`.

1. The server returns input requests and opaque `requestState`.
2. The client retains the original operation, caller, and deadline.
3. Roots, sampling, or elicitation callbacks run in supervised request tasks.
4. The client retries the original method with a new JSON-RPC ID, `inputResponses`, and the exact `requestState`.
5. Intermediate and retried MRTR results are never cached.

The library treats `requestState` as opaque and excludes it from logs. Applications must authenticate or seal state that affects authorization or behavior.

## Subscriptions

Modern long-lived notifications use `subscriptions/listen`. The client receives a cancellable subscription handle.

- HTTP creates an independent request-owned POST/SSE worker so normal requests remain concurrent.
- stdio multiplexes subscription notifications through its connection writer.
- Closing the stream cancels the subscription.
- Modern traffic does not use a GET notification stream, `Last-Event-ID`, event replay, polling retry fields, or session deletion.

Legacy resource subscriptions and SSE behavior remain available only to legacy versions.

## Schemas and Structured Content

Wire schemas are preserved as arbitrary JSON Schema 2020-12 maps, including unknown keywords, `$defs`, composition, and references. External network `$ref` resolution is disabled by default and local validation is resource-bounded.

A `SchemaValidator` behaviour separates wire preservation from local validation. Peri remains the adapter for legacy and the compatible common subset. Unsupported client-received schemas retain the tool and raw schema, disable local validation for that tool, and emit diagnostics. A focused conformance spike must prove the need for any additional validator before adding a dependency.

`structuredContent` accepts every JSON value, including arrays, primitives, booleans, and `null`. Text-content fallback remains available for clients that need it.

## Caching

Modern complete results for discovery, tool/prompt/resource lists, resource templates, and resource reads include `ttlMs` and `cacheScope`. The default is conservative: `ttlMs: 0`, `cacheScope: "private"`.

Server registration and response finalization may override those hints. The first client implementation parses and exposes cache hints but does not serve cached results, because client-side caching is optional. Validator/catalog caching remains separate from protocol response caching.

## Errors

Modern mappings are version-specific:

| Condition | Code |
| --- | ---: |
| Header mismatch | `-32020` |
| Missing required client capability | `-32021` |
| Unsupported protocol version | `-32022` |
| Missing or invalid required metadata | `-32602` |
| Modern resource not found | `-32602` |
| Method not found | `-32601` |
| Unexpected application callback failure | `-32603` |

Unsupported-version data includes the requested and supported versions. Legacy revisions retain their current mappings, including resource-not-found `-32002` where applicable.

Expected failures use explicit error tuples. Application callback exceptions are contained at the protocol boundary, reported through sanitized telemetry, and translated to internal errors without exposing stack traces or killing the client connection. Internal invariant failures remain crashable and supervised.

## Authorization and Sensitive Data

Existing HTTP resource-server authorization runs before modern dispatch. Modern client authorization adds exact RFC 9207 issuer validation, keys persisted credentials by validated authorization-server issuer, includes `application_type` in DCR, and prefers Client ID Metadata Documents while retaining deprecated DCR compatibility.

Bearer tokens, client credentials, mirrored sensitive parameters, authorization codes, and `requestState` are excluded from logs and telemetry metadata. Private caching, if later enabled, must include client and authorization identity in its cache key.

## Compatibility

- Existing public server macros, legacy callbacks, and client operations remain source-compatible.
- Existing versions and transports retain their behavior.
- Removed modern operations stay callable in the Elixir API but return a version-aware unsupported-operation error.
- The package fixes the pre-existing mismatch where the default protocol version is not accepted by the Streamable HTTP client transport.
- The negotiated legacy version returned by `initialize` becomes authoritative client state.

## Testing and Conformance

Implementation follows TDD with focused tests at each boundary:

- independent modern profile and registry activation;
- metadata, result envelopes, errors, and cache hints;
- discovery and supported-version retry;
- HTTP and stdio era detection and legacy fallback;
- standard and custom header generation and validation;
- stateless execution with no session creation;
- complete and all MRTR flows;
- request-owned subscriptions and cancellation;
- JSON Schema 2020-12 preservation and all JSON structured-content shapes;
- issuer validation and sensitive-data redaction;
- regression coverage for every legacy version.

The release gate is:

1. all package unit, integration, and doctests pass;
2. frozen official `2026-07-28` server conformance passes;
3. frozen official `2026-07-28` client conformance passes;
4. additional normative tests cover requirements not scored by the official suite, particularly server header validation, schema handling, and fallback classification;
5. package docs build and `mix hex.build --unpack` succeeds.

## Documentation and Release

Update the package README, client/server guides, reference pages, changelog, and generated `llms*.txt` assets. Record reproducible package test, docs, conformance, and package-build commands. Root CI and release workflows remain outside this package-only phase.

The package version is updated according to the repository's synchronized release policy only after the implementation is ready. Registry activation and the switch to `:auto` occur in the final implementation milestone so partial work never advertises unsupported behavior.

## Acceptance Criteria

The design is complete when evidence proves all of the following:

- `2026-07-28` is advertised and selected by default through `:auto`;
- modern client and server roles work over HTTP and stdio;
- legacy peers continue to interoperate through automatic fallback;
- modern requests are stateless and do not create session processes;
- required metadata, headers, results, errors, caching, MRTR, subscriptions, schemas, and authorization behavior are implemented;
- the optional modern Tasks extension is absent while legacy Tasks remain working;
- package tests and both frozen official conformance roles pass;
- no application outside `apps/backplane_mcp_protocol` is required to change for this phase.
