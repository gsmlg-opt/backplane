# Deploying Backplane behind Caddy

Backplane exposes a **streaming** MCP endpoint (`GET /api/mcp` / `GET /mcp` is a
long-lived `text/event-stream`). Reverse proxies that pool and reuse upstream
HTTP/1.1 connections must be configured with that in mind, otherwise a streaming
response can pin or poison a pooled connection and make the *next* request to the
backend hang.

## Recommended reverse_proxy block

```caddyfile
backplane.example.net {
	# MCP endpoint is a Server-Sent Events stream — flush every write
	# immediately and never buffer the response.
	@mcp path /mcp /mcp/* /api/mcp /api/mcp/*
	reverse_proxy @mcp 127.0.0.1:4100 {
		flush_interval -1
	}

	# Everything else (admin UI, LLM proxy, REST APIs)
	reverse_proxy 127.0.0.1:4100
}
```

- `flush_interval -1` disables response buffering for the SSE route so events
  reach the client as soon as Backplane writes them.
- Keep the MCP matcher first so the streaming settings only apply there.

## Why this matters (the HEAD-then-POST hang)

A `HEAD /mcp` matches the SSE `GET` route. The client (`curl -I`) returns as soon
as it has the response headers, but a buggy/old server build keeps streaming the
body forever. Caddy then returns that still-busy upstream connection to its pool
and reuses it for the next request (e.g. a `POST /mcp`), which blocks until it
times out.

The backend side of this is fixed in `Backplane.Api.Endpoint`: a `HEAD` to the MCP
path is answered with `204 No Content` *before* `Plug.Head` rewrites it to a `GET`
(which would otherwise reach the SSE handler and stream forever). The SSE loop also
probes the connection on open so a vanished peer is detected immediately. The
`flush_interval -1` setting above is the matching proxy-side hardening.

If you ever see a `POST /mcp` hang only after a preceding `HEAD`/`GET` to the same
endpoint, you are almost certainly running a backend build from before the HEAD
short-circuit — redeploy the current `main`.
