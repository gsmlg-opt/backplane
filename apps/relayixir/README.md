# Relayixir

An Elixir-native HTTP/WebSocket reverse proxy built on Bandit + Plug + Mint + Mint.WebSocket.

Upstream source: [gsmlg-dev/relayixir](https://github.com/gsmlg-dev/relayixir)

## Role in Backplane

Relayixir is included as an umbrella app in the Backplane project. It provides reverse proxy capabilities for forwarding HTTP and WebSocket requests to upstream MCP API services.

Bandit standalone server is disabled (`config :relayixir, start_server: false`). Backplane uses Relayixir as a library — calling `Relayixir.Router` as a Plug or using its proxy modules directly, and configuring routes at runtime via `Relayixir.load/1`.

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
Client -> Router -> HttpPlug -> HttpClient (Mint) -> Upstream
```

**WebSocket** (bidirectional, long-lived):
```
Client -> Router -> WebSocket.Plug -> Bridge (GenServer) -> UpstreamClient (Mint.WebSocket) -> Upstream
```

See [`docs/design.md`](docs/design.md) for the full architecture document.

## License

MIT
