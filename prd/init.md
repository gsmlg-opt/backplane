# Relayixir — Product Requirements Document

**Status:** Draft
**Product:** Relayixir
**Type:** Infrastructure Library / Standalone Service
**Language:** Elixir / Erlang OTP

---

## 1. Overview

Relayixir is an Elixir-native reverse proxy for HTTP and WebSocket traffic. It provides a correct, extensible, protocol-aware proxy foundation built on Bandit, Plug, Mint, and Mint.WebSocket.

### Target Users

- Elixir developers who need an embeddable reverse proxy component
- Teams running Elixir services that require a standalone HTTP/WebSocket gateway
- Developers building debugging, inspection, or traffic control tools on top of a proxy core

### Value Proposition

Existing Elixir proxy solutions break on edge cases: streaming failures, client disconnects mid-response, WebSocket close negotiation, incorrect response framing, and silent upstream errors. Relayixir treats these as first-class concerns — not afterthoughts.

---

## 2. Problem Statement

Current Elixir reverse proxy options are fragile in production-critical scenarios:

1. **Streaming response failures are silent** — chunk-write errors to disconnected clients go unhandled, leaking upstream connections
2. **Response framing is incorrect** — proxies use chunked encoding when Content-Length is available, or vice versa
3. **WebSocket proxying lacks lifecycle management** — no explicit state machine, no close negotiation, no crash coordination between downstream handler and upstream connection
4. **Backpressure is invisible** — no control over buffering between upstream and downstream
5. **Header policy is ad-hoc** — hop-by-hop stripping, forwarding headers, and host rewriting are scattered across code paths
6. **Error handling is inconsistent** — different failures produce different (often wrong) HTTP status codes

There is no Elixir proxy library that makes these concerns explicit and correct from the start.

---

## 3. Product Goals

### P0 — Must Have (MVP)

1. **HTTP reverse proxying** — forward HTTP requests to configured upstream servers and stream responses back to clients
2. **Correct response streaming** — select the right response mode (Content-Length vs chunked), handle downstream disconnects on every chunk write, clean up upstream connections on failure
3. **Header policy** — strip hop-by-hop headers, set forwarding headers (x-forwarded-for/proto/host), support per-route host forwarding mode
4. **Static route configuration** — resolve upstream destination from configuration (host, port, scheme, path prefix, timeouts)
5. **Deterministic error handling** — map all internal errors to appropriate HTTP status codes (404, 502, 504, 500) through a centralized error mapper
6. **Structured logging** — emit structured log events with request_id, method, path, upstream, status, and duration
7. **Telemetry events** — emit `:telemetry` events for request lifecycle (start/stop/exception), upstream connect, and downstream disconnect

### P1 — Should Have (Phase 2)

8. **WebSocket proxying** — detect upgrade requests, validate WebSocket handshake, relay frames bidirectionally between client and upstream
9. **WebSocket lifecycle management** — explicit state machine (connecting → open → closing → closed), supervised bridge process with `:temporary` restart, monitor/link coordination with Bandit handler
10. **WebSocket close negotiation** — handle normal close from either side, timeout on close acknowledgment, force-terminate on failure, send appropriate close codes (including 1014 for post-upgrade upstream failure)
11. **WebSocket telemetry** — session start/stop, frame in/out, exception events

### P2 — Nice to Have (Phase 3+)

12. **Request body streaming** — forward request bodies without full buffering
13. **Connection reuse** — optional connection pooling for upstream HTTP connections
14. **Bounded buffering** — configurable memory limits for response and WebSocket frame buffering
15. **Normalized request/response structs** — for inspection and dump hook consumers
16. **Dump/inspection hooks** — opt-in observer callbacks for header/body capture and debugging
17. **Route-level policy** — per-route rules for access control, rewrite, and traffic shaping
18. **Runtime config reload** — update routes and upstream definitions without restart

---

## 4. User Stories

### HTTP Proxying

**US-1:** As a developer, I can configure Relayixir with upstream destinations so that HTTP requests are forwarded to the correct backend based on route rules.

**US-2:** As a developer, I can trust that streaming responses (SSE, large downloads) are forwarded with correct framing so that clients receive data progressively without corruption.

**US-3:** As a developer, when a client disconnects mid-stream, the upstream connection is cleaned up immediately so that resources are not leaked.

**US-4:** As a developer, I see structured logs and telemetry for every proxied request so that I can monitor and debug traffic.

### WebSocket Proxying

**US-5:** As a developer, I can configure routes as WebSocket-eligible so that upgrade requests are detected and proxied automatically.

**US-6:** As a developer, WebSocket frames are relayed bidirectionally with correct ordering so that real-time applications work through the proxy.

**US-7:** As a developer, when either side of a WebSocket connection fails or closes, the other side is notified with the correct close code so that applications can handle disconnects gracefully.

### Deployment

**US-8:** As a developer, I can run Relayixir as a standalone OTP application with a Bandit listener so that it serves as an independent reverse proxy.

**US-9:** As a developer, I can embed Relayixir as a Plug within a larger Elixir application so that it acts as an internal proxy component.

---

## 5. Functional Requirements

### 5.1 HTTP Proxy

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | Accept HTTP requests via Bandit and route to configured upstreams | P0 |
| FR-2 | Read full request body via `Plug.Conn.read_body/2` and forward buffered | P0 |
| FR-3 | Open a new Mint connection per request to the resolved upstream | P0 |
| FR-4 | Stream response parts (status, headers, body chunks, done) from upstream | P0 |
| FR-5 | Use `send_resp/3` when upstream provides Content-Length; use `send_chunked/2` + `chunk/2` otherwise | P0 |
| FR-6 | Check every `chunk/2` return for `{:error, :closed}` and close upstream immediately | P0 |
| FR-7 | Handle empty-body responses (204, 304) without sending chunks | P0 |
| FR-8 | Support close-delimited responses (no Content-Length, no Transfer-Encoding) | P0 |
| FR-9 | Enforce connect timeout (default 5s), first-byte timeout (default 30s), overall timeout (default 60s) | P0 |
| FR-10 | Timeouts configurable per-route and globally | P0 |

### 5.2 Header Policy

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-11 | Strip hop-by-hop headers: connection, keep-alive, proxy-authenticate, proxy-authorization, te, trailers, transfer-encoding, upgrade | P0 |
| FR-12 | Set/append x-forwarded-for with client IP | P0 |
| FR-13 | Set/append x-forwarded-proto and x-forwarded-host | P0 |
| FR-14 | Apply per-route host forwarding mode: `:preserve`, `:rewrite_to_upstream`, `:route_defined` | P0 |
| FR-15 | Strip `Expect: 100-continue` on outbound | P0 |
| FR-16 | Do not trust inbound x-forwarded-* headers by default | P0 |

### 5.3 Routing and Configuration

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-17 | Resolve upstream from static configuration based on request host, path, and method | P0 |
| FR-18 | Upstream descriptor includes: scheme, host, port, path_prefix_rewrite, timeouts, websocket flag, host_forward_mode | P0 |
| FR-19 | Return 404 for unmatched routes | P0 |

### 5.4 Error Handling

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-20 | Map `:route_not_found` → 404 | P0 |
| FR-21 | Map `:upstream_connect_failed` → 502 | P0 |
| FR-22 | Map `:upstream_timeout` → 504 | P0 |
| FR-23 | Map `:upstream_invalid_response` → 502 | P0 |
| FR-24 | Map `:internal_error` → 500 | P0 |
| FR-25 | On `:downstream_disconnected`, skip response (client is gone), log, emit telemetry | P0 |

### 5.5 WebSocket Proxy

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-26 | Detect WebSocket upgrade requests by checking Upgrade, Connection, Sec-WebSocket-Key, Sec-WebSocket-Version headers | P1 |
| FR-27 | After Bandit completes HTTP 101 upgrade, start a supervised Bridge GenServer under DynamicSupervisor | P1 |
| FR-28 | Bridge connects to upstream WebSocket via Mint.WebSocket | P1 |
| FR-29 | Relay text, binary, ping, and pong frames bidirectionally | P1 |
| FR-30 | Implement explicit state machine: `:connecting` → `:open` → `:closing` → `:closed` | P1 |
| FR-31 | On upstream connect failure after 101: send close frame with code 1014, terminate | P1 |
| FR-32 | On normal close from either side: propagate close, await ack with timeout (default 5s), terminate | P1 |
| FR-33 | On Bandit handler death: bridge detects via monitor, closes upstream, terminates | P1 |
| FR-34 | On bridge crash: handler receives exit signal, Bandit cleans up downstream | P1 |
| FR-35 | Bridge uses `:temporary` restart strategy (no automatic restart) | P1 |
| FR-36 | Register bridge sessions in `BridgeRegistry` for introspection | P1 |
| FR-37 | Forward `Sec-WebSocket-Protocol` header; do not forward `permessage-deflate` extension | P1 |

### 5.6 Observability

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-38 | Emit structured logs with: request_id, method, path, upstream, status, duration_ms | P0 |
| FR-39 | Emit telemetry: `[:relayixir, :http, :request, :start/:stop/:exception]` | P0 |
| FR-40 | Emit telemetry: `[:relayixir, :http, :upstream, :connect, :start/:stop]` | P0 |
| FR-41 | Emit telemetry: `[:relayixir, :http, :downstream, :disconnect]` | P0 |
| FR-42 | Emit telemetry: `[:relayixir, :websocket, :session, :start/:stop]` | P1 |
| FR-43 | Emit telemetry: `[:relayixir, :websocket, :frame, :in/:out]` | P1 |
| FR-44 | Emit telemetry: `[:relayixir, :websocket, :exception]` | P1 |
| FR-45 | WebSocket logs include: session_id, close_code, close_reason | P1 |

---

## 6. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1 | Elixir ≥ 1.15, OTP ≥ 26 |
| NFR-2 | Dependencies limited to: Bandit, Plug, Mint, Mint.WebSocket, Telemetry |
| NFR-3 | No hidden global state — Mint connections are process-local |
| NFR-4 | No open proxy behavior by default — all routes must be explicitly configured |
| NFR-5 | Embeddable as a Plug in existing applications without requiring standalone deployment |
| NFR-6 | All modules testable at unit level with no external dependencies |
| NFR-7 | Integration tests use real Bandit/Mint connections to local test servers |

---

## 7. Out of Scope

- Raw TCP/UDP proxying, TLS MITM, SOCKS, HTTP CONNECT tunneling
- L4 load balancing, service mesh, admin dashboard, multi-node control plane
- Rate limiting, WAF, caching, request/response rewrite DSL
- HTTP/2 upstream, body decompression/recompression, traffic replay
- Connection pooling (MVP), request body streaming (MVP)
- Runtime config reload, dynamic route providers, service discovery

---

## 8. Success Criteria

### Phase 1 (HTTP MVP)

- [ ] HTTP requests are proxied to configured upstreams and responses stream correctly
- [ ] Content-Length responses use `send_resp`; chunked/close-delimited responses use `send_chunked`
- [ ] Client disconnect mid-stream closes upstream connection immediately
- [ ] Empty-body responses (204) handled without sending chunks
- [ ] Timeouts fire correctly (connect, first-byte, overall)
- [ ] All error categories produce correct HTTP status codes
- [ ] Structured logs and telemetry events emitted for all request lifecycle stages
- [ ] Close-delimited upstream responses handled as streaming
- [ ] Upstream 1xx informational responses do not break the proxy

### Phase 2 (WebSocket)

- [ ] WebSocket upgrade requests detected and proxied
- [ ] Bidirectional frame relay works for text, binary, ping, pong
- [ ] Close semantics are deterministic — both normal and abnormal paths
- [ ] Post-upgrade upstream failure sends close frame 1014
- [ ] Bridge processes supervised with `:temporary` restart, registered in BridgeRegistry
- [ ] Concurrent bridge crash and handler death does not leak resources

### Phase 3 (Production Hardening)

- [ ] Request bodies can be streamed without full buffering
- [ ] Bounded buffering limits memory usage for large responses
- [ ] Optional connection reuse reduces upstream connection overhead

### Phase 4 (Inspection & Policy)

- [ ] Dump hooks can capture request/response headers and body samples
- [ ] Route-level policy can restrict or transform traffic

---

## 9. Technical Constraints

1. **One Mint connection per request (MVP)** — no connection pooling. Slow upstreams hold Bandit handler processes. Acceptable for initial release; must be revisited under high upstream latency.
2. **Request bodies fully buffered (MVP)** — large uploads consume handler process memory. `read_body/2` length limit should be configured.
3. **Mint auto-dechunks** — original upstream transfer encoding is not preserved. Downstream re-framing is explicit and correct, but not transparent.
4. **WebSocket upgrade is irreversible** — HTTP 101 is sent before upstream connection attempt. Upstream failure after upgrade can only communicate via close frame.
5. **No backpressure (MVP)** — data flows directly from Mint recv to Plug chunk write. No intermediate buffering or slow-consumer handling.

---

## 10. Delivery Phases

| Phase | Scope | Key Deliverables |
|-------|-------|------------------|
| 1 | HTTP MVP | Router, HttpPlug, HttpClient, Headers, Upstream, ErrorMapper, logging, telemetry |
| 2 | WebSocket | WebSocket.Plug, Bridge, UpstreamClient, Frame, Close, DynamicSupervisor, Registry |
| 3 | Hardening | Request streaming, connection reuse, bounded buffering, improved timeouts, Request/Response structs |
| 4 | Extensions | Dump hooks, inspection hooks, route policy, rewrite extensions |

Each phase is independently shippable. Later phases do not require rework of earlier ones.
