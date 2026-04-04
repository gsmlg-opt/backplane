# Relayixir Architecture Design Document

**Status:** Draft v2 (post-review)
**Package Name:** `relayixir`
**Language:** Elixir
**Runtime:** Erlang/OTP
**Scope:** HTTP reverse proxy and WebSocket reverse proxy framework/service
**Primary Stack:** Bandit + Plug + Mint + Mint.WebSocket

---

## 1. Executive Summary

Relayixir is an Elixir-native reverse proxy focused on **correctness, streaming safety, protocol-aware behavior, and future extensibility**.

It serves as a foundation for:

* HTTP reverse proxying with streaming response forwarding
* WebSocket proxying with supervised bidirectional relay
* request/response inspection and debugging
* future routing, policy, telemetry, and rewrite features

Relayixir is an **application-layer reverse proxy** built around Plug for inbound handling and Mint for outbound transport. It is explicitly not an L4 proxy.

The project follows a phased approach:

1. Build a stable HTTP proxy core with correct streaming
2. Add WebSocket bridging with explicit lifecycle management
3. Add production hardening behaviors
4. Add policy/inspection/dump extensions

---

## 2. Problem Statement

Existing Elixir reverse proxy solutions become fragile in edge cases:

* streaming response handling and chunk-write failures
* chunked vs content-length response mode selection
* client disconnects during streaming
* backpressure and buffering ambiguity
* WebSocket upgrade semantics and post-upgrade failure paths
* WebSocket close negotiation
* body inspection and dump hooks
* fine-grained outbound transport control

Relayixir provides a proxy foundation where these concerns are first-class architectural considerations.

### Initial Requirements

1. Reverse proxy HTTP with clean module boundaries
2. Make HTTP streaming behavior explicit and correct
3. Support WebSocket proxying as a separate, stateful relay path
4. Preserve extension points for audit/dump, header/body rewrite, route policy, observability, and upstream control

---

## 3. Goals

### 3.1 Functional Goals

* Reverse proxy HTTP requests to configured upstreams
* Stream upstream responses back to downstream clients with correct framing
* Forward requests with controlled header policy
* Detect and proxy WebSocket upgrade requests
* Relay WebSocket frames bidirectionally
* Provide deterministic error handling
* Support centralized route and upstream resolution

### 3.2 Architectural Goals

* Separate inbound and outbound responsibilities
* Separate HTTP and WebSocket transport models
* Keep long-lived connection logic explicit and supervised
* Centralize protocol correctness rules
* Expose clear extension points for future features

### 3.3 Operational Goals

* Produce structured logs
* Emit telemetry events for critical lifecycle stages
* Avoid hidden transport behavior
* Fail predictably
* Be testable at module, integration, and end-to-end levels

---

## 4. Non-Goals

### 4.1 Protocol/Layer Exclusions

* Raw TCP/UDP proxying
* TLS MITM
* Transparent proxying
* SOCKS proxy support
* HTTP CONNECT tunnel proxying
* Full L4 load balancer behavior

### 4.2 Platform Exclusions

* Service mesh control plane
* Config distribution system
* Admin dashboard
* Multi-node distributed control plane
* Built-in certificate authority
* Persistence-heavy management plane

### 4.3 Feature Exclusions in MVP

* Advanced load balancing algorithms
* Rate limiting
* WAF/rule engine
* Caching
* Request/response rewrite DSL
* Body decompression/recompression pipeline
* Traffic replay system
* HTTP/2 upstream support
* Connection pooling
* Request body streaming (buffered forwarding only)

These may be added later. The architecture must not depend on them.

---

## 5. Design Principles

### 5.1 Separate Inbound from Outbound

**Inbound responsibilities:** accept client request, parse HTTP, validate request form, determine request type, handle response writing, handle protocol upgrade handoff.

**Outbound responsibilities:** establish upstream transport connection, issue outbound request, read upstream response parts, manage WebSocket upstream session, expose a controlled transport interface to proxy logic.

This reduces coupling and makes failures easier to reason about.

### 5.2 Model HTTP and WebSocket as Different Systems

HTTP is finite, request/response oriented, mostly stateless per request, and stream-capable but bounded by request lifecycle.

WebSocket is upgraded from HTTP, stateful, bidirectional, long-lived, and driven by frame relay and connection state transitions.

Relayixir implements separate `HTTP proxy path` and `WebSocket proxy path`. They share route resolution, header policy, logging, telemetry, and configuration shape. They do not share a transport core.

### 5.3 Make Protocol Rules Explicit

Proxy correctness depends on hop-by-hop headers, forwarding headers, response streaming lifecycle, downstream disconnect behavior, upgrade validation, WebSocket close semantics, and response framing mode selection. These rules are centralized in dedicated modules, not distributed across code paths.

### 5.4 Prioritize Correctness Before Optimization

The first implementation prefers deterministic behavior, correctness of forwarding, explicit lifecycle handling, easy debugging, and clear ownership of state — over aggressive connection reuse, speculative optimization, feature breadth, or premature abstraction.

### 5.5 OTP First

Use OTP where it provides real value: supervised long-lived processes, explicit process boundaries, failure containment, and message-driven bridge sessions. This is especially important for WebSocket bridging.

### 5.6 Honest Abstractions

Do not introduce normalization boundaries that leak. If a struct carries a raw handle, the abstraction is illusory. Prefer passing concrete types (e.g. `Plug.Conn`) directly until there is a real consumer for the normalized form (dump hooks, inspection layers).

---

## 6. Technology Choices

### 6.1 Bandit

Inbound HTTP server. Provides Plug integration, modern Elixir-native HTTP server behavior, and support for protocol upgrade flows needed by WebSocket handling. Bandit is the inbound edge of Relayixir.

**Constraint:** Bandit has a finite handler pool. Long upstream response times hold handler processes. This is acceptable for MVP with one-connection-per-request, but must be revisited if upstream latency is high.

### 6.2 Plug

Abstraction boundary for inbound handling. Used for routing, request normalization, response writing (chunked and content-length modes), and WebSocket upgrade handoff. Relayixir presents itself as a Plug-based application with internal OTP components.

### 6.3 Mint

Outbound HTTP transport. Provides explicit transport lifecycle control, streaming response visibility, process-bound connection model, and precise ownership of connection state. A reverse proxy needs transport details exposed rather than hidden.

**Important behavior:** Mint automatically dechunks upstream `Transfer-Encoding: chunked` responses. Relayixir re-frames downstream — this is correct but must be understood: original framing is not preserved.

### 6.4 Mint.WebSocket

Outbound WebSocket transport. Provides explicit session establishment, explicit frame encoding/decoding, and compatibility with a bridge/state-machine design.

### 6.5 Why Not `:gen_tcp`

Raw TCP would require owning HTTP parsing, framing, chunked transfer logic, keep-alive semantics, upgrade logic, TLS handling, and low-level socket lifecycle. This is too much for an application-layer reverse proxy. Raw TCP is only warranted for L4 proxying, tunnel proxying, raw CONNECT support, or non-HTTP protocols — all outside current scope.

---

## 7. Architecture Overview

```text
Client
  → Bandit
  → Relayixir.Router
     → Relayixir.Proxy.HttpPlug
        → Relayixir.Proxy.Headers     (pure functions)
        → Relayixir.Proxy.Upstream    (route resolution)
        → Relayixir.Proxy.HttpClient  (Mint transport, yields response parts)
        → Relayixir.Proxy.ErrorMapper (pure functions)
        → [streaming loop: pattern-match response parts, write to Plug.Conn]

     → Relayixir.Proxy.WebSocket.Plug
        → upgrade via Bandit WebSock behaviour
        → Relayixir.Proxy.WebSocket.Bridge  (supervised GenServer)
           → Relayixir.Proxy.WebSocket.UpstreamClient
           → Relayixir.Proxy.WebSocket.Frame
           → Relayixir.Proxy.WebSocket.Close
```

Three major ideas:

1. Routing is separate from transport
2. HTTP and WebSocket are separate flows
3. Outbound transport is isolated from inbound request handling

### HTTP Path: No Separate Streamer

The streaming loop lives inside `HttpPlug` as private functions. `HttpClient` exposes a function that yields response parts (status, headers, body chunks, done). `HttpPlug` pattern-matches on parts and writes to `Plug.Conn`. There is no separate `HttpStreamer` module — the streaming coordination is inherently coupled to both the Mint conn state and the `Plug.Conn`, and splitting it suggests independent state that does not exist.

---

## 8. Deployment Model

### 8.1 Standalone Service

Relayixir runs as its own OTP application with Bandit listener, static or runtime proxy configuration, route and upstream definitions, logs and telemetry. This is the default deployment model.

### 8.2 Embeddable Proxy Component

Relayixir may be embedded into a larger Elixir system: mounted as Plug routes, used as an internal proxy layer, integrated with other supervision trees. The architecture does not assume standalone-only operation.

---

## 9. Project Structure

```text
lib/
  relayixir/
    application.ex
    router.ex

    config/
      route_config.ex
      upstream_config.ex
      listener_config.ex

    proxy/
      http_plug.ex
      http_client.ex
      headers.ex
      upstream.ex
      error_mapper.ex

      websocket/
        plug.ex
        bridge.ex
        upstream_client.ex
        frame.ex
        close.ex

    telemetry/
      events.ex

    support/
      errors.ex
      timeout.ex
```

Intentionally flat for MVP. `Request`/`Response` structs are deferred to Phase 3 when dump/inspection hooks create a real consumer for them.

---

## 10. Core Data Structures

### 10.1 Upstream Descriptor

```elixir
defmodule Relayixir.Proxy.Upstream do
  defstruct [
    :scheme,
    :host,
    :port,
    :path_prefix_rewrite,
    :request_timeout,
    :connect_timeout,
    :websocket?,
    :host_forward_mode,
    :metadata
  ]
end
```

Purpose: represent resolved upstream behavior explicitly. Avoid leaking route config shape into transport logic.

`host_forward_mode` is one of `:preserve | :rewrite_to_upstream | :route_defined` — per-route from day one.

### 10.2 WebSocket Bridge State

```elixir
defmodule Relayixir.Proxy.WebSocket.Bridge.State do
  defstruct [
    :session_id,
    :route,
    :downstream_pid,
    :downstream_monitor,
    :upstream_conn,
    :upstream_ref,
    :started_at,
    :last_activity_at,
    :status,
    :close_reason
  ]
end
```

Purpose: keep session lifecycle explicit, support observability and deterministic shutdown. Includes `downstream_pid` and `downstream_monitor` for crash coordination with the Bandit handler process.

### 10.3 Deferred: Request/Response Structs

Normalized `Request` and `Response` structs are deferred to Phase 3 (inspection/dump). In MVP, `Plug.Conn` flows directly through the HTTP path. Introducing a normalized struct that carries `raw_conn` defeats the abstraction — better to be honest about the dependency until there is a real consumer.

---

## 11. Core Modules

### 11.1 `Relayixir.Router`

Top-level Plug router. Decides whether a request is an HTTP proxy request or a WebSocket upgrade request. Dispatches to the right proxy path. Remains thin — no transport logic, no complex header rules.

### 11.2 `Relayixir.Proxy.HttpPlug`

Orchestration layer for HTTP proxying. Receives inbound HTTP requests via `Plug.Conn`. Resolves upstream. Applies header policy. Invokes `HttpClient` to connect and send the request. Runs the streaming loop: receives response parts from `HttpClient`, writes to `Plug.Conn`.

**Critical responsibilities in the streaming loop:**

* Select downstream response mode based on upstream response: use `Plug.Conn.send_resp/3` for `Content-Length` responses, `Plug.Conn.send_chunked/2` + `Plug.Conn.chunk/2` for chunked/close-delimited responses
* Handle `{:error, :closed}` from `Plug.Conn.chunk/2` on every write — clean up the upstream Mint connection immediately
* Handle empty bodies (e.g. 204) without sending chunks
* Convert failures into proxy responses via `ErrorMapper`

Does not embed complex transport state machines — `HttpClient` owns that.

### 11.3 `Relayixir.Proxy.HttpClient`

Connects to upstream via Mint. Issues outbound request. Reads upstream response messages. Yields response parts to the caller: `{:status, status}`, `{:headers, headers}`, `{:data, chunk}`, `:done`, `{:error, reason}`. Enforces connect and response timeouts. Closes connection on completion or error.

**MVP strategy:** one upstream connection per downstream request. No pooling. No hidden global state. The Mint conn lives in the calling process (the Bandit handler running `HttpPlug`).

**Protocol notes:**

* Mint dechunks automatically — callers receive raw body data regardless of upstream transfer encoding
* Close-delimited responses (no Content-Length, no Transfer-Encoding) are surfaced as data chunks followed by `:done`
* Trailer headers are received as `{:headers, trailers}` after body data — log but do not forward in MVP

### 11.4 `Relayixir.Proxy.Headers`

Pure functions. Applies outbound header policy and inbound response header policy. Strips hop-by-hop headers (`connection`, `keep-alive`, `proxy-authenticate`, `proxy-authorization`, `te`, `trailers`, `transfer-encoding`, `upgrade`). Sets or appends `x-forwarded-for`, `x-forwarded-proto`, `x-forwarded-host`. Applies host-forwarding strategy based on upstream's `host_forward_mode`.

**Protocol notes:**

* `Expect: 100-continue` — strip on outbound in MVP. Bandit handles the client-side expectation; forwarding it adds complexity with no MVP benefit.
* `Sec-WebSocket-Protocol` — forward on the WebSocket path. The upstream's selection must be respected and relayed back to the client.
* `Sec-WebSocket-Extensions` — do not forward `permessage-deflate` in MVP. Negotiate compression independently on each side to avoid decompression/recompression complexity.

### 11.5 `Relayixir.Proxy.Upstream`

Resolves route destination. Returns an `Upstream` struct. Inputs: request host, path, method, upgrade intent, route metadata. Config-only in MVP (no dynamic resolution).

### 11.6 `Relayixir.Proxy.ErrorMapper`

Pure functions. Maps internal errors to downstream HTTP responses. Centralizes status code behavior.

| Error | HTTP Status |
|---|---|
| `:route_not_found` | 404 |
| `:upstream_connect_failed` | 502 |
| `:upstream_timeout` | 504 |
| `:upstream_invalid_response` | 502 |
| `:downstream_disconnected` | (no response — client is gone) |
| `:internal_error` | 500 |

WebSocket errors after upgrade: graceful close frame if possible, forced termination if necessary. No HTTP error responses are possible post-upgrade.

### 11.7 `Relayixir.Proxy.WebSocket.Plug`

Entry point for WebSocket proxying. Implements `WebSock` behaviour for Bandit. Validates upgrade request. On `c:WebSock.init/1` callback (called after Bandit completes the HTTP upgrade), starts the bridge process and links to it.

**Critical design point:** The HTTP upgrade has already been sent to the client before `init/1` runs. If the upstream WebSocket connection fails at this point, the only way to communicate failure is via a WebSocket close frame (e.g. close code 1014 — Bad Gateway equivalent). This is not an error — it is the correct protocol behavior. The plug must handle this path explicitly.

### 11.8 `Relayixir.Proxy.WebSocket.Bridge`

Supervised GenServer. Manages the proxied WebSocket session. Relays frames bidirectionally. Manages ping/pong/close behavior. Coordinates termination semantics. Emits lifecycle telemetry.

**Process relationship:** The bridge process monitors the Bandit handler process (which owns the downstream WebSocket connection). If the handler dies, the bridge tears down the upstream connection and terminates. Conversely, the handler links to the bridge — if the bridge crashes, the handler receives an exit signal and can clean up.

This is the heart of WebSocket proxying.

### 11.9 `Relayixir.Proxy.WebSocket.UpstreamClient`

Establishes upstream WebSocket via Mint + Mint.WebSocket. Encodes/decodes upstream frames. Surfaces upstream events to the bridge. Sends frames on bridge instruction. Isolates outbound WebSocket transport details from bridge logic.

### 11.10 `Relayixir.Proxy.WebSocket.Frame`

Normalized frame representation. Abstracts away raw library-specific frame formats. Supports: text, binary, ping, pong, close (with code and reason).

### 11.11 `Relayixir.Proxy.WebSocket.Close`

Pure functions. Centralizes close code/reason mapping. Defines graceful shutdown behavior. Ensures bridge termination is consistent.

Close handling rules:

* Downstream closes normally → attempt graceful upstream close, await ack, terminate
* Upstream closes normally → propagate close downstream, terminate
* One side fails unexpectedly → send close frame to surviving side with appropriate code, terminate
* Close cannot be performed gracefully → force terminate, log reason

---

## 12. HTTP Flow

### 12.1 Normal Flow

```text
1. Client sends HTTP request
2. Bandit accepts, invokes HttpPlug
3. HttpPlug resolves upstream via Upstream module
4. Headers module rewrites outbound headers
5. HttpClient opens Mint connection to upstream
6. HttpClient sends request (buffered body)
7. HttpClient yields {:status, status}
8. HttpClient yields {:headers, headers}
9. HttpPlug selects response mode:
   - Content-Length present → send_resp path
   - Otherwise → send_chunked path
10. HttpClient yields {:data, chunk} repeatedly
11. HttpPlug writes chunks downstream, checking for {:error, :closed}
12. HttpClient yields :done
13. HttpPlug completes response, Mint connection is closed
```

### 12.2 Error Flow

```text
1. Any step fails → internal error tuple
2. ErrorMapper selects downstream status/response
3. Failure is logged with structured metadata
4. Telemetry event emitted
5. Upstream Mint connection cleaned up
6. Request ends deterministically
```

### 12.3 Downstream Disconnect During Streaming

```text
1. Plug.Conn.chunk/2 returns {:error, :closed}
2. HttpPlug stops reading from upstream
3. Mint connection is closed immediately
4. Telemetry event: downstream_disconnected
5. Process exits normally (Bandit handles cleanup)
```

This path must be tested explicitly — it is the #1 source of bugs in Elixir proxies.

---

## 13. Request Body Handling

### 13.1 MVP: Buffered Forwarding

Read the full request body via `Plug.Conn.read_body/2`. Forward the buffered body to upstream in the `HttpClient.send_request/3` call. Acceptable for most API proxy use cases.

**Documented limitation:** large uploads will be fully buffered in the handler process. `Plug.Conn.read_body/2` has a configurable `:length` limit — use it.

### 13.2 Deferred: Streamed Request Forwarding

A later phase adds streamed request upload, no mandatory full buffering, slow upload support, and request streaming timeout policy. This is a separate delivery milestone.

---

## 14. Response Body Handling

Response streaming is a first-class requirement.

Relayixir supports:

* Immediate downstream response after status/headers
* Progressive forwarding of response chunks
* Correct response mode selection (Content-Length vs chunked)
* Deterministic stop on upstream completion
* Safe stop on downstream disconnect (every `chunk/2` call checked)
* Close-delimited upstream responses (no Content-Length, no Transfer-Encoding) handled as streaming

---

## 15. WebSocket Flow

### 15.1 Session Establishment

```text
1. Client issues WebSocket upgrade request
2. Router dispatches to WebSocket.Plug
3. Upgrade request validated (required headers, version)
4. Bandit performs HTTP upgrade (101 sent to client)
5. WebSock.init/1 callback fires
6. Bridge process started under DynamicSupervisor, linked to handler
7. Bridge attempts upstream WebSocket connection
8. On success: relay begins, bridge enters :open state
9. On failure: bridge sends close frame (1014) to client, terminates
```

### 15.2 Bidirectional Relay

```text
client → [Bandit handler] → bridge → [Mint.WebSocket] → upstream
upstream → [Mint.WebSocket] → bridge → [Bandit handler] → client
```

The bridge relays: text frames, binary frames, ping frames, pong frames, close frames.

### 15.3 Session Teardown

Teardown is explicit:

| Trigger | Action |
|---|---|
| Downstream closes normally | Attempt graceful upstream close, await ack, terminate |
| Upstream closes normally | Propagate close downstream, terminate |
| One side fails unexpectedly | Close surviving side with appropriate code, terminate |
| Graceful close times out | Force terminate, log |
| Bandit handler process dies | Bridge detects via monitor, close upstream, terminate |
| Bridge process crashes | Handler receives exit signal, Bandit cleans up downstream |

---

## 16. WebSocket State Machine

```text
:connecting → :open → :closing → :closed
              :open → :closed  (abnormal)
:connecting → :closed           (upstream connect failed)
```

### `:connecting`

Downstream upgraded. Upstream not yet connected. Bridge is attempting upstream WebSocket handshake.

### `:open`

Both sides established. Frame relay active.

### `:closing`

Close initiated by either side. Awaiting acknowledgment from the other side. Timeout applies.

### `:closed`

Session ended. No more frame forwarding. Process terminates.

This state machine is explicit in code, not implied.

---

## 17. Supervision Strategy

```text
Relayixir.Application
├── Relayixir.Config.RouteConfig
├── Relayixir.Config.UpstreamConfig
├── Relayixir.Telemetry
├── Relayixir.WebSocket.BridgeSupervisor  (DynamicSupervisor)
├── Relayixir.WebSocket.BridgeRegistry    (Registry)
└── {Bandit, plug: Relayixir.Router, scheme: :http, port: 4000}
```

**Key decisions:**

* Regular HTTP requests do not need dedicated supervised workers — they run in Bandit's handler processes
* Each WebSocket bridge session is started under `BridgeSupervisor` as a `DynamicSupervisor` child
* Bridge processes use `:temporary` restart strategy — no automatic restarts on crash. A crashed bridge means a dead session; restarting would produce a zombie process with no downstream connection
* `BridgeRegistry` (Elixir `Registry`) allows introspection of active bridge sessions — useful for debugging and future admin tooling
* Bridge processes are monitored by the Bandit handler and linked bidirectionally for crash propagation
* Future connection pools can be added as supervised components

---

## 18. Configuration Model

### 18.1 Listener Configuration

Scheme, host, port, transport options.

### 18.2 Route Configuration

Route match rules, upstream destination, WebSocket eligibility, timeouts, host forward mode (`:preserve | :rewrite_to_upstream | :route_defined`).

Host forwarding is per-route from day one. It is a single field and many real services depend on it.

### 18.3 Proxy Behavior Configuration

Default timeouts, header forwarding strategy, dump toggles (disabled by default), telemetry toggles.

### 18.4 Deferred Runtime Features

Runtime reload, dynamic route providers, service discovery, health-based upstream selection. MVP is static config only.

---

## 19. Header Policy

### 19.1 Required Behavior

* Strip hop-by-hop headers: `connection`, `keep-alive`, `proxy-authenticate`, `proxy-authorization`, `te`, `trailers`, `transfer-encoding`, `upgrade`
* Set/append `x-forwarded-for` with client IP
* Set/append `x-forwarded-proto`
* Set/append `x-forwarded-host`
* Apply host-forwarding mode per upstream config

### 19.2 Protocol-Specific Handling

| Header | Behavior |
|---|---|
| `Expect: 100-continue` | Strip on outbound (MVP). Bandit handles client side. |
| `Sec-WebSocket-Protocol` | Forward to upstream, relay upstream's selection back |
| `Sec-WebSocket-Extensions` | Do not forward `permessage-deflate` (MVP). Negotiate independently per side. |
| `Trailer` / trailer headers | Log, do not forward (MVP) |
| Inbound `x-forwarded-*` | Do not trust by default. Future: trusted proxy list. |

---

## 20. Timeout Model

### 20.1 HTTP Timeouts

| Timeout | Scope | Default |
|---|---|---|
| Connect timeout | Mint TCP/TLS connect | 5s |
| First-byte timeout | Time to first response byte from upstream | 30s |
| Overall request timeout | Total request lifecycle | 60s |

Configurable per route or globally.

### 20.2 WebSocket Timeouts

| Timeout | Scope | Default |
|---|---|---|
| Connect timeout | Upstream WebSocket TCP connect | 5s |
| Handshake timeout | Upstream WebSocket upgrade completion | 10s |
| Close timeout | Time to receive close ack after sending close | 5s |

Idle timeout deferred to Phase 3.

---

## 21. Buffering and Backpressure

### 21.1 MVP Position

Minimal and explicit buffering. Request bodies are fully buffered (see §13). Response streaming has no intermediate buffer — data flows from Mint recv to `Plug.Conn.chunk/2`. This is correct for most traffic patterns but incomplete for extreme cases.

### 21.2 Deferred (Phase 3)

Bounded buffering rules, downstream slow-consumer policy, upstream slow-producer handling, maximum frame/body memory thresholds. Important for large responses, streaming APIs, and long-lived WebSocket sessions.

---

## 22. Error Model

Centralized internal error tuples with metadata:

```elixir
{:error, {:upstream_timeout, %{phase: :connect, upstream: "api.example.com:443"}}}
{:error, {:upstream_connect_failed, %{reason: :nxdomain, upstream: "..."}}}
{:error, {:downstream_disconnected, %{bytes_sent: 4096}}}
{:error, {:websocket_upstream_failed, %{close_code: 1014, reason: "upstream refused"}}}
```

Error categories:

* `:route_not_found`
* `:upstream_connect_failed`
* `:upstream_timeout`
* `:upstream_invalid_response`
* `:downstream_disconnected`
* `:request_body_error`
* `:websocket_upgrade_failed`
* `:websocket_upstream_failed`
* `:websocket_protocol_error`
* `:internal_error`

---

## 23. Observability

### 23.1 Logging

Structured metadata on all log events:

* `request_id` — unique per request
* `method`, `path`, `upstream` — request context
* `status`, `duration_ms` — outcome
* `session_id` — WebSocket sessions
* `close_code`, `close_reason` — WebSocket teardown

Minimum events: request start, request stop, request exception, upstream chosen, upstream connect failure, status returned, downstream disconnect, WebSocket open, WebSocket close, WebSocket exception.

### 23.2 Telemetry

```elixir
[:relayixir, :http, :request, :start]
[:relayixir, :http, :request, :stop]
[:relayixir, :http, :request, :exception]
[:relayixir, :http, :upstream, :connect, :start]
[:relayixir, :http, :upstream, :connect, :stop]
[:relayixir, :http, :downstream, :disconnect]
[:relayixir, :websocket, :session, :start]
[:relayixir, :websocket, :session, :stop]
[:relayixir, :websocket, :frame, :in]
[:relayixir, :websocket, :frame, :out]
[:relayixir, :websocket, :exception]
```

### 23.3 Dump and Audit Hooks (Phase 4)

Extension points reserved for request/response header dump, body sampling, full capture in debug mode. Implemented as observer hooks (opt-in callbacks), not middleware pipeline — avoids per-request overhead when disabled.

**Security:** dump features disabled by default. Redaction considered for sensitive headers (`authorization`, `cookie`, `set-cookie`).

---

## 24. Security Considerations

### 24.1 Header Trust

Do not blindly trust inbound forwarding headers. Future: trusted proxy lists.

### 24.2 Dump Safety

Dump features disabled by default. Redaction for sensitive headers.

### 24.3 Route Safety

Route definitions are explicit. No open proxy behavior unless intentionally configured.

### 24.4 Upgrade Validation

WebSocket upgrade handling validates required conditions (`Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Key`, `Sec-WebSocket-Version: 13`) before accepting.

---

## 25. Testing Strategy

### 25.1 Unit Tests

* Header rewriting (hop-by-hop stripping, forwarding headers, host modes)
* Route resolution
* Error mapping
* WebSocket state transitions
* Frame normalization
* Close code mapping

### 25.2 Integration Tests

* HTTP request forwarding with real Mint connections to a test server
* Streaming responses (chunked and content-length modes)
* Client disconnect during streaming — verify upstream cleanup
* Upstream timeout behavior
* Host forwarding policy per mode

### 25.3 End-to-End Tests

* Real Bandit listener, real upstream HTTP service
* Real upstream WebSocket service
* Bridge open/relay/close behavior
* Failure and timeout scenarios

### 25.4 Top 10 Edge Cases to Test First

1. Upstream returns headers then hangs — verify request timeout fires
2. Client disconnects mid-stream — verify upstream Mint connection is closed
3. Upstream returns `Content-Length` response — verify `send_resp` used (not chunked)
4. Upstream returns empty body (204) — verify no chunk is sent
5. WebSocket upstream rejects connection after HTTP 101 already sent to client
6. WebSocket client sends close, upstream is slow to acknowledge close
7. Upstream sends close-delimited response (no Content-Length, no Transfer-Encoding)
8. Request with `Transfer-Encoding: chunked` body from client
9. Concurrent bridge crash and Bandit handler death (race condition)
10. Upstream returns 1xx informational before final response

---

## 26. Phased Delivery Plan

### Phase 1: HTTP MVP

**Deliver:** Bandit listener, Router, HttpPlug with streaming loop, HttpClient, Upstream resolution (static config), Headers module, ErrorMapper, logging, telemetry.

**Success criteria:** Standard proxying works. Streaming responses work with correct framing mode. `Plug.Conn.chunk/2` errors are handled. Common failure paths are observable. Edge cases 1–4, 7, 8, 10 pass.

### Phase 2: WebSocket Support

**Deliver:** WebSocket.Plug, Bridge GenServer, UpstreamClient, Frame module, Close module, DynamicSupervisor + Registry, WebSocket telemetry.

**Success criteria:** Bidirectional frame relay works. Close semantics are deterministic. Bridge processes are supervised with `:temporary` restart. Post-upgrade upstream failure sends close frame 1014. Edge cases 5, 6, 9 pass.

### Phase 3: Production Hardening

**Deliver:** Request body streaming, better timeout control, bounded buffering policy, optional connection reuse, improved config controls, normalized Request/Response structs for inspection readiness.

**Success criteria:** Large and slow traffic is safer. Failure behavior is tighter. Resource use is more controlled.

### Phase 4: Inspection and Policy

**Deliver:** Dump observer hooks, inspection hooks, route-level policy, richer observability, optional rewrite extensions.

**Success criteria:** Platform becomes useful for debugging and traffic control use cases.

---

## 27. Architecture Risks

### 27.1 Response Streaming Complexity (High)

The biggest early correctness risk. Downstream disconnects, upstream partial responses, chunk write failures, completion ordering, and framing mode selection must all be handled correctly in the `HttpPlug` streaming loop.

### 27.2 WebSocket Post-Upgrade Failure Path (Medium)

The client receives HTTP 101 before the upstream connection is attempted. Upstream connection failure can only be communicated via close frame. This is correct but unfamiliar to many developers and must be tested explicitly.

### 27.3 Header Correctness (Medium)

Proxy bugs often come from hop-by-hop stripping, host forwarding, upgrade header handling, and forwarding header trust.

### 27.4 Bandit Handler Process Holding (Medium)

One-connection-per-request means slow upstreams hold Bandit handler processes. Acceptable for MVP but creates a ceiling on concurrent request capacity under high upstream latency.

### 27.5 Bridge/Handler Crash Coordination (Medium)

The monitor/link relationship between the Bandit handler process and the bridge process must be correct. Race conditions between concurrent crashes must not leak resources.

### 27.6 Backpressure (Low in MVP)

MVP has no backpressure. Correct for most cases but incomplete for extreme traffic. Deferred to Phase 3.

---

## 28. Key Decisions Summary

| Decision | Choice | Rationale |
|---|---|---|
| Separate HttpStreamer module | **No** | Streaming is coupled to both Mint conn and Plug.Conn; fold into HttpPlug |
| Request/Response structs in MVP | **No** | No real consumer yet; Plug.Conn flows directly |
| Host forwarding per-route | **Yes** | Single field, many services depend on it |
| Connection pooling in MVP | **No** | One-conn-per-request is predictable |
| Request body streaming in MVP | **No** | Buffered is sufficient; defer to Phase 3 |
| Bridge process restart strategy | **`:temporary`** | Crashed bridge = dead session; restart would be zombie |
| Bridge registry | **Yes** | Registry for introspection from day one |
| Dump hooks style | **Observer hooks** | Opt-in, no per-request pipeline overhead |
| HTTP/2 upstream | **Deferred** | Get HTTP/1.1 right first |
| `permessage-deflate` forwarding | **No** | Negotiate independently per side in MVP |

---

## 29. Conclusion

Relayixir is built as a **protocol-aware, application-layer reverse proxy for Elixir** with emphasis on correctness and extensibility.

Its architectural choices: Bandit for inbound, Plug for request abstraction, Mint for outbound HTTP, Mint.WebSocket for outbound WebSocket, explicit separation of HTTP and WebSocket paths, OTP supervision for long-lived connections, centralized header/route/error behavior, and honest abstractions that don't leak.

The design starts small and correct: no pooling, no rewrite DSL, no admin API, no HTTP/2 upstream. It creates boundaries so future capabilities can be added without rewriting the core.