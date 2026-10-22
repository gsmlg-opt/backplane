# Relayixir

An Elixir-native HTTP/WebSocket reverse proxy built on Gaoxy + Plug + HTTP Fetch + HTTP WebSocket.

Upstream source: [gsmlg-dev/relayixir](https://github.com/gsmlg-dev/relayixir)

## Role in Backplane

Relayixir is included as an umbrella app in the Backplane project. It forwards HTTP and WebSocket requests to upstream LLM providers.

Gaoxy standalone server is disabled (`config :relayixir, start_server: false`). Backplane uses Relayixir as a library — calling `Relayixir.Router` as a Plug or using its proxy modules directly, and configuring routes at runtime via `Relayixir.load/1`.

## Features

- **HTTP Reverse Proxy** — streaming response forwarding with correct chunked/content-length handling
- **WebSocket Proxy** — full bidirectional relay with explicit state machine and close semantics
- **Protocol-Aware Headers** — hop-by-hop stripping, x-forwarded-* injection, configurable host forwarding
- **Route Policy** — per-route allowed methods, request header injection, body size limits
- **Connection Pooling** — optional per-upstream idle connection reuse
- **Dump Hooks** — optional callbacks for request/response inspection and WebSocket frame capture
- **Telemetry** — structured events for request lifecycle, upstream connections, and WebSocket sessions
- **OTP Supervision** — WebSocket bridges under DynamicSupervisor with temporary restart strategy

## Usage

Configure routes and upstreams at runtime:

```elixir
Relayixir.load(
  routes: [
    %{
      host_match: "*",
      path_prefix: "/api",
      upstream_name: "backend",
      websocket: false,
      host_forward_mode: :rewrite_to_upstream,
      allowed_methods: ["GET", "POST", "PUT", "DELETE"]
    }
  ],
  upstreams: %{
    "backend" => %{
      scheme: :http,
      host: "localhost",
      port: 4001
    }
  }
)
```

## Architecture

Two separate proxy paths:

**HTTP** (request/response):
```
Client -> Router -> HttpPlug -> HttpClient (HTTP.fetch) -> Upstream
```

**WebSocket** (bidirectional, long-lived):
```
Client -> Router -> WebSocket.Plug -> Bridge (GenServer) -> UpstreamClient (HTTP.WebSocket) -> Upstream
```

Outbound transports use the HTTP family at version 0.21.2. Fetch runs in HTTP/1 proxy mode with manual redirects, raw response bytes, header-first response streams, and acknowledgements after downstream consumption. SSE is forwarded through this byte stream; EventSource parsing and automatic reconnection would change the proxy contract.

Fetch owns optional HTTP/1 connection reuse. `pool_size` sets the retained idle sockets per route, capped at sixteen by Fetch; the shared pool retains at most 256 idle sockets. A supervised request guard cancels requests when the calling process exits, including while waiting for response headers.

HTTP upstream preparation emits `[:relayixir, :http, :upstream, :prepare, :start/:stop]`. Socket establishment occurs later inside Fetch; use request lifecycle events for end-to-end timing.

Requests are sent once. Fetch's structured `HTTP.RequestError` preserves the underlying failure and exposes conservative dispatch evidence. Direct TCP connection failures can prove pre-send failure; proxy, pooled, TLS and post-send failures remain unknown, so Relayixir does not replay them.

Direct HTTP/1 requests, including pooled requests, and supported explicit HTTP/HTTPS proxy routes use the public completion barrier on release and cancellation. A successful barrier confirms that request resources have settled and the socket has closed or returned safely to the pool. HTTP proxies support forwarding to HTTP origins and CONNECT to HTTPS origins; HTTPS proxies support forwarding to HTTP origins. Nested TLS through an HTTPS proxy remains unsupported. Pending, unsupported, or unconfirmed cleanup retains the guard/controller until its bounded deadline.

With HTTP Fetch 0.21.14, failed proxy TLS setup reports `cleanup_unconfirmed`: OTP does not return a TLS socket exposing the receiver/sender processes whose termination the barrier would need to confirm. Relayixir preserves that result and retains the aborted guard/controller until the configured request deadline plus its one-second cleanup allowance. Their eventual termination does not upgrade the missing TLS cleanup evidence to success. Cancellation of an established, tracked TLS connection can still confirm cleanup.

Environment-selected HTTP proxies are supported, including CONNECT for HTTPS origins. HTTPS proxy endpoints for HTTP origins use TLS with certificate verification, authenticated absolute-form targets, and the existing NO_PROXY policy. Failed proxy connections never switch to a direct origin request.

Fetch owns terminal upload cleanup, including preconnect failures and early responses. RequestGuard retains only caller-lifetime cancellation and caller-owned upload tracking; the Promise-monitor workaround for #70 has been removed.

WebSocket uses the public proxy frame API with automatic Pong disabled, acknowledged incoming frames, and local write completion before Close. Mint and Mint.WebSocket remain test-only clients.

See [`docs/design.md`](docs/design.md) for the historical architecture draft.

## License

MIT
