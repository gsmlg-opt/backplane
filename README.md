# Relayixir

[![Test](https://github.com/gsmlg-dev/relayixir/actions/workflows/test.yml/badge.svg)](https://github.com/gsmlg-dev/relayixir/actions/workflows/test.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/relayixir.svg)](https://hex.pm/packages/relayixir)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/relayixir)

An Elixir-native HTTP/WebSocket reverse proxy built on Bandit + Plug + Mint + Mint.WebSocket.

## Features

- **HTTP Reverse Proxy** — streaming response forwarding with correct chunked/content-length handling
- **WebSocket Proxy** — full bidirectional relay with explicit state machine and close semantics
- **Protocol-Aware Headers** — hop-by-hop stripping, x-forwarded-* injection, configurable host forwarding
- **Route Policy** — per-route allowed methods, request header injection, body size limits
- **Connection Pooling** — optional per-upstream idle connection reuse
- **Dump Hooks** — optional callbacks for request/response inspection and WebSocket frame capture
- **Telemetry** — structured events for request lifecycle, upstream connections, and WebSocket sessions
- **OTP Supervision** — WebSocket bridges under DynamicSupervisor with temporary restart strategy

## Requirements

- Elixir >= 1.18
- Erlang/OTP >= 27

## Installation

Add `relayixir` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:relayixir, "~> 0.1.0"}
  ]
end
```

## Usage

### Basic Configuration

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

### WebSocket Routes

Enable WebSocket proxying on a route:

```elixir
Relayixir.load(
  routes: [
    %{
      host_match: "*",
      path_prefix: "/ws",
      upstream_name: "realtime",
      websocket: true
    }
  ],
  upstreams: %{
    "realtime" => %{scheme: :http, host: "localhost", port: 4002}
  }
)
```

### Connection Pooling

Enable per-upstream connection reuse by setting `pool_size`:

```elixir
upstreams: %{
  "backend" => %{
    scheme: :http,
    host: "localhost",
    port: 4001,
    pool_size: 10
  }
}
```

### Dump Hooks

Attach optional inspection callbacks:

```elixir
Relayixir.load(
  routes: [...],
  upstreams: %{...},
  hooks: [
    on_request_complete: fn request, response ->
      Logger.info("#{request.method} #{request.path} → #{response.status}")
    end,
    on_ws_frame: fn session_id, direction, frame ->
      Logger.debug("WS #{session_id} #{direction}: #{inspect(frame)}")
    end
  ]
)
```

### Application Environment

Alternatively, configure via `Application.put_env/3` and call `Relayixir.reload/0`:

```elixir
# config/runtime.exs
config :relayixir,
  routes: [
    %{host_match: "*", path_prefix: "/", upstream_name: "app"}
  ],
  upstreams: %{
    "app" => %{scheme: :http, host: "localhost", port: 3000}
  }
```

### Upstream Options

| Option | Default | Description |
|--------|---------|-------------|
| `scheme` | `:http` | `:http` or `:https` |
| `host` | required | Upstream hostname |
| `port` | required | Upstream port |
| `path_prefix_rewrite` | `nil` | Rewrite path prefix on forwarded requests |
| `pool_size` | `nil` | Connection pool size (nil = no pooling, one conn per request) |
| `max_request_body_size` | `8_388_608` | Max request body size in bytes (8 MB) |
| `max_response_body_size` | `10_485_760` | Max response body size in bytes (10 MB) |

### Route Options

| Option | Default | Description |
|--------|---------|-------------|
| `host_match` | required | Host pattern to match (`"*"` for all) |
| `path_prefix` | required | URL path prefix to match |
| `upstream_name` | required | Name of the upstream to forward to |
| `websocket` | `false` | Enable WebSocket upgrade detection |
| `host_forward_mode` | `:preserve` | `:preserve`, `:rewrite_to_upstream`, or `:route_defined` |
| `allowed_methods` | `nil` | List of allowed HTTP methods (nil = all) |
| `inject_request_headers` | `[]` | Extra headers to add to forwarded requests |
| `timeouts` | `%{}` | Per-route timeout overrides |

## Architecture

Relayixir implements two separate proxy paths:

**HTTP** (request/response):
```
Client → Bandit → Router → HttpPlug → HttpClient (Mint) → Upstream
```

**WebSocket** (bidirectional, long-lived):
```
Client → Bandit → Router → WebSocket.Plug → Bridge (GenServer) → UpstreamClient (Mint.WebSocket) → Upstream
```

See [`docs/design.md`](docs/design.md) for the full architecture document.

## Development

```bash
mix deps.get    # Install dependencies
mix compile     # Compile
mix test        # Run tests
mix format      # Format code
```

## License

MIT
