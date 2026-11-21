# Responses WebSocket gateway

The gateway supports native Responses JSON messages over WebSocket with model
routing from the first create. Enable `responses_websocket` on a provider's
OpenAI API surface, which must advertise native `openai_responses`. It defaults
to false and is independent of HTTP/SSE and `responses_lifecycle`.

## Client contract

Connect to `GET /v1/responses` with the ordinary Backplane bearer credential
(or supported `x-api-key` carrier). Malformed upgrades and requested
subprotocols are rejected. The first `response.create` selects the model, and
model aliases resolve at that point. Query parameters have no routing effect.
For Codex, use `supports_websockets = true` and select a model as usual. Remove
any old static `query_params.model` from the provider configuration.

Send a complete native JSON text message such as:

```json
{"type":"response.create","model":"provider/model","input":"Hello"}
```

The first create pins the upstream for this connection. Later creates may name
the original requested model or the pinned raw upstream model. Open a new
connection when switching models. Backplane rewrites the model to the upstream
name and preserves unknown fields.
For providers using the `openai-codex` preset, Backplane removes the redundant
`stream: true` flag sent by Codex CLI, including on prewarm and continuation
requests. All other uses of `stream`, as well as `background`, other client event
types, binary messages and model switching, are rejected. Upstream text events
are forwarded with identical bytes. Multiple creates can use the same connection;
the provider owns response scheduling and correlation. Backplane does not invent
interrupt, steering, cancellation or provider concurrency semantics.

Authentication and invocation scope are checked before upgrade and revalidated
before every create. Provider/API/model enabled state, route identity, credential
snapshot and provider RPM limits are also checked on each create. Because
upstream WebSocket authentication occurs only during the HTTP Upgrade handshake,
any credential update—including a normal same-account OAuth token refresh—prevents
further creates on the existing socket and closes it fail-closed (`credential_refreshed`
for same-account OAuth refresh, `route_changed` for rotation/account/config changes)
so the client reconnects with fresh credentials. OAuth refresh occurs before
connecting upstream, using the existing credential service. Request-scoped
unsubmitted rejections on an established session (`rate_limited`, `model_mismatch`,
`invalid_request`, `message_too_big`, `message_exceeds_peer_limit`, `submission_expired`)
return a native JSON `error` event without tearing down unaffected in-flight lanes.
This does not imply Codex OAuth supports public REST cancellation. WebSocket
response IDs are not enrolled in the HTTP lifecycle store.

## Ownership and forwarding

`backplane_llama` owns admission (`ResponsesWebSocket`), routing/auth policy
(`Policy`/`Headers`), a temporary supervised upstream owner (`Session`) and the
Gaoxy `WebSock` callbacks (`Socket`). The request process reserves a session
before upgrade. The downstream socket takes ownership at attachment, and the
first create opens the upstream. After attachment, the gateway allows up to
five minutes to receive the first complete create, subject to the connection's
idle and lifetime limits. Owner death closes the upstream and releases capacity.

The gateway replaces all downstream credential carriers with the selected provider
credential. It forwards only these caller metadata headers: `session_id`,
`conversation_id`, `x-codex-turn-state`, `x-codex-turn-metadata`, `openai-beta`,
`originator`, `user-agent`, `x-client-request-id`. Connection-nominated headers are
removed. Provider/API default headers are applied, with credential-owned headers
protected from caller/default overrides. Codex account/FedRAMP headers come from
credential metadata. Caller cookies and account/project/organization overrides
are not forwarded. Upstream URL uses the configured API base plus `/responses`
(or `/v1/responses` for a base without a path), without forwarding the gateway-only routing query.
Outbound connections use the shared environment proxy rules (`HTTP_PROXY` for
`ws`, `HTTPS_PROXY` for `wss`, and `NO_PROXY` for bypass). The WebSocket transport
supports HTTP proxies, using CONNECT for `wss`.

The downstream `101` acknowledges the connection to Backplane. An upstream
handshake rejection is returned in a native WebSocket `error` event with the
4xx/5xx status and, when present, `retry-after`. The gateway rejects truncated or
invalid upstream handshake metadata and enforces the peer's outbound size
limit. The upstream handshake has its own access record, and completed
responses continue to record usage. Upstream credentials and raw transport
diagnostics are never returned.

Ping/pong are hop-local on both sides of the gateway. The gateway actively sends
periodic Ping frames downstream (`downstream_ping_interval_ms`) and upstream
(`upstream_ping_interval_ms`, via `HTTP.WebSocket` `mode: :proxy` with `automatic_pong: true`)
and enforces bounded Pong timeouts (`downstream_pong_timeout_ms`, `upstream_pong_timeout_ms`).
Output-only streams, long reasoning pauses, and tool-wait periods remain connected
indefinitely (`max_lifetime_ms: :infinity` and `downstream_read_timeout_ms: :infinity`
by default; operators can still configure finite caps), while genuinely unresponsive
peers are closed cleanly within the configured Pong bound. Transport reads, queues,
fragments, mailboxes and pending writes are bounded. Upstream delivery credit is
released after Gaoxy completes the corresponding downstream local push. Each gateway
node admits up to 128 sessions.

The gateway reads the Codex Responses peer-limit header `x-codex-websocket-max-message-bytes`
case-insensitively and constrains outgoing creates to `min(local, peer)`. The separate
app-server control-socket header `x-codex-websocket-max-unfragmented-message-bytes` is
ignored. End-to-end real-socket propagation of `x-codex-websocket-max-message-bytes`
through `HTTP.WebSocket` requires upstream [http_fetch#174](https://github.com/gsmlg-dev/http_fetch/issues/174).

The default `134,217,728` byte (128 MiB) message/string/aggregate limits are an explicit
local policy sized to cover the announced 128 MB Codex model-request class (not a claim
that the announcement specifies exact MiB). Structural budgets (`max_depth`,
`max_map_entries`, `max_list_length`, `max_nodes`, `max_response_ids`) remain
independently bounded and are not scaled with message size.

Set these environment variables to positive integers (or `"infinity"` where noted) when
starting a production gateway. Each connection snapshots its limits at upgrade.

| Environment variable | Default | Applies to |
| --- | ---: | --- |
| `BACKPLANE_RESPONSES_WS_MAX_MESSAGE_BYTES` | 134,217,728 (128 MiB) | Each frame, complete message and encoded JSON payload |
| `BACKPLANE_RESPONSES_WS_MAX_BYTES` | 134,217,728 (128 MiB) | Total UTF-8 bytes of keys and strings in a create |
| `BACKPLANE_RESPONSES_WS_MAX_STRING_BYTES` | 134,217,728 (128 MiB) | Each key or string in a create |
| `BACKPLANE_RESPONSES_WS_MAX_DEPTH` | 320 | Object and array nesting in a create |
| `BACKPLANE_RESPONSES_WS_MAX_MAP_ENTRIES` | 5,120 | Keys per object in a create |
| `BACKPLANE_RESPONSES_WS_MAX_LIST_LENGTH` | 40,960 | Items per array in a create |
| `BACKPLANE_RESPONSES_WS_MAX_NODES` | 327,680 | JSON values in a create, including tool definitions |
| `BACKPLANE_RESPONSES_WS_MAX_RESPONSE_IDS` | 20,480 | Response IDs tracked for usage logging per connection |
| `BACKPLANE_RESPONSES_WS_MAX_LIFETIME_MS` | `infinity` | Optional finite connection lifetime cap (ms or `infinity`) |
| `BACKPLANE_RESPONSES_WS_FIRST_CREATE_TIMEOUT_MS` | 300,000 | Time allowed after upgrade for first `response.create` (ms) |
| `BACKPLANE_RESPONSES_WS_CONNECT_TIMEOUT_MS` | 10,000 | Upstream TCP/TLS connect timeout (ms) |
| `BACKPLANE_RESPONSES_WS_OPENING_TIMEOUT_MS` | 10,000 | Upstream HTTP 101 handshake timeout (ms) |
| `BACKPLANE_RESPONSES_WS_WRITE_TIMEOUT_MS` | 15,000 | Upstream frame write timeout (ms) |
| `BACKPLANE_RESPONSES_WS_SUBMISSION_TIMEOUT_MS` | 30,000 | End-to-end submission budget covering route, handshake, prepare, and write (ms) |
| `BACKPLANE_RESPONSES_WS_DELIVERY_ACK_TIMEOUT_MS` | 15,000 | Downstream local-write ACK deadline per forwarded event (ms) |
| `BACKPLANE_RESPONSES_WS_CALLBACK_TIMEOUT_MS` | 15,000 | Gaoxy WebSock callback watchdog (ms) |
| `BACKPLANE_RESPONSES_WS_DOWNSTREAM_READ_TIMEOUT_MS` | `infinity` | Downstream read-idle timeout (ms or `infinity`) |
| `BACKPLANE_RESPONSES_WS_DOWNSTREAM_PING_INTERVAL_MS` | 30,000 | Downstream hop-local Ping cadence (ms or `infinity`) |
| `BACKPLANE_RESPONSES_WS_DOWNSTREAM_PONG_TIMEOUT_MS` | 15,000 | Downstream Pong deadline after Ping (ms) |
| `BACKPLANE_RESPONSES_WS_UPSTREAM_PING_INTERVAL_MS` | 30,000 | Upstream hop-local Ping cadence (ms or `infinity`) |
| `BACKPLANE_RESPONSES_WS_UPSTREAM_PONG_TIMEOUT_MS` | 15,000 | Upstream Pong deadline after Ping (ms) |
| `BACKPLANE_RESPONSES_WS_UPSTREAM_IDLE_TIMEOUT_MS` | `infinity` | Upstream idle timeout (ms or `infinity`) |
| `BACKPLANE_RESPONSES_WS_MAX_PENDING_SUBMITS` | 4 | Maximum queued creates awaiting serialization per socket |

Closing confirms local cleanup, not provider cancellation. No reconnect, failover
or request replay occurs, including after uncertain submission. Clients must not
blindly retry a create after an ambiguous disconnect.

## Reusable components

`backplane_ai_protocol` exports the pure `OpenAIResponsesWebSocket` codec, without
network, database or gateway dependencies. `examples/responses_websocket_client`
is an independent caller-owned reference transport using published HTTP rc.5.
It exposes `open/3`, `create/2`, `next_event/2`, `completion/1` and `close/1`.
Neither component selects gateway credentials or models for another application.

## Dependency and verification status

Published HTTP family `1.0.0-rc.5`, DuskMoon bundler family `10.1.2`, Gaoxy `0.15.0`
and Phoenix Socket Client `0.9.0` resolve without HTTP version overrides. The
existing Gaoxy adapter package-identity override remains. This resolves the
version-graph blocker recorded in [http_fetch #155](https://github.com/gsmlg-dev/http_fetch/issues/155).
The older [#152](https://github.com/gsmlg-dev/http_fetch/issues/152) metadata fix
still has the deliberately narrow response-header boundary above.

Verified in the cloud workspace on 2026-11-07:

- Complete umbrella `MIX_ENV=test mix compile --warnings-as-errors` passed.
- Published dependency resolution and test-database migrations passed.
- New gateway suite: 13 real Gaoxy-to-Gaoxy endpoint tests passed, including
  OAuth/account headers, mixed-case default precedence, stale OAuth token cache,
  credential rotation, revoked clients, multiple turns, limits and no replay.
- Session suite: 8 TCP tests passed, including ordered ACK delivery, handoff,
  owner death, malformed handshake metadata, expired sends and redaction.
- Reference client: 10 TCP/TLS 1.3 tests passed against rc.5; pure protocol suite:
  211 tests passed. Existing config/router/authorization tests: 75 passed;
  admin provider tests: 24 passed; Relayixir WebSocket tests: 86 passed.
- Existing HTTP Responses lifecycle suite initially had two failures (408 on
  request-local project scope rejection; 500 on DELETE). Both passed when run
  individually. With the original seed, the lifecycle and new WebSocket endpoint
  suites then passed together (38 tests). The initial failures' root cause remains
  unconfirmed; they were not silently labeled pre-existing or fixed.
- Changed-file formatting, diff checks and scoped strict Credo passed.

The previous TLS 1.2 exploratory failure was diagnosed: OTP 28's test peer omitted
Extended Master Secret, which ex_ssl deliberately requires. A verified-CA TLS 1.2
connection and HTTP exchange against OpenSSL 3.5.7 succeeded. Native WebSocket
TLS 1.2/provider interoperability is not claimed from that HTTP-only probe.

Build environment: mdex_native's configured download host returned HTTP 403;
its existing cached artifact matched the package SHA256 and was consumed with
Rustler's supported global-cache option. Published ex_turso 3.1.15 forces source
compilation; installing official Rust 1.99.1 allowed that build to pass. No source
patch, incompatible dependency override or NIF validation bypass was used.
On 2026-11-19, Codex CLI 0.170.0 completed a plain response and a tool round trip
through a local gateway using `openai-codex/gpt-6.1-sol` over an HTTP CONNECT proxy.
With HTTP fallback blocked, the tool round trip used one WebSocket for prewarm,
generation and tool output continuation. The plain-response check recovered from
one failed prewarm handshake by opening a new WebSocket. This verification covers
the selected Codex route. Other providers still need live verification.

LLM logs record the handshake (`responses.websocket.handshake`), a separate row
for each observed `response.completed`, `response.incomplete` or `response.failed`
event with a response ID (`responses.websocket.create`), transport-interrupted
in-progress responses (`error_code: "responses_interrupted"`, unknown usage, no
fabricated terminal state or zero tokens), and exactly one sanitized connection-end
row (`responses.websocket.close`) carrying correlation IDs, phase, initiator,
normalized cause, duration, last activity ages, close codes, and interrupted response
count. Error kind and error code are visible in the LLM log detail view without
exposing raw payloads, credentials, or unrestricted transport diagnostics. Arbitrary
response-header forwarding remains unsupported.
