# Issue 24: Streamable HTTP Auto-Discovery Legacy Fallback

## Status

Approved on 2026-08-21.

## Context

[Issue #24](https://github.com/gsmlg-opt/backplane/issues/24) reports that a
`backplane_mcp_protocol` client using `protocol_version: :auto` cannot connect
to a legacy Streamable HTTP server when `server/discover` returns JSON-RPC
`-32601 Method not found`.

The client currently treats this error as terminal over Streamable HTTP, even
though the same reason is already classified as legacy evidence over stdio.
Pinning the same peer to a legacy version succeeds through `initialize`,
`notifications/initialized`, and `tools/list`.

## Goals

- Let an unpinned `:auto` Streamable HTTP client treat a valid JSON-RPC
  `-32601 Method not found` response to `server/discover` as evidence that the
  peer only supports the legacy lifecycle.
- Require an HTTP 400 JSON-RPC response ID to match the current discovery
  request before it can trigger fallback.
- Retry negotiation with `Protocol.fallback_version()` and the normal legacy
  `initialize` flow.
- Support both common HTTP envelopes for that JSON-RPC error:
  - HTTP 200 with a JSON-RPC error response.
  - HTTP 400 with a valid JSON-RPC error body.
- Preserve explicitly pinned client behavior and every unrelated error policy.
- Preserve existing server-side support for old clients using
  `initialize`, `tools/list`, and `tools/call`.

## Non-Goals

- Do not broaden HTTP fallback to `parse_error`, `invalid_request`,
  `invalid_params`, malformed responses, authentication failures, 5xx
  responses, network failures, or timeouts.
- Do not change stdio negotiation; it already handles `method_not_found`.
- Do not change `Error` decoding or `Protocol.fallback_version/0`.
- Do not modify Backplane proxy, admin, endpoint, or database code.
- Do not bump versions, publish a package, close the issue, or create a release
  as part of this fix.

## Root Cause

The same JSON-RPC error reaches negotiation in two forms:

1. An HTTP 200 JSON-RPC error is decoded by the client into
   `%Error{reason: :method_not_found}` and passed directly to HTTP negotiation.
   It has no outer HTTP error metadata, so the HTTP response classifier cannot
   identify it.
2. An HTTP 400 JSON-RPC error is wrapped as an HTTP transport error. The
   negotiation layer decodes its body and passes the recognized
   `method_not_found` error to `handle_recognized_modern_error/3`, but the
   current decoder discards the response ID.

The direct path has no `method_not_found` branch, while the recognized-error
helper only handles `unsupported_protocol_version`. Both paths therefore fail
negotiation.

## Design

Keep the policy in `Backplane.McpProtocol.Client.Negotiation`, where protocol
preference and era selection already live.

1. Route a direct Streamable HTTP `method_not_found` discovery error through
   the same recognized-modern-error helper used by decoded HTTP 400 responses.
2. Retain the JSON-RPC response ID when decoding an HTTP 400 error body.
3. Permit decoded HTTP 400 `method_not_found` fallback only when that ID equals
   the current discovery request ID. A missing, null, or mismatched ID remains
   terminal and preserves the outer transport error.
4. Add an unpinned-only `method_not_found` clause to that helper.
5. The clause calls `initialize(state, Protocol.fallback_version())`.
6. The existing catch-all remains terminal, so an explicit modern pin never
   downgrades.

No new process, state field, retry loop, or transport policy is introduced.
The subsequent legacy lifecycle remains the existing one:

```text
server/discover
  -> JSON-RPC -32601 Method not found
  -> initialize using Protocol.fallback_version() (currently 2025-03-26)
  -> notifications/initialized
  -> tools/list / tools/call
```

An error during the fallback `initialize` remains terminal, so this design
cannot create repeated cross-era downgrade loops.

## Error Policy

| Preference | Discovery outcome | Result |
|---|---|---|
| `:auto` | Valid JSON-RPC `-32601`, HTTP 200 | Legacy `initialize` fallback |
| `:auto` | Valid JSON-RPC `-32601`, HTTP 400 | Legacy `initialize` fallback |
| `:auto` | HTTP 400 `-32601` with missing, null, or mismatched ID | Terminal outer transport error |
| Explicit modern version | JSON-RPC `-32601`, HTTP 200 or 400 | Terminal `method_not_found` |
| `:auto` | Valid `-32022` with a mutually supported modern version | Existing modern retry |
| `:auto` | JSON-RPC-looking HTTP 404 | Existing terminal outer transport error |
| `:auto` | Other JSON-RPC errors or transport failures | Existing terminal behavior |

## Compatibility

- Old servers benefit because default `:auto` clients can reach their legacy
  initialization and tool APIs.
- Old clients are unaffected because server-side legacy routes and sessions do
  not change.
- Modern servers are unaffected because successful `server/discover` behavior
  does not change.
- Explicitly pinned clients retain strict no-downgrade behavior.

## Test Strategy

### Negotiation unit tests

- RED: direct HTTP `method_not_found` with `:auto` sends legacy `initialize`.
- RED: decoded HTTP 400 JSON-RPC `method_not_found` with `:auto` sends legacy
  `initialize`.
- Assert missing, null, and mismatched HTTP 400 response IDs never downgrade.
- Assert the operation uses `Protocol.fallback_version()` and the state becomes
  legacy/initializing.
- Assert explicit modern pins remain failed/modern for both representations.
- Preserve terminal behavior for `invalid_params`, malformed modern responses,
  JSON-RPC-looking 404, authentication/5xx/network failures, and timeouts.
- Preserve existing `unsupported_protocol_version` retry behavior.

### Streamable HTTP integration tests

Use Bypass to prove both HTTP 200 and HTTP 400 JSON-RPC `-32601` flows:

```text
server/discover -> initialize -> notifications/initialized
```

Then assert the client becomes ready in the legacy era and can complete
`tools/list`. Add pinned-modern negative coverage proving no `initialize`
request is sent.

### Verification scope

- Focused negotiation and Streamable HTTP tests.
- Full `backplane_mcp_protocol` suite.
- Changed-file formatting and `git diff --check`.
- GitNexus change detection, with direct source and tests authoritative if the
  Elixir symbols remain unindexed.

## Documentation

- Update the package README to name a recognized `server/discover`
  `method_not_found` response as legacy evidence for `:auto`.
- Add an Unreleased changelog entry describing the regression fix.

## Expected File Scope

- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/negotiation.ex`
- `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/negotiation_test.exs`
- `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http_test.exs`
- `apps/backplane_mcp_protocol/README.md`
- `apps/backplane_mcp_protocol/CHANGELOG.md`

## Success Criteria

- Auto clients fall back exactly once after `server/discover` returns valid
  JSON-RPC `-32601` over HTTP 200 or 400.
- HTTP 400 fallback requires an ID matching the current discovery request.
- The fallback completes legacy initialization and tool listing.
- Pinned clients and all other error classifications are unchanged.
- Package tests and focused regressions pass without unrelated edits.
