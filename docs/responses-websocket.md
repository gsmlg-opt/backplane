# Responses WebSocket gateway

The gateway supports native Responses JSON messages over WebSocket using an
explicit handshake-time model route. Enable `responses_websocket` on a provider's
OpenAI API surface, which must advertise native `openai_responses`. It defaults
to false and is independent of HTTP/SSE and `responses_lifecycle`.

## Client contract

Connect to `GET /v1/responses?model=provider/model` with the ordinary Backplane
bearer credential (or supported `x-api-key` carrier). Model aliases also resolve
at admission. The query must contain exactly one `model`; credentials are never
accepted in the query. A missing query model, malformed upgrade or requested
subprotocol is rejected. This explicit routing contract permits validating the
upstream handshake before upgrading downstream. Clients that send their model
only in the first frame must add this query parameter.

Send a complete native JSON text message such as:

```json
{"type":"response.create","model":"provider/model","input":"Hello"}
```

The request model may be the original requested model or the pinned raw upstream
model. Only that field is rewritten; unknown fields remain intact. HTTP-only
`stream` and `background` fields, other client event types, binary messages and
model switching are rejected. Unknown upstream text events are forwarded with
identical bytes. Multiple creates can use the same connection; the provider owns
response scheduling and correlation. Backplane does not invent interrupt,
steering, cancellation or provider concurrency semantics.

Authentication and invocation scope are checked before upgrade and revalidated
before every create. Provider/API/model enabled state, route identity, credential
snapshot and provider RPM limits are also checked on each create. Configuration
or credential changes end use of the old session; they do not silently reconnect
with another account. OAuth refresh occurs before connecting upstream, using the
existing credential service. This does not imply Codex OAuth supports public REST
cancellation. WebSocket response IDs are not enrolled in the HTTP lifecycle store.

## Ownership and forwarding

`backplane_llama` owns admission (`ResponsesWebSocket`), routing/auth policy
(`Policy`/`Headers`), a temporary supervised upstream owner (`Session`) and the
Gaoxy `WebSock` callbacks (`Socket`). HTTP routes and Relayixir's generic bridge
remain unchanged. The request process owns the session until the downstream
socket attaches. Owner death, failed upgrade or handoff timeout closes upstream.

The gateway replaces all downstream credential carriers with the selected provider
credential. It forwards only these caller metadata headers: `session_id`,
`conversation_id`, `x-codex-turn-state`, `x-codex-turn-metadata`, `openai-beta`,
`originator`, `user-agent`, `x-client-request-id`. Connection-nominated headers are
removed. Provider/API default headers are applied, with credential-owned headers
protected from caller/default overrides. Codex account/FedRAMP headers come from
credential metadata. Caller cookies and account/project/organization overrides
are not forwarded. Upstream URL uses the configured API base plus `/responses`
(or `/v1/responses` for a base without a path), without forwarding the gateway-only routing query.

HTTP rc.5 exposes only `retry-after` and
`x-codex-websocket-max-unfragmented-message-bytes` in handshake responses. The
gateway mirrors those two, rejects truncated/invalid metadata and enforces the
peer's outbound size limit. It does **not** promise arbitrary response/session
headers, cookies, subprotocol or extension transparency. Upstream HTTP rejection
status is preserved for 4xx/5xx with safe selected headers and a local generic
body. No upstream credential or raw transport diagnostic is returned.

Ping/pong are hop-local; this is a bounded JSON message proxy, not a raw frame
bridge. Each message/frame is at most 2 MiB; transport reads, queues, fragments,
mailboxes and pending writes are bounded. Upstream delivery credit is released
only after Gaoxy completes the corresponding downstream local push. At most 128 sessions are admitted per gateway node. Connections
have a five-minute maximum lifetime and finite idle/handshake/write/cleanup limits.
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
Real-provider/Codex qualification has not been performed. Arbitrary response-header
forwarding and WebSocket-specific token-usage accounting are not implemented;
the admin toggle explicitly discloses the accounting limitation.
